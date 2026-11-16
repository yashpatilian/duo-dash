import XCTest
@testable import DuoDash

/// Serves queued responses and records requests. No real network, no real key.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var json: Any
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var failNetwork = false

    static func reset() {
        replies = []; requests = []; bodies = []; failNetwork = false
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var collected = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                collected.append(buffer, count: n)
            }
            stream.close()
            data = collected
        }
        if let data, let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            Self.bodies.append(body)
        }
        if Self.failNetwork {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let reply = Self.replies.isEmpty ? Reply(status: 500, json: [:]) : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Records tool calls and answers them.
@MainActor
private final class FakeTools: AssistantToolRunner {
    var calls: [(String, [String: Any])] = []
    var toolSpecs: [AssistantToolSpec] { AssistantTools.all }

    func runTool(named name: String, input: Data) async -> ToolOutcome {
        calls.append((name, (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]))
        if name == "plan_route" { return ToolOutcome(text: "Error: no route", say: "No route", isError: true) }
        return ToolOutcome(text: "1. Shell — Petrol station — 4 min drive", say: "Found it")
    }
}

@MainActor
final class ClaudeBrainTests: XCTestCase {
    private var settings: AssistantSettings!
    private var waits: [TimeInterval] = []

    override func setUp() {
        StubURLProtocol.reset()
        let name = "test.\(UUID().uuidString)"
        settings = AssistantSettings(defaults: UserDefaults(suiteName: name)!, keyStore: InMemorySecretStore("sk-ant-test"))
        settings.provider = .claude
        waits = []
    }

    private func makeBrain() -> ClaudeBrain {
        let client = ClaudeClient(session: StubURLProtocol.session)
        client.pause = { [weak self] seconds in await MainActor.run { self?.waits.append(seconds) } }
        return ClaudeBrain(settings: settings, client: client)
    }

    private var context: AssistantContext {
        AssistantContext(now: Date(), coordinate: .init(latitude: -37.8136, longitude: 144.9631),
                         locality: "Springfield, IL", city: "Springfield", region: "Illinois", routeSummary: nil)
    }

    private func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

    func testRequestShape() async throws {
        StubURLProtocol.replies = [.init(status: 200, json: ["stop_reason": "end_turn", "content": [text("Hi there.")]])]
        let reply = try await makeBrain().respond(to: "hello", context: context, tools: FakeTools())
        XCTAssertEqual(reply, "Hi there.")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(request.timeoutInterval, 30)

        let body = try XCTUnwrap(StubURLProtocol.bodies.first)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16000)
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        for forbidden in ["thinking", "temperature", "top_p", "top_k", "tool_choice"] {
            XCTAssertNil(body[forbidden], "\(forbidden) must not be sent")
        }
        let system = try XCTUnwrap(body["system"] as? String)
        XCTAssertTrue(system.contains("Springfield"))
        XCTAssertTrue(system.contains(AssistantContext.localeHint), "the reply style follows the phone's locale")
        XCTAssertTrue(system.contains("one or two short spoken sentences"))

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let custom = tools.filter { $0["input_schema"] != nil }
        XCTAssertEqual(Set(custom.compactMap { $0["name"] as? String }), Set(AssistantTools.all.map(\.name)))
        XCTAssertTrue(custom.allSatisfy { $0["strict"] as? Bool == true })
        let search = try XCTUnwrap(tools.first { $0["type"] as? String == "web_search_20260209" })
        XCTAssertEqual(search["name"] as? String, "web_search")
        XCTAssertEqual(search["max_uses"] as? Int, 3)
        let location = try XCTUnwrap(search["user_location"] as? [String: Any])
        XCTAssertEqual(location["type"] as? String, "approximate")
        XCTAssertEqual(location["country"] as? String, Locale.current.region?.identifier, "web search uses the phone's region")
        XCTAssertEqual(location["city"] as? String, "Springfield")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hello")
    }

    func testToolLoopKeepsContentAndSendsAllResultsInOneMessage() async throws {
        let firstContent: [[String: Any]] = [
            ["type": "thinking", "thinking": "Need petrol stations.", "signature": "sig123"],
            ["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": ["query": "petrol prices"]],
            ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1",
             "content": ["type": "web_search_tool_result_error", "error_code": "max_uses_exceeded"]],
            text("Let me look."),
            ["type": "tool_use", "id": "toolu_A", "name": "search_places", "input": ["query": "petrol station", "near": "along_route"]],
            ["type": "tool_use", "id": "toolu_B", "name": "plan_route", "input": ["destination": "MCG"]],
        ]
        StubURLProtocol.replies = [
            .init(status: 200, json: ["stop_reason": "tool_use", "content": firstContent]),
            .init(status: 200, json: ["stop_reason": "end_turn", "content": [text("Shell is 4 minutes away.")]]),
        ]
        let tools = FakeTools()
        let brain = makeBrain()
        let reply = try await brain.respond(to: "petrol on the way", context: context, tools: tools)
        XCTAssertEqual(reply, "Shell is 4 minutes away.")
        XCTAssertEqual(tools.calls.map(\.0), ["search_places", "plan_route"])
        XCTAssertEqual(tools.calls[0].1["near"] as? String, "along_route")

        XCTAssertEqual(StubURLProtocol.bodies.count, 2)
        let messages = try XCTUnwrap(StubURLProtocol.bodies[1]["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        // The assistant turn goes back exactly as received.
        XCTAssertEqual(messages[1]["content"] as? NSArray, firstContent as NSArray)
        let results = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map { $0["type"] as? String }, ["tool_result", "tool_result"])
        XCTAssertEqual(results.map { $0["tool_use_id"] as? String }, ["toolu_A", "toolu_B"])
        XCTAssertNil(results[0]["is_error"])
        XCTAssertEqual(results[1]["is_error"] as? Bool, true)

        // The finished turn is remembered for follow-ups.
        StubURLProtocol.replies = [.init(status: 200, json: ["stop_reason": "end_turn", "content": [text("Sure.")]])]
        _ = try await brain.respond(to: "the first one", context: context, tools: tools)
        let followUp = try XCTUnwrap(StubURLProtocol.bodies.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(followUp.count, 5)
        brain.reset()
        XCTAssertTrue(brain.history.isEmpty)
    }

    func testPauseTurnIsResent() async throws {
        let paused: [[String: Any]] = [["type": "server_tool_use", "id": "srvtoolu_9", "name": "web_search", "input": ["query": "x"]]]
        StubURLProtocol.replies = [
            .init(status: 200, json: ["stop_reason": "pause_turn", "content": paused]),
            .init(status: 200, json: ["stop_reason": "end_turn", "content": [text("Open until 10.")]]),
        ]
        let reply = try await makeBrain().respond(to: "is it open", context: context, tools: FakeTools())
        XCTAssertEqual(reply, "Open until 10.")
        let messages = try XCTUnwrap(StubURLProtocol.bodies[1]["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant"])
    }

    func testRefusalAndTruncation() async throws {
        StubURLProtocol.replies = [.init(status: 200, json: ["stop_reason": "refusal", "content": [], "stop_details": ["type": "refusal"]])]
        let refused = try await makeBrain().respond(to: "x", context: context, tools: FakeTools())
        XCTAssertEqual(refused, "Sorry, I can't help with that one.")

        StubURLProtocol.replies = [.init(status: 200, json: ["stop_reason": "max_tokens", "content": [text("The best option is")]])]
        let cut = try await makeBrain().respond(to: "x", context: context, tools: FakeTools())
        XCTAssertEqual(cut, "The best option is…")
    }

    func testUnauthorizedAsksForKey() async {
        StubURLProtocol.replies = [.init(status: 401, json: ["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]])]
        do {
            _ = try await makeBrain().respond(to: "x", context: context, tools: FakeTools())
            XCTFail("expected an error")
        } catch let error as AssistantBrainError {
            XCTAssertEqual(error.message, "Check your Claude API key in Settings.")
            XCTAssertTrue(error.fallBack)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "401 is not retried")
    }

    func testOverloadRetriesHonouringRetryAfter() async throws {
        StubURLProtocol.replies = [
            .init(status: 529, json: ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]], headers: ["retry-after": "3"]),
            .init(status: 429, json: [:]),
            .init(status: 200, json: ["stop_reason": "end_turn", "content": [text("OK")]]),
        ]
        let reply = try await makeBrain().respond(to: "x", context: context, tools: FakeTools())
        XCTAssertEqual(reply, "OK")
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertEqual(waits, [3, 2])
    }

    func testServerErrorsFallBackAfterRetries() async {
        StubURLProtocol.replies = [.init(status: 500, json: [:]), .init(status: 503, json: [:]), .init(status: 500, json: [:])]
        do {
            _ = try await makeBrain().respond(to: "x", context: context, tools: FakeTools())
            XCTFail("expected an error")
        } catch let error as AssistantBrainError {
            XCTAssertTrue(error.fallBack)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
    }

    func testNetworkFailureAndBadRequest() async {
        StubURLProtocol.failNetwork = true
        do {
            _ = try await makeBrain().respond(to: "x", context: context, tools: FakeTools())
            XCTFail("expected an error")
        } catch let error as AssistantBrainError {
            XCTAssertEqual(error.message, ClaudeError.network.localizedDescription)
        } catch { XCTFail("\(error)") }

        StubURLProtocol.reset()
        StubURLProtocol.replies = [.init(status: 400, json: ["type": "error", "error": ["type": "invalid_request_error", "message": "temperature is not supported"]])]
        do {
            _ = try await makeBrain().respond(to: "x", context: context, tools: FakeTools())
            XCTFail("expected an error")
        } catch let error as AssistantBrainError {
            // The API's own wording stays in the debug log, not on screen.
            XCTAssertFalse(error.message.contains("temperature"))
        } catch { XCTFail("\(error)") }
    }

    func testMissingKey() async {
        settings.clearClaudeKey()
        do {
            _ = try await makeBrain().respond(to: "x", context: context, tools: FakeTools())
            XCTFail("expected an error")
        } catch let error as AssistantBrainError {
            XCTAssertTrue(error.message.contains("API key"))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testKeyTestUsesTheSameShape() async throws {
        StubURLProtocol.replies = [.init(status: 200, json: ["stop_reason": "end_turn", "content": [text("OK")]])]
        let result = await settings.testClaudeKey(session: StubURLProtocol.session)
        if case .failure(let error) = result { XCTFail("\(error)") }
        let body = try XCTUnwrap(StubURLProtocol.bodies.first)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["tools"])
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")

        StubURLProtocol.reset()
        StubURLProtocol.replies = [.init(status: 401, json: [:])]
        let failed = await settings.testClaudeKey(session: StubURLProtocol.session)
        guard case .failure(let error) = failed else { return XCTFail("expected failure") }
        XCTAssertEqual(error as? ClaudeError, .unauthorized)
    }
}
