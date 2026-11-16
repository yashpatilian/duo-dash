import Foundation

/// A tool the assistant can call, defined once and adapted to each provider
/// (Foundation Models `Tool`, Claude tool JSON, and the local intent parser).
struct AssistantToolSpec: Sendable, Equatable {
    struct Parameter: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case string
            case stringArray
            case boolean
            case oneOf([String])
        }

        var name: String
        var description: String
        var kind: Kind
        var required: Bool
    }

    var name: String
    var description: String
    var parameters: [Parameter]

    /// JSON Schema for Claude's `input_schema` (strict: no extra properties).
    var jsonSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for p in parameters {
            var property: [String: Any]
            switch p.kind {
            case .string: property = ["type": "string"]
            case .boolean: property = ["type": "boolean"]
            case .stringArray: property = ["type": "array", "items": ["type": "string"]]
            case .oneOf(let options): property = ["type": "string", "enum": options]
            }
            property["description"] = p.description
            properties[p.name] = property
        }
        return [
            "type": "object",
            "properties": properties,
            "required": parameters.filter(\.required).map(\.name),
            "additionalProperties": false,
        ]
    }

    /// The entry for Claude's `tools` array.
    var claudeTool: [String: Any] {
        ["name": name, "description": description, "input_schema": jsonSchema, "strict": true]
    }
}

/// What a tool hands back: text for the model, and a sentence for the driver
/// (used directly by the local fallback, which has no model to phrase a reply).
struct ToolOutcome: Sendable, Equatable {
    var text: String
    var say: String
    var isError = false

    static func failure(_ message: String) -> ToolOutcome {
        ToolOutcome(text: "Error: \(message)", say: message, isError: true)
    }
}

/// Runs tools by name with JSON input. Implemented by AssistantModel.
@MainActor
protocol AssistantToolRunner: AnyObject {
    var toolSpecs: [AssistantToolSpec] { get }
    func runTool(named name: String, input: Data) async -> ToolOutcome
}

// MARK: - The tools

enum AssistantTools {
    static let searchPlaces = AssistantToolSpec(
        name: "search_places",
        description: "Search Apple Maps for places (restaurants, petrol stations, cafes, a business by name). Results are shown to the driver as cards and map pins. Returns name, category, address, distance and drive time from the driver, phone and website. Apple Maps gives no ratings or review text.",
        parameters: [
            .init(name: "query", description: "What to look for, e.g. \"dinner\", \"petrol station\", \"Corner Bakery\".", kind: .string, required: true),
            .init(name: "near", description: "Where to search: around the driver (default), around the trip's destination, or along the current route.",
                  kind: .oneOf(["current_location", "destination", "along_route"]), required: false),
        ])

    static let findContactAddress = AssistantToolSpec(
        name: "find_contact_address",
        description: "Look up a person in the driver's Contacts and find their street address on the map, e.g. for \"take me to Sam's house\". If several people match, it returns their names so you can ask which one.",
        parameters: [
            .init(name: "name", description: "The person's name as the driver said it, e.g. \"Sam\".", kind: .string, required: true),
        ])

    static let planRoute = AssistantToolSpec(
        name: "plan_route",
        description: "Plan a driving route and show it. destination can be a place name, an address, a search result name, a contact found with find_contact_address, or home/work/uni. stop_along_the_way picks the stop of that kind (e.g. \"petrol station\") that adds the least time to the trip. Set start_now when the driver asked to be taken somewhere straight away.",
        parameters: [
            .init(name: "destination", description: "Where the trip ends.", kind: .string, required: true),
            .init(name: "stops", description: "Named places to stop at on the way, in order.", kind: .stringArray, required: false),
            .init(name: "stop_along_the_way", description: "A kind of place to stop at on the way, e.g. \"petrol station\", \"coffee\".", kind: .string, required: false),
            .init(name: "start_now", description: "Start guidance immediately instead of showing a preview.", kind: .boolean, required: false),
        ])

    static let addStop = AssistantToolSpec(
        name: "add_stop",
        description: "Add a stop to the trip that is planned or being driven. Give either a named place or a kind of place to find along the route (the quickest detour is chosen).",
        parameters: [
            .init(name: "place", description: "A named place or search result to stop at.", kind: .string, required: false),
            .init(name: "category_along_the_way", description: "A kind of place to find along the route, e.g. \"petrol station\".", kind: .string, required: false),
        ])

    static let startNavigation = AssistantToolSpec(
        name: "start_navigation",
        description: "Start turn-by-turn guidance on the route that is being previewed, once the driver confirms.",
        parameters: [])

    static let endNavigation = AssistantToolSpec(
        name: "end_navigation",
        description: "Cancel the planned route or end guidance.",
        parameters: [])

    static let all = [searchPlaces, findContactAddress, planRoute, addStop, startNavigation, endNavigation]
}

// MARK: - Typed, validated inputs

enum ToolInputError: Error, LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

struct SearchPlacesInput: Codable, Equatable {
    enum Near: String, Codable { case current_location, destination, along_route }
    var query: String
    var near: Near?

    func validated() throws -> SearchPlacesInput {
        guard !query.assistantTrimmed.isEmpty else { throw ToolInputError.invalid("query is empty") }
        return self
    }
}

struct FindContactInput: Codable, Equatable {
    var name: String

    func validated() throws -> FindContactInput {
        guard !name.assistantTrimmed.isEmpty else { throw ToolInputError.invalid("name is empty") }
        return self
    }
}

struct PlanRouteInput: Codable, Equatable {
    var destination: String
    var stops: [String]?
    var stop_along_the_way: String?
    var start_now: Bool?

    func validated() throws -> PlanRouteInput {
        guard !destination.assistantTrimmed.isEmpty else { throw ToolInputError.invalid("destination is empty") }
        var copy = self
        copy.stops = stops?.map(\.assistantTrimmed).filter { !$0.isEmpty }
        if copy.stop_along_the_way?.assistantTrimmed.isEmpty ?? false { copy.stop_along_the_way = nil }
        guard (copy.stops?.count ?? 0) <= 5 else { throw ToolInputError.invalid("at most 5 stops") }
        return copy
    }
}

struct AddStopInput: Codable, Equatable {
    var place: String?
    var category_along_the_way: String?

    func validated() throws -> AddStopInput {
        let hasPlace = !(place?.assistantTrimmed.isEmpty ?? true)
        let hasCategory = !(category_along_the_way?.assistantTrimmed.isEmpty ?? true)
        guard hasPlace || hasCategory else { throw ToolInputError.invalid("give place or category_along_the_way") }
        return self
    }
}

struct EmptyInput: Codable, Equatable {}

extension AssistantToolSpec {
    /// Decodes and validates tool input. Unknown keys are rejected (strict schema).
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, allowed: [String]) throws -> T {
        let object = (try? JSONSerialization.jsonObject(with: data.isEmpty ? Data("{}".utf8) : data)) as? [String: Any]
        guard let object else { throw ToolInputError.invalid("input is not a JSON object") }
        let extra = Set(object.keys).subtracting(allowed)
        guard extra.isEmpty else { throw ToolInputError.invalid("unexpected field \(extra.sorted().joined(separator: ", "))") }
        do {
            // Drop explicit nulls so optional fields decode cleanly.
            let cleaned = object.filter { !($0.value is NSNull) }
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: cleaned))
        } catch {
            throw ToolInputError.invalid("input doesn't match the schema")
        }
    }
}

extension String {
    var assistantTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
