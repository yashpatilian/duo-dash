import Foundation

/// How Duo Dash gets its Spotify token.
enum SpotifySignInMode: String, Equatable, Sendable {
    /// Authorization Code with PKCE: sign in once, renewed silently with the refresh token.
    /// Needs the user on the Spotify developer app's allow-list while it's in development mode.
    case signInOnce = "sign-in"
    /// App Remote only: the Spotify app hands over an `app-remote-control` token when it opens
    /// for a moment (`authorizeAndPlayURI`). No Web API and no accounts.spotify.com sign-in, so
    /// it has the best chance of working for people who aren't on the allow-list. The token
    /// can't be renewed silently: when it runs out, Connect opens Spotify for a moment again.
    case appRemoteOnly = "app-remote"

    /// The Info.plist value `SpotifySignInMode` (build setting `DUODASH_SPOTIFY_MODE`; the
    /// TestFlight and App Store builds set `app-remote`). Anything else means sign-in.
    init(infoValue: String?) {
        let value = (infoValue ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        self = SpotifySignInMode(rawValue: value) ?? .signInOnce
    }

    static var thisBuild: SpotifySignInMode {
        SpotifySignInMode(infoValue: Bundle.main.object(forInfoDictionaryKey: "SpotifySignInMode") as? String)
    }

    /// The mode to use. The user's own developer app (Settings → Spotify) always gets the full
    /// sign-in; an account Spotify refused for the sign-in stays on App Remote only.
    static func choose(build: SpotifySignInMode, hasOwnClientID: Bool, fellBackToAppRemote: Bool) -> SpotifySignInMode {
        if hasOwnClientID { return .signInOnce }
        if fellBackToAppRemote { return .appRemoteOnly }
        return build
    }
}

/// Spotify's ways of saying "this account may not use this developer app" (the development-mode
/// allow-list, or a client ID it won't accept), as opposed to the user saying no or a token
/// simply running out.
enum SpotifyRefusal {
    static func isNotAllowed(_ text: String?) -> Bool {
        guard let text = text?.lowercased(), !text.isEmpty else { return false }
        return ["not registered", "invalid_client", "invalid client", "unauthorized_client",
                "forbidden", "403", "not allowed to use"].contains { text.contains($0) }
    }
}

/// The Spotify choices that persist: the user's own Client ID, and the fallbacks Duo Dash took.
/// Backed by UserDefaults (nothing here is secret: a Client ID is an identifier), or by memory
/// for the demo backend and tests.
@MainActor
final class SpotifyAccessSettings {
    private let defaults: UserDefaults?
    private var memory: [String: Any] = [:]

    enum Keys {
        static let ownClientID = "spotify.ownClientID"
        static let appRemoteOnly = "spotify.fellBackToAppRemote"
        static let limited = "spotify.limited"
    }

    /// nil: kept in memory only.
    init(defaults: UserDefaults?) { self.defaults = defaults }

    private func value(_ key: String) -> Any? {
        if let defaults { return defaults.object(forKey: key) }
        return memory[key]
    }

    private func store(_ value: Any?, _ key: String) {
        if let defaults {
            defaults.set(value, forKey: key)
        } else {
            memory[key] = value
        }
    }

    /// The Client ID of the user's own Spotify developer app, if they set one.
    var ownClientID: String? {
        get { (value(Keys.ownClientID) as? String).flatMap { $0.isEmpty ? nil : $0 } }
        set { store(newValue, Keys.ownClientID) }
    }

    /// Spotify refused the PKCE sign-in for this account: use App Remote only.
    var fellBackToAppRemote: Bool {
        get { value(Keys.appRemoteOnly) as? Bool ?? false }
        set { store(newValue, Keys.appRemoteOnly) }
    }

    /// The Spotify app refused this account too: show "Open Spotify" instead of retrying.
    var isLimited: Bool {
        get { value(Keys.limited) as? Bool ?? false }
        set { store(newValue, Keys.limited) }
    }

    /// A Client ID typed in Settings: 32 hex characters, as the dashboard shows it.
    static func normalisedClientID(_ text: String) -> String? {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.count == 32, id.allSatisfy(\.isHexDigit) else { return nil }
        return id
    }
}
