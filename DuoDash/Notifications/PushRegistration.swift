import Foundation

/// What the app tells the announcements server (backend/notifications) about this install:
/// the APNs device token, which build it is, which APNs environment to use, and the app
/// version. Nothing else. Pure value logic, so the unit tests can check every request.
struct PushRegistration: Equatable, Sendable, Encodable {
    /// Which APNs server can reach this install. TestFlight and App Store builds use
    /// production; builds run from Xcode (and the Simulator) use the sandbox.
    enum Environment: String, Sendable, Encodable {
        case sandbox, production
    }

    var token: String
    var bundleId: String
    var environment: Environment
    var appVersion: String

    // MARK: Requests

    /// POST <base>/register with this registration as JSON.
    func registerRequest(base: URL) -> URLRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.post(base.appendingPathComponent("register"), body: (try? encoder.encode(self)) ?? Data())
    }

    /// POST <base>/unregister {token}: the server forgets this device.
    static func unregisterRequest(base: URL, token: String) -> URLRequest {
        let body = (try? JSONSerialization.data(withJSONObject: ["token": token])) ?? Data()
        return post(base.appendingPathComponent("unregister"), body: body)
    }

    private static func post(_ url: URL, body: Data) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    // MARK: Helpers

    /// The device token as lowercase hex, the form APNs and the server use.
    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// The server's base URL from the Info.plist value (DuoDashNotifyURL, set from the
    /// xcconfig variable DUODASH_NOTIFY_URL). Empty or unusable → nil, and the feature hides.
    /// A bare host gets https:// (xcconfig files treat "//" as a comment). Only https is used.
    static func baseURL(from value: String?) -> URL? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.hasPrefix("$("), !text.hasSuffix(":") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Picks the APNs environment for this build. Builds from the App Store and TestFlight carry
    /// no embedded provisioning profile and always use production. A build installed from Xcode
    /// has one: its aps-environment says which server issued the token (development → sandbox).
    static func environment(provisioningProfile: Data?, isSimulator: Bool) -> Environment {
        if isSimulator { return .sandbox }
        guard let profile = provisioningProfile else { return .production }
        let aps = entitlements(inProfile: profile)?["aps-environment"] as? String
        return aps == "production" ? .production : .sandbox
    }

    /// The Entitlements dictionary of a .mobileprovision (a signed blob with an XML plist inside).
    static func entitlements(inProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        return plist?["Entitlements"] as? [String: Any]
    }
}
