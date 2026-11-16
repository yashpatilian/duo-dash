import Foundation

/// A Bluetooth LE OBD-II adapter seen while scanning.
struct OBDAdapter: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    /// Its name or advertised services look like an ELM327 adapter.
    var isLikelyOBD: Bool

    /// Name fragments used by common BLE ELM327 adapters (Vgate iCar Pro, Veepeak,
    /// OBDLink CX, Vlink and the many unbranded "OBDII" clones).
    static let nameHints = ["OBD", "ELM", "VGATE", "VEEPEAK", "OBDLINK", "IOS-VLINK", "VLINK", "ICAR"]
    /// Service UUIDs these adapters advertise or expose.
    static let serviceHints = ["FFF0", "FFE0", "18F0"]

    static func isLikelyOBD(name: String?, services: [String]) -> Bool {
        let upper = (name ?? "").uppercased()
        if nameHints.contains(where: { upper.contains($0) }) { return true }
        return services.map(BLECharacteristicPicker.shortUUID).contains(where: serviceHints.contains)
    }

    /// Likely adapters first, then the strongest signal, then by name.
    static func ranked(_ adapters: [OBDAdapter]) -> [OBDAdapter] {
        adapters.sorted {
            if $0.isLikelyOBD != $1.isLikelyOBD { return $0.isLikelyOBD }
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// The Bluetooth side of the connection, before any ELM327 talk.
enum OBDLinkState: Equatable {
    case idle
    case poweredOff
    case unauthorised
    case unsupported
    /// Scanning, and waiting for the remembered adapter if there is one.
    case searching
    case connecting(String)
    /// Connected with a write and a notify characteristic: commands can be sent.
    case ready(String)
    case failed(String)
}

enum OBDTransportEvent {
    case link(OBDLinkState)
    case adapters([OBDAdapter])
}

enum OBDError: Error, Equatable {
    case notConnected
    /// A command is already waiting for its `>` prompt.
    case busy
    case timeout
    case disconnected
    case writeFailed(String)
}

/// A serial-like link to an ELM327: write a command, read lines until the `>` prompt.
/// One command at a time; `ELM327Session` serialises callers.
@MainActor
protocol OBDTransport: AnyObject {
    var isDemo: Bool { get }
    var onEvent: (@MainActor (OBDTransportEvent) -> Void)? { get set }
    var linkState: OBDLinkState { get }
    /// Adapters found by the current scan, best candidates first.
    var adapters: [OBDAdapter] { get }
    /// The adapter it reconnects to automatically, if one was chosen.
    var rememberedAdapterName: String? { get }

    /// Power up Bluetooth (may show the permission prompt), scan, and reconnect
    /// to the remembered adapter whenever it appears.
    func start()
    func stop()
    /// Refresh the list of nearby adapters.
    func scan()
    func connect(to adapterID: UUID)
    /// Disconnect and stop reconnecting automatically.
    func forgetAdapter()
    /// Sends `command` followed by a carriage return and returns the reply lines
    /// (prompt removed). Throws `OBDError.timeout` if no `>` arrives in time.
    func send(_ command: String, timeout: Duration) async throws -> [String]
}

/// Collects text from the adapter until the ELM327 `>` prompt. BLE delivers the
/// reply in small notifications, so a reply usually spans several chunks.
struct ELMReceiveBuffer {
    private(set) var text = ""

    mutating func reset() { text = "" }

    mutating func append(_ data: Data) -> [String]? {
        append(String(decoding: data, as: UTF8.self))
    }

    /// Returns the reply's lines once the prompt has arrived; keeps anything after it.
    mutating func append(_ chunk: String) -> [String]? {
        text += chunk.replacingOccurrences(of: "\0", with: "")
        guard let prompt = text.firstIndex(of: ">") else { return nil }
        let body = String(text[..<prompt])
        text = String(text[text.index(after: prompt)...])
        return Self.lines(in: body)
    }

    /// Non-empty, trimmed lines. `\r\n` is one Character in Swift, so split on `isNewline`.
    static func lines(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// One GATT characteristic, reduced to what matters for choosing the adapter's pipe.
struct BLECharacteristicInfo: Equatable {
    var service: String
    var uuid: String
    var canWrite: Bool
    var canWriteWithoutResponse: Bool
    var canNotify: Bool

    var isWritable: Bool { canWrite || canWriteWithoutResponse }
}

/// Picks the write + notify characteristic pair an ELM327 BLE adapter talks through.
enum BLECharacteristicPicker {
    /// (service, write, notify) layouts used by common adapters.
    static let knownLayouts: [(service: String, write: String, notify: String)] = [
        ("FFF0", "FFF2", "FFF1"),   // Vgate iCar Pro, Veepeak and most clones
        ("FFE0", "FFE1", "FFE1"),   // HM-10 style modules: one characteristic for both
        ("18F0", "2AF1", "2AF0"),   // OBDLink CX / LX BLE
    ]
    /// Standard services that never carry the serial link.
    static let ignoredServices: Set<String> = ["1800", "1801", "180A", "180F"]

    /// `FFF0` from either `FFF0` or the full Bluetooth-base form.
    static func shortUUID(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        let suffix = "-0000-1000-8000-00805F9B34FB"
        if upper.hasSuffix(suffix), upper.hasPrefix("0000"), upper.count == 36 {
            return String(upper.dropFirst(4).prefix(4))
        }
        return upper
    }

    /// Indices of the (write, notify) characteristics, or nil when there is no usable pair.
    static func pick(_ characteristics: [BLECharacteristicInfo]) -> (write: Int, notify: Int)? {
        let items = characteristics.enumerated().map { index, info in
            (index: index, info: info, service: shortUUID(info.service), uuid: shortUUID(info.uuid))
        }
        for layout in knownLayouts {
            let inService = items.filter { $0.service == layout.service }
            if let write = inService.first(where: { $0.uuid == layout.write && $0.info.isWritable }),
               let notify = inService.first(where: { $0.uuid == layout.notify && $0.info.canNotify }) {
                return (write.index, notify.index)
            }
        }
        // Unknown layout: a service with both a writable and a notifying characteristic.
        let candidates = items.filter { !ignoredServices.contains($0.service) }
        for service in candidates.map(\.service) {
            let inService = candidates.filter { $0.service == service }
            if let write = inService.first(where: { $0.info.isWritable }),
               let notify = inService.first(where: { $0.info.canNotify }) {
                return (write.index, notify.index)
            }
        }
        return nil
    }
}
