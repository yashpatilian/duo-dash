import Foundation
import Observation

/// Where the car-data connection stands. Every state has something useful to show.
enum CarConnectionState: Equatable {
    /// `start()` hasn't been called (Bluetooth untouched, no permission prompt yet).
    case idle
    case bluetoothOff
    case unauthorised
    /// Scanning, or waiting for the remembered adapter to appear.
    case searching
    case connecting(String)
    /// Bluetooth is connected; resetting the adapter and looking for the car's computer.
    case initialising
    case connected(protocol: String)
    /// The adapter works (battery voltage) but the car's computer isn't answering.
    case noECU(message: String)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// The adapter is talking, so `ATRV` battery voltage is available.
    var hasAdapter: Bool {
        switch self {
        case .initialising, .connected, .noECU: true
        default: false
        }
    }
}

/// Live car data from an ELM327 OBD-II adapter, for the Car screen and the dashboard card.
///
/// Flow: transport finds and connects the adapter → `ELM327Session` resets it and sends
/// 0100 → if the car answers, the supported PIDs are polled round-robin (RPM and speed
/// about 4 Hz, the rest every few seconds) and trouble codes are read; if it doesn't
/// (common on some Japanese-market cars) the screen says so, shows battery voltage from
/// `ATRV`, and tries the car again every 20 s in case the ignition was off.
@MainActor
@Observable
final class CarDataModel {
    private(set) var state: CarConnectionState = .idle
    private(set) var values: [OBDPID: Double] = [:]
    private(set) var batteryVoltage: Double?
    /// PIDs the car says it supports (and actually answers), of the ones Duo Dash shows.
    private(set) var supportedPIDs: Set<OBDPID> = []
    private(set) var storedCodes: [DTC] = []
    private(set) var pendingCodes: [DTC] = []
    private(set) var codesCheckedAt: Date?
    private(set) var codesMessage: String?
    private(set) var isReadingCodes = false
    private(set) var isClearingCodes = false
    private(set) var lastUpdate: Date?
    private(set) var adapters: [OBDAdapter] = []
    /// The adapter being connected to or in use.
    private(set) var adapterName: String?
    /// "ELM327 v1.5", from the adapter's reset banner.
    private(set) var adapterVersion: String?
    private(set) var rememberedAdapterName: String?
    let isDemo: Bool

    @ObservationIgnored private let transport: OBDTransport
    @ObservationIgnored private let session: ELM327Session
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    /// Bumped whenever a session starts or stops, so a cancelled one can't write state.
    @ObservationIgnored private var generation = 0
    /// Monotonic seconds, injectable for tests.
    @ObservationIgnored var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var retryDelay: Duration = .seconds(4)
    /// How long to wait before asking a silent car's computer again.
    @ObservationIgnored var noECURetryInterval: TimeInterval = 20
    /// Unanswered polls in a row (all PIDs) before deciding the car stopped answering.
    @ObservationIgnored var stoppedAnsweringThreshold = 8
    /// Unanswered polls in a row for one PID before hiding it.
    @ObservationIgnored var hidePIDThreshold = 5

    static let noECUMessage = "Adapter connected, but the car's computer didn't answer generic OBD-II requests — common on some Japanese-market cars. Battery voltage still works."
    static let stoppedAnsweringMessage = "The car's computer stopped answering, as it does when the ignition is switched off. Battery voltage still works."

