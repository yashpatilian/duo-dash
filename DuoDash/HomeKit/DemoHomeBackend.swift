import Foundation

/// A deterministic stand-in for HomeKit, used in the Simulator (which has no
/// accessories), with `-DemoHome` on a device, and in tests.
///
/// One home, "Home": Garage Door (opens and closes over `doorTravelTime`, with
/// a switchable obstruction), Front Door Lock, Porch Light, Hallway Light, a
/// Driveway Gate that is not responding, and the scenes "Arrive Home" and
/// "Leave Home".
@MainActor
final class DemoHomeBackend: HomeBackend {
    enum Scenario { case standard, denied, restricted, noHomes }

    static let homeID = "demo-home"
    static let garageID = "demo-garage"
    static let gateID = "demo-gate"
    static let lockID = "demo-front-lock"
    static let porchLightID = "demo-porch-light"
    static let hallwayLightID = "demo-hallway-light"
    static let arriveSceneID = "demo-scene-arrive"
    static let leaveSceneID = "demo-scene-leave"

    let isDemo = true
    var onEvent: (@MainActor (HomeBackendEvent) -> Void)?

    let scenario: Scenario
    /// How long the demo takes to answer a write. Zero answers immediately.
    var latency: Duration
    /// How long the garage door takes to open or close.
    var doorTravelTime: Duration
    /// The garage door's beam is blocked: a moving door stops and reports it.
    private(set) var isObstructed = false
    /// Unreachable accessories never answer (exercises the model's timeout)
    /// instead of failing after `latency`.
    var unreachableHangs = false
    /// Make the next write fail, to exercise rollback.
    var failNextWrite: HomeError?

    private(set) var sentCommands: [(command: HomeCommand, accessoryID: String)] = []
    private(set) var scenesRun: [String] = []

    private var home: HomeSnapshot
    private var doorTask: Task<Void, Never>?

    init(scenario: Scenario = .standard, latency: Duration = .milliseconds(350),
         doorTravelTime: Duration = .seconds(3)) {
        self.scenario = scenario
        self.latency = latency
        self.doorTravelTime = doorTravelTime
        home = Self.makeHome()
    }

    static func makeHome() -> HomeSnapshot {
        HomeSnapshot(
            id: homeID, name: "Home", isPrimary: true,
            accessories: [
                HomeAccessory(id: garageID, name: "Garage Door", room: "Garage", kind: .garageDoor,
                              state: .door(current: .closed, targetOpen: false, obstructed: false)),
                HomeAccessory(id: lockID, name: "Front Door Lock", room: "Entry", kind: .lock,
                              state: .lock(current: .secured, targetSecured: true)),
                HomeAccessory(id: porchLightID, name: "Porch Light", room: "Outside", kind: .light,
                              state: .power(isOn: false)),
                HomeAccessory(id: hallwayLightID, name: "Hallway Light", room: "Hallway", kind: .light,
                              state: .power(isOn: false)),
                HomeAccessory(id: gateID, name: "Driveway Gate", room: "Outside", kind: .gate,
                              state: .door(current: .closed, targetOpen: false, obstructed: false),
                              isReachable: false),
            ],
            scenes: [
                HomeScene(id: arriveSceneID, name: "Arrive Home", kind: .arrive),
                HomeScene(id: leaveSceneID, name: "Leave Home", kind: .leave, touchesLocks: true),
            ])
    }

    /// The demo home as it is now.
    var snapshot: HomeSnapshot { home }

    func start() {
        switch scenario {
        case .denied:
            onEvent?(.authorization(.denied))
        case .restricted:
            onEvent?(.authorization(.restricted))
        case .noHomes:
            onEvent?(.authorization(.authorized))
            onEvent?(.homes([]))
        case .standard:
            onEvent?(.authorization(.authorized))
            onEvent?(.homes([home]))
        }
    }

    // MARK: Writes

