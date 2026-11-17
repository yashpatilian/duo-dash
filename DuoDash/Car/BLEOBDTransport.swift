import Foundation
import CoreBluetooth

/// An ELM327 adapter over Bluetooth LE (Vgate iCar Pro BLE, Veepeak OBDCheck BLE,
/// OBDLink CX…). Classic-Bluetooth (SPP) adapters can't be used from iOS.
///
/// Scans without a service filter (many clones don't advertise a service), ranks
/// what it finds, connects, discovers every service and picks the write/notify
/// pair. The chosen adapter is remembered and reconnected to whenever it appears,
/// using a pending connect (which also works with the screen locked) as well as the scan.
@MainActor
final class BLEOBDTransport: NSObject, OBDTransport {
    static let rememberedIDKey = "car.adapter.id"
    static let rememberedNameKey = "car.adapter.name"

    let isDemo = false
    var onEvent: (@MainActor (OBDTransportEvent) -> Void)?
    private(set) var linkState: OBDLinkState = .idle {
        didSet { if linkState != oldValue { onEvent?(.link(linkState)) } }
    }
    private(set) var adapters: [OBDAdapter] = []
    var rememberedAdapterName: String? { rememberedID == nil ? nil : defaults.string(forKey: Self.rememberedNameKey) }

    /// How long a tap on an adapter may take to connect before giving up.
    var connectTimeout: Duration = .seconds(15)

    private let defaults: UserDefaults
    private var central: CBCentralManager?
    private var found: [UUID: (peripheral: CBPeripheral, adapter: OBDAdapter)] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var servicesLeft = 0
    private var buffer = ELMReceiveBuffer()
    private var pending: CheckedContinuation<[String], Error>?
    private var timeoutTask: Task<Void, Never>?
    /// A command timed out, so its reply may still be on the way. Until that reply's `>` prompt
    /// arrives (or a short wait passes), the next command isn't sent, so late replies can't be
    /// read as the answer to a later command.
    private var expectingLateReply = false
    private var connectTimeoutTask: Task<Void, Never>?
    private var isRunning = false
    /// Off after Forget, so the same adapter isn't picked straight back up.
    private var autoConnectsToUnknown = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    private var rememberedID: UUID? {
        defaults.string(forKey: Self.rememberedIDKey).flatMap(UUID.init(uuidString:))
    }

    private func remember(_ peripheral: CBPeripheral, name: String) {
        defaults.set(peripheral.identifier.uuidString, forKey: Self.rememberedIDKey)
        defaults.set(name, forKey: Self.rememberedNameKey)
    }

    private func name(of peripheral: CBPeripheral) -> String {
        found[peripheral.identifier]?.adapter.name ?? peripheral.name ?? "OBD adapter"
    }

    // MARK: OBDTransport

    func start() {
        isRunning = true
        if let central {
            centralDidUpdateState(central)
        } else {
            // Creating the manager is what shows the Bluetooth permission prompt.
            central = CBCentralManager(delegate: self, queue: nil,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func stop() {
        isRunning = false
        central?.stopScan()
        disconnect()
        linkState = .idle
    }

    func scan() {
        guard let central, central.state == .poweredOn else { return }
        found = found.filter { $0.value.peripheral.state != .disconnected || $0.key == rememberedID }
        publishAdapters()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func connect(to adapterID: UUID) {
        guard let central, central.state == .poweredOn else { return }
        if case .ready = linkState, peripheral?.identifier == adapterID { return }
        guard let target = found[adapterID]?.peripheral
                ?? central.retrievePeripherals(withIdentifiers: [adapterID]).first else { return }
        if let peripheral, peripheral.identifier != adapterID { disconnect() }
        autoConnectsToUnknown = true
        beginConnecting(target)
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self, connectTimeout] in
            try? await Task.sleep(for: connectTimeout)
            guard !Task.isCancelled, let self, case .connecting(let name) = self.linkState else { return }
            self.disconnect()
            self.linkState = .failed("Couldn't connect to \(name). Check it's plugged in and the ignition is on.")
        }
    }

    func forgetAdapter() {
        defaults.removeObject(forKey: Self.rememberedIDKey)
        defaults.removeObject(forKey: Self.rememberedNameKey)
        autoConnectsToUnknown = false
        disconnect()
        if central?.state == .poweredOn, isRunning {
            linkState = .searching
            scan()
        }
    }

    func send(_ command: String, timeout: Duration) async throws -> [String] {
        guard case .ready = linkState, let peripheral, let writeCharacteristic else { throw OBDError.notConnected }
        guard pending == nil else { throw OBDError.busy }
        guard let data = (command + "\r").data(using: .ascii) else { throw OBDError.writeFailed("Not ASCII") }
        if expectingLateReply {
            for _ in 0..<6 where expectingLateReply { try? await Task.sleep(for: .milliseconds(50)) }
            expectingLateReply = false
        }
        guard pending == nil else { throw OBDError.busy }
        buffer.reset()
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            let type: CBCharacteristicWriteType =
                writeCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            let chunk = max(20, peripheral.maximumWriteValueLength(for: type))
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                peripheral.writeValue(data.subdata(in: offset..<end), for: writeCharacteristic, type: type)
                offset = end
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.expectingLateReply = true
                self?.finish(.failure(OBDError.timeout))
            }
        }
    }

    // MARK: Internals

    private func finish(_ result: Result<[String], Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(with: result)
    }

    private func beginConnecting(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        linkState = .connecting(name(of: target))
        if target.state != .connected { central?.connect(target) } else { target.discoverServices(nil) }
    }

    /// Drops the current connection (no automatic reconnect until the next start/connect).
    private func disconnect() {
        connectTimeoutTask?.cancel()
        finish(.failure(OBDError.disconnected))
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
    }