    /// No Bluetooth in the Simulator; `-DemoCar` / `-DemoCarNoECU` ask for the demo on a device.
    static var usesDemo: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-DemoCar") || arguments.contains("-DemoCarNoECU")
        #endif
    }

    init(transport: OBDTransport? = nil) {
        let transport = transport ?? (Self.usesDemo
            ? DemoOBDTransport(elm: DemoELM327(profile: ProcessInfo.processInfo.arguments.contains("-DemoCarNoECU")
                                                ? .noECU : .standard))
            : BLEOBDTransport())
        self.transport = transport
        session = ELM327Session(transport: transport)
        isDemo = transport.isDemo
        rememberedAdapterName = transport.rememberedAdapterName
        adapters = transport.adapters
        transport.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: Derived

    /// Supported values in tile order.
    var visiblePIDs: [OBDPID] { OBDPID.displayOrder.filter(supportedPIDs.contains) }

    func value(_ pid: OBDPID) -> Double? { values[pid] }

    var hasTroubleCodes: Bool { !storedCodes.isEmpty || !pendingCodes.isEmpty }

    var canClearCodes: Bool { clearCodesBlockedReason == nil && hasTroubleCodes }

    /// Why Clear codes is unavailable, or nil when it's allowed.
    var clearCodesBlockedReason: String? {
        guard state.isConnected else { return "Connect to the car first." }
        guard !isClearingCodes else { return "Clearing…" }
        guard let speed = values[.speed] else { return "Waiting for the car's speed." }
        return speed == 0 ? nil : "Stop the car to clear codes."
    }

    // MARK: Actions

    /// Starts Bluetooth (first time: the permission prompt), scanning and auto-reconnect.
    func start() {
        if state == .idle || state == .bluetoothOff { transport.start() }
        else if case .failed = state { transport.start() }
    }

    func stop() {
        endSession()
        transport.stop()
        state = .idle
    }

    func scanForAdapters() {
        if state == .idle { transport.start() }
        transport.scan()
    }

    func connect(to adapter: OBDAdapter) {
        transport.connect(to: adapter.id)
    }

    func forgetAdapter() {
        endSession()
        transport.forgetAdapter()
        rememberedAdapterName = nil
        adapterName = nil
    }

    /// Try again after a failure, or ask a silent car's computer again right now.
    func retry() {
        if case .ready = transport.linkState {
            beginSession()
        } else {
            transport.start()
        }
    }

    func refreshCodes() async {
        guard state.isConnected else { return }
        await readCodes(generation)
    }

    /// Mode 04. Only when connected and the car is stationary; the screen confirms first.
    @discardableResult
    func clearCodes() async -> Bool {
        guard canClearCodes else { return false }
        let gen = generation
        isClearingCodes = true
        let cleared = (try? await session.clearTroubleCodes()) ?? false
        guard gen == generation else { return false }
        isClearingCodes = false
        if cleared {
            codesMessage = nil
            await readCodes(gen)
        } else {
            codesMessage = "The car didn't accept the request. Switch the engine off, leave the ignition on and try again."
        }
        return cleared
    }

    // MARK: Transport events

    private func handle(_ event: OBDTransportEvent) {
        switch event {
        case .adapters(let list):
            adapters = list
        case .link(let link):
            rememberedAdapterName = transport.rememberedAdapterName
            switch link {
            case .idle:
                endSession()
                state = .idle
            case .poweredOff:
                endSession()
                state = .bluetoothOff
            case .unauthorised:
                endSession()
                state = .unauthorised
            case .unsupported:
                endSession()
                state = .failed("This device doesn't support Bluetooth LE.")
            case .searching:
                endSession()
                state = .searching
            case .connecting(let name):
                adapterName = name
                state = .connecting(name)
            case .ready(let name):
                adapterName = name
                beginSession()
            case .failed(let message):
                endSession()
                state = .failed(message)
            }
        }
    }

    // MARK: Session

    private func endSession() {
        generation += 1
        sessionTask?.cancel()
        sessionTask = nil
        values = [:]
        supportedPIDs = []
        batteryVoltage = nil
        isReadingCodes = false
        isClearingCodes = false
    }

    private func beginSession() {
        endSession()
        let gen = generation
        state = .initialising
        sessionTask = Task { [weak self] in await self?.runSession(gen) }
    }

    private func runSession(_ gen: Int) async {
        do {
            try await session.initialise()
            guard gen == generation else { return }
            adapterVersion = session.adapterVersion
            await readBattery(gen)
            while gen == generation {
                try await detectAndPoll(gen)
            }
        } catch {
            guard gen == generation, !(error is CancellationError) else { return }
            guard case .ready = transport.linkState else { return }   // the link event explains it
            state = .failed(error as? OBDError == .timeout
                ? "The adapter stopped responding. Unplug it, plug it back in, and it will reconnect."
                : "Lost contact with the adapter.")
            try? await Task.sleep(for: retryDelay)
            guard gen == generation, !Task.isCancelled else { return }
            beginSession()
        }
    }

    /// One round: look for the car's computer, poll it while it answers, then wait
    /// (reading battery voltage) before looking again.
    private func detectAndPoll(_ gen: Int) async throws {
        let detection = try await session.detectVehicle()
        guard gen == generation else { throw CancellationError() }
        switch detection {
        case .connected(let name, let pids):
            supportedPIDs = Set(OBDPID.allCases.filter { pids.contains($0.rawValue) })
            state = .connected(protocol: name)
            await readCodes(gen)
            try await pollLoop(gen)
            guard gen == generation else { throw CancellationError() }
            values = [:]
            supportedPIDs = []
            state = .noECU(message: Self.stoppedAnsweringMessage)
        case .noECU:
            values = [:]
            supportedPIDs = []
            state = .noECU(message: Self.noECUMessage)
        }
        try await waitWithBattery(gen, for: noECURetryInterval)
    }

    private func waitWithBattery(_ gen: Int, for seconds: TimeInterval) async throws {
        let end = now() + seconds
        while now() < end {
            try Task.checkCancellation()
            guard gen == generation else { throw CancellationError() }
            await readBattery(gen)
            try await Task.sleep(for: .seconds(min(CarPollItem.battery.interval, max(0.05, end - now()))))
        }
    }

    /// Returns when the car stops answering; throws on cancellation or a dead adapter.
    private func pollLoop(_ gen: Int) async throws {
        var items: [CarPollItem] = OBDPID.displayOrder.filter(supportedPIDs.contains).map { .pid($0) }
        items += [.battery, .troubleCodes]
        var scheduler = OBDPollScheduler(items: items, now: now())
        scheduler.didPoll(.troubleCodes, at: now())   // just read
        var unanswered = 0
        var unansweredByPID: [OBDPID: Int] = [:]
        var timeouts = 0

        while true {
            try Task.checkCancellation()
            guard gen == generation else { throw CancellationError() }
            guard let item = scheduler.nextItem(now: now()) else {
                try await Task.sleep(for: .seconds(max(0.02, scheduler.timeUntilNextDue(now: now()))))
                continue
            }
            do {
                switch item {
                case .battery:
                    await readBattery(gen)
                case .troubleCodes:
                    await readCodes(gen)
                case .pid(let pid):
                    let reading = try await session.read(pid)
                    guard gen == generation else { throw CancellationError() }
                    switch reading {
                    case .value(let value):
                        values[pid] = value
                        lastUpdate = .now
                        unanswered = 0
                        unansweredByPID[pid] = 0
                    case .unavailable:
                        values[pid] = nil
                        unanswered += 1
                        unansweredByPID[pid, default: 0] += 1
                        // Claimed in the bitmap but never answers: hide it.
                        if unansweredByPID[pid, default: 0] >= hidePIDThreshold, unanswered < stoppedAnsweringThreshold {
                            supportedPIDs.remove(pid)
                            scheduler.remove(item)
                            continue
                        }
                    }
                }
                timeouts = 0
            } catch OBDError.timeout {
                timeouts += 1
                if timeouts >= 3 { throw OBDError.timeout }
            }
            scheduler.didPoll(item, at: now())
            if unanswered >= stoppedAnsweringThreshold { return }
        }
    }

    private func readBattery(_ gen: Int) async {
        guard let volts = try? await session.readBatteryVoltage(), gen == generation else { return }
        batteryVoltage = volts
        lastUpdate = .now
    }

    private func readCodes(_ gen: Int) async {
        guard !isReadingCodes else { return }
        isReadingCodes = true
        let stored = try? await session.readTroubleCodes(pending: false)
        let pending = try? await session.readTroubleCodes(pending: true)
        guard gen == generation else { return }
        isReadingCodes = false
        if let stored { storedCodes = stored }
        if let pending { pendingCodes = pending }
        if stored == nil && pending == nil {
            codesMessage = "The car didn't answer the trouble-code request."
        } else {
            codesMessage = nil
            codesCheckedAt = .now
        }
    }
}
