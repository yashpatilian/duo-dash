import UIKit
import Security

/// Something in the user's Spotify: a playlist, album, section or song, as
/// App Remote's content API describes it.
struct SpotifyItem: Identifiable, Hashable, Sendable {
    /// App Remote's identifier (unique per item, used for caches).
    let identifier: String
    /// The URI that plays it, e.g. `spotify:playlist:…`.
    let uri: String
    let title: String
    var subtitle: String = ""
    var imageIdentifier: String? = nil
    /// Has children (a section, playlist or album).
    var isContainer = false
    var isPlayable = true

    var id: String { identifier }

    /// Tapping it opens a page of its songs rather than playing it. App Remote flags only
    /// feed sections as containers: playlists, albums, artists and shows come back as plain
    /// playable items, so the URI decides (tracks and episodes play straight away).
    var opensAsPage: Bool {
        isContainer || Self.isCollection(uri: uri)
    }

    static func isCollection(uri: String) -> Bool {
        let parts = uri.lowercased().split(separator: ":").map(String.init)
        guard parts.first == "spotify" else { return false }
        if parts.contains("track") || parts.contains("episode") { return false }
        return parts.contains { ["playlist", "album", "artist", "show", "collection", "station"].contains($0) }
    }
}

/// What Spotify reports about its player.
struct SpotifyPlayerState: Equatable, Sendable {
    var trackURI: String
    var title: String
    var artist: String
    var album: String = ""
    var imageIdentifier: String? = nil
    var isPaused: Bool
    /// Seconds into the track when the state was reported.
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var shuffle = false
    var repeatSetting: RepeatSetting = .off
}

/// Things App Remote tells us, delivered on the main actor.
enum SpotifyBackendEvent: Equatable {
    case connected
    case connectionFailed(String?)
    case disconnected(String?)
    case playerState(SpotifyPlayerState)
    /// The demo backend's stand-in for Spotify opening `duodash://spotify-callback`.
    case redirect(URL)
}

/// What came back on the redirect URL after authorising in the Spotify app.
enum SpotifyAuthResult: Equatable {
    case token(String, expiresIn: TimeInterval)
    case failed(String)
    /// Spotify won't let this account use the developer app (allow-list, invalid client).
    case refused(String)
}

enum SpotifyError: LocalizedError {
    case notConnected
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Spotify isn't connected."
        case .failed(let reason): reason
        }
    }
}

/// What the Spotify screen needs from App Remote. `SpotifyAppRemoteBackend`
/// talks to the Spotify app; `DemoSpotifyBackend` stands in for it in the
/// Simulator (which has no Spotify app) and in tests.
@MainActor
protocol SpotifyBackend: AnyObject {
    var isDemo: Bool { get }
    /// A client ID is set in `Config/Secrets.xcconfig`.
    var isConfigured: Bool { get }
    var onEvent: (@MainActor (SpotifyBackendEvent) -> Void)? { get set }
    /// Where the "Get Spotify" button goes.
    var appStoreURL: URL { get }

    func isSpotifyInstalled() -> Bool
    /// Opens Spotify to authorise (and start playback, which App Remote needs);
    /// Spotify then opens our redirect URL. `false`: Spotify can't be opened.
    func authorize(playURI: String, completion: @escaping @MainActor (Bool) -> Void)
    /// `nil` when the URL isn't our Spotify redirect.
    func authorizationResult(from url: URL) -> SpotifyAuthResult?
    func connect(accessToken: String)
    func disconnect()
    /// Use another Client ID (the user's own developer app), or nil for none.
    func setClientID(_ clientID: String?)

    func resume() async throws
    func pause() async throws
    func skipToNext() async throws
    func skipToPrevious() async throws
    func setShuffle(_ on: Bool) async throws
    func setRepeat(_ setting: RepeatSetting) async throws
    func play(_ item: SpotifyItem) async throws

    /// Spotify's home feed: recently played and recommendations, in sections
    /// (or one flat list).
    func recommendedItems(flatten: Bool) async throws -> [SpotifyItem]
    func children(of item: SpotifyItem) async throws -> [SpotifyItem]
    func image(for imageIdentifier: String, size: CGSize) async -> UIImage?
}

// MARK: - Tokens

/// The Spotify sign-in: an access token (about an hour) and, from the PKCE sign-in, a refresh
/// token that renews it without the user. A token from App Remote's wake-up bounce through
/// Spotify replaces the access token and keeps the refresh token.
struct SpotifyToken: Codable, Equatable {
    var accessToken: String
    var expiresAt: Date
    /// nil for tokens saved before sign-in-once (App Remote only): those need Spotify again.
    var refreshToken: String? = nil

    /// Renew this long before expiry, so a drive never starts on a token about to run out.
    static let refreshMargin: TimeInterval = 5 * 60

    /// A minute of slack, so a token isn't used just as it runs out.
    func isValid(at date: Date = .now) -> Bool { expiresAt.timeIntervalSince(date) > 60 }

    /// Expired, or within `refreshMargin` of it.
    func needsRefresh(at date: Date = .now) -> Bool { expiresAt.timeIntervalSince(date) < Self.refreshMargin }
}

/// What to do with the saved token before connecting App Remote.
enum SpotifyTokenPlan: Equatable {
    /// Connect with this access token.
    case use(String)
    /// Renew silently with this refresh token first.
    case refresh(String)
    /// Nothing usable: the user has to sign in.
    case signIn

    static func plan(for token: SpotifyToken?, at date: Date) -> SpotifyTokenPlan {
        guard let token else { return .signIn }
        if !token.needsRefresh(at: date) { return .use(token.accessToken) }
        if let refresh = token.refreshToken, !refresh.isEmpty { return .refresh(refresh) }
        // An old App Remote token with no refresh token: use it while it lasts.
        return token.isValid(at: date) ? .use(token.accessToken) : .signIn
    }
}

@MainActor
protocol SpotifyTokenStore: AnyObject {
    func load() -> SpotifyToken?
    func save(_ token: SpotifyToken)
    func clear()
}

/// Keeps the access token, its expiry and the refresh token in the Keychain (this device
/// only, readable after first unlock so a reconnect while driving with the phone locked
/// still works). Signing out deletes the item.
@MainActor
final class KeychainSpotifyTokenStore: SpotifyTokenStore {
    private let service: String
    private let account: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "duodash") + ".spotify", account: String = "app-remote-token") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> SpotifyToken? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifyToken.self, from: data)
    }

    func save(_ token: SpotifyToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attributes) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// For the demo backend and tests.
@MainActor
final class MemorySpotifyTokenStore: SpotifyTokenStore {
    var token: SpotifyToken?
    init(token: SpotifyToken? = nil) { self.token = token }
    func load() -> SpotifyToken? { token }
    func save(_ token: SpotifyToken) { self.token = token }
    func clear() { token = nil }
}
