import Foundation

/// The fallback: simple intent parsing driving the same tools. Handles the core
/// commands ("take me to…", "find … near me", "stop for petrol on the way").
@MainActor
final class LocalBrain: AssistantBrain {
    let displayName = "Simple commands"

    func reset() {}

    func respond(to transcript: String, context: AssistantContext, tools: AssistantToolRunner) async throws -> String {
        let intent = IntentParser.parse(transcript)
        switch intent {
        case let .navigate(destination, along, startNow):
            var input: [String: Any] = ["destination": destination, "start_now": startNow]
            if let along { input["stop_along_the_way"] = along }
            return await run(AssistantTools.planRoute, input, tools)
        case let .findPlaces(query, nearDestination):
            var input: [String: Any] = ["query": query]
            if nearDestination { input["near"] = "destination" }
            return await run(AssistantTools.searchPlaces, input, tools)
        case let .addStopAlongTheWay(category):
            return await run(AssistantTools.addStop, ["category_along_the_way": category], tools)
        case let .addStop(place):
            return await run(AssistantTools.addStop, ["place": place], tools)
        case .startNavigation:
            return await run(AssistantTools.startNavigation, [:], tools)
        case .endNavigation:
            return await run(AssistantTools.endNavigation, [:], tools)
        case .reviews:
            return "Apple Maps doesn't give me reviews. Tap Details on a place to see its ratings in Apple Maps."
        case .unknown:
            return "I can find places and plan routes. Try \"take me to Central Station\" or \"find petrol near me\"."
        }
    }

    private func run(_ spec: AssistantToolSpec, _ input: [String: Any], _ tools: AssistantToolRunner) async -> String {
        let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
        return await tools.runTool(named: spec.name, input: data).say
    }
}
