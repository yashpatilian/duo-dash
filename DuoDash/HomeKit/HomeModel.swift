import Foundation
import CoreLocation
import Observation

/// Home (HomeKit) state for the UI: homes, the selected home, Dashboard
/// favourites, accessory actions with optimistic updates, and the arrival
/// suggestion ("Open garage?") shown when the car gets close to home.
@MainActor
@Observable
final class HomeModel {
    private(set) var authorization: HomeAuthorization = .notDetermined
    private(set) var homes: [HomeSnapshot] = []
    private(set) var hasLoaded = false
    /// Accessories with a write in flight.
    private(set) var pendingIDs: Set<String> = []
    /// Accessories whose last write got no answer (shown as "Not responding"
    /// until the accessory reports again).
    private(set) var unresponsiveIDs: Set<String> = []
    /// The last failure, for a short message on screen.
    var errorMessage: String?
    /// The arrival offer currently on screen (see `arrivalSuggestion`).
    private(set) var activeArrival: ArrivalSuggestion?

    /// Saved favourite tile ids, in the order the user added them. `nil` until
    /// the user first changes them, so a sensible default can show.
    private(set) var savedFavouriteIDs: [String]? {
        didSet { save(savedFavouriteIDs, Keys.favourites) }
    }

    var selectedHomeID: String? {
        didSet { save(selectedHomeID, Keys.selectedHome) }
    }

    /// Open the garage without asking when arriving. Off by default.
    var autoOpenGarageOnArrival: Bool {
        didSet { save(autoOpenGarageOnArrival, Keys.autoOpen) }
    }

    /// How close to the saved Home place (metres) before offering an action.
    var arrivalDistance: CLLocationDistance {
        didSet { save(arrivalDistance, Keys.arrivalDistance) }
    }

    let isDemo: Bool

    /// How long to wait for an accessory before giving up. Shortened in tests.
    @ObservationIgnored var commandTimeout: Duration = .seconds(10)
    /// The demo backend, when in use (for the demo controls and tests).
    @ObservationIgnored let demo: DemoHomeBackend?

    @ObservationIgnored private let backend: HomeBackend
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var started = false
    /// Arrival: armed once the car has been away from home; spent after one
    /// suggestion, until the car leaves again.
    @ObservationIgnored private var arrivalArmed = false
    /// Consecutive fixes beyond `rearmDistance`. One stray fix (a cold start, a cell-tower
    /// guess) mustn't count as having left home.
    @ObservationIgnored private var farFixes = 0
    @ObservationIgnored private var arrivalSpent = false
    /// Per-accessory write generation, so an old write's result can't undo a newer one.
    @ObservationIgnored private var writeGeneration: [String: Int] = [:]

    enum Keys {
        static let favourites = "homekit.favourites"
        static let selectedHome = "homekit.selectedHome"
        static let autoOpen = "homekit.autoOpenGarageOnArrival"
        static let arrivalDistance = "homekit.arrivalDistance"
        static let all = [favourites, selectedHome, autoOpen, arrivalDistance]
    }

    static let defaultArrivalDistance: CLLocationDistance = 300
    static let maxDashboardItems = 3
    /// Without a route home, don't offer anything while driving past faster than this (≈ 50 km/h).
    static let passingSpeed: CLLocationSpeed = 14
    /// Fixes in a row beyond `rearmDistance` before a new trip home counts.
    static let fixesToRearm = 3

