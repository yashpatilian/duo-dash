import XCTest
@testable import DuoDash

@MainActor
private final class RecordingTools: AssistantToolRunner {
    var calls: [String] = []
    var toolSpecs: [AssistantToolSpec] { AssistantTools.all }
    func runTool(named name: String, input: Data) async -> ToolOutcome {
        calls.append(name + " " + (String(data: input, encoding: .utf8) ?? ""))
        return ToolOutcome(text: "1. Shell — Petrol station — 3 min drive — 1.2 km", say: "Found Shell")
    }
}

/// Reports what Foundation Models says on this machine; when the model is available,
/// checks that it calls our tools through the adapter. Skips otherwise.
@MainActor
final class AppleIntelligenceLiveTests: XCTestCase {
    func testFoundationModelsAvailabilityAndToolCall() async throws {
        print("FOUNDATION-MODELS-AVAILABILITY: \(AppleIntelligenceBrain.availabilityDescription)")
        guard AppleIntelligenceBrain.unavailableReason == nil else {
            throw XCTSkip("Foundation Models unavailable: \(AppleIntelligenceBrain.availabilityDescription)")
        }
        let tools = RecordingTools()
        let brain = AppleIntelligenceBrain()
        let reply: String
        do {
            reply = try await brain.respond(to: "Find a petrol station near me", context: AssistantContext(), tools: tools)
        } catch let error as AssistantBrainError {
            // Seen in the iOS 27.2 Simulator: availability says .available, but the
            // model assets are missing (UnifiedAssetFramework 5000) and generation fails.
            XCTAssertTrue(error.fallBack, "a model failure must fall back to the local parser")
            XCTAssertTrue(brain.recentlyFailed)
            throw XCTSkip("Foundation Models reported available but could not generate: \(error.message)")
        }
        print("FOUNDATION-MODELS-REPLY: \(reply) CALLS: \(tools.calls)")
        XCTAssertFalse(reply.isEmpty)
        XCTAssertTrue(tools.calls.contains { $0.hasPrefix("search_places") }, "model did not call search_places: \(tools.calls)")
    }
}