    func send(_ command: HomeCommand, to accessoryID: String, in homeID: String) async throws {
        guard homeID == home.id, let accessory = accessory(accessoryID) else { throw HomeError.notFound }
        sentCommands.append((command, accessoryID))
        if !accessory.isReachable {
            if unreachableHangs { try await Task.sleep(for: .seconds(3600)) }
            try await wait(latency)
            throw HomeError.notResponding
        }
        try await wait(latency)
        if let failure = failNextWrite {
            failNextWrite = nil
            throw failure
        }
        apply(command, to: accessoryID)
    }

    func runScene(_ sceneID: String, in homeID: String) async throws {
        guard homeID == home.id, home.scenes.contains(where: { $0.id == sceneID }) else { throw HomeError.notFound }
        try await wait(latency)
        if let failure = failNextWrite {
            failNextWrite = nil
            throw failure
        }
        scenesRun.append(sceneID)
        switch sceneID {
        case Self.arriveSceneID:
            apply(.setPower(on: true), to: Self.porchLightID)
            apply(.setPower(on: true), to: Self.hallwayLightID)
        case Self.leaveSceneID:
            apply(.setPower(on: false), to: Self.porchLightID)
            apply(.setPower(on: false), to: Self.hallwayLightID)
            apply(.setLock(secured: true), to: Self.lockID)
            apply(.setDoor(open: false), to: Self.garageID)
        default:
            break
        }
    }

    // MARK: Demo controls

    /// Block or clear the garage door's beam. A moving door stops at once.
    func setObstructed(_ obstructed: Bool) {
        isObstructed = obstructed
        guard var garage = accessory(Self.garageID), case let .door(current, targetOpen, _) = garage.state else { return }
        if obstructed, current == .opening || current == .closing {
            doorTask?.cancel()
            garage.state = .door(current: .stopped, targetOpen: targetOpen, obstructed: true)
        } else {
            garage.state = .door(current: current, targetOpen: targetOpen, obstructed: obstructed && current == .stopped)
        }
        update(garage)
    }

    /// Change reachability (e.g. to bring the gate back).
    func setReachable(_ reachable: Bool, accessoryID: String) {
        guard var accessory = accessory(accessoryID) else { return }
        accessory.isReachable = reachable
        update(accessory)
    }

    // MARK: Internals

    private func accessory(_ id: String) -> HomeAccessory? {
        home.accessories.first { $0.id == id }
    }

    private func update(_ accessory: HomeAccessory) {
        guard let index = home.accessories.firstIndex(where: { $0.id == accessory.id }) else { return }
        home.accessories[index] = accessory
        onEvent?(.accessory(homeID: home.id, accessory))
    }

    private func wait(_ duration: Duration) async throws {
        if duration > .zero { try await Task.sleep(for: duration) }
    }

    private func apply(_ command: HomeCommand, to id: String) {
        guard var accessory = accessory(id) else { return }
        switch (accessory.state, command) {
        case let (.door(current, _, _), .setDoor(open)):
            moveDoor(&accessory, from: current, open: open)
            return
        case (.lock, .setLock(let secured)):
            // Locks report the new position once the bolt has moved.
            accessory.state = .lock(current: secured ? .secured : .unsecured, targetSecured: secured)
        case (.power, .setPower(let on)):
            accessory.state = .power(isOn: on)
        default:
            return
        }
        update(accessory)
    }

    /// Opening → Open (or Closing → Closed) over `doorTravelTime`, unless the
    /// beam is blocked, in which case the door stops and reports the obstruction.
    private func moveDoor(_ door: inout HomeAccessory, from current: DoorPosition, open: Bool) {
        let end: DoorPosition = open ? .open : .closed
        doorTask?.cancel()
        guard current != end else {
            door.state = .door(current: end, targetOpen: open, obstructed: false)
            update(door)
            return
        }
        if isObstructed {
            door.state = .door(current: .stopped, targetOpen: open, obstructed: true)
            update(door)
            return
        }
        door.state = .door(current: open ? .opening : .closing, targetOpen: open, obstructed: false)
        update(door)
        let id = door.id
        let travel = doorTravelTime
        doorTask = Task { [weak self] in
            if travel > .zero { try? await Task.sleep(for: travel) }
            guard let self, !Task.isCancelled, var door = self.accessory(id) else { return }
            door.state = .door(current: end, targetOpen: open, obstructed: false)
            self.update(door)
        }
    }
}
