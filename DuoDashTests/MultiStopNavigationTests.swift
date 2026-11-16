import XCTest
import MapKit
@testable import DuoDash

/// MKRoute pieces with fixed geometry, so legs can be driven with simulated fixes.
private final class FakeStep: MKRoute.Step {
    private let _instructions: String
    private let _polyline: MKPolyline
    private let _distance: CLLocationDistance

    init(_ instructions: String, _ points: [CLLocationCoordinate2D]) {
        _instructions = instructions
        _polyline = MKPolyline(coordinates: points, count: points.count)
        _distance = zip(points, points.dropFirst()).reduce(0) { $0 + MKMapPoint($1.0).distance(to: MKMapPoint($1.1)) }
        super.init()
    }

    override var instructions: String { _instructions }
    override var polyline: MKPolyline { _polyline }
    override var distance: CLLocationDistance { _distance }
}

private final class FakeRoute: MKRoute {
    private let _steps: [MKRoute.Step]
    private let _polyline: MKPolyline
    private let _time: TimeInterval

    /// A straight two-step leg: drive to the midpoint, turn, drive on to the end.
    init(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, minutes: Double) {
        let mid = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
        _steps = [FakeStep("", [a, mid]), FakeStep("Turn left onto Test St", [mid, b])]
        _polyline = MKPolyline(coordinates: [a, mid, b], count: 3)
        _time = minutes * 60
        super.init()
    }

    override var steps: [MKRoute.Step] { _steps }
    override var polyline: MKPolyline { _polyline }
    override var distance: CLLocationDistance { _steps.reduce(0) { $0 + $1.distance } }
    override var expectedTravelTime: TimeInterval { _time }
    override var name: String { "Test Rd" }
}

@MainActor
final class MultiStopNavigationTests: XCTestCase {
    private let start = CLLocationCoordinate2D(latitude: -37.8000, longitude: 144.9600)
    private let stopA = CLLocationCoordinate2D(latitude: -37.7900, longitude: 144.9600)
    private let stopB = CLLocationCoordinate2D(latitude: -37.7800, longitude: 144.9600)
    private let end = CLLocationCoordinate2D(latitude: -37.7700, longitude: 144.9600)

    private var defaults: UserDefaults!
    private var requested: [(source: CLLocationCoordinate2D?, destination: String)] = []

    override func setUp() {
        let name = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        requested = []
    }

    private func item(_ name: String, _ c: CLLocationCoordinate2D) -> MKMapItem {
        let item = MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
        item.name = name
        return item
    }

