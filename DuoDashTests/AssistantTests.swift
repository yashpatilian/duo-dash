import XCTest
import MapKit
@testable import DuoDash

// MARK: - Stop selection

final class StopPlannerTests: XCTestCase {
    /// About 11 km due north from the CBD.
    private let line = [CLLocationCoordinate2D(latitude: -37.80, longitude: 144.96),
                        CLLocationCoordinate2D(latitude: -37.75, longitude: 144.96),
                        CLLocationCoordinate2D(latitude: -37.70, longitude: 144.96)]

    func testSamplesAreEvenlySpacedAndCapped() {
        let samples = StopPlanner.samplePoints(along: line, spacing: 2_000, maxCount: 4)
        XCTAssertEqual(samples.count, 4)
        // Half a gap in from each end, rising steadily north.
        XCTAssertEqual(samples[0].latitude, -37.80 + 0.1 / 8, accuracy: 0.002)
        XCTAssertEqual(samples[3].latitude, -37.70 - 0.1 / 8, accuracy: 0.002)
        for k in 1..<samples.count { XCTAssertGreaterThan(samples[k].latitude, samples[k - 1].latitude) }
        XCTAssertEqual(StopPlanner.samplePoints(along: line, spacing: 50_000, maxCount: 5).count, 1)
        XCTAssertTrue(StopPlanner.samplePoints(along: [], spacing: 1_000, maxCount: 3).isEmpty)
    }

    func testDistanceToPolyline() {
        let east = CLLocationCoordinate2D(latitude: -37.75, longitude: 144.97)   // ~880 m east of the line
        XCTAssertEqual(StopPlanner.distance(from: east, to: line), 880, accuracy: 40)
        XCTAssertEqual(StopPlanner.distance(from: line[1], to: line), 0, accuracy: 0.5)
    }

    func testShortlistKeepsNearestDedupedAndDropsFarOnes() {
        let near = StopPlanner.Candidate(id: "near", coordinate: .init(latitude: -37.76, longitude: 144.961))
        let mid = StopPlanner.Candidate(id: "mid", coordinate: .init(latitude: -37.72, longitude: 144.965))
        let far = StopPlanner.Candidate(id: "far", coordinate: .init(latitude: -37.75, longitude: 145.10))
        let list = StopPlanner.shortlist([mid, far, near, near], route: line, limit: 5, maxOffset: 3_000)
        XCTAssertEqual(list.map(\.id), ["near", "mid"])
        XCTAssertEqual(StopPlanner.shortlist([mid, near], route: line, limit: 1).map(\.id), ["near"])
    }

    func testRankPicksSmallestTotalTripTime() {
        let options = [
            StopPlanner.Option(id: "a", toStop: 300, toDestination: 900),    // 1200
            StopPlanner.Option(id: "b", toStop: 600, toDestination: 450),    // 1050 (best)
            StopPlanner.Option(id: "c", toStop: 100, toDestination: nil),    // no ETA: dropped
            StopPlanner.Option(id: "d", toStop: 200, toDestination: 1_000),  // 1200, reached sooner than a
        ]
        let ranked = StopPlanner.rank(options, direct: 1_000)
        XCTAssertEqual(ranked.map(\.id), ["b", "d", "a"])
        XCTAssertEqual(ranked[0].total, 1_050)
        XCTAssertEqual(ranked[0].added, 50)
        XCTAssertEqual(StopPlanner.best(options, direct: nil)?.id, "b")
        XCTAssertNil(StopPlanner.best(options, direct: nil)?.added)
        XCTAssertNil(StopPlanner.best([.init(id: "x", toStop: nil, toDestination: 5)], direct: 10))
        // A stop right on the route never reports negative added time.
        XCTAssertEqual(StopPlanner.rank([.init(id: "z", toStop: 400, toDestination: 590)], direct: 1_000)[0].added, 0)
    }
}

// MARK: - Intent parsing fallback

