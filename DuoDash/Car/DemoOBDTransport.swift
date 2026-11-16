import Foundation

/// A pretend ELM327 v1.5 plugged into a pretend car. It speaks the real text protocol
/// (echo, spaces, `SEARCHING...`, multi-ECU replies, `NO DATA`, `?`), so the parser and
/// session code run for real in the Simulator and in tests.
///
/// `.standard`: a 4-cylinder petrol on ISO 15765-4 CAN that idles for 8 s, then loops a
/// drive (accelerate to 80 km/h, cruise, brake, idle) every 60 s while warming up. It
/// doesn't support oil temperature (0x5C), so that tile stays hidden, and has P0420 stored.
/// `.noECU`: an adapter in a car whose computer ignores generic OBD-II (some JDM imports):
/// `ATRV` works, everything else is `UNABLE TO CONNECT`.
@MainActor
final class DemoELM327 {
    enum Profile { case standard, noECU }

    let profile: Profile
    /// Seconds since start; injectable so tests can put the car anywhere in its drive.
    var elapsed: () -> TimeInterval
    private(set) var storedCodes: [UInt16] = [0x0420]
    var pendingCodes: [UInt16] = []
    private(set) var commandCount = 0

    private var echo = true
    private var spaces = true
    private var linefeeds = true
    private var protocolFound = false

    static let enginePIDs: Set<UInt8> = [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
                                         0x11, 0x13, 0x1C, 0x20, 0x2F, 0x33, 0x40, 0x42]
    /// The gearbox ECU answers 0100 too (a second line), with a subset.
    static let transmissionPIDs: Set<UInt8> = [0x05, 0x0C, 0x0D]

    init(profile: Profile = .standard, elapsed: (() -> TimeInterval)? = nil) {
        self.profile = profile
        if let elapsed {
            self.elapsed = elapsed
        } else {
            let start = ProcessInfo.processInfo.systemUptime
            self.elapsed = { ProcessInfo.processInfo.systemUptime - start }
        }
    }

    /// The adapter's full reply, including the echo and the final `>` prompt.
    func respond(to command: String) -> String {
        commandCount += 1
        let compact = ELMParser.compact(command)
        var out: [String] = echo ? [command] : []
        out += reply(to: compact)
        let eol = linefeeds ? "\r\n" : "\r"
        return out.joined(separator: eol) + eol + eol + ">"
    }

    private func reply(to cmd: String) -> [String] {
        if cmd.hasPrefix("AT") { return atReply(String(cmd.dropFirst(2))) }
        guard cmd.count >= 2, cmd.count % 2 == 0, ELMParser.isHex(cmd),
              let bytes = ELMParser.bytes(fromHexLine: cmd) else { return ["?"] }
        let searching = protocolFound ? [] : ["SEARCHING..."]
        if profile == .noECU { return searching + ["UNABLE TO CONNECT"] }
        protocolFound = true
        switch (bytes[0], bytes.count) {
        case (0x01, 2): return searching + (mode01(bytes[1]) ?? ["NO DATA"])
        case (0x03, 1): return searching + [codesLine(0x43, storedCodes)]
        case (0x07, 1): return searching + [codesLine(0x47, pendingCodes)]
        case (0x04, 1):
            storedCodes = []
            pendingCodes = []
            return searching + [format([0x44])]
        default: return searching + ["NO DATA"]
        }
    }

    private func atReply(_ at: String) -> [String] {
        switch at {
        case "Z", "WS":
            echo = true
            spaces = true
            linefeeds = true
            protocolFound = false
            return ["", "ELM327 v1.5"]
        case "I": return ["ELM327 v1.5"]
        case "E0": echo = false
        case "E1": echo = true
        case "L0": linefeeds = false
        case "L1": linefeeds = true
        case "S0": spaces = false
        case "S1": spaces = true
        case "H0", "H1", "D", "AT0", "AT1", "AT2": break
        case "SP0", "SPA0": protocolFound = false
        case "RV": return [String(format: "%.1fV", car.battery)]
        case "DP":
            return profile == .standard && protocolFound ? ["AUTO, ISO 15765-4 (CAN 11/500)"] : ["AUTO"]
        case "DPN": return profile == .standard && protocolFound ? ["A6"] : ["A0"]
        default:
            if at.hasPrefix("ST") { break }
            return ["?"]
        }
        return ["OK"]
    }

    private func mode01(_ pid: UInt8) -> [String]? {
        switch pid {
        case 0x00:
            return [format([0x41, 0x00] + OBDSupport.encode(Self.enginePIDs, base: 0x00)),
                    format([0x41, 0x00] + OBDSupport.encode(Self.transmissionPIDs, base: 0x00))]
        case 0x20, 0x40:
            return [format([0x41, pid] + OBDSupport.encode(Self.enginePIDs, base: pid))]
        default:
            guard Self.enginePIDs.contains(pid), let data = encode(pid) else { return nil }
            return [format([0x41, pid] + data)]
        }
    }

    private func encode(_ pid: UInt8) -> [UInt8]? {
        let car = car
        func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
        func word(_ value: Double) -> [UInt8] {
            let raw = Int(max(0, min(65535, value.rounded())))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        }
        switch OBDPID(rawValue: pid) {
        case .engineLoad: return [byte(car.load * 255 / 100)]
        case .coolantTemp: return [byte(car.coolant + 40)]
        case .rpm: return word(car.rpm * 4)
        case .speed: return [byte(car.speed)]
        case .intakeTemp: return [byte(car.intake + 40)]
        case .throttle: return [byte(car.throttle * 255 / 100)]
        case .fuelLevel: return [byte(car.fuel * 255 / 100)]
        case .moduleVoltage: return word(car.battery * 1000 - 100)
        case .oilTemp: return nil
        case nil: return pid == 0x01 ? [0x00, 0x07, 0xE5, 0x00] : [0x80]   // PIDs the app doesn't show
        }
    }