    /// Routes straight from the source (or `start` for "current location") to the destination.
    private func makeModel() -> (NavigationModel, LocationManager) {
        let location = LocationManager(live: false)   // fixes only from drive(), never the simulator's GPS
        let model = NavigationModel(location: location, defaults: defaults) { [unowned self] source, destination in
            let from = source.isCurrentLocation ? self.start : source.location.coordinate
            self.requested.append((source.isCurrentLocation ? nil : source.location.coordinate, destination.name ?? ""))
            return FakeRoute(from: from, to: destination.location.coordinate, minutes: 2)
        }
        return (model, location)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Feeds fixes every ~50 m along a straight line, like a car driving it.
    private func drive(_ location: LocationManager, from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) {
        let metres = MKMapPoint(a).distance(to: MKMapPoint(b))
        let count = max(2, Int(metres / 50))
        for i in 0...count {
            let t = Double(i) / Double(count)
            let c = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                           longitude: a.longitude + (b.longitude - a.longitude) * t)
            location.onUpdate?(CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                          course: 0, speed: 12, timestamp: Date()))
        }
    }

    func testVoiceGuidanceIsOffByDefaultAndRemembered() {
        let (model, _) = makeModel()
        XCTAssertFalse(model.voiceEnabled)
        model.voiceEnabled = true
        XCTAssertTrue(defaults.bool(forKey: NavigationModel.voiceKey))
        XCTAssertTrue(makeModel().0.voiceEnabled)
        makeModel().0.voiceEnabled = false
        XCTAssertFalse(makeModel().0.voiceEnabled)
    }

    func testTripThroughTwoStopsProgressesLegByLeg() async throws {
        let (model, location) = makeModel()
        model.go(to: item("End", end), via: [item("Stop A", stopA), item("Stop B", stopB)])
        await waitUntil { model.state == .navigating }
        XCTAssertEqual(model.state, .navigating)
        XCTAssertEqual(model.legs.count, 3)
        XCTAssertEqual(requested.map(\.destination).sorted(), ["End", "Stop A", "Stop B"])
        XCTAssertEqual(model.legIndex, 0)
        XCTAssertEqual(model.stopProgressText, "Stop 1 of 2 · Stop A")
        XCTAssertEqual(model.tripTime, 360, accuracy: 0.1)
        XCTAssertEqual(model.remainingTime, 360, accuracy: 1)
        XCTAssertEqual(model.remainingDistance, model.tripDistance, accuracy: 1)
        XCTAssertEqual(model.maneuverInstruction, "Turn left onto Test St")

        // Leg 1: turn at the midpoint, then arrive at Stop A and carry straight on.
        drive(location, from: start, to: stopA)
        XCTAssertEqual(model.state, .navigating, "a stop is not the end of the trip")
        XCTAssertEqual(model.legIndex, 1)
        XCTAssertEqual(model.currentTarget?.name, "Stop B")
        XCTAssertEqual(model.stopProgressText, "Stop 2 of 2 · Stop B")
        XCTAssertEqual(model.remainingTime, 240, accuracy: 5)

        // The saved trip now only lists the stop still to come.
        let saved = try JSONDecoder().decode(SavedTrip.self, from: XCTUnwrap(defaults.data(forKey: NavigationModel.activeKey)))
        XCTAssertEqual(saved.name, "End")
        XCTAssertEqual(saved.stops?.map(\.name), ["Stop B"])

        drive(location, from: stopA, to: stopB)
        XCTAssertEqual(model.legIndex, 2)
        XCTAssertNil(model.stopProgressText)
        XCTAssertEqual(model.currentTarget?.name, "End")

        drive(location, from: stopB, to: end)
        XCTAssertEqual(model.state, .arrived)
        XCTAssertEqual(model.maneuverInstruction, "Arrive at End")
        XCTAssertNil(defaults.data(forKey: NavigationModel.activeKey), "arriving clears the resumable trip")
    }

    func testSingleDestinationStillArrives() async {
        let (model, location) = makeModel()
        model.go(to: item("End", stopA))
        await waitUntil { model.state == .navigating }
        XCTAssertEqual(model.legs.count, 1)
        XCTAssertNil(model.stopProgressText)
        drive(location, from: start, to: stopA)
        XCTAssertEqual(model.state, .arrived)
    }

    func testAddingAStopWhileGuidingMakesItTheNextStop() async {
        let (model, location) = makeModel()
        model.go(to: item("End", end))
        await waitUntil { model.state == .navigating }
        drive(location, from: start, to: CLLocationCoordinate2D(latitude: -37.7990, longitude: 144.9600))

        model.addStop(item("Servo", stopA))
        await waitUntil { model.legs.count == 2 && !model.isRerouting }
        XCTAssertEqual(model.stops.map(\.name), ["Servo"])
        XCTAssertEqual(model.legIndex, 0)
        XCTAssertEqual(model.stopProgressText, "Stop 1 of 1 · Servo")
        XCTAssertEqual(model.state, .navigating)

        // Adding to a preview goes before the destination instead.
        model.end()
        model.preview(to: item("End", end), via: [item("Stop A", stopA)])
        await waitUntil { model.state == .previewing }
        model.addStop(item("Stop B", stopB))
        await waitUntil { model.state == .previewing && model.legs.count == 3 }
        XCTAssertEqual(model.stops.map(\.name), ["Stop A", "Stop B"])
    }

    func testOffRouteReroutesOnlyTheCurrentLeg() async {
        let (model, location) = makeModel()
        model.go(to: item("End", end), via: [item("Stop A", stopA)])
        await waitUntil { model.state == .navigating }
        requested = []
        // Three good fixes well away from the leg.
        for _ in 0..<3 {
            location.onUpdate?(CLLocation(coordinate: .init(latitude: -37.7950, longitude: 144.9700), altitude: 0,
                                          horizontalAccuracy: 10, verticalAccuracy: 10, course: 0, speed: 10, timestamp: Date()))
        }
        await waitUntil { !self.requested.isEmpty && !model.isRerouting }
        XCTAssertEqual(requested.map(\.destination), ["Stop A"], "reroute targets the next stop, not the destination")
        XCTAssertEqual(model.legs.count, 2)
        XCTAssertEqual(model.stops.map(\.name), ["Stop A"])
    }

    func testSkipStop() async {
        let (model, _) = makeModel()
        model.go(to: item("End", end), via: [item("Stop A", stopA)])
        await waitUntil { model.state == .navigating }
        model.skipStop()
        XCTAssertTrue(model.stops.isEmpty)
        XCTAssertEqual(model.legs.count, 1)
        XCTAssertEqual(model.currentTarget?.name, "End")
    }

    // MARK: Resume after kill

    func testOldSingleDestinationDataStillResumes() async throws {
        // Exactly what the app saved before multi-stop.
        let old = try JSONEncoder().encode(SavedPlace(name: "Central Station", latitude: -37.818, longitude: 144.967))
        defaults.set(old, forKey: NavigationModel.activeKey)
        let (model, _) = makeModel()
        XCTAssertEqual(model.resumable?.name, "Central Station")
        XCTAssertTrue(model.resumableStops.isEmpty)
        model.resume()
        await waitUntil { model.state == .navigating }
        XCTAssertEqual(model.destination?.name, "Central Station")
        XCTAssertTrue(model.stops.isEmpty)
    }

    func testMultiStopTripResumesWithAllStops() async throws {
        let (first, _) = makeModel()
        first.go(to: item("End", end), via: [item("Stop A", stopA), item("Stop B", stopB)])
        await waitUntil { first.state == .navigating }

        // The new format is still readable as a plain SavedPlace (older builds).
        let data = try XCTUnwrap(defaults.data(forKey: NavigationModel.activeKey))
        XCTAssertEqual(try JSONDecoder().decode(SavedPlace.self, from: data).name, "End")

        let (relaunched, _) = makeModel()
        XCTAssertEqual(relaunched.resumable?.name, "End")
        XCTAssertEqual(relaunched.resumableStops.map(\.name), ["Stop A", "Stop B"])
        relaunched.resume()
        await waitUntil { relaunched.state == .navigating }
        XCTAssertEqual(relaunched.stops.map(\.name), ["Stop A", "Stop B"])
        XCTAssertEqual(relaunched.legs.count, 3)

        relaunched.dismissResume()
        relaunched.end()
        XCTAssertNil(defaults.data(forKey: NavigationModel.activeKey))
    }
}
