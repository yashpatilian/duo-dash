import Foundation
import FoundationModels

/// Apple's on-device model (Foundation Models) with our tools. Private and keyless.
@MainActor
final class AppleIntelligenceBrain: AssistantBrain {
    let displayName = "Apple Intelligence"
    private var session: LanguageModelSession?

    /// nil when the on-device model can be used; otherwise why not, for the driver.
    static var unavailableReason: String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(Locale.current) ? nil
                : "Apple Intelligence doesn't support your language setting yet."
        case .unavailable(.deviceNotEligible):
            return "This iPhone doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to use the smart assistant."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready (downloading). Try again soon."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    /// A short label of the raw availability, for diagnostics.
    static var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available: "available"
        case .unavailable(let reason): "unavailable(\(reason))"
        }
    }

    /// When generation last failed outright. Availability can say `.available` while
    /// the model assets are missing (seen in the Simulator), and each failed attempt
    /// takes seconds, so the assistant skips the model for a while after one.
    private(set) var lastFailure: Date?

    var recentlyFailed: Bool {
        lastFailure.map { Date().timeIntervalSince($0) < 300 } ?? false
    }

    func reset() { session = nil }

    func respond(to transcript: String, context: AssistantContext, tools: AssistantToolRunner) async throws -> String {
        do {
            let reply = try await generate(transcript, context: context, tools: tools)
            lastFailure = nil
            return reply
        } catch let error as AssistantBrainError where error.fallBack {
            lastFailure = Date()
            session = nil
            throw error
        }
    }

    private func generate(_ transcript: String, context: AssistantContext, tools: AssistantToolRunner) async throws -> String {
        if let reason = Self.unavailableReason { throw AssistantBrainError(message: reason) }
        let session = self.session ?? makeSession(context: context, tools: tools)
        self.session = session

        // The context changes as the car moves, so it rides along with each prompt.
        let prompt = """
        [Now: \(context.localTime). Location: \(context.locality ?? context.coarseCoordinate ?? "unknown"). \
        Trip: \(context.routeSummary ?? "none").]
        Driver: \(transcript)
        """
        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Done." : text
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                // Start a fresh conversation and try once more.
                self.session = makeSession(context: context, tools: tools)
                let response = try await self.session!.respond(to: prompt)
                return response.content
            case .guardrailViolation, .refusal:
                return "Sorry, I can't help with that one."
            case .unsupportedLanguageOrLocale:
                throw AssistantBrainError(message: "Apple Intelligence doesn't support this language yet.")
            case .assetsUnavailable:
                throw AssistantBrainError(message: "Apple Intelligence is still getting ready. Try again soon.")
            case .rateLimited, .concurrentRequests:
                throw AssistantBrainError(message: "Apple Intelligence is busy. Try again in a moment.")
            default:
                throw AssistantBrainError(message: "Apple Intelligence couldn't answer that.")
            }
        } catch let error as LanguageModelSession.ToolCallError {
            throw AssistantBrainError(message: error.underlyingError.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AssistantBrainError(message: "Apple Intelligence couldn't answer that.")
        }
    }

    private func makeSession(context: AssistantContext, tools: AssistantToolRunner) -> LanguageModelSession {
        let adapters: [any Tool] = tools.toolSpecs.compactMap { spec in
            guard let schema = try? Self.schema(for: spec) else { return nil }
            return FoundationModelTool(name: spec.name, description: spec.description, parameters: schema) { [weak tools] json in
                guard let tools else { return "Error: the assistant was closed." }
                return await tools.runTool(named: spec.name, input: Data(json.utf8)).text
            }
        }
        return LanguageModelSession(tools: adapters, instructions: context.instructions(webSearch: false))
    }

    /// The same parameter list as the Claude schema, as a Foundation Models schema.
    static func schema(for spec: AssistantToolSpec) throws -> GenerationSchema {
        let properties = spec.parameters.map { p -> DynamicGenerationSchema.Property in
            let schema: DynamicGenerationSchema
            switch p.kind {
            case .string: schema = DynamicGenerationSchema(type: String.self)
            case .boolean: schema = DynamicGenerationSchema(type: Bool.self)
            case .stringArray: schema = DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), maximumElements: 5)
            case .oneOf(let options): schema = DynamicGenerationSchema(name: "\(spec.name)_\(p.name)", anyOf: options)
            }
            return DynamicGenerationSchema.Property(name: p.name, description: p.description, schema: schema, isOptional: !p.required)
        }
        let root = DynamicGenerationSchema(name: spec.name, description: spec.description, properties: properties)
        return try GenerationSchema(root: root, dependencies: [])
    }
}

/// Wraps one of our tools as a Foundation Models `Tool`. Arguments arrive as
/// generated content and are handed on as JSON, so validation is shared with Claude.
struct FoundationModelTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let run: @Sendable (String) async -> String

    func call(arguments: GeneratedContent) async throws -> String {
        await run(arguments.jsonString)
    }
}
