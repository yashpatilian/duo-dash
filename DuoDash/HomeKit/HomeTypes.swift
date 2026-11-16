import Foundation

// Plain value types for the Home (HomeKit) module. Nothing here imports HomeKit,
// so the model, the views, the demo and the tests all work without accessories.

/// Whether the app may read the user's homes.
enum HomeAuthorization: Equatable {
    case notDetermined
    case authorized
    /// The user said no (Settings → Privacy & Security → HomeKit).
    case denied
    /// Blocked by Screen Time or device management.
    case restricted
}

/// What the Home screen should show.
enum HomeStatus: Equatable {
    /// This build has no HomeKit entitlement (it's opt-in: scripts/setup.sh --homekit).
    case notEnabled
    case loading
    case denied
    case restricted
    /// Allowed, but there is no home set up in Apple's Home app.
    case noHomes
    case ready
}

/// The kinds of accessory that are useful from a car.
enum HomeAccessoryKind: String, Codable, CaseIterable {
    case garageDoor
    case gate
    case lock
    case light
    case switchPower
    case outlet

    var isDoor: Bool { self == .garageDoor || self == .gate }

    /// Order on screens: garage first, then gates, locks, lights, switches.
    var sortRank: Int {
        switch self {
        case .garageDoor: 0
        case .gate: 1
        case .lock: 2
        case .light: 3
        case .switchPower: 4
        case .outlet: 5
        }
    }
}

/// HomeKit's current door state (`HMCharacteristicValueDoorState`).
enum DoorPosition: Int, Equatable {
    case open = 0, closed = 1, opening = 2, closing = 3, stopped = 4
}

/// HomeKit's current lock state (`HMCharacteristicValueLockMechanismState`).
enum LockPosition: Int, Equatable {
    case unsecured = 0, secured = 1, jammed = 2, unknown = 3
}

/// The live state of one accessory tile.
enum HomeAccessoryState: Equatable {
    /// Garage door or gate. `targetOpen` is what was last asked for.
    case door(current: DoorPosition, targetOpen: Bool, obstructed: Bool)
    case lock(current: LockPosition, targetSecured: Bool)
    case power(isOn: Bool)
}

/// One controllable accessory (a HomeKit service). The id is the service's
/// unique identifier, so a two-bulb fixture shows as two tiles.
struct HomeAccessory: Identifiable, Equatable {
    let id: String
    var name: String
    var room: String?
    var kind: HomeAccessoryKind
    var state: HomeAccessoryState
    var isReachable: Bool = true

    /// The word under the name on a tile.
    var stateText: String {
        guard isReachable else { return "Not responding" }
        switch state {
        case let .door(current, _, obstructed):
            if obstructed { return "Obstructed" }
            switch current {
            case .open: return "Open"
            case .closed: return "Closed"
            case .opening: return "Opening…"
            case .closing: return "Closing…"
            case .stopped: return "Stopped"
            }
        case let .lock(current, targetSecured):
            switch current {
            case .secured: return targetSecured ? "Locked" : "Unlocking…"
            case .unsecured: return targetSecured ? "Locking…" : "Unlocked"
            case .jammed: return "Jammed"
            case .unknown: return targetSecured ? "Locking…" : "Unknown"
            }
        case let .power(isOn):
            return isOn ? "On" : "Off"
        }
    }

    /// Highlighted (tinted) tile: door open or moving, unlocked, light on.
    var isActive: Bool {
        switch state {
        case let .door(current, targetOpen, _): current != .closed || targetOpen
        case let .lock(current, _): current != .secured
        case let .power(isOn): isOn
        }
    }

    /// Something the driver should notice (obstruction, jam).
    var needsAttention: Bool {
        switch state {
        case let .door(_, _, obstructed): obstructed
        case let .lock(current, _): current == .jammed
        case .power: false
        }
    }

    var symbol: String {
        switch kind {
        case .garageDoor:
            if case let .door(current, _, _) = state, current == .closed { return "door.garage.closed" }
            return "door.garage.open"
        case .gate:
            return "door.sliding.left.hand.open"
        case .lock:
            if case let .lock(current, _) = state, current == .secured { return "lock.fill" }
            return "lock.open.fill"
        case .light:
            return isActive ? "lightbulb.fill" : "lightbulb"
        case .switchPower:
            return "switch.2"
        case .outlet:
            return isActive ? "poweroutlet.type.b.fill" : "poweroutlet.type.b"
        }
    }

    /// Door wants to end up open (or already is).
    var isDoorHeadingOpen: Bool {
        if case let .door(current, targetOpen, _) = state {
            return targetOpen || current == .open || current == .opening
        }
        return false
    }

    /// Door is fully closed and not moving.
    var isDoorClosed: Bool {
        if case let .door(current, targetOpen, _) = state { return current == .closed && !targetOpen }
        return false
    }
}

/// A HomeKit scene (action set) such as "Arrive Home".
struct HomeScene: Identifiable, Equatable {
    enum Kind: String, Equatable { case arrive, leave, wakeUp, sleep, custom }

