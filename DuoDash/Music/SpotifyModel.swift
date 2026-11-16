import UIKit
import Observation

/// Where the Spotify connection stands. Every failure ends in a state the
/// screen can show (never a silent failure).
enum SpotifyStatus: Equatable {
    /// No client ID in `Config/Secrets.xcconfig`.
    case notConfigured
    case notInstalled
    /// Never connected (or the saved token ran out): needs a trip through Spotify.
    case notConnected
    case connecting
    case connected
    /// Was connected, or tried and failed: shows Reconnect with the reason.
    case disconnected(String)

    var isConnected: Bool { self == .connected }
}

/// One row-group on the Playlists tab: a section of Spotify's feed and its items.
struct SpotifyShelf: Identifiable, Equatable {
    let section: SpotifyItem
    var items: [SpotifyItem]
    var id: String { section.id }
}

/// Spotify state for the UI, and the `.spotify` source for NowPlayingModel.
///
/// Connect flow: with a valid saved token, connect straight away (Spotify must
/// be running). Otherwise, or when that fails after a tap, authorise: Spotify
/// opens briefly, starts playing (App Remote needs it to) and returns through
/// `duodash://spotify-callback` with a token, which is saved in the Keychain.
@MainActor
@Observable
final class SpotifyModel: NowPlayingController, PlayerSource {
    private(set) var status: SpotifyStatus = .notConnected
    private(set) var snapshot = PlayerSnapshot()
    private(set) var recents: [SpotifyItem] = []
    private(set) var shelves: [SpotifyShelf] = []
    private(set) var isLoadingLibrary = false
    private(set) var hasLoadedLibrary = false
    private(set) var libraryError: String?
    /// Opened playlist/album pages, by item id.
    private(set) var children: [String: [SpotifyItem]] = [:]
    private(set) var childErrors: [String: String] = [:]
    private(set) var pendingItemID: String?
    var errorMessage: String?

    let isDemo: Bool

    @ObservationIgnored private let backend: SpotifyBackend
    @ObservationIgnored private let tokens: SpotifyTokenStore
    @ObservationIgnored private let nowPlaying: NowPlayingModel
    @ObservationIgnored private var playerState: SpotifyPlayerState?
    @ObservationIgnored private var stateReceivedAt = Date.now
    @ObservationIgnored private var images: [String: UIImage] = [:]
    /// The current connect attempt was a tap (so it may open Spotify), and
    /// whether it has already been through Spotify's authorisation.
    @ObservationIgnored private var userInitiated = false
    @ObservationIgnored private var hasAuthorized = false
    @ObservationIgnored private(set) var isAwaitingRedirect = false
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// Injectable clock for token-expiry tests.
    @ObservationIgnored var now: () -> Date = { .now }
    /// How long to wait for App Remote, and for Spotify's redirect after
    /// coming back to the app. Shortened in tests.
    @ObservationIgnored var connectTimeout: Duration = .seconds(12)
    @ObservationIgnored var redirectTimeout: Duration = .seconds(5)

