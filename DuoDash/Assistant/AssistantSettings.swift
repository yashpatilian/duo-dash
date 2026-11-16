import Foundation
import Observation
import Security

/// Which AI answers the driving assistant.
enum AssistantProvider: String, CaseIterable, Identifiable, Codable {
    /// On-device Foundation Models: private, no key, no network for the model itself.
    case appleIntelligence
    /// Claude via the Anthropic API (needs an API key and a connection).
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .claude: "Claude"
        }
    }
}

/// Assistant preferences. Plain choices live in UserDefaults; the Anthropic API key
/// lives only in the Keychain and is never logged.
@MainActor
@Observable
final class AssistantSettings {
    static let effortOptions = ["low", "medium", "high"]
    static let defaultClaudeModel = "claude-opus-5-5"

    var provider: AssistantProvider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }

    /// Anthropic model id.
    var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: Keys.model) }
    }

    /// `output_config.effort`: low / medium / high. Low suits short voice turns.
    var claudeEffort: String {
        didSet {
            if !Self.effortOptions.contains(claudeEffort) { claudeEffort = "low" }
            defaults.set(claudeEffort, forKey: Keys.effort)
        }
    }

    /// Speak the assistant's replies aloud (separate from turn-by-turn voice).
    var speaksReplies: Bool {
        didSet { defaults.set(speaksReplies, forKey: Keys.speaks) }
    }

    /// A Claude key is saved in the Keychain.
    private(set) var hasClaudeKey: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let keyStore: SecretStore

    private enum Keys {
        static let provider = "assistant.provider"
        static let model = "assistant.claudeModel"
        static let effort = "assistant.claudeEffort"
        static let speaks = "assistant.speaksReplies"
    }

    init(defaults: UserDefaults = .standard, keyStore: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.keyStore = keyStore
        provider = defaults.string(forKey: Keys.provider).flatMap(AssistantProvider.init(rawValue:)) ?? .appleIntelligence
        let model = defaults.string(forKey: Keys.model) ?? ""
        claudeModel = model.isEmpty ? Self.defaultClaudeModel : model
        let effort = defaults.string(forKey: Keys.effort) ?? "low"
        claudeEffort = Self.effortOptions.contains(effort) ? effort : "low"
        speaksReplies = defaults.object(forKey: Keys.speaks) as? Bool ?? true
        hasClaudeKey = !(keyStore.read() ?? "").isEmpty
    }

    /// The saved key, read when a request is made. Never displayed or logged.
    var claudeKey: String? {
        let key = keyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    func setClaudeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clearClaudeKey(); return }
        hasClaudeKey = keyStore.write(trimmed)
    }

    func clearClaudeKey() {
        keyStore.delete()
        hasClaudeKey = false
    }

    /// Sends a tiny request with the saved key. Success carries a short status line.
    func testClaudeKey(session: URLSession = .shared) async -> Result<String, Error> {
        guard let key = claudeKey else { return .failure(ClaudeError.missingKey) }
        let client = ClaudeClient(session: session)
        do {
            let body = ClaudeClient.body(model: claudeModel, effort: claudeEffort,
                                         system: "Reply with the single word OK.",
                                         tools: [], webSearchLocation: nil,
                                         messages: [["role": "user", "content": "Ping"]],
                                         maxTokens: 64)
            _ = try await client.send(body: body, key: key)
            return .success("Connected to \(claudeModel).")
        } catch {
            return .failure(error)
        }
    }
}

/// Where the API key is kept. The Keychain in the app; in memory in tests.
protocol SecretStore {
    func read() -> String?
    @discardableResult func write(_ value: String) -> Bool
    func delete()
}

struct KeychainSecretStore: SecretStore {
    var service = (Bundle.main.bundleIdentifier ?? "duodash") + ".anthropic"
    var account = "api-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

final class InMemorySecretStore: SecretStore {
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { value }
    func write(_ value: String) -> Bool { self.value = value; return true }
    func delete() { value = nil }
}