    private func publishAdapters() {
        adapters = OBDAdapter.ranked(found.values.map(\.adapter))
        onEvent?(.adapters(adapters))
    }

    /// Queue a connect to the remembered adapter; iOS completes it when the adapter
    /// next appears, even much later.
    private func reconnectRemembered() {
        guard let central, peripheral == nil, let id = rememberedID,
              let target = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        peripheral = target
        target.delegate = self
        central.connect(target)
    }

    private func centralDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard isRunning else { return }
            if peripheral == nil || linkState == .poweredOff { linkState = .searching }
            reconnectRemembered()
            scan()
        case .poweredOff:
            disconnect()
            linkState = .poweredOff
        case .unauthorized:
            disconnect()
            linkState = .unauthorised
        case .unsupported:
            linkState = .unsupported
        default:
            break
        }
    }

    private func discovered(_ target: CBPeripheral, advertisement: [String: Any], rssi: Int) {
        let advertisedName = advertisement[CBAdvertisementDataLocalNameKey] as? String
        let services = (advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let name = advertisedName ?? target.name
        let likely = OBDAdapter.isLikelyOBD(name: name, services: services)
        // Unnamed devices that don't look like an adapter are just noise in the list.
        guard name != nil || likely else { return }
        let adapter = OBDAdapter(id: target.identifier, name: name ?? "OBD adapter", rssi: rssi, isLikelyOBD: likely)
        let previous = found[target.identifier]?.adapter
        found[target.identifier] = (target, adapter)
        if previous == nil || previous?.name != adapter.name || abs((previous?.rssi ?? 0) - rssi) >= 10 {
            publishAdapters()
        }
        guard linkState == .searching else { return }
        if target.identifier == rememberedID {
            beginConnecting(target)
        } else if rememberedID == nil, autoConnectsToUnknown, likely, name != nil, peripheral == nil {
            // First run: the obvious adapter gets picked without a tap.
            beginConnecting(target)
        }
    }

    private func didConnect(_ target: CBPeripheral) {
        guard target.identifier == peripheral?.identifier else { return }
        central?.stopScan()
        linkState = .connecting(name(of: target))
        servicesLeft = 0
        target.discoverServices(nil)
    }

    private func didDiscoverServices(_ target: CBPeripheral, error: Error?) {
        let services = target.services ?? []
        guard error == nil, !services.isEmpty else {
            fail(target, "\(name(of: target)) doesn't look like an OBD-II adapter.")
            return
        }
        servicesLeft = services.count
        for service in services { target.discoverCharacteristics(nil, for: service) }
    }

    private func didDiscoverCharacteristics(_ target: CBPeripheral) {
        servicesLeft -= 1
        guard servicesLeft <= 0 else { return }
        let characteristics = (target.services ?? []).flatMap { $0.characteristics ?? [] }
        let infos = characteristics.map { c in
            BLECharacteristicInfo(service: c.service?.uuid.uuidString ?? "", uuid: c.uuid.uuidString,
                                  canWrite: c.properties.contains(.write),
                                  canWriteWithoutResponse: c.properties.contains(.writeWithoutResponse),
                                  canNotify: c.properties.contains(.notify) || c.properties.contains(.indicate))
        }
        guard let pair = BLECharacteristicPicker.pick(infos) else {
            fail(target, "\(name(of: target)) doesn't look like an OBD-II adapter.")
            return
        }
        writeCharacteristic = characteristics[pair.write]
        notifyCharacteristic = characteristics[pair.notify]
        target.setNotifyValue(true, for: characteristics[pair.notify])
    }

    private func didUpdateNotificationState(_ target: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == notifyCharacteristic else { return }
        if let error {
            fail(target, "Couldn't open \(name(of: target)): \(error.localizedDescription)")
            return
        }
        connectTimeoutTask?.cancel()
        let name = name(of: target)
        remember(target, name: name)
        autoConnectsToUnknown = true
        linkState = .ready(name)
    }

    private func didReceive(_ characteristic: CBCharacteristic) {
        guard characteristic == notifyCharacteristic, let data = characteristic.value else { return }
        guard pending != nil else {
            // Unsolicited text, or a reply that arrived after its timeout: drop it, and once its
            // prompt has come the next command can go.
            if data.contains(UInt8(ascii: ">")) { expectingLateReply = false }
            buffer.reset()
            return
        }
        if let lines = buffer.append(data) { finish(.success(lines)) }
    }

    private func didDisconnect(_ target: CBPeripheral) {
        guard target.identifier == peripheral?.identifier else { return }
        finish(.failure(OBDError.disconnected))
        writeCharacteristic = nil
        notifyCharacteristic = nil
        peripheral = nil
        guard isRunning, central?.state == .poweredOn else { return }
        linkState = .searching
        reconnectRemembered()
        scan()
    }

    /// Unlike a dropped connection, don't queue another connect straight away (it
    /// would fail the same way); the scan reconnects when the adapter shows up.
    private func didFailToConnect(_ target: CBPeripheral) {
        guard target.identifier == peripheral?.identifier else { return }
        connectTimeoutTask?.cancel()
        peripheral = nil
        guard isRunning, central?.state == .poweredOn else { return }
        linkState = .searching
        scan()
    }

    private func fail(_ target: CBPeripheral, _ message: String) {
        disconnect()
        linkState = .failed(message)
    }
}

// MARK: CoreBluetooth delegates (delivered on the main queue, where the manager was created)

extension BLEOBDTransport: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { centralDidUpdateState(central) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { discovered(peripheral, advertisement: advertisementData, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { didConnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { didFailToConnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { didDisconnect(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { didDiscoverServices(peripheral, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated { didDiscoverCharacteristics(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated { didUpdateNotificationState(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated { didReceive(characteristic) }
    }
}