final class IntentParserTests: XCTestCase {
    func testNavigate() {
        XCTAssertEqual(IntentParser.parse("Take me to Central Station"),
                       .navigate(destination: "central station", stopAlongTheWay: nil, startNow: true))
        XCTAssertEqual(IntentParser.parse("Hey, can you navigate to the MCG please?"),
                       .navigate(destination: "the mcg", stopAlongTheWay: nil, startNow: true))
        XCTAssertEqual(IntentParser.parse("take me home"), .navigate(destination: "home", stopAlongTheWay: nil, startNow: true))
        XCTAssertEqual(IntentParser.parse("Take me to Sam’s house"),
                       .navigate(destination: "sam's house", stopAlongTheWay: nil, startNow: true))
        XCTAssertEqual(IntentParser.parse("I want to go to Chin Chin"),
                       .navigate(destination: "chin chin", stopAlongTheWay: nil, startNow: false))
    }

    func testNavigateWithStopOnTheWay() {
        XCTAssertEqual(IntentParser.parse("I want to go to Corner Bakery but stop for petrol on the way"),
                       .navigate(destination: "corner bakery", stopAlongTheWay: "petrol", startNow: false))
        XCTAssertEqual(IntentParser.parse("Take me to Geelong and stop at a servo along the way"),
                       .navigate(destination: "geelong", stopAlongTheWay: "servo", startNow: false))
        XCTAssertEqual(IntentParser.parse("Navigate to work, grab coffee on the way"),
                       .navigate(destination: "work", stopAlongTheWay: "coffee", startNow: false))
    }

    func testStopAlongTheWayAlone() {
        XCTAssertEqual(IntentParser.parse("Stop at a petrol station on the way"), .addStopAlongTheWay(category: "petrol station"))
        XCTAssertEqual(IntentParser.parse("I need to get petrol on the way"), .addStopAlongTheWay(category: "petrol"))
        XCTAssertEqual(IntentParser.parse("add a stop at Bunnings"), .addStop(place: "bunnings"))
    }

    func testFindPlaces() {
        XCTAssertEqual(IntentParser.parse("Suggest some places for dinner"), .findPlaces(query: "restaurant", nearDestination: false))
        XCTAssertEqual(IntentParser.parse("find coffee near me"), .findPlaces(query: "coffee", nearDestination: false))
        XCTAssertEqual(IntentParser.parse("Find a petrol station near my destination"),
                       .findPlaces(query: "petrol station", nearDestination: true))
        XCTAssertEqual(IntentParser.parse("petrol"), .findPlaces(query: "petrol", nearDestination: false))
    }

    func testCommands() {
        XCTAssertEqual(IntentParser.parse("Start"), .startNavigation)
        XCTAssertEqual(IntentParser.parse("let's go"), .startNavigation)
        XCTAssertEqual(IntentParser.parse("Yes please."), .startNavigation)
        XCTAssertEqual(IntentParser.parse("cancel the route"), .endNavigation)
        XCTAssertEqual(IntentParser.parse("Does it have good reviews?"), .reviews)
        XCTAssertEqual(IntentParser.parse("what's the meaning of life"), .unknown)
        XCTAssertEqual(IntentParser.parse("   "), .unknown)
    }

    func testContactNameAndCategories() {
        XCTAssertEqual(IntentParser.contactName(in: "Sam's house"), "sam")
        XCTAssertEqual(IntentParser.contactName(in: "Mum’s place"), "mum")
        XCTAssertNil(IntentParser.contactName(in: "Central Station"))
        XCTAssertEqual(PlaceCategory.match("servo")?.category, .gasStation)
        XCTAssertEqual(PlaceCategory.match("petrol station")?.query, "petrol station")
        XCTAssertEqual(PlaceCategory.match("coffee")?.category, .cafe)
        XCTAssertNil(PlaceCategory.match("Corner Bakery"))
    }
}

// MARK: - Tool schemas and input validation

@MainActor
final class AssistantToolTests: XCTestCase {
    func testClaudeSchemasAreStrict() {
        for spec in AssistantTools.all {
            let tool = spec.claudeTool
            XCTAssertEqual(tool["strict"] as? Bool, true, spec.name)
            let schema = tool["input_schema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object")
            XCTAssertEqual(schema?["additionalProperties"] as? Bool, false)
            XCTAssertNotNil(schema?["required"] as? [String])
        }
        let plan = AssistantTools.planRoute.jsonSchema
        XCTAssertEqual(plan["required"] as? [String], ["destination"])
        let props = plan["properties"] as? [String: [String: Any]]
        XCTAssertEqual(props?["stops"]?["type"] as? String, "array")
        XCTAssertEqual(props?["start_now"]?["type"] as? String, "boolean")
        let near = (AssistantTools.searchPlaces.jsonSchema["properties"] as? [String: [String: Any]])?["near"]
        XCTAssertEqual(near?["enum"] as? [String], ["current_location", "destination", "along_route"])
    }