    /// The Simulator has no Spotify app; UI tests can also ask for the demo on a device.
    static var usesDemo: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("-DemoSpotify")
        #endif
    }

    init(nowPlaying: NowPlayingModel, backend: SpotifyBackend? = nil, tokens: SpotifyTokenStore? = nil,
         observesLifecycle: Bool = true) {
        let arguments = ProcessInfo.processInfo.arguments
        let backend = backend ?? (Self.usesDemo
            ? DemoSpotifyBackend(installed: !arguments.contains("-DemoSpotifyNotInstalled"))
            : SpotifyAppRemoteBackend())
        self.backend = backend
        self.tokens = tokens ?? (backend.isDemo ? MemorySpotifyTokenStore() : KeychainSpotifyTokenStore())
        self.nowPlaying = nowPlaying
        self.isDemo = backend.isDemo
        nowPlaying.register(.spotify, controller: self)
        backend.onEvent = { [weak self] event in self?.handle(event) }
        status = baseStatus()
        if status == .notConnected, let token = validToken {
            beginConnecting(token: token, userInitiated: false)
        }
        if observesLifecycle {
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidBecomeActive() }
            }
        }
    }

    var appStoreURL: URL { backend.appStoreURL }
    var track: TrackInfo? { snapshot.track }

    var currentTime: TimeInterval {
        guard let state = playerState else { return 0 }
        let running = state.isPaused ? 0 : now().timeIntervalSince(stateReceivedAt)
        return min(state.position + max(0, running), state.duration > 0 ? state.duration : .infinity)
    }

    private var validToken: String? {
        guard let token = tokens.load(), token.isValid(at: now()) else { return nil }
        return token.accessToken
    }

    /// Not configured / not installed / not connected, before any connection.
    private func baseStatus() -> SpotifyStatus {
        if !backend.isConfigured { return .notConfigured }
        if !backend.isSpotifyInstalled() { return .notInstalled }
        return .notConnected
    }

    // MARK: Connecting

    /// The Connect / Reconnect button.
    func connect() {
        switch status {
        case .connected, .connecting, .notConfigured: return
        default: break
        }
        status = baseStatus()
        guard status == .notConnected else { return }
        errorMessage = nil
        hasAuthorized = false
        if let token = validToken {
            beginConnecting(token: token, userInitiated: true)
        } else {
            authorize()
        }
    }

    private func beginConnecting(token: String, userInitiated: Bool) {
        self.userInitiated = userInitiated
        status = .connecting
        startTimeout(connectTimeout, message: "Spotify didn't respond. Open Spotify, then tap Reconnect.")
        backend.connect(accessToken: token)
    }

    /// Opens Spotify to get a fresh token. Spotify comes back via `handleOpenURL`.
    private func authorize() {
        hasAuthorized = true
        userInitiated = true
        status = .connecting
        isAwaitingRedirect = true
        timeoutTask?.cancel()
        // Blank: Spotify resumes whatever was playing last.
        backend.authorize(playURI: "") { [weak self] opened in
            guard let self, !opened else { return }
            self.isAwaitingRedirect = false
            self.status = self.backend.isSpotifyInstalled()
                ? .disconnected("Couldn't open Spotify.")
                : .notInstalled
        }
    }

    /// Spotify's redirect after authorising. Returns false for other URLs.
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        guard let result = backend.authorizationResult(from: url) else { return false }
        isAwaitingRedirect = false
        timeoutTask?.cancel()
        switch result {
        case .token(let token, let expiresIn):
            tokens.save(SpotifyToken(accessToken: token, expiresAt: now().addingTimeInterval(expiresIn)))
            beginConnecting(token: token, userInitiated: true)
        case .failed(let message):
            status = .disconnected(message)
        }
        return true
    }

    /// Back in the foreground: notice Spotify being installed or removed, give
    /// up on an authorisation the user abandoned, and reconnect quietly if a
    /// call or Spotify being closed dropped the connection.
    func appDidBecomeActive() {
        switch status {
        case .notInstalled, .notConnected, .disconnected:
            let base = baseStatus()
            if base != .notConnected {
                status = base
                return
            }
            if status == .notInstalled { status = .notConnected }
        default:
            break
        }
        if isAwaitingRedirect {
            // The redirect normally arrives right after we're active again.
            startTimeout(redirectTimeout, message: "Spotify didn't finish connecting. Tap Reconnect to try again.")
            return
        }
        switch status {
        case .notConnected, .disconnected:
            if let token = validToken { beginConnecting(token: token, userInitiated: false) }
        default:
            break
        }
    }

    private func startTimeout(_ duration: Duration, message: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.status == .connecting else { return }
            self.isAwaitingRedirect = false
            self.status = .disconnected(message)
        }
    }

    // MARK: Events

    private func handle(_ event: SpotifyBackendEvent) {
        switch event {
        case .connected:
            timeoutTask?.cancel()
            status = .connected
            userInitiated = false
            if !hasLoadedLibrary { Task { await loadLibrary() } }
        case .connectionFailed(let reason):
            timeoutTask?.cancel()
            if userInitiated && !hasAuthorized {
                // Spotify isn't running, or the saved token was refused: go
                // through Spotify, which also starts it.
                authorize()
            } else {
                userInitiated = false
                status = .disconnected(Self.describe(reason, fallback: "Couldn't connect to Spotify."))
            }
        case .disconnected(let reason):
            switch status {
            case .connected, .connecting:
                status = .disconnected(Self.describe(reason, fallback: "Spotify disconnected."))
            default:
                break
            }
            clearPlayer()
        case .playerState(let state):
            apply(state)
        case .redirect(let url):
            handleOpenURL(url)
        }
    }

    private static func describe(_ reason: String?, fallback: String) -> String {
        guard let reason, !reason.isEmpty else { return fallback }
        return "\(fallback) \(reason)"
    }

    // MARK: Player state

    private func apply(_ state: SpotifyPlayerState) {
        guard !state.trackURI.isEmpty else { clearPlayer(); return }
        playerState = state
        stateReceivedAt = now()
        publish()
        if let id = state.imageIdentifier, images[Self.key(id, 600)] == nil {
            Task {
                guard let image = await backend.image(for: id, size: CGSize(width: 600, height: 600)) else { return }
                images[Self.key(id, 600)] = image
                if playerState?.imageIdentifier == id { publish() }
            }
        }
    }

    private func publish() {
        guard let state = playerState else { return }
        let artwork = state.imageIdentifier.flatMap { images[Self.key($0, 600)] }
        let latest = PlayerSnapshot(track: TrackInfo(title: state.title, artist: state.artist, album: state.album,
                                                     artwork: artwork, isPlaying: !state.isPaused,
                                                     duration: state.duration),
                                    shuffle: state.shuffle, repeatSetting: state.repeatSetting)
        if latest != snapshot { snapshot = latest }
        nowPlaying.update(.spotify, track: latest.track)
    }

    private func clearPlayer() {
        playerState = nil
        if snapshot != PlayerSnapshot() { snapshot = PlayerSnapshot() }
        nowPlaying.update(.spotify, track: nil)
    }

    // MARK: Controls

    func togglePlayPause() {
        let paused = playerState?.isPaused ?? true
        perform { paused ? try await $0.resume() : try await $0.pause() }
    }

    func skipToNext() { perform { try await $0.skipToNext() } }
    func skipToPrevious() { perform { try await $0.skipToPrevious() } }

    func toggleShuffle() {
        let on = !snapshot.shuffle
        perform { try await $0.setShuffle(on) }
    }

    func cycleRepeat() {
        let next = snapshot.repeatSetting.next
        perform { try await $0.setRepeat(next) }
    }

    private func perform(_ operation: @escaping @MainActor (SpotifyBackend) async throws -> Void) {
        let backend = backend
        Task {
            do {
                try await operation(backend)
            } catch {
                report(error, doing: "control Spotify")
            }
        }
    }

    private func report(_ error: Error, doing what: String) {
        if case SpotifyError.notConnected = error {
            if status == .connected { status = .disconnected("Spotify disconnected.") }
            errorMessage = "Spotify isn't connected. Tap Reconnect on the Spotify screen."
        } else {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = "Couldn't \(what). \(reason)"
        }
    }

    /// Plays a playlist, album or song. Rapid taps: the last one wins.
    func play(_ item: SpotifyItem) {
        playTask?.cancel()
        pendingItemID = item.id
        errorMessage = nil
        let backend = backend
        playTask = Task {
            do {
                try await backend.play(item)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                report(error, doing: "play “\(item.title)”")
            }
            if pendingItemID == item.id { pendingItemID = nil }
        }
    }

    // MARK: Library

    /// Recents and the Playlists shelves, from Spotify's home feed.
    func loadLibrary() async {
        guard status == .connected, !isLoadingLibrary else { return }
        isLoadingLibrary = true
        libraryError = nil
        do {
            let sections = try await backend.recommendedItems(flatten: false)
            let recent = sections.first { $0.title.localizedCaseInsensitiveContains("recent") }
            var shelves: [SpotifyShelf] = []
            for section in sections where section != recent {
                if section.isContainer {
                    shelves.append(SpotifyShelf(section: section, items: try await backend.children(of: section)))
                } else {
                    // A loose playable item: group them under one heading.
                    if shelves.last?.section.identifier == "loose" {
                        shelves[shelves.count - 1].items.append(section)
                    } else {
                        shelves.append(SpotifyShelf(section: SpotifyItem(identifier: "loose", uri: "", title: "For you"),
                                                    items: [section]))
                    }
                }
            }
            if let recent {
                recents = try await backend.children(of: recent)
            } else {
                recents = try await backend.recommendedItems(flatten: true)
            }
            self.shelves = shelves
            hasLoadedLibrary = true
        } catch {
            libraryError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load your Spotify library."
        }
        isLoadingLibrary = false
    }

    /// Loads a playlist's or album's contents once; later visits use the cache.
    func loadChildren(of item: SpotifyItem) async {
        guard children[item.id] == nil else { return }
        childErrors[item.id] = nil
        do {
            children[item.id] = try await backend.children(of: item)
        } catch {
            childErrors[item.id] = (error as? LocalizedError)?.errorDescription ?? "Couldn't open “\(item.title)”."
        }
    }

    func image(for item: SpotifyItem, size: CGFloat) async -> UIImage? {
        guard let id = item.imageIdentifier else { return nil }
        let key = Self.key(id, size)
        if let cached = images[key] { return cached }
        let image = await backend.image(for: id, size: CGSize(width: size, height: size))
        if let image { images[key] = image }
        return image
    }

    private static func key(_ id: String, _ size: CGFloat) -> String { "\(id)@\(Int(size))" }
}