    let id: String
    var name: String
    var kind: Kind
    /// The scene changes a lock. Such scenes are never offered on arrival.
    var touchesLocks: Bool = false

    var symbol: String {
        switch kind {
        case .arrive: "house.fill"
        case .leave: "figure.walk.departure"
        case .wakeUp: "sun.max.fill"
        case .sleep: "moon.fill"
        case .custom: "sparkles"
        }
    }
}

/// One home and the parts of it the dashboard cares about.
struct HomeSnapshot: Identifiable, Equatable {
    let id: String
    var name: String
    var isPrimary: Bool
    var accessories: [HomeAccessory]
    var scenes: [HomeScene]
}

/// A write to one accessory.
enum HomeCommand: Equatable {
    case setDoor(open: Bool)
    case setLock(secured: Bool)
    case setPower(on: Bool)
}

enum HomeError: Error, Equatable, LocalizedError {
    /// HomeKit can't reach the accessory (off, out of range, hub offline).
    case notResponding
    /// No answer in time.
    case timedOut
    /// The home, accessory or scene isn't there any more.
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notResponding, .timedOut: "Not responding"
        case .notFound: "That accessory isn't in this home any more."
        case let .failed(message): message
        }
    }

    /// Shown as "Not responding" on the tile.
    var isNoResponse: Bool { self == .notResponding || self == .timedOut }
}

/// A tile: an accessory or a scene.
enum HomeTile: Identifiable, Equatable {
    case accessory(HomeAccessory)
    case scene(HomeScene)

    var id: String {
        switch self {
        case let .accessory(accessory): accessory.id
        case let .scene(scene): scene.id
        }
    }

    var name: String {
        switch self {
        case let .accessory(accessory): accessory.name
        case let .scene(scene): scene.name
        }
    }

    /// Garage first, then gates, locks, lights…, scenes last.
    var sortRank: Int {
        switch self {
        case let .accessory(accessory): accessory.kind.sortRank
        case .scene: 10
        }
    }
}

/// Something to offer when arriving home.
struct ArrivalSuggestion: Equatable, Identifiable {
    enum Action: Equatable {
        case openDoor(accessoryID: String)
        case runScene(sceneID: String)
    }

    let action: Action
    /// "Open garage?"
    let title: String
    /// "Open"
    let actionTitle: String
    let symbol: String
    /// The model already did it (garage auto-open is on).
    var wasPerformed = false

    var id: String {
        switch action {
        case let .openDoor(id): "door-\(id)"
        case let .runScene(id): "scene-\(id)"
        }
    }
}

/// Mapping from HomeKit's raw values. Kept free of HomeKit types so it can be tested anywhere.
enum HomeStateMapping {
    static func door(current raw: Int?, target rawTarget: Int?, obstructed: Bool?) -> HomeAccessoryState {
        let current = raw.flatMap(DoorPosition.init(rawValue:)) ?? .stopped
        // Target door state: 0 open, 1 closed. Unknown target follows the current state.
        let targetOpen = rawTarget.map { $0 == 0 } ?? (current == .open || current == .opening)
        return .door(current: current, targetOpen: targetOpen, obstructed: obstructed ?? false)
    }

    static func lock(current raw: Int?, target rawTarget: Int?) -> HomeAccessoryState {
        let current = raw.flatMap(LockPosition.init(rawValue:)) ?? .unknown
        // Target lock state: 0 unsecured, 1 secured.
        let targetSecured = rawTarget.map { $0 == 1 } ?? (current == .secured)
        return .lock(current: current, targetSecured: targetSecured)
    }

    static func power(_ value: Any?) -> HomeAccessoryState {
        .power(isOn: bool(value) ?? false)
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let int as Int: int
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: bool
        case let number as NSNumber: number.boolValue
        default: nil
        }
    }

    /// `HMActionSetType…` string → scene kind.
    static func sceneKind(actionSetType: String) -> HomeScene.Kind {
        switch actionSetType {
        case "HMActionSetTypeHomeArrival": .arrive
        case "HMActionSetTypeHomeDeparture": .leave
        case "HMActionSetTypeWakeUp": .wakeUp
        case "HMActionSetTypeSleep": .sleep
        default: .custom
        }
    }

    /// The value written for a command, as HomeKit expects it.
    static func value(for command: HomeCommand) -> Int {
        switch command {
        case let .setDoor(open): open ? 0 : 1
        case let .setLock(secured): secured ? 1 : 0
        case let .setPower(on): on ? 1 : 0
        }
    }

    /// The state to show straight away, before the accessory confirms.
    static func optimistic(_ state: HomeAccessoryState, for command: HomeCommand) -> HomeAccessoryState {
        switch (state, command) {
        case let (.door(current, _, _), .setDoor(open)):
            let moving: DoorPosition
            if open { moving = current == .open ? .open : .opening } else { moving = current == .closed ? .closed : .closing }
            return .door(current: moving, targetOpen: open, obstructed: false)
        case let (.lock(current, _), .setLock(secured)):
            return .lock(current: current, targetSecured: secured)
        case let (.power, .setPower(on)):
            return .power(isOn: on)
        default:
            return state
        }
    }
}