    func testFoundationModelsSchemasBuild() throws {
        for spec in AssistantTools.all {
            XCTAssertNoThrow(try AppleIntelligenceBrain.schema(for: spec), spec.name)
        }
    }

    func testInputDecodingValidates() throws {
        let ok = try AssistantToolSpec.decode(PlanRouteInput.self,
                                              from: Data(#"{"destination":"MCG","stops":[" ", "Bunnings"],"start_now":null}"#.utf8),
                                              allowed: ["destination", "stops", "stop_along_the_way", "start_now"]).validated()
        XCTAssertEqual(ok.destination, "MCG")
        XCTAssertEqual(ok.stops, ["Bunnings"])
        XCTAssertNil(ok.start_now)

        XCTAssertThrowsError(try AssistantToolSpec.decode(PlanRouteInput.self, from: Data(#"{"destination":"x","bogus":1}"#.utf8),
                                                          allowed: ["destination"]))
        XCTAssertThrowsError(try AssistantToolSpec.decode(PlanRouteInput.self, from: Data(#"{"stops":[]}"#.utf8),
                                                          allowed: ["destination", "stops"]))
        XCTAssertThrowsError(try AssistantToolSpec.decode(SearchPlacesInput.self, from: Data(#"{"query":"x","near":"mars"}"#.utf8),
                                                          allowed: ["query", "near"]))
        XCTAssertThrowsError(try AssistantToolSpec.decode(SearchPlacesInput.self, from: Data(#"{"query":"  "}"#.utf8),
                                                          allowed: ["query", "near"]).validated())
        XCTAssertThrowsError(try AssistantToolSpec.decode(AddStopInput.self, from: Data("{}".utf8),
                                                          allowed: ["place", "category_along_the_way"]).validated())
        XCTAssertNoThrow(try AssistantToolSpec.decode(EmptyInput.self, from: Data(), allowed: []))
    }
}

// MARK: - Settings

@MainActor
final class AssistantSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultsAndPersistence() {
        let d = freshDefaults()
        let store = InMemorySecretStore()
        let s = AssistantSettings(defaults: d, keyStore: store)
        XCTAssertEqual(s.provider, .appleIntelligence)
        XCTAssertEqual(s.claudeModel, "claude-opus-5-5")
        XCTAssertEqual(s.claudeEffort, "low")
        XCTAssertTrue(s.speaksReplies)
        XCTAssertFalse(s.hasClaudeKey)

        s.provider = .claude
        s.claudeEffort = "high"
        s.claudeEffort = "extreme"          // not an option: back to low
        s.speaksReplies = false
        s.setClaudeKey("  sk-test-123 \n")
        XCTAssertTrue(s.hasClaudeKey)
        XCTAssertEqual(s.claudeKey, "sk-test-123")
        XCTAssertNil(d.dictionaryRepresentation().values.compactMap { $0 as? String }.first { $0.contains("sk-test") },
                     "the key must never be written to UserDefaults")

        let reloaded = AssistantSettings(defaults: d, keyStore: store)
        XCTAssertEqual(reloaded.provider, .claude)
        XCTAssertEqual(reloaded.claudeEffort, "low")
        XCTAssertFalse(reloaded.speaksReplies)
        XCTAssertTrue(reloaded.hasClaudeKey)
        reloaded.clearClaudeKey()
        XCTAssertFalse(reloaded.hasClaudeKey)
        XCTAssertNil(reloaded.claudeKey)
    }

    func testKeychainStoreRoundTrip() {
        let store = KeychainSecretStore(service: "duodash.anthropic.tests", account: UUID().uuidString)
        XCTAssertNil(store.read())
        XCTAssertTrue(store.write("abc"))
        XCTAssertTrue(store.write("def"))
        XCTAssertEqual(store.read(), "def")
        store.delete()
        XCTAssertNil(store.read())
    }
}