    /// CAN style: count byte, then two bytes per code.
    private func codesLine(_ mode: UInt8, _ codes: [UInt16]) -> String {
        format([mode, UInt8(codes.count)] + codes.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
    }

    private func format(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", UInt32($0)) }.joined(separator: spaces ? " " : "")
    }

    // MARK: The car

    struct Snapshot {
        var rpm: Double, speed: Double, coolant: Double, intake: Double
        var throttle: Double, load: Double, fuel: Double, battery: Double
    }

    var car: Snapshot { Self.snapshot(at: elapsed(), engineRunning: profile == .standard) }

    static func snapshot(at t: TimeInterval, engineRunning: Bool = true) -> Snapshot {
        guard engineRunning else {
            return Snapshot(rpm: 0, speed: 0, coolant: 20, intake: 20, throttle: 0, load: 0, fuel: 60,
                            battery: 12.4 + 0.02 * sin(t))
        }
        let jitter = sin(t * 7) * 0.5
        var rpm = 820 + 15 * sin(t * 5), speed = 0.0, throttle = 14.0, load = 22.0
        if t >= 8 {
            let p = (t - 8).truncatingRemainder(dividingBy: 60)
            switch p {
            case ..<12:   // accelerate through the gears
                speed = 80 * p / 12
                rpm = 1300 + 3600 * (p / 4 - (p / 4).rounded(.down))
                throttle = 55
                load = 70
            case ..<32:   // cruise
                speed = 80 + 2 * sin(p)
                rpm = 2600 + 40 * sin(p * 3)
                throttle = 18
                load = 32
            case ..<42:   // brake to a stop
                let f = 1 - (p - 32) / 10
                speed = max(0, 80 * f)
                rpm = max(850, 2600 * f)
                throttle = 0
                load = 12
            default:
                break
            }
        }
        return Snapshot(rpm: max(0, rpm + jitter * 10), speed: max(0, speed.rounded()),
                        coolant: min(88, 35 + t * 0.8), intake: speed > 0 ? 26 : 31,
                        throttle: throttle, load: load + jitter, fuel: max(5, 62 - t / 600),
                        battery: 14.2 + 0.05 * sin(t))
    }
}

/// The Simulator's (and tests') stand-in for `BLEOBDTransport`: one adapter called
/// "OBDII", found shortly after `start()`, whose replies arrive in 20-byte chunks like
/// BLE notifications.
@MainActor
final class DemoOBDTransport: OBDTransport {
    static let adapterID = UUID(uuidString: "0BD00000-0000-4000-8000-00000000D0D0")!
    static let adapterName = "OBDII"

    let isDemo = true
    var onEvent: (@MainActor (OBDTransportEvent) -> Void)?
    private(set) var linkState: OBDLinkState = .idle {
        didSet { if linkState != oldValue { onEvent?(.link(linkState)) } }
    }
    private(set) var adapters: [OBDAdapter] = []
    private(set) var rememberedAdapterName: String?
    let elm: DemoELM327
    var latency: Duration
    var connectDelay: Duration
    private(set) var sentCommands: [String] = []
    private var buffer = ELMReceiveBuffer()
    private var connectTask: Task<Void, Never>?

    init(elm: DemoELM327? = nil, latency: Duration = .milliseconds(30),
         connectDelay: Duration = .milliseconds(500), remembered: Bool = true) {
        self.elm = elm ?? DemoELM327()
        self.latency = latency
        self.connectDelay = connectDelay
        rememberedAdapterName = remembered ? Self.adapterName : nil
    }

    private var adapter: OBDAdapter {
        OBDAdapter(id: Self.adapterID, name: Self.adapterName, rssi: -55, isLikelyOBD: true)
    }

    func start() {
        switch linkState {
        case .idle, .failed: break
        default: return
        }
        linkState = .searching
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: connectDelay)
            guard !Task.isCancelled, linkState == .searching else { return }
            scan()
            if rememberedAdapterName != nil { connect(to: Self.adapterID) }
        }
    }

    func stop() {
        connectTask?.cancel()
        linkState = .idle
    }

    func scan() {
        adapters = [adapter]
        onEvent?(.adapters(adapters))
    }

    func connect(to adapterID: UUID) {
        guard adapterID == Self.adapterID else { return }
        if case .ready = linkState { return }
        linkState = .connecting(Self.adapterName)
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: connectDelay)
            guard !Task.isCancelled, case .connecting = linkState else { return }
            rememberedAdapterName = Self.adapterName
            linkState = .ready(Self.adapterName)
        }
    }

    func forgetAdapter() {
        connectTask?.cancel()
        rememberedAdapterName = nil
        linkState = .searching
        scan()
    }

    /// The adapter was unplugged (tests).
    func simulateDisconnect() {
        connectTask?.cancel()
        linkState = .searching
    }

    func send(_ command: String, timeout: Duration) async throws -> [String] {
        guard case .ready = linkState else { throw OBDError.notConnected }
        sentCommands.append(command)
        if latency > .zero { try await Task.sleep(for: latency) }
        guard case .ready = linkState else { throw OBDError.disconnected }
        buffer.reset()
        let reply = Array(elm.respond(to: command))
        var lines: [String]?
        var index = 0
        while index < reply.count {
            let end = min(index + 20, reply.count)
            if let complete = buffer.append(String(reply[index..<end])) { lines = complete }
            index = end
        }
        guard let lines else { throw OBDError.timeout }
        return lines
    }
}
