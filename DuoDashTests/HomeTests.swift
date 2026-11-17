import XCTest
import HomeKit
@testable import DuoDash

/// The Home (HomeKit) module against the demo backend: fast and offline.
@MainActor
final class HomeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "HomeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func make(_ backend: DemoHomeBackend? = nil) -> (HomeModel, DemoHomeBackend) {
        let backend = backend ?? DemoHomeBackend(latency: .zero, doorTravelTime: .milliseconds(150))
        let model = HomeModel(backend: backend, defaults: defaults, resetState: false)
        model.commandTimeout = .seconds(2)
        model.start()
        return (model, backend)
    }

    private func garage(_ model: HomeModel) -> HomeAccessory { model.accessory(DemoHomeBackend.garageID)! }

    // MARK: Mapping

    func testDoorStateMapping() {
        XCTAssertEqual(HomeStateMapping.door(current: 0, target: 0, obstructed: false),
                       .door(current: .open, targetOpen: true, obstructed: false))
        XCTAssertEqual(HomeStateMapping.door(current: 1, target: 1, obstructed: nil),
                       .door(current: .closed, targetOpen: false, obstructed: false))
        XCTAssertEqual(HomeStateMapping.door(current: 2, target: nil, obstructed: nil),
                       .door(current: .opening, targetOpen: true, obstructed: false), "unknown target follows motion")
        XCTAssertEqual(HomeStateMapping.door(current: nil, target: nil, obstructed: true),
                       .door(current: .stopped, targetOpen: false, obstructed: true))

        func text(_ state: HomeAccessoryState, reachable: Bool = true) -> String {
            HomeAccessory(id: "g", name: "Garage", kind: .garageDoor, state: state, isReachable: reachable).stateText
        }
        XCTAssertEqual(text(.door(current: .open, targetOpen: true, obstructed: false)), "Open")
        XCTAssertEqual(text(.door(current: .closed, targetOpen: false, obstructed: false)), "Closed")
        XCTAssertEqual(text(.door(current: .opening, targetOpen: true, obstructed: false)), "Opening…")
        XCTAssertEqual(text(.door(current: .closing, targetOpen: false, obstructed: false)), "Closing…")
        XCTAssertEqual(text(.door(current: .stopped, targetOpen: false, obstructed: true)), "Obstructed")
        XCTAssertEqual(text(.door(current: .open, targetOpen: true, obstructed: false), reachable: false), "Not responding")
    }

    func testLockAndPowerMapping() {
        XCTAssertEqual(HomeStateMapping.lock(current: 1, target: 1), .lock(current: .secured, targetSecured: true))
        XCTAssertEqual(HomeStateMapping.lock(current: 0, target: nil), .lock(current: .unsecured, targetSecured: false))
        XCTAssertEqual(HomeStateMapping.lock(current: 9, target: nil), .lock(current: .unknown, targetSecured: false))
        func text(_ state: HomeAccessoryState) -> String {
            HomeAccessory(id: "l", name: "Lock", kind: .lock, state: state).stateText
        }
        XCTAssertEqual(text(.lock(current: .secured, targetSecured: true)), "Locked")
        XCTAssertEqual(text(.lock(current: .unsecured, targetSecured: false)), "Unlocked")
        XCTAssertEqual(text(.lock(current: .secured, targetSecured: false)), "Unlocking…")
        XCTAssertEqual(text(.lock(current: .unsecured, targetSecured: true)), "Locking…")
        XCTAssertEqual(text(.lock(current: .jammed, targetSecured: true)), "Jammed")

        XCTAssertEqual(HomeStateMapping.power(NSNumber(value: true)), .power(isOn: true))
        XCTAssertEqual(HomeStateMapping.power(1 as NSNumber), .power(isOn: true))
        XCTAssertEqual(HomeStateMapping.power(nil), .power(isOn: false))
        XCTAssertEqual(HomeStateMapping.int(NSNumber(value: 3)), 3)

        XCTAssertEqual(HomeStateMapping.value(for: .setDoor(open: true)), 0)
        XCTAssertEqual(HomeStateMapping.value(for: .setDoor(open: false)), 1)
        XCTAssertEqual(HomeStateMapping.value(for: .setLock(secured: true)), 1)
        XCTAssertEqual(HomeStateMapping.value(for: .setPower(on: true)), 1)
    }

    func testHomeKitConstantsMapping() {
        XCTAssertEqual(HomeStateMapping.sceneKind(actionSetType: HMActionSetTypeHomeArrival), .arrive)
        XCTAssertEqual(HomeStateMapping.sceneKind(actionSetType: HMActionSetTypeHomeDeparture), .leave)
        XCTAssertEqual(HomeStateMapping.sceneKind(actionSetType: HMActionSetTypeUserDefined), .custom)
        XCTAssertEqual(HomeKitBackend.authorization(from: []), .notDetermined)
        XCTAssertEqual(HomeKitBackend.authorization(from: [.determined]), .denied)
        XCTAssertEqual(HomeKitBackend.authorization(from: [.determined, .restricted]), .restricted)
        XCTAssertEqual(HomeKitBackend.authorization(from: [.determined, .authorized]), .authorized)
        let busy = NSError(domain: HMErrorDomain, code: HMError.Code.accessoryNotReachable.rawValue)
        XCTAssertEqual(HomeKitBackend.map(busy), .notResponding)
        let slow = NSError(domain: HMErrorDomain, code: HMError.Code.timedOutWaitingForAccessory.rawValue)
        XCTAssertEqual(HomeKitBackend.map(slow), .timedOut)
    }

    // MARK: States

    func testStatuses() {
        XCTAssertEqual(make(DemoHomeBackend(scenario: .denied, latency: .zero)).0.status, .denied)
        XCTAssertEqual(make(DemoHomeBackend(scenario: .restricted, latency: .zero)).0.status, .restricted)
        XCTAssertEqual(make(DemoHomeBackend(scenario: .noHomes, latency: .zero)).0.status, .noHomes)
        let (model, _) = make()
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.selectedHome?.name, "Home")
        XCTAssertEqual(model.accessories.first?.kind, .garageDoor, "garage first")
        XCTAssertEqual(model.scenes.map(\.name), ["Arrive Home", "Leave Home"])
        let gate = model.accessory(DemoHomeBackend.gateID)!
        XCTAssertEqual(model.stateText(for: gate), "Not responding")
        XCTAssertFalse(model.isResponding(gate))
        let unloaded = HomeModel(backend: DemoHomeBackend(latency: .zero), defaults: defaults, resetState: false)
        XCTAssertEqual(unloaded.status, .loading, "nothing until start()")
    }

    // MARK: Optimistic updates

    func testToggleIsOptimisticAndConfirmed() async {
        let backend = DemoHomeBackend(latency: .milliseconds(100))
        let (model, _) = make(backend)
        let task = model.toggle(DemoHomeBackend.porchLightID)
        XCTAssertEqual(model.accessory(DemoHomeBackend.porchLightID)?.state, .power(isOn: true), "shows on at once")
        XCTAssertTrue(model.pendingIDs.contains(DemoHomeBackend.porchLightID))
        await task?.value
        XCTAssertEqual(model.accessory(DemoHomeBackend.porchLightID)?.state, .power(isOn: true))
        XCTAssertFalse(model.pendingIDs.contains(DemoHomeBackend.porchLightID))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(backend.sentCommands.last?.command, .setPower(on: true))
    }

    func testRollbackOnError() async {
        let (model, backend) = make()
        backend.failNextWrite = .failed("The lock is busy.")
        let task = model.unlock(DemoHomeBackend.lockID)
        XCTAssertEqual(model.accessory(DemoHomeBackend.lockID)?.stateText, "Unlocking…")
        await task?.value
        XCTAssertEqual(model.accessory(DemoHomeBackend.lockID)?.state, .lock(current: .secured, targetSecured: true),
                       "rolled back")
        XCTAssertEqual(model.errorMessage, "Front Door Lock: The lock is busy.")
        XCTAssertFalse(model.pendingIDs.contains(DemoHomeBackend.lockID))
    }

    func testUnreachableRollsBackAndShowsNotResponding() async {
        let (model, _) = make()
        let task = model.openGarage(DemoHomeBackend.gateID)
        XCTAssertEqual(model.accessory(DemoHomeBackend.gateID)?.isDoorHeadingOpen, true)
        await task?.value
        let gate = model.accessory(DemoHomeBackend.gateID)!
        XCTAssertTrue(gate.isDoorClosed, "rolled back")
        XCTAssertEqual(model.stateText(for: gate), "Not responding")
        XCTAssertTrue(model.errorMessage?.contains("Not responding") ?? false)
    }

    func testTimeoutRollsBack() async {
        let (model, backend) = make()
        backend.unreachableHangs = true
        model.commandTimeout = .milliseconds(150)
        // The gate never answers at all.
        let gate = DemoHomeBackend.gateID
        let start = Date()
        let task = model.openGarage(gate)
        await task?.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "gives up at the timeout")
        XCTAssertTrue(model.accessory(gate)!.isDoorClosed)
        XCTAssertTrue(model.unresponsiveIDs.contains(gate))
        // A fresh report from the accessory clears "Not responding".
        backend.setReachable(true, accessoryID: gate)
        XCTAssertFalse(model.unresponsiveIDs.contains(gate))
        XCTAssertEqual(model.stateText(for: model.accessory(gate)!), "Closed")
    }

    func testScene() async {
        let (model, backend) = make()
        await model.runScene(DemoHomeBackend.arriveSceneID)?.value
        XCTAssertEqual(backend.scenesRun, [DemoHomeBackend.arriveSceneID])
        XCTAssertEqual(model.accessory(DemoHomeBackend.porchLightID)?.state, .power(isOn: true))
        XCTAssertEqual(model.accessory(DemoHomeBackend.hallwayLightID)?.state, .power(isOn: true))
        XCTAssertFalse(model.pendingIDs.contains(DemoHomeBackend.arriveSceneID))
    }

    func testUnlockNeedsConfirmationButLockDoesNot() {
        let (model, _) = make()
        let lock = HomeTile.accessory(model.accessory(DemoHomeBackend.lockID)!)
        XCTAssertTrue(model.needsConfirmation(lock))
        XCTAssertFalse(model.needsConfirmation(.accessory(garage(model))))
        var asked: HomeAccessory?
        model.handleTap(lock) { asked = $0 }
        XCTAssertEqual(asked?.id, DemoHomeBackend.lockID)
        XCTAssertEqual(model.accessory(DemoHomeBackend.lockID)?.stateText, "Locked", "nothing sent before confirming")
    }

    // MARK: Garage in the demo

    func testGarageOpensThenCloses() async {
        let (model, _) = make()
        XCTAssertEqual(garage(model).stateText, "Closed")
        let task = model.openGarage()
        XCTAssertEqual(garage(model).stateText, "Opening…")
        await task?.value
        XCTAssertEqual(garage(model).stateText, "Opening…", "still travelling")
        await waitUntil { self.garage(model).stateText == "Open" }
        XCTAssertEqual(garage(model).state, .door(current: .open, targetOpen: true, obstructed: false))

        model.perform(.accessory(garage(model)))
        XCTAssertEqual(garage(model).stateText, "Closing…", "tap on an open door closes it")
        await waitUntil { self.garage(model).stateText == "Closed" }
        XCTAssertTrue(garage(model).isDoorClosed)
    }

    func testGarageObstruction() async {
        let backend = DemoHomeBackend(latency: .zero, doorTravelTime: .seconds(5))
        let (model, _) = make(backend)
        await model.openGarage()?.value
        XCTAssertEqual(garage(model).stateText, "Opening…")
        backend.setObstructed(true)
        XCTAssertEqual(garage(model).state, .door(current: .stopped, targetOpen: true, obstructed: true))
        XCTAssertEqual(garage(model).stateText, "Obstructed")
        XCTAssertTrue(garage(model).needsAttention)

        await model.closeGarage()?.value
        XCTAssertEqual(garage(model).stateText, "Obstructed", "won't move while blocked")

        backend.doorTravelTime = .milliseconds(100)
        backend.setObstructed(false)
        XCTAssertEqual(garage(model).stateText, "Stopped")
        await model.closeGarage()?.value
        await waitUntil { self.garage(model).stateText == "Closed" }
        XCTAssertEqual(garage(model).stateText, "Closed")
    }

    // MARK: Arrival

    func testArrivalOncePerTrip() {
        let (model, _) = make()
        XCTAssertNil(model.arrivalSuggestion(distanceToHome: 100, isNavigatingHome: true, speed: 5),
                     "not while leaving home")
        _ = model.arrivalSuggestion(distanceToHome: 5000, isNavigatingHome: true, speed: 20); _ = model.arrivalSuggestion(distanceToHome: 5000, isNavigatingHome: true, speed: 20)   // leaving home takes 3 good fixes
        XCTAssertNil(model.arrivalSuggestion(distanceToHome: 5000, isNavigatingHome: true, speed: 20))
        XCTAssertNil(model.arrivalSuggestion(distanceToHome: 400, isNavigatingHome: true, speed: 10), "not yet within 300 m")
        let offer = model.arrivalSuggestion(distanceToHome: 280, isNavigatingHome: true, speed: 10)
        XCTAssertEqual(offer?.title, "Open garage?")
        XCTAssertEqual(offer?.action, .openDoor(accessoryID: DemoHomeBackend.garageID))
        XCTAssertEqual(offer?.wasPerformed, false)
        XCTAssertEqual(model.activeArrival, offer)
        XCTAssertEqual(model.arrivalSuggestion(distanceToHome: 150, isNavigatingHome: true, speed: 5), offer,
                       "same offer while it is on screen")
        XCTAssertEqual(garage(model).stateText, "Closed", "never acts on its own by default")

        model.dismissArrival()
        XCTAssertNil(model.arrivalSuggestion(distanceToHome: 50, isNavigatingHome: true, speed: 2), "once per trip")
        XCTAssertNil(model.arrivalSuggestion(distanceToHome: 10, isNavigatingHome: false, speed: 0))

        // Leave and come back: a new trip.
        _ = model.arrivalSuggestion(distanceToHome: 3000, isNavigatingHome: false, speed: 20); _ = model.arrivalSuggestion(distanceToHome: 3000, isNavigatingHome: false, speed: 20)   // leaving home takes 3 good fixes
        XCTAssertNil(model.arrivalSuggestion(distanceToHome: 3000, isNavigatingHome: false, speed: 20))
        XCTAssertNotNil(model.arrivalSuggestion(distanceToHome: 200, isNavigatingHome: false, speed: 8))
        model.acceptArrival()
        XCTAssertNil(model.activeArrival)
        XCTAssertEqual(garage(model).stateText, "Opening…", "Open on the banner opens it")
    }

    /// One stray fix far away (cold start, cell-tower guess) while parked at home must not
    /// re-arm arrival, and opening by itself needs a real speed reading.
    func testStrayFixDoesNotOpenTheGarage() {
        let (model, _) = make()
        model.autoOpenGarageOnArrival = true
        _ = model.arrivalSuggestion(distanceToHome: 5000, isNavigatingHome: false, speed: 20)
        _ = model.arrivalSuggestion(distanceToHome: 5000, isNavigatingHome: false, speed: 20)
        _ = model.arrivalSuggestion(distanceToHome: 5000, isNavigatingHome: false, speed: 20)
        let first = model.arrivalSuggestion(distanceToHome: 100, isNavigatingHome: false, speed: 3)
        XCTAssertEqual(first?.wasPerformed, true, "a real trip home opens it")
        model.dismissArrival()
        // Parked at home: one stray far fix, then home again.
        XCTAssertNil(model.arrivalSuggestion(distanceToHome: 3000, isNavigatingHome: false, speed: nil))
        XCTAssertNil(model.arrivalSuggestion(distanceToHome: 20, isNavigatingHome: false, speed: nil), "not re-armed by one fix")
        // A real trip, but the speed is unknown at the end: offer, don't open.
        for _ in 0..<3 { _ = model.arrivalSuggestion(distanceToHome: 4000, isNavigatingHome: false, speed: 20) }
        let offer = model.arrivalSuggestion(distanceToHome: 100, isNavigatingHome: false, speed: nil)
        XCTAssertNotNil(offer)
        XCTAssertEqual(offer?.wasPerformed, false)
    }

    func testArrivalDistanceAndSpeed() {
        let (model, _) = make()
        model.arrivalDistance = 500
        XCTAssertEqual(model.rearmDistance, 1500)
        _ = model.arrivalSuggestion(distanceToHome: 2000, isNavigatingHome: false, speed: 20); _ = model.arrivalSuggestion(distanceToHome: 2000, isNavigatingHome: false, speed: 20)   // leaving home takes 3 good fixes
        model.arrivalSuggestion(distanceToHome: 2000, isNavigatingHome: false, speed: 20)
        XCTAssertNil(model.arrivalSuggestion(distanceToHome: 450, isNavigatingHome: false, speed: 25),
                     "passing at speed without a route home")
        XCTAssertNil(model.arrivalSuggestion(distanceToHome: nil, isNavigatingHome: false, speed: nil))
        XCTAssertNotNil(model.arrivalSuggestion(distanceToHome: 450, isNavigatingHome: true, speed: 25),
                        "navigating home: speed doesn't matter")
    }

    func testArrivalNeverOffersLocks() async {
        let (model, _) = make()
        // Garage already open: next comes the gate (not responding, so skipped), then the
        // arrive scene, which has no lock in it.
        await model.openGarage()?.value
        model.beginTrip()
        let offer = model.arrivalSuggestion(distanceToHome: 100, isNavigatingHome: true, speed: 5)
        XCTAssertEqual(offer?.action, .runScene(sceneID: DemoHomeBackend.arriveSceneID))
        XCTAssertEqual(offer?.title, "Run Arrive Home?")

        // A home with only a lock and a scene that unlocks: nothing to offer.
        final class LockOnly: HomeBackend {
            let isDemo = true
            var onEvent: (@MainActor (HomeBackendEvent) -> Void)?
            func start() {
                onEvent?(.homes([HomeSnapshot(
                    id: "h", name: "Flat", isPrimary: true,
                    accessories: [HomeAccessory(id: "l", name: "Door", kind: .lock,
                                                state: .lock(current: .secured, targetSecured: true))],
                    scenes: [HomeScene(id: "s", name: "I'm Home", kind: .arrive, touchesLocks: true)])]))
            }
            func send(_ command: HomeCommand, to accessoryID: String, in homeID: String) async throws {
                XCTFail("must not write")
            }
            func runScene(_ sceneID: String, in homeID: String) async throws { XCTFail("must not run") }
        }
        let flat = HomeModel(backend: LockOnly(), defaults: defaults, resetState: false)
        flat.autoOpenGarageOnArrival = true
        flat.start()
        flat.beginTrip()
        XCTAssertNil(flat.arrivalSuggestion(distanceToHome: 50, isNavigatingHome: true, speed: 3))
    }

    func testAutoOpenOnlyWhenEnabled() async {
        let (model, backend) = make()
        XCTAssertFalse(model.autoOpenGarageOnArrival, "off by default")
        model.autoOpenGarageOnArrival = true
        model.beginTrip()
        let offer = model.arrivalSuggestion(distanceToHome: 250, isNavigatingHome: false, speed: 6)
        XCTAssertEqual(offer?.wasPerformed, true)
        XCTAssertEqual(garage(model).stateText, "Opening…")
        await waitUntil { backend.sentCommands.count == 1 }
        XCTAssertEqual(backend.sentCommands.first?.command, .setDoor(open: true))
        XCTAssertEqual(backend.sentCommands.first?.accessoryID, DemoHomeBackend.garageID)
        model.acceptArrival()
        XCTAssertEqual(backend.sentCommands.count, 1, "accepting a done offer doesn't send again")
        XCTAssertEqual(HomeModel(backend: DemoHomeBackend(), defaults: defaults, resetState: false)
            .autoOpenGarageOnArrival, true, "setting persists")
    }

    // MARK: Favourites

    func testFavouritesPersistAndOrder() {
        let (model, _) = make()
        XCTAssertEqual(model.favouriteIDs, [DemoHomeBackend.garageID, DemoHomeBackend.gateID, DemoHomeBackend.arriveSceneID],
                       "defaults before the user picks")
        model.toggleFavourite(DemoHomeBackend.gateID)
        model.toggleFavourite(DemoHomeBackend.arriveSceneID)
        model.toggleFavourite(DemoHomeBackend.porchLightID)
        model.toggleFavourite(DemoHomeBackend.lockID)
        XCTAssertEqual(model.favouriteIDs, [DemoHomeBackend.garageID, DemoHomeBackend.porchLightID, DemoHomeBackend.lockID])
        XCTAssertFalse(model.isFavourite(DemoHomeBackend.gateID))
        XCTAssertEqual(model.dashboardTiles.map(\.id),
                       [DemoHomeBackend.garageID, DemoHomeBackend.lockID, DemoHomeBackend.porchLightID],
                       "garage first, then by kind")

        let (reopened, _) = make()
        XCTAssertEqual(reopened.favouriteIDs, model.favouriteIDs)

        model.toggleFavourite(DemoHomeBackend.garageID)
        model.toggleFavourite(DemoHomeBackend.leaveSceneID)
        model.toggleFavourite(DemoHomeBackend.hallwayLightID)
        model.toggleFavourite(DemoHomeBackend.garageID)
        XCTAssertEqual(model.dashboardTiles.count, 3, "at most three")
        XCTAssertEqual(model.dashboardTiles.first?.id, DemoHomeBackend.garageID, "garage first even when added last")

        let reset = HomeModel(backend: DemoHomeBackend(latency: .zero), defaults: defaults, resetState: true)
        reset.start()
        XCTAssertNil(reset.savedFavouriteIDs, "-ResetState clears it")
    }

    func testSelectedHomePersists() {
        final class TwoHomes: HomeBackend {
            let isDemo = true
            var onEvent: (@MainActor (HomeBackendEvent) -> Void)?
            func start() {
                onEvent?(.homes([HomeSnapshot(id: "a", name: "House", isPrimary: true, accessories: [], scenes: []),
                                 HomeSnapshot(id: "b", name: "Beach", isPrimary: false, accessories: [], scenes: [])]))
            }
            func send(_ command: HomeCommand, to accessoryID: String, in homeID: String) async throws {}
            func runScene(_ sceneID: String, in homeID: String) async throws {}
        }
        let model = HomeModel(backend: TwoHomes(), defaults: defaults, resetState: false)
        model.start()
        XCTAssertEqual(model.selectedHome?.name, "House", "primary by default")
        model.selectHome("b")
        let again = HomeModel(backend: TwoHomes(), defaults: defaults, resetState: false)
        again.start()
        XCTAssertEqual(again.selectedHome?.name, "Beach")
    }
}
