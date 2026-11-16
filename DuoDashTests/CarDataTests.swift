import XCTest
@testable import DuoDash

/// ELM327 parsing, PID maths, DTCs, the session against the simulated adapter, the
/// no-ECU path and the poll scheduler. Offline and fast (the demo runs with no latency).
@MainActor
final class CarDataTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 4, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func demoTransport(_ profile: DemoELM327.Profile = .standard, at time: TimeInterval = 2,
                               remembered: Bool = true) -> DemoOBDTransport {
        let elm = DemoELM327(profile: profile, elapsed: { time })
        return DemoOBDTransport(elm: elm, latency: .zero, connectDelay: .zero, remembered: remembered)
    }

    private func readyTransport(_ profile: DemoELM327.Profile = .standard) async -> DemoOBDTransport {
        let transport = demoTransport(profile)
        transport.start()
        await waitUntil { if case .ready = transport.linkState { true } else { false } }
        return transport
    }

    // MARK: Response parsing

    func testParseStripsEchoPromptAndSearching() {
        let r = ELMParser.parse(["0100", "SEARCHING...", "41 00 BE 1F A8 13", ">"], command: "0100")
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.lines, ["41 00 BE 1F A8 13"])
        XCTAssertEqual(r.payloads(mode: 0x41, pid: 0x00), [[0xBE, 0x1F, 0xA8, 0x13]])
    }

    func testParseWithAndWithoutSpaces() {
        let spaced = ELMParser.parse(["41 0C 1A F8"], command: "010C")
        let packed = ELMParser.parse(["410C1AF8"], command: "010C")
        XCTAssertEqual(spaced.payloads(mode: 0x41, pid: 0x0C), [[0x1A, 0xF8]])
        XCTAssertEqual(packed.payloads(mode: 0x41, pid: 0x0C), [[0x1A, 0xF8]])
        // Echo without spaces, reply with lower-case hex.
        let echoed = ELMParser.parse(["01 0c", "410c1af8"], command: "010C")
        XCTAssertEqual(echoed.payloads(mode: 0x41, pid: 0x0C), [[0x1A, 0xF8]])
    }

    func testParseHeadersAreSkipped() {
        XCTAssertEqual(ELMParser.parse(["7E8 04 41 0C 1A F8"], command: "010C").payloads(mode: 0x41, pid: 0x0C),
                       [[0x1A, 0xF8]])
        XCTAssertEqual(ELMParser.parse(["7E804410C1AF8"], command: "010C").payloads(mode: 0x41, pid: 0x0C),
                       [[0x1A, 0xF8]])
    }

    func testMultiECUReplies() {
        let r = ELMParser.parse(["41 00 BE 3E B8 11", "41 00 98 18 00 01"], command: "0100")
        let maps = r.payloads(mode: 0x41, pid: 0x00)
        XCTAssertEqual(maps.count, 2)
        var union = Set<UInt8>()
        for map in maps { union.formUnion(OBDSupport.decode(map, base: 0)) }
        XCTAssertTrue(union.contains(0x20))
        XCTAssertTrue(union.contains(0x0C))
    }

    func testMultiFrameReply() {
        let lines = ["00A", "0: 43 04 01 33 01 34", "1: 01 35 01 36 00 00"]
        let r = ELMParser.parse(lines, command: "03")
        XCTAssertEqual(r.messages, [[0x43, 0x04, 0x01, 0x33, 0x01, 0x34, 0x01, 0x35, 0x01, 0x36]])
        XCTAssertEqual(DTC.codes(fromPayloads: r.payloads(mode: 0x43)).map(\.code), ["P0133", "P0134", "P0135", "P0136"])
        let packed = ELMParser.parse(["00A", "0:430401330134", "1:013501360000"], command: "03")
        XCTAssertEqual(packed.messages, r.messages)
    }

    func testStatuses() {
        XCTAssertEqual(ELMParser.parse(["NO DATA"], command: "010C").status, .noData)
        XCTAssertEqual(ELMParser.parse(["NODATA"], command: "010C").status, .noData)
        XCTAssertEqual(ELMParser.parse(["?"], command: "01").status, .unknownCommand)
        XCTAssertEqual(ELMParser.parse(["SEARCHING...", "UNABLE TO CONNECT"], command: "0100").status, .unableToConnect)
        XCTAssertEqual(ELMParser.parse(["STOPPED"], command: "0100").status, .stopped)
        XCTAssertEqual(ELMParser.parse(["BUS INIT: ...ERROR"], command: "0100").status, .busInitError)
        XCTAssertEqual(ELMParser.parse(["CAN ERROR"], command: "0100").status, .canError)
        XCTAssertEqual(ELMParser.parse([], command: "0100").status, .noData)
        XCTAssertEqual(ELMParser.parse(["0100"], command: "0100").status, .noData, "echo alone is not data")
        let ok = ELMParser.parse(["BUS INIT: ...OK", "41 00 BE 1F A8 13"], command: "0100")
        XCTAssertEqual(ok.status, .ok)
        XCTAssertEqual(ok.lines.count, 1)
        XCTAssertTrue(ELMStatus.unableToConnect.isNoResponse)
        XCTAssertFalse(ELMStatus.unknownCommand.isNoResponse)
    }

    func testReceiveBufferAssemblesChunks() {
        var buffer = ELMReceiveBuffer()
        XCTAssertNil(buffer.append("41 0C 1A"))
        XCTAssertNil(buffer.append(" F8\r\n41 0C"))
        XCTAssertEqual(buffer.append(" 1B 00\r\r>"), ["41 0C 1A F8", "41 0C 1B 00"])
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(buffer.append(Data("OK\r\0\r>".utf8)), ["OK"])
    }

    // MARK: Supported PIDs

    func testSupportedBitmapDecoding() {
        // The classic example: BE 1F A8 13.
        let pids = OBDSupport.decode([0xBE, 0x1F, 0xA8, 0x13], base: 0x00)
        XCTAssertEqual(pids, [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13,
                              0x15, 0x1C, 0x1F, 0x20])
        XCTAssertEqual(OBDSupport.decode([0x00, 0x02, 0x00, 0x01], base: 0x20), [0x2F, 0x40])
        XCTAssertEqual(OBDSupport.decode([0x40, 0x00, 0x00, 0x00], base: 0x40), [0x42])
        XCTAssertEqual(OBDSupport.decode([0x00, 0x00, 0x00, 0x10], base: 0x40), [0x5C])
        let set: Set<UInt8> = [0x04, 0x0C, 0x0D, 0x20]
        XCTAssertEqual(OBDSupport.decode(OBDSupport.encode(set, base: 0), base: 0), set)
    }

    // MARK: PID formulas

    func testPIDFormulas() throws {
        XCTAssertEqual(OBDPID.rpm.decode([0x1A, 0xF8]), 1726)
        XCTAssertEqual(OBDPID.speed.decode([0x50]), 80)
        XCTAssertEqual(OBDPID.coolantTemp.decode([0x7B]), 83)
        XCTAssertEqual(OBDPID.intakeTemp.decode([0x28]), 0)
        XCTAssertEqual(OBDPID.oilTemp.decode([0x96]), 110)
        XCTAssertEqual(OBDPID.throttle.decode([0xFF]), 100)
        XCTAssertEqual(try XCTUnwrap(OBDPID.engineLoad.decode([0x80])), 50.2, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(OBDPID.fuelLevel.decode([0x40])), 25.1, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(OBDPID.moduleVoltage.decode([0x37, 0x6E])), 14.19, accuracy: 0.001)
        XCTAssertNil(OBDPID.rpm.decode([0x1A]), "too short")
        XCTAssertEqual(OBDPID.rpm.command, "010C")
        XCTAssertEqual(OBDPID.oilTemp.command, "015C")
        XCTAssertEqual(OBDPID.moduleVoltage.format(14.19), "14.2")
        XCTAssertEqual(OBDPID.rpm.format(1726.4), "1726")
    }

    func testBatteryVoltageParsing() {
        XCTAssertEqual(ELMParser.voltage(in: ["12.6V"]), 12.6)
        XCTAssertEqual(ELMParser.voltage(in: ["12.6 V"]), 12.6)
        XCTAssertEqual(ELMParser.voltage(in: ["14.1"]), 14.1)
        XCTAssertNil(ELMParser.voltage(in: ["?"]))
        XCTAssertNil(ELMParser.voltage(in: []))
        XCTAssertEqual(ELMParser.parse(["ATRV", "12.4V"], command: "ATRV").lines, ["12.4V"])
    }

    // MARK: DTCs

    func testDTCDecoding() {
        XCTAssertEqual(DTC.decode(0x01, 0x33), "P0133")
        XCTAssertEqual(DTC.decode(0x04, 0x20), "P0420")
        XCTAssertEqual(DTC.decode(0x14, 0x20), "P1420")
        XCTAssertEqual(DTC.decode(0x41, 0x23), "C0123")
        XCTAssertEqual(DTC.decode(0x81, 0x00), "B0100")
        XCTAssertEqual(DTC.decode(0xC1, 0x55), "U0155")
        XCTAssertEqual(DTC(code: "P0420").description, "Catalytic converter efficiency below threshold (bank 1)")
        XCTAssertTrue(DTC(code: "P1457").description.contains("Manufacturer"))
        XCTAssertTrue(DTC(code: "U0100").description.contains("Network"))
        XCTAssertGreaterThanOrEqual(DTC.descriptions.count, 80)
    }

    func testDTCPayloadFormats() {
        // CAN: count byte first.
        XCTAssertEqual(DTC.codes(fromPayloads: [[0x01, 0x04, 0x20]]).map(\.code), ["P0420"])
        XCTAssertEqual(DTC.codes(fromPayloads: [[0x00]]), [])
        // Older protocols: three pairs per line, zero padded, several lines.
        let legacy: [[UInt8]] = [[0x01, 0x33, 0x00, 0x00, 0x00, 0x00], [0x03, 0x00, 0x01, 0x33, 0x00, 0x00]]
        XCTAssertEqual(DTC.codes(fromPayloads: legacy).map(\.code), ["P0133", "P0300"], "duplicates collapse")
        XCTAssertTrue(DTC.codes(fromPayloads: [[0x01, 0x04, 0x20]], pending: true)[0].isPending)
    }

    // MARK: BLE helpers

    func testCharacteristicPicker() {
        let vgate = [
            BLECharacteristicInfo(service: "180A", uuid: "2A29", canWrite: false, canWriteWithoutResponse: false, canNotify: false),
            BLECharacteristicInfo(service: "FFF0", uuid: "FFF1", canWrite: false, canWriteWithoutResponse: false, canNotify: true),
            BLECharacteristicInfo(service: "FFF0", uuid: "FFF2", canWrite: true, canWriteWithoutResponse: true, canNotify: false),
        ]
        XCTAssertEqual(BLECharacteristicPicker.pick(vgate)?.write, 2)
        XCTAssertEqual(BLECharacteristicPicker.pick(vgate)?.notify, 1)

        let hm10 = [BLECharacteristicInfo(service: "0000FFE0-0000-1000-8000-00805F9B34FB", uuid: "FFE1",
                                          canWrite: false, canWriteWithoutResponse: true, canNotify: true)]
        XCTAssertEqual(BLECharacteristicPicker.pick(hm10)?.write, 0)
        XCTAssertEqual(BLECharacteristicPicker.pick(hm10)?.notify, 0)

        let obdlink = [
            BLECharacteristicInfo(service: "18F0", uuid: "2AF0", canWrite: false, canWriteWithoutResponse: false, canNotify: true),
            BLECharacteristicInfo(service: "18F0", uuid: "2AF1", canWrite: true, canWriteWithoutResponse: true, canNotify: false),
        ]
        XCTAssertEqual(BLECharacteristicPicker.pick(obdlink)?.write, 1)

        let unknown = [
            BLECharacteristicInfo(service: "1800", uuid: "2A00", canWrite: true, canWriteWithoutResponse: false, canNotify: true),
            BLECharacteristicInfo(service: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", uuid: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F",
                                  canWrite: true, canWriteWithoutResponse: true, canNotify: true),
        ]
        XCTAssertEqual(BLECharacteristicPicker.pick(unknown)?.write, 1, "skips the GAP service")
        XCTAssertNil(BLECharacteristicPicker.pick([]))
    }

    func testAdapterRanking() {
        XCTAssertTrue(OBDAdapter.isLikelyOBD(name: "Vgate iCar Pro", services: []))
        XCTAssertTrue(OBDAdapter.isLikelyOBD(name: "IOS-Vlink", services: []))
        XCTAssertTrue(OBDAdapter.isLikelyOBD(name: nil, services: ["FFF0"]))
        XCTAssertFalse(OBDAdapter.isLikelyOBD(name: "AirPods", services: ["180F"]))
        let ranked = OBDAdapter.ranked([
            OBDAdapter(id: UUID(), name: "AirPods", rssi: -40, isLikelyOBD: false),
            OBDAdapter(id: UUID(), name: "OBDII", rssi: -80, isLikelyOBD: true),
        ])
        XCTAssertEqual(ranked.first?.name, "OBDII")
    }

    // MARK: Session against the simulated adapter

    func testSessionInitialisesAndDetectsAgainstDemo() async throws {
        let transport = await readyTransport()
        let session = ELM327Session(transport: transport)
        session.resetPause = .zero
        try await session.initialise()
        XCTAssertEqual(session.adapterVersion, "ELM327 v1.5")
        XCTAssertEqual(Array(transport.sentCommands.prefix(6)), ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"])

        let detection = try await session.detectVehicle()
        guard case .connected(let name, let pids) = detection else { return XCTFail("\(detection)") }
        XCTAssertEqual(name, "ISO 15765-4 (CAN 11/500)")
        for pid in [OBDPID.rpm, .speed, .coolantTemp, .intakeTemp, .throttle, .engineLoad, .fuelLevel, .moduleVoltage] {
            XCTAssertTrue(pids.contains(pid.rawValue), "\(pid)")
        }
        XCTAssertFalse(pids.contains(OBDPID.oilTemp.rawValue))
        XCTAssertTrue(transport.sentCommands.contains("0120"))
        XCTAssertTrue(transport.sentCommands.contains("0140"))

        // Idle at t = 2 s.
        guard case .value(let rpm) = try await session.read(.rpm) else { return XCTFail() }
        XCTAssertEqual(rpm, 820, accuracy: 30)
        let speed = try await session.read(.speed)
        XCTAssertEqual(speed, .value(0))
        let oil = try await session.read(.oilTemp)
        XCTAssertEqual(oil, .unavailable(.noData))
        let battery = try await session.readBatteryVoltage()
        XCTAssertEqual(try XCTUnwrap(battery), 14.2, accuracy: 0.1)

        let stored = try await session.readTroubleCodes(pending: false)
        XCTAssertEqual(stored?.map(\.code), ["P0420"])
        let pending = try await session.readTroubleCodes(pending: true)
        XCTAssertEqual(pending, [])
        let cleared = try await session.clearTroubleCodes()
        XCTAssertTrue(cleared)
        let after = try await session.readTroubleCodes(pending: false)
        XCTAssertEqual(after, [])
    }

    func testSessionNoECUPath() async throws {
        let transport = await readyTransport(.noECU)
        let session = ELM327Session(transport: transport)
        session.resetPause = .zero
        try await session.initialise()
        let detection = try await session.detectVehicle()
        XCTAssertEqual(detection, .noECU(.unableToConnect))
        let battery = try await session.readBatteryVoltage()
        XCTAssertEqual(try XCTUnwrap(battery), 12.4, accuracy: 0.1)
        let codes = try await session.readTroubleCodes(pending: false)
        XCTAssertNil(codes)
    }

    func testDemoCarDrives() {
        let idle = DemoELM327.snapshot(at: 3)
        XCTAssertEqual(idle.speed, 0)
        let cruising = DemoELM327.snapshot(at: 8 + 20)
        XCTAssertEqual(cruising.speed, 80, accuracy: 3)
        XCTAssertGreaterThan(cruising.rpm, 2000)
        XCTAssertEqual(DemoELM327.snapshot(at: 300).coolant, 88)
    }

    // MARK: Model

    func testModelConnectsPollsAndClearsCodesWhenParked() async {
        var time: TimeInterval = 2
        let elm = DemoELM327(elapsed: { time })
        let transport = DemoOBDTransport(elm: elm, latency: .zero, connectDelay: .zero)
        let model = CarDataModel(transport: transport)
        XCTAssertEqual(model.state, .idle)
        model.start()
        await waitUntil { model.state.isConnected && model.value(.speed) != nil && model.value(.rpm) != nil }
        XCTAssertEqual(model.state, .connected(protocol: "ISO 15765-4 (CAN 11/500)"))
        XCTAssertEqual(model.adapterName, "OBDII")
        XCTAssertFalse(model.visiblePIDs.contains(.oilTemp), "unsupported PIDs stay hidden")
        XCTAssertEqual(model.visiblePIDs.first, .speed)
        XCTAssertEqual(model.storedCodes.map(\.code), ["P0420"])
        XCTAssertTrue(model.hasTroubleCodes)
        await waitUntil { model.batteryVoltage != nil }
        XCTAssertNotNil(model.batteryVoltage)

        // Driving: clearing is refused.
        time = 8 + 20
        await waitUntil { (model.value(.speed) ?? 0) > 0 }
        XCTAssertFalse(model.canClearCodes)
        XCTAssertEqual(model.clearCodesBlockedReason, "Stop the car to clear codes.")
        let refused = await model.clearCodes()
        XCTAssertFalse(refused)
        XCTAssertEqual(elm.storedCodes, [0x0420])

        // Parked again: allowed.
        time = 2
        await waitUntil { model.value(.speed) == 0 }
        XCTAssertTrue(model.canClearCodes)
        let cleared = await model.clearCodes()
        XCTAssertTrue(cleared)
        XCTAssertEqual(model.storedCodes, [])
        XCTAssertFalse(model.hasTroubleCodes)

        transport.simulateDisconnect()
        XCTAssertEqual(model.state, .searching)
        XCTAssertTrue(model.values.isEmpty)
        model.stop()
    }

    func testModelNoECUShowsBatteryOnly() async {
        let transport = demoTransport(.noECU)
        let model = CarDataModel(transport: transport)
        model.start()
        await waitUntil { if case .noECU = model.state { model.batteryVoltage != nil } else { false } }
        XCTAssertEqual(model.state, .noECU(message: CarDataModel.noECUMessage))
        XCTAssertTrue(model.visiblePIDs.isEmpty)
        XCTAssertEqual(try XCTUnwrap(model.batteryVoltage), 12.4, accuracy: 0.1)
        XCTAssertTrue(model.state.hasAdapter)
        XCTAssertFalse(model.canClearCodes)
        model.stop()
    }

    func testModelForgetAdapter() async {
        let transport = demoTransport()
        let model = CarDataModel(transport: transport)
        model.start()
        await waitUntil { model.state.isConnected }
        XCTAssertEqual(model.rememberedAdapterName, "OBDII")
        model.forgetAdapter()
        XCTAssertNil(model.rememberedAdapterName)
        XCTAssertEqual(model.state, .searching)
        XCTAssertEqual(model.adapters.map(\.name), ["OBDII"])
        model.connect(to: model.adapters[0])
        await waitUntil { model.state.isConnected }
        XCTAssertEqual(model.rememberedAdapterName, "OBDII")
        model.stop()
    }

    // MARK: Scheduler

    func testSchedulerIsFairAndKeepsRates() {
        let items: [CarPollItem] = OBDPID.displayOrder.map { .pid($0) } + [.battery]
        var scheduler = OBDPollScheduler(items: items, now: 0)
        var counts: [CarPollItem: Int] = [:]
        var clock: TimeInterval = 0
        let commandTime = 0.06   // a typical BLE adapter round trip
        while clock < 60 {
            if let item = scheduler.nextItem(now: clock) {
                clock += commandTime
                counts[item, default: 0] += 1
                scheduler.didPoll(item, at: clock)
            } else {
                clock += max(0.01, scheduler.timeUntilNextDue(now: clock))
            }
        }
        // Fast items about 4 Hz, slow items at their interval, nothing starved.
        XCTAssertGreaterThan(counts[.pid(.rpm)] ?? 0, 200)
        XCTAssertGreaterThan(counts[.pid(.speed)] ?? 0, 200)
        for item in items where item.interval > 1 {
            let expected = 60 / item.interval
            XCTAssertGreaterThanOrEqual(Double(counts[item] ?? 0), expected * 0.85, "\(item)")
            XCTAssertLessThanOrEqual(Double(counts[item] ?? 0), expected + 1, "\(item)")
        }
    }

    func testSchedulerSaturatedAdapterStillServesEveryone() {
        let items: [CarPollItem] = [.pid(.rpm), .pid(.speed), .pid(.coolantTemp), .pid(.fuelLevel), .battery]
        var scheduler = OBDPollScheduler(items: items, now: 0)
        var counts: [CarPollItem: Int] = [:]
        var clock: TimeInterval = 0
        while clock < 30 {   // a slow adapter: 400 ms per command, far slower than the schedule
            guard let item = scheduler.nextItem(now: clock) else {
                clock += scheduler.timeUntilNextDue(now: clock)
                continue
            }
            clock += 0.4
            counts[item, default: 0] += 1
            scheduler.didPoll(item, at: clock)
        }
        for item in items { XCTAssertGreaterThanOrEqual(counts[item] ?? 0, 5, "\(item) starved") }
        XCTAssertGreaterThan(counts[.pid(.rpm)] ?? 0, counts[.pid(.fuelLevel)] ?? 0)
    }

    func testSchedulerRemove() {
        var scheduler = OBDPollScheduler(items: [.pid(.rpm), .battery], now: 0)
        scheduler.remove(.pid(.rpm))
        XCTAssertEqual(scheduler.items, [.battery])
        XCTAssertEqual(scheduler.nextItem(now: 0), .battery)
    }
}
