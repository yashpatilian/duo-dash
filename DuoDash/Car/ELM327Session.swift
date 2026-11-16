import Foundation

/// What `0100` found.
enum OBDDetection: Equatable {
    /// The car's computer answered: its protocol and every PID it says it supports.
    case connected(protocolName: String, supportedPIDs: Set<UInt8>)
    /// The adapter works but nothing answered generic OBD-II requests.
    case noECU(ELMStatus)
}

enum OBDReading: Equatable {
    case value(Double)
    case unavailable(ELMStatus)
}

/// Talks ELM327 over any `OBDTransport`. Commands are queued, so polling, a manual
/// trouble-code check and Clear codes never overlap on the adapter.
@MainActor
final class ELM327Session {
    let transport: OBDTransport
    /// "ELM327 v1.5" (or whatever the adapter says to ATZ / ATI).
    private(set) var adapterVersion: String?
    /// Pause after ATZ: clones can take a moment before accepting the next command.
    var resetPause: Duration = .milliseconds(300)

    nonisolated static let atTimeout: Duration = .seconds(2)
    nonisolated static let resetTimeout: Duration = .seconds(5)
    /// `0100` with automatic protocol search tries each protocol in turn.
    nonisolated static let searchTimeout: Duration = .seconds(12)
    nonisolated static let pidTimeout: Duration = .seconds(2)
    nonisolated static let diagnosticsTimeout: Duration = .seconds(6)

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(transport: OBDTransport) {
        self.transport = transport
    }

    /// Sends one command once the adapter is free and parses the reply.
    func command(_ text: String, timeout: Duration = ELM327Session.atTimeout) async throws -> ELMResponse {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let raw = try await transport.send(text, timeout: timeout)
        return ELMParser.parse(raw, command: text)
    }

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: Set-up

    /// Reset, then echo off, linefeeds off, spaces off, headers off, automatic protocol.
    func initialise() async throws {
        let reset: ELMResponse
        do {
            reset = try await command("ATZ", timeout: Self.resetTimeout)
        } catch OBDError.timeout {
            // A few clones never answer ATZ; ATI proves the adapter is there.
            reset = try await command("ATI", timeout: Self.resetTimeout)
        }
        if resetPause > .zero { try await Task.sleep(for: resetPause) }
        adapterVersion = reset.lines.first { $0.uppercased().contains("ELM") || $0.uppercased().contains("STN") }
            ?? reset.lines.last
        for setting in ["ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"] {
            _ = try await command(setting)
        }
    }

    /// Sends `0100` (which starts the protocol search) and reads the supported-PID bitmaps.
    func detectVehicle() async throws -> OBDDetection {
        let first = try await command("0100", timeout: Self.searchTimeout)
        let bitmaps = first.payloads(mode: 0x41, pid: 0x00)
        guard first.status == .ok, !bitmaps.isEmpty else {
            return .noECU(first.status == .ok ? .noData : first.status)
        }
        // Several ECUs (engine, gearbox) may answer: a PID is supported if any says so.
        var supported = Set<UInt8>()
        for bitmap in bitmaps { supported.formUnion(OBDSupport.decode(bitmap, base: 0x00)) }
        for base: UInt8 in [0x20, 0x40] {
            guard supported.contains(base) else { break }
            let reply = try await command(String(format: "01%02X", UInt32(base)), timeout: Self.pidTimeout)
            for bitmap in reply.payloads(mode: 0x41, pid: base) {
                supported.formUnion(OBDSupport.decode(bitmap, base: base))
            }
        }
        let description = try? await command("ATDP")
        return .connected(protocolName: ELMParser.protocolName(from: description?.lines ?? []),
                          supportedPIDs: supported)
    }

    // MARK: Values

    func read(_ pid: OBDPID) async throws -> OBDReading {
        let reply = try await command(pid.command, timeout: Self.pidTimeout)
        guard reply.status == .ok else { return .unavailable(reply.status) }
        for payload in reply.payloads(mode: 0x41, pid: pid.rawValue) {
            if let value = pid.decode(payload) { return .value(value) }
        }
        return .unavailable(.noData)
    }

    /// The adapter's own reading of the OBD port's 12 V pin. Works on any car.
    func readBatteryVoltage() async throws -> Double? {
        ELMParser.voltage(in: try await command("ATRV").lines)
    }

    // MARK: Diagnostics

    /// Mode 03 (stored) or 07 (pending). Nil when the car didn't answer.
    func readTroubleCodes(pending: Bool) async throws -> [DTC]? {
        let reply = try await command(pending ? "07" : "03", timeout: Self.diagnosticsTimeout)
        switch reply.status {
        case .ok:
            return DTC.codes(fromPayloads: reply.payloads(mode: pending ? 0x47 : 0x43), pending: pending)
        case .noData:
            return []   // some cars answer NO DATA when there's nothing stored
        default:
            return nil
        }
    }

    /// Mode 04: clears stored codes, freeze frame and readiness monitors.
    func clearTroubleCodes() async throws -> Bool {
        let reply = try await command("04", timeout: Self.diagnosticsTimeout)
        return reply.status == .ok && !reply.payloads(mode: 0x44).isEmpty
    }
}
