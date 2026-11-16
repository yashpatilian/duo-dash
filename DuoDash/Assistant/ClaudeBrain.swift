import Foundation
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "duodash", category: "assistant.claude")

enum ClaudeError: Error, LocalizedError, Equatable {
    case missingKey
    case unauthorized
    /// 429 / 529 / 5xx after the retries ran out.
    case unavailable(status: Int)
    case network
    /// 400 and other 4xx: the API's own message (logged at debug level only).
    case badRequest(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Claude API key in Settings."
        case .unauthorized: "Check your Claude API key in Settings."
        case .unavailable: "Claude is busy right now. Try again in a moment."
        case .network: "Can't reach Claude. Check your connection."
        case .badRequest: "Claude couldn't handle that request."
        case .invalidResponse: "Claude sent back something unexpected."
        }
    }
}

/// Raw HTTP client for the Anthropic Messages API (there's no official Swift SDK).
final class ClaudeClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let beta = "server-side-fallback-2026-07-01"

    let session: URLSession
    var maxRetries = 2
    /// Waits between retries; replaced in tests so they don't sleep.
    var pause: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The request body. Deliberately has no `thinking`, `temperature`, `top_p`,
    /// `top_k` or forced `tool_choice`: this model/API version rejects them.
    static func body(model: String, effort: String, system: String, tools: [AssistantToolSpec],
                     webSearchLocation: [String: String]?, messages: [[String: Any]],
                     maxTokens: Int = 16000) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": ["effort": effort],
            "fallbacks": "default",
            "system": system,
            "messages": messages,
        ]
        var toolList: [[String: Any]] = tools.map(\.claudeTool)
        if let webSearchLocation {
            // Approximate location for web search: the phone's region, plus city/region when known.
            var location: [String: Any] = ["type": "approximate"]
            if let country = Locale.current.region?.identifier, country.count == 2 { location["country"] = country }
            for (key, value) in webSearchLocation where !value.isEmpty { location[key] = value }
            toolList.append(["type": "web_search_20260209", "name": "web_search", "max_uses": 3, "user_location": location])
        }
        if !toolList.isEmpty { body["tools"] = toolList }
        return body
    }

    static func request(body: [String: Any], key: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Sends one Messages request, retrying overloads and network failures.
    func send(body: [String: Any], key: String) async throws -> [String: Any] {
        let request: URLRequest
        do { request = try Self.request(body: body, key: key) } catch { throw ClaudeError.invalidResponse }

        var attempt = 0
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard attempt < maxRetries else { throw ClaudeError.network }
                attempt += 1
                await pause(Double(attempt))
                continue
            }
            guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
            let status = http.statusCode
            switch status {
            case 200..<300:
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw ClaudeError.invalidResponse
                }
                return json
            case 401, 403:
                throw ClaudeError.unauthorized
            case 429, 529, 500..<600:
                guard attempt < maxRetries else { throw ClaudeError.unavailable(status: status) }
                attempt += 1
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                await pause(min(max(retryAfter ?? Double(attempt), 0), 10))
            default:
                let message = Self.errorMessage(in: data) ?? "HTTP \(status)"
                log.debug("Claude request rejected (\(status)): \(message, privacy: .public)")
                throw ClaudeError.badRequest(message)
            }
        }
    }

    static func errorMessage(in data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

/// Claude with our tools plus Anthropic's server-side web search.
@MainActor
final class ClaudeBrain: AssistantBrain {
    let displayName = "Claude"
    let settings: AssistantSettings
    let client: ClaudeClient
    var maxIterations = 8
    /// Completed turns (each starts with the driver's words). Only recent ones are kept.
    private(set) var history: [[[String: Any]]] = []
    private let keptTurns = 6

    init(settings: AssistantSettings, client: ClaudeClient = ClaudeClient()) {
        self.settings = settings
        self.client = client
    }

    func reset() { history = [] }

    func respond(to transcript: String, context: AssistantContext, tools: AssistantToolRunner) async throws -> String {
        guard let key = settings.claudeKey else {
            throw AssistantBrainError(message: ClaudeError.missingKey.localizedDescription)
        }
        var location: [String: String] = ["timezone": TimeZone.current.identifier]
        if let city = context.city { location["city"] = city }
        if let region = context.region { location["region"] = region }

        var turn: [[String: Any]] = [["role": "user", "content": transcript]]
        for _ in 0..<maxIterations {
            let body = ClaudeClient.body(model: settings.claudeModel, effort: settings.claudeEffort,
                                         system: context.instructions(webSearch: true),
                                         tools: tools.toolSpecs, webSearchLocation: location,
                                         messages: history.flatMap { $0 } + turn)
            let json: [String: Any]
            do {
                json = try await client.send(body: body, key: key)
            } catch let error as ClaudeError {
                throw AssistantBrainError(message: error.localizedDescription)
            }
            // Kept exactly as received, including thinking and web search blocks.
            let content = json["content"] as? [Any] ?? []
            switch json["stop_reason"] as? String {
            case "tool_use":
                turn.append(["role": "assistant", "content": content])
                turn.append(["role": "user", "content": await runTools(in: content, with: tools)])
            case "pause_turn":
                // A long server-side step (web search) paused: send it back to continue.
                turn.append(["role": "assistant", "content": content])
            case "refusal":
                if let details = json["stop_details"] {
                    log.debug("Claude declined: \(String(describing: details), privacy: .public)")
                }
                return "Sorry, I can't help with that one."
            case "max_tokens":
                let text = Self.text(in: content)
                commit(turn, reply: content)
                return text.isEmpty ? "Sorry, that answer got cut off. Try asking again." : text + "…"
            default:
                commit(turn, reply: content)
                let text = Self.text(in: content)
                return text.isEmpty ? "Done." : text
            }
        }
        throw AssistantBrainError(message: "That took too many steps. Try asking a simpler way.", fallBack: false)
    }

    private func commit(_ turn: [[String: Any]], reply content: [Any]) {
        history.append(turn + [["role": "assistant", "content": content]])
        if history.count > keptTurns { history.removeFirst(history.count - keptTurns) }
    }

    /// Runs every tool_use block and returns one tool_result per block, in order.
    /// Look-ups run in parallel; anything that changes the trip runs in order after them.
    private func runTools(in content: [Any], with tools: AssistantToolRunner) async -> [[String: Any]] {
        let calls: [(id: String, name: String, input: Any?)] = content.compactMap { block in
            guard let block = block as? [String: Any], block["type"] as? String == "tool_use",
                  let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
            return (id, name, block["input"])
        }
        let readOnly: Set<String> = [AssistantTools.searchPlaces.name, AssistantTools.findContactAddress.name]

        func run(_ call: (id: String, name: String, input: Any?)) async -> ToolOutcome {
            guard let input = call.input as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: input) else {
                return .failure("input must be a JSON object")
            }
            return await tools.runTool(named: call.name, input: data)
        }

        var lookups: [Int: Task<ToolOutcome, Never>] = [:]
        for (index, call) in calls.enumerated() where readOnly.contains(call.name) {
            lookups[index] = Task { await run(call) }
        }
        var outcomes: [Int: ToolOutcome] = [:]
        for (index, task) in lookups { outcomes[index] = await task.value }
        for (index, call) in calls.enumerated() where lookups[index] == nil {
            outcomes[index] = await run(call)
        }

        return calls.enumerated().map { index, call in
            let outcome = outcomes[index] ?? .failure("tool didn't run")
            var result: [String: Any] = ["type": "tool_result", "tool_use_id": call.id, "content": outcome.text]
            if outcome.isError { result["is_error"] = true }
            return result
        }
    }

    static func text(in content: [Any]) -> String {
        content.compactMap { block -> String? in
            guard let block = block as? [String: Any], block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
