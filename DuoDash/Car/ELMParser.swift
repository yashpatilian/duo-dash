import Foundation

/// What an ELM327 reply amounts to.
enum ELMStatus: Equatable {
    case ok
    case noData
    case unableToConnect
    /// `?`: the adapter didn't understand the command.
    case unknownCommand
    case stopped
    case busInitError
    case canError
    case bufferFull
    case error(String)

    /// The car's computer didn't answer, or the bus to it couldn't be started.
    var isNoResponse: Bool {
        switch self {
        case .noData, .unableToConnect, .busInitError, .canError, .stopped: true
        default: false
        }
    }
}

/// A cleaned-up reply: echo, prompt, `SEARCHING...` and bus-init chatter removed.
struct ELMResponse: Equatable {
    var lines: [String]
    var status: ELMStatus

    /// One byte array per ECU message (multi-frame replies joined).
    var messages: [[UInt8]] { ELMParser.messages(in: lines) }

    /// The data after `mode` (+ `pid`) in each message, e.g. mode 0x41 pid 0x0C.
    func payloads(mode: UInt8, pid: UInt8? = nil) -> [[UInt8]] {
        ELMParser.payloads(in: messages, mode: mode, pid: pid)
    }
}

/// Pure functions that turn ELM327 text into bytes. Works with spaces on or off,
/// echo on or off, headers on or off, single or several ECUs, single or multi-frame.
enum ELMParser {
    static func parse(_ raw: [String], command: String) -> ELMResponse {
        let echo = compact(command)
        var lines: [String] = []
        var status: ELMStatus?
        for rawLine in raw {
            let line = rawLine.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            let c = compact(line)
            if c.isEmpty || (!echo.isEmpty && c == echo) { continue }
            if c.hasPrefix("SEARCHING") { continue }
            if c.hasPrefix("BUSINIT") {
                if c.contains("ERROR") { status = status ?? .busInitError }
                continue
            }
            if let error = errorStatus(c, line: line) {
                status = status ?? error
                continue
            }
            lines.append(line)
        }
        return ELMResponse(lines: lines, status: lines.isEmpty ? (status ?? .noData) : .ok)
    }

    /// Upper case with spaces removed.
    static func compact(_ text: String) -> String {
        text.uppercased().filter { $0 != " " && $0 != "\t" }
    }

    static func isHex<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.allSatisfy(\.isHexDigit)
    }

    private static func errorStatus(_ c: String, line: String) -> ELMStatus? {
        switch c {
        case "NODATA": return .noData
        case "UNABLETOCONNECT": return .unableToConnect
        case "?": return .unknownCommand
        case "STOPPED": return .stopped
        case "CANERROR": return .canError
        case "BUFFERFULL": return .bufferFull
        default:
            let prefixes = ["ERR", "BUSERROR", "BUSBUSY", "FBERROR", "DATAERROR", "<DATAERROR", "<RXERROR",
                            "ACTALERT", "LVRESET", "LPALERT"]
            return prefixes.contains(where: c.hasPrefix) ? .error(line) : nil
        }
    }

    /// Bytes in one line of hex. Odd-length tokens (11-bit CAN headers such as `7E8`)
    /// are skipped when spaces are on, and dropped from the front when they are off.
    static func bytes(fromHexLine line: String) -> [UInt8]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(" ") {
            let tokens = trimmed.split(separator: " ")
            guard tokens.allSatisfy({ isHex($0) }) else { return nil }
            return tokens.filter { $0.count == 2 }.compactMap { UInt8($0, radix: 16) }
        }
        guard isHex(trimmed) else { return nil }
        var hex = Substring(trimmed)
        if hex.count % 2 == 1 {
            guard hex.count > 3 else { return nil }
            hex = hex.dropFirst(3)
        }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    /// Groups lines into messages. ISO 15765 multi-frame replies (headers off) look like
    /// `00A` / `0: 43 04 01 33 01 34` / `1: 01 35 01 36 00 00`; they're joined and trimmed
    /// to the stated length. Every other hex line is a message of its own (one per ECU).
    static func messages(in lines: [String]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var current: [UInt8]?
        var expected: Int?
        func flush() {
            if let frame = current {
                result.append(expected.map { Array(frame.prefix($0)) } ?? frame)
            }
            current = nil
            expected = nil
        }
        for line in lines {
            let c = compact(line)
            if c.count == 3, isHex(c) {
                flush()
                current = []
                expected = Int(c, radix: 16)
                continue
            }
            let parts = c.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].count == 1, isHex(parts[0]) {
                if current == nil { current = [] }
                current?.append(contentsOf: bytes(fromHexLine: String(parts[1])) ?? [])
                continue
            }
            flush()
            if let bytes = bytes(fromHexLine: line), !bytes.isEmpty { result.append(bytes) }
        }
        flush()
        return result
    }

    /// The bytes after the `[mode, pid]` header in each message that has one.
    static func payloads(in messages: [[UInt8]], mode: UInt8, pid: UInt8?) -> [[UInt8]] {
        let header = pid.map { [mode, $0] } ?? [mode]
        return messages.compactMap { message in
            guard message.count >= header.count else { return nil }
            for start in 0...(message.count - header.count)
            where Array(message[start..<start + header.count]) == header {
                return Array(message[(start + header.count)...])
            }
            return nil
        }
    }

    /// `ATRV` replies like `12.6V`, `12.6 V` or `12.6`.
    static func voltage(in lines: [String]) -> Double? {
        for line in lines {
            var number = ""
            for character in line.uppercased() {
                if character.isNumber || (character == "." && !number.isEmpty) {
                    number.append(character)
                } else if !number.isEmpty {
                    break
                }
            }
            if let value = Double(number), (0...40).contains(value) { return value }
        }
        return nil
    }

    /// "ISO 15765-4 (CAN 11/500)" from `ATDP`'s "AUTO, ISO 15765-4 (CAN 11/500)".
    static func protocolName(from lines: [String]) -> String {
        guard var name = lines.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "OBD-II" }
        if name.uppercased().hasPrefix("AUTO,") { name = String(name.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        return name.uppercased() == "AUTO" || name.isEmpty ? "OBD-II" : name
    }
}