    init(backend: HomeBackend? = nil, defaults: UserDefaults = .standard, resetState: Bool = LaunchOptions.resetState) {
        if resetState { Keys.all.forEach(defaults.removeObject(forKey:)) }
        let backend = backend ?? HomeBackendFactory.make()
        self.backend = backend
        self.defaults = defaults
        isDemo = backend.isDemo
        demo = backend as? DemoHomeBackend
        savedFavouriteIDs = defaults.stringArray(forKey: Keys.favourites)
        selectedHomeID = defaults.string(forKey: Keys.selectedHome)
        autoOpenGarageOnArrival = defaults.bool(forKey: Keys.autoOpen)
        let distance = defaults.double(forKey: Keys.arrivalDistance)
        arrivalDistance = distance > 0 ? distance : Self.defaultArrivalDistance
        backend.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Start loading homes. Call when the Home screen or the dashboard card
    /// first appears (on a device this can show the HomeKit prompt).
    func start() {
        guard !started else { return }
        started = true
        backend.start()
    }

    // MARK: State

    var status: HomeStatus {
        if backend is DisabledHomeBackend { return .notEnabled }
        switch authorization {
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .loading
        case .authorized: return !hasLoaded ? .loading : homes.isEmpty ? .noHomes : .ready
        }
    }

    /// The chosen home, else the primary one, else the first.
    var selectedHome: HomeSnapshot? {
        homes.first { $0.id == selectedHomeID } ?? homes.first { $0.isPrimary } ?? homes.first
    }

    func selectHome(_ id: String) {
        guard homes.contains(where: { $0.id == id }) else { return }
        selectedHomeID = id
    }

    /// Accessories in the selected home, garage first.
    var accessories: [HomeAccessory] {
        (selectedHome?.accessories ?? []).enumerated()
            .sorted { ($0.element.kind.sortRank, $0.offset) < ($1.element.kind.sortRank, $1.offset) }
            .map(\.element)
    }

    var scenes: [HomeScene] { selectedHome?.scenes ?? [] }

    var tiles: [HomeTile] { accessories.map(HomeTile.accessory) + scenes.map(HomeTile.scene) }

    func accessory(_ id: String) -> HomeAccessory? {
        selectedHome?.accessories.first { $0.id == id }
    }

    func tile(_ id: String) -> HomeTile? {
        if let accessory = accessory(id) { return .accessory(accessory) }
        return scenes.first { $0.id == id }.map(HomeTile.scene)
    }

    /// The tile's status line, including "Not responding" after a failed write.
    func stateText(for accessory: HomeAccessory) -> String {
        unresponsiveIDs.contains(accessory.id) ? "Not responding" : accessory.stateText
    }

    func isResponding(_ accessory: HomeAccessory) -> Bool {
        accessory.isReachable && !unresponsiveIDs.contains(accessory.id)
    }

    // MARK: Events

    private func handle(_ event: HomeBackendEvent) {
        switch event {
        case let .authorization(authorization):
            self.authorization = authorization
            if authorization != .authorized { homes = [] }
        case let .homes(homes):
            authorization = .authorized
            self.homes = homes
            hasLoaded = true
        case let .accessory(homeID, accessory):
            guard let h = homes.firstIndex(where: { $0.id == homeID }),
                  let a = homes[h].accessories.firstIndex(where: { $0.id == accessory.id }) else { return }
            homes[h].accessories[a] = accessory
            // A fresh report means it answered.
            if accessory.isReachable { unresponsiveIDs.remove(accessory.id) }
        }
    }

    private func setState(_ state: HomeAccessoryState, for id: String, in homeID: String) {
        guard let h = homes.firstIndex(where: { $0.id == homeID }),
              let a = homes[h].accessories.firstIndex(where: { $0.id == id }) else { return }
        homes[h].accessories[a].state = state
    }

    // MARK: Actions

    /// Tap on a tile: toggle it (garage open/close, lock/unlock, power, or run the scene).
    @discardableResult
    func perform(_ tile: HomeTile) -> Task<Void, Never>? {
        switch tile {
        case let .scene(scene):
            return runScene(scene.id)
        case let .accessory(accessory):
            switch accessory.state {
            case .door:
                return accessory.isDoorHeadingOpen ? closeGarage(accessory.id) : openGarage(accessory.id)
            case let .lock(_, targetSecured):
                return targetSecured ? unlock(accessory.id) : lock(accessory.id)
            case .power:
                return toggle(accessory.id)
            }
        }
    }

    /// Open a garage door or gate (the first garage door when `id` is nil).
    @discardableResult
    func openGarage(_ id: String? = nil) -> Task<Void, Never>? {
        guard let id = id ?? firstGarage?.id else { return nil }
        return send(.setDoor(open: true), to: id)
    }

    @discardableResult
    func closeGarage(_ id: String? = nil) -> Task<Void, Never>? {
        guard let id = id ?? firstGarage?.id else { return nil }
        return send(.setDoor(open: false), to: id)
    }

    /// Flip a light, switch or outlet.
    @discardableResult
    func toggle(_ id: String) -> Task<Void, Never>? {
        guard let accessory = accessory(id), case let .power(isOn) = accessory.state else { return nil }
        return send(.setPower(on: !isOn), to: id)
    }

    @discardableResult
    func lock(_ id: String) -> Task<Void, Never>? { send(.setLock(secured: true), to: id) }

    /// Only ever called from a tap the user confirmed; nothing here unlocks on its own.
    @discardableResult
    func unlock(_ id: String) -> Task<Void, Never>? { send(.setLock(secured: false), to: id) }

    @discardableResult
    func runScene(_ id: String) -> Task<Void, Never>? {
        guard let homeID = selectedHome?.id, let scene = scenes.first(where: { $0.id == id }) else { return nil }
        pendingIDs.insert(id)
        errorMessage = nil
        let backend = backend
        let timeout = commandTimeout
        return Task {
            do {
                try await withHomeTimeout(timeout) { try await backend.runScene(id, in: homeID) }
            } catch {
                self.errorMessage = "\(scene.name) didn't run. \(Self.message(for: error))"
            }
            self.pendingIDs.remove(id)
        }
    }

    /// Tapping this tile would unlock a door, so the screen asks first.
    func needsConfirmation(_ tile: HomeTile) -> Bool {
        if case let .accessory(accessory) = tile, case let .lock(_, targetSecured) = accessory.state {
            return targetSecured
        }
        return false
    }

    var firstGarage: HomeAccessory? { accessories.first { $0.kind == .garageDoor } }

    /// Show the result straight away, then roll back if the accessory says no
    /// or doesn't answer in time.
    private func send(_ command: HomeCommand, to id: String) -> Task<Void, Never>? {
        guard let homeID = selectedHome?.id, let accessory = accessory(id) else { return nil }
        let previous = accessory.state
        let optimistic = HomeStateMapping.optimistic(previous, for: command)
        let generation = (writeGeneration[id] ?? 0) + 1
        writeGeneration[id] = generation
        setState(optimistic, for: id, in: homeID)
        pendingIDs.insert(id)
        unresponsiveIDs.remove(id)
        errorMessage = nil
        let backend = backend
        let timeout = commandTimeout
        return Task {
            do {
                try await withHomeTimeout(timeout) { try await backend.send(command, to: id, in: homeID) }
            } catch {
                guard self.writeGeneration[id] == generation else { return }
                // Roll back unless the accessory has reported something newer.
                if self.accessory(id)?.state == optimistic { self.setState(previous, for: id, in: homeID) }
                if (error as? HomeError)?.isNoResponse == true { self.unresponsiveIDs.insert(id) }
                self.errorMessage = "\(accessory.name): \(Self.message(for: error))"
            }
            if self.writeGeneration[id] == generation { self.pendingIDs.remove(id) }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? HomeError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Favourites

    /// Ids shown on the Dashboard card: the user's picks, or until they pick,
    /// the garage door(s) and the arrival scene.
    var favouriteIDs: [String] {
        if let savedFavouriteIDs { return savedFavouriteIDs }
        let doors = accessories.filter(\.kind.isDoor).map(\.id)
        let arrive = scenes.filter { $0.kind == .arrive }.map(\.id)
        return Array((doors + arrive).prefix(Self.maxDashboardItems))
    }

    func isFavourite(_ id: String) -> Bool { favouriteIDs.contains(id) }

    /// Long-press on a tile: add to or remove from the Dashboard.
    func toggleFavourite(_ id: String) {
        var ids = favouriteIDs
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        savedFavouriteIDs = ids
    }

    /// Up to three favourites for the Dashboard card, garage first.
    var dashboardTiles: [HomeTile] {
        let ids = favouriteIDs
        return ids.compactMap(tile)
            .enumerated()
            .sorted { ($0.element.sortRank, $0.offset) < ($1.element.sortRank, $1.offset) }
            .prefix(Self.maxDashboardItems)
            .map(\.element)
    }

    // MARK: Arrival

    /// Call on each location update with the distance (metres) to the saved
    /// Home place. Returns the action to offer while the car is within
    /// `arrivalDistance`, at most once per trip:
    ///
    /// - A trip starts once the car has been well away from home (so nothing is
    ///   offered while pulling out of the driveway).
    /// - Offers, in order: open a closed garage door, open a closed gate, run an
    ///   "Arrive Home" scene that doesn't touch a lock. Never anything with a lock.
    /// - Without a route home, nothing is offered while passing at speed.
    /// - With "Open garage automatically" on, the garage opens and the result
    ///   has `wasPerformed` set. Nothing else is ever done without a tap.
    ///
    /// While the offer is on screen the same value is returned; after it is
    /// accepted or dismissed, `nil` until the next trip.
    @discardableResult
    func arrivalSuggestion(distanceToHome: CLLocationDistance?, isNavigatingHome: Bool,
                           speed: CLLocationSpeed?) -> ArrivalSuggestion? {
        guard let distance = distanceToHome, distance >= 0 else { return activeArrival }
        if distance > rearmDistance {
            farFixes += 1
            if farFixes >= Self.fixesToRearm {
                arrivalArmed = true
                arrivalSpent = false
                activeArrival = nil
            }
            return nil
        }
        farFixes = 0
        if let activeArrival { return activeArrival }
        guard status == .ready, arrivalArmed, !arrivalSpent, distance <= arrivalDistance else { return nil }
        if !isNavigatingHome, let speed, speed > Self.passingSpeed { return nil }
        guard var suggestion = makeArrivalSuggestion() else { return nil }
        arrivalSpent = true
        // Opening by itself needs a real, slow-enough speed reading (an unknown speed only offers).
        if autoOpenGarageOnArrival, let speed, speed >= 0, speed <= Self.passingSpeed,
           case let .openDoor(id) = suggestion.action, accessory(id)?.kind == .garageDoor {
            openGarage(id)
            suggestion.wasPerformed = true
        }
        activeArrival = suggestion
        return suggestion
    }

    /// Beyond this the car has left home, and the next approach is a new trip.
    var rearmDistance: CLLocationDistance { max(arrivalDistance * 3, 1000) }

    private func makeArrivalSuggestion() -> ArrivalSuggestion? {
        let usable = accessories.filter { isResponding($0) }
        if let garage = usable.first(where: { $0.kind == .garageDoor && !$0.isDoorHeadingOpen }) {
            return ArrivalSuggestion(action: .openDoor(accessoryID: garage.id), title: "Open \(Self.shortName(garage))?",
                                     actionTitle: "Open", symbol: "door.garage.open")
        }
        if let gate = usable.first(where: { $0.kind == .gate && !$0.isDoorHeadingOpen }) {
            return ArrivalSuggestion(action: .openDoor(accessoryID: gate.id), title: "Open \(Self.shortName(gate))?",
                                     actionTitle: "Open", symbol: gate.symbol)
        }
        if let scene = scenes.first(where: { $0.kind == .arrive && !$0.touchesLocks }) {
            return ArrivalSuggestion(action: .runScene(sceneID: scene.id), title: "Run \(scene.name)?",
                                     actionTitle: "Run", symbol: scene.symbol)
        }
        return nil
    }

    /// "Garage Door" → "garage", "Driveway Gate" → "gate".
    private static func shortName(_ accessory: HomeAccessory) -> String {
        switch accessory.kind {
        case .garageDoor: "garage"
        case .gate: "gate"
        default: accessory.name
        }
    }

    /// "Open" on the banner.
    func acceptArrival() {
        guard let suggestion = activeArrival else { return }
        activeArrival = nil
        guard !suggestion.wasPerformed else { return }
        switch suggestion.action {
        case let .openDoor(id): openGarage(id)
        case let .runScene(id): runScene(id)
        }
    }

    /// "Not now" (or the banner timed out).
    func dismissArrival() {
        activeArrival = nil
    }

    /// Start a new trip by hand (e.g. when navigation starts away from home).
    func beginTrip() {
        arrivalArmed = true
        arrivalSpent = false
        activeArrival = nil
    }

    // MARK: Persistence

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
