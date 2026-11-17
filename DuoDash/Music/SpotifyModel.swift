import UIKit
import Observation

/// Where the Spotify connection stands. Every failure ends in a state the
/// screen can show (never a silent failure).
enum SpotifyStatus: Equatable {
    /// No client ID in `Config/Secrets.xcconfig`.
    case notConfigured
    case notInstalled
    /// Not connected and not trying: shows Connect (sign in once, or wake Spotify).
    case notConnected
    case connecting
    case connected
    /// Was connected, or tried and failed: shows Reconnect with the reason.
    case disconnected(String)
    /// Spotify refused this account for both the sign-in and App Remote (e.g. not on the
    /// developer app's allow-list). Shows "Open Spotify"; no automatic retries.
    case limited

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
/// Connect flow (sign in once, then it just works):
/// 1. No saved sign-in: the user signs in once (Authorization Code with PKCE). The access
///    and refresh tokens go in the Keychain.
/// 2. Before every connect, an access token that has expired or is within 5 minutes of it is
///    renewed silently with the refresh token. Only a refused refresh token (`invalid_grant`)
///    asks the user to sign in again.
/// 3. App Remote needs the Spotify app running. When it isn't and the user tapped Connect,
///    Spotify opens for a moment (`authorizeAndPlayURI`, no questions after the first time),
///    starts playing and returns through `duodash://spotify-callback`. Right after a sign-in
///    this happens straight away.
///
/// App Remote only (`SpotifySignInMode.appRemoteOnly`): the TestFlight and App Store builds,
/// and any account whose PKCE sign-in Spotify refuses (development-mode allow-list). No
/// accounts.spotify.com sign-in: the token comes from the Spotify app when it opens for a
/// moment, and when it runs out Connect opens Spotify again. If the Spotify app refuses the
/// account too, the screen shows `.limited` ("Open Spotify") instead of retrying.
/// Everything the Spotify screen shows (player, artwork, the home-feed shelves, playlist and
/// album pages) comes over App Remote in both modes; Duo Dash makes no Web API calls.
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
    /// A refresh token is saved: Connect no longer needs a sign-in.
    private(set) var isSignedIn = false
    /// How the token is obtained right now (see the type's notes).
    private(set) var mode: SpotifySignInMode = .signInOnce
    /// The Client ID of the user's own developer app (Settings → Spotify), if set.
    private(set) var ownClientID: String?

    let isDemo: Bool
    /// What this build was set up for (Info.plist `SpotifySignInMode`).
    let buildMode: SpotifySignInMode
    @ObservationIgnored private let access: SpotifyAccessSettings

    @ObservationIgnored private let backend: SpotifyBackend
    @ObservationIgnored private let tokens: SpotifyTokenStore
    @ObservationIgnored private let auth: SpotifyAuthorizing
    /// The sign-in or silent renewal in progress.
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private let nowPlaying: NowPlayingModel
    @ObservationIgnored private var playerState: SpotifyPlayerState?
    @ObservationIgnored private var stateReceivedAt = Date.now
    @ObservationIgnored private var images: [String: UIImage] = [:]
    /// The current connect attempt was a tap (so it may open Spotify), and
    /// whether it has already been through Spotify to wake it.
    @ObservationIgnored private var userInitiated = false
    @ObservationIgnored private var hasWoken = false
    /// Signed out and not tapped Connect since: a late App Remote connection is dropped.
    @ObservationIgnored private var hasSignedOut = false
    @ObservationIgnored private(set) var isAwaitingRedirect = false
    /// When this app last sent the user to Spotify to authorise. A redirect is only accepted
    /// within 10 minutes of that, so another app or a web page can't plant a token.
    @ObservationIgnored private var authorizationStartedAt: Date?
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

    /// `auth` defaults to the demo backend's stand-in, or the PKCE sign-in with this build's client ID.
    /// `access` (own Client ID, fallbacks) defaults to UserDefaults, or memory for the demo.
    /// `buildMode` defaults to this build's Info.plist setting.
    init(nowPlaying: NowPlayingModel, backend: SpotifyBackend? = nil, tokens: SpotifyTokenStore? = nil,
         auth: SpotifyAuthorizing? = nil, access: SpotifyAccessSettings? = nil,
         buildMode: SpotifySignInMode? = nil, observesLifecycle: Bool = true) {
        let arguments = ProcessInfo.processInfo.arguments
        let backend = backend ?? (Self.usesDemo ? Self.demoBackend(arguments) : SpotifyAppRemoteBackend())
        self.backend = backend
        self.tokens = tokens ?? (backend.isDemo ? MemorySpotifyTokenStore() : KeychainSpotifyTokenStore())
        let access = access ?? SpotifyAccessSettings(defaults: backend.isDemo ? nil : .standard)
        self.access = access
        let clientID = access.ownClientID ?? SpotifyConfig.clientID()
        self.auth = auth ?? (backend as? SpotifyAuthorizing) ?? SpotifyPKCEAuthorizer(clientID: clientID ?? "")
        self.buildMode = buildMode ?? .thisBuild
        self.nowPlaying = nowPlaying
        self.isDemo = backend.isDemo
        ownClientID = access.ownClientID
        if access.ownClientID != nil { backend.setClientID(clientID) }
        updateMode()
        nowPlaying.register(.spotify, controller: self)
        backend.onEvent = { [weak self] event in self?.handle(event) }
        isSignedIn = self.tokens.load()?.refreshToken != nil
        status = baseStatus()
        if status == .notConnected { proceed(userInitiated: false) }
        if observesLifecycle {
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidBecomeActive() }
            }
        }
    }

    /// The Simulator's stand-in. `-DemoSpotifyNotAllowlisted`: the sign-in is refused (App
    /// Remote still works); `-DemoSpotifyRefused`: App Remote refuses the account too.
    private static func demoBackend(_ arguments: [String]) -> DemoSpotifyBackend {
        let demo = DemoSpotifyBackend(installed: !arguments.contains("-DemoSpotifyNotInstalled"))
        demo.signInNotAllowed = arguments.contains("-DemoSpotifyNotAllowlisted") || arguments.contains("-DemoSpotifyRefused")
        demo.appRemoteRefused = arguments.contains("-DemoSpotifyRefused")
        return demo
    }

    private func updateMode() {
        mode = SpotifySignInMode.choose(build: buildMode, hasOwnClientID: access.ownClientID != nil,
                                        fellBackToAppRemote: access.fellBackToAppRemote)
    }

    /// Opens the Spotify app (the "Open Spotify" button when control is limited).
    static let spotifyAppURL = URL(string: "spotify:")!

    var appStoreURL: URL { backend.appStoreURL }
    var track: TrackInfo? { snapshot.track }

    var currentTime: TimeInterval {
        guard let state = playerState else { return 0 }
        let running = state.isPaused ? 0 : now().timeIntervalSince(stateReceivedAt)
        return min(state.position + max(0, running), state.duration > 0 ? state.duration : .infinity)
    }

    private func saveToken(_ token: SpotifyToken) {
        tokens.save(token)
        isSignedIn = token.refreshToken != nil
    }

    /// Not configured / not installed / not connected, before any connection.
    private func baseStatus() -> SpotifyStatus {
        if !backend.isConfigured { return .notConfigured }
        if !backend.isSpotifyInstalled() { return .notInstalled }
        if access.isLimited { return .limited }
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
        hasWoken = false
        hasSignedOut = false
        proceed(userInitiated: true)
    }

    /// "Try Again" on the limited screen (e.g. after being added to the allow-list).
    func retryAfterLimited() {
        access.isLimited = false
        status = baseStatus()
        connect()
    }

    /// Settings → Spotify → "Use my own Spotify developer app": switch to its Client ID (nil:
    /// back to this build's). Signs out, since tokens belong to one Client ID, and forgets the
    /// fallbacks taken with the old one.
    func useOwnClientID(_ clientID: String?) {
        signOut()
        access.ownClientID = clientID
        access.fellBackToAppRemote = false
        access.isLimited = false
        ownClientID = clientID
        let active = clientID ?? SpotifyConfig.clientID()
        backend.setClientID(active)
        auth.setClientID(active)
        updateMode()
        status = baseStatus()
    }

    /// The account isn't allowed to sign in (allow-list): carry on with App Remote only.
    private func fallBackToAppRemote() {
        access.fellBackToAppRemote = true
        updateMode()
        tokens.clear()
        isSignedIn = false
    }

    /// Spotify refused the account for App Remote too: stop, and offer to open Spotify.
    private func enterLimited() {
        access.isLimited = true
        tokens.clear()
        isSignedIn = false
        userInitiated = false
        isAwaitingRedirect = false
        timeoutTask?.cancel()
        status = .limited
    }

    /// Sign out: forget the tokens (Keychain included), drop the connection and the
    /// library. The next Connect signs in again.
    func signOut() {
        authTask?.cancel()
        authTask = nil
        timeoutTask?.cancel()
        isAwaitingRedirect = false
        authorizationStartedAt = nil
        userInitiated = false
        hasSignedOut = true
        tokens.clear()
        isSignedIn = false
        status = baseStatus()
        backend.disconnect()
        clearPlayer()
        recents = []
        shelves = []
        children = [:]
        childErrors = [:]
        hasLoadedLibrary = false
        libraryError = nil
        errorMessage = nil
    }

    /// Connects with the saved sign-in: as it is, renewed first, or (only after a tap)
    /// by signing in. Without a tap and without a usable sign-in it does nothing.
    private func proceed(userInitiated: Bool) {
        if mode == .appRemoteOnly {
            // No refresh token to renew with: use the token while it lasts, otherwise (only
            // after a tap) get a new one from the Spotify app.
            if let token = tokens.load(), token.isValid(at: now()) {
                beginConnecting(token: token.accessToken, userInitiated: userInitiated)
            } else if userInitiated {
                wake()
            }
            return
        }
        switch SpotifyTokenPlan.plan(for: tokens.load(), at: now()) {
        case .use(let token):
            beginConnecting(token: token, userInitiated: userInitiated)
        case .refresh(let refreshToken):
            renewThenConnect(refreshToken, userInitiated: userInitiated)
        case .signIn:
            if userInitiated { signIn() }
        }
    }

    /// Renews the access token silently, then connects. A refused refresh token is
    /// forgotten: after a tap that means signing in again; otherwise Connect shows.
    private func renewThenConnect(_ refreshToken: String, userInitiated: Bool) {
        self.userInitiated = userInitiated
        status = .connecting
        timeoutTask?.cancel()
        authTask?.cancel()
        let auth = auth
        authTask = Task { [weak self] in
            do {
                let token = try await auth.refresh(refreshToken)
                guard let self, !Task.isCancelled else { return }
                self.saveToken(token)
                self.beginConnecting(token: token.accessToken, userInitiated: userInitiated)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.renewalFailed(error, userInitiated: userInitiated)
            }
        }
    }

    private func renewalFailed(_ error: Error, userInitiated: Bool) {
        if case SpotifyAuthError.notAllowed = error {
            fallBackToAppRemote()
            if userInitiated { wake() } else { status = baseStatus() }
            return
        }
        if case SpotifyAuthError.invalidGrant = error {
            tokens.clear()
            isSignedIn = false
            if userInitiated {
                signIn()
            } else {
                status = .disconnected(SpotifyAuthError.invalidGrant.errorDescription ?? "Sign in to Spotify again.")
            }
            return
        }
        // Offline or Spotify having a moment: an access token with a minute left still works.
        if let token = tokens.load(), token.isValid(at: now()) {
            beginConnecting(token: token.accessToken, userInitiated: userInitiated)
            return
        }
        self.userInitiated = false
        let reason = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach Spotify."
        status = .disconnected(reason)
    }

    /// The one-time sign-in (PKCE). Then Spotify is woken so App Remote can connect.
    private func signIn() {
        userInitiated = true
        status = .connecting
        timeoutTask?.cancel()
        authTask?.cancel()
        let auth = auth
        authTask = Task { [weak self] in
            do {
                let token = try await auth.signIn()
                guard let self, !Task.isCancelled else { return }
                self.saveToken(token)
                // App Remote needs Spotify running; the user is already setting up, so open
                // it now (it also starts playback) rather than trying and failing first.
                self.wake()
            } catch {
                guard let self, !Task.isCancelled else { return }
                if case SpotifyAuthError.notAllowed = error {
                    // Not on the allow-list: App Remote talks to the Spotify app instead,
                    // which may still let this account in.
                    self.fallBackToAppRemote()
                    self.wake()
                    return
                }
                self.userInitiated = false
                if case SpotifyAuthError.cancelled = error {
                    self.status = self.baseStatus()
                } else {
                    self.status = .disconnected((error as? LocalizedError)?.errorDescription ?? "Couldn't sign in to Spotify.")
                }
            }
        }
    }

    private func beginConnecting(token: String, userInitiated: Bool) {
        self.userInitiated = userInitiated
        status = .connecting
        startTimeout(connectTimeout, message: "Spotify didn't respond. Open Spotify, then tap Reconnect.")
        backend.connect(accessToken: token)
    }

    /// Opens Spotify for a moment so it's running (App Remote can't start it). Spotify comes
    /// back via `handleOpenURL` with an access token.
    private func wake() {
        hasWoken = true
        userInitiated = true
        status = .connecting
        isAwaitingRedirect = true
        authorizationStartedAt = now()
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
        // Not something we asked for: swallow it without changing anything.
        guard let started = authorizationStartedAt, now().timeIntervalSince(started) < 600 else { return true }
        authorizationStartedAt = nil
        isAwaitingRedirect = false
        timeoutTask?.cancel()
        switch result {
        case .token(let token, let expiresIn):
            // A fresh access token from Spotify; the sign-in's refresh token carries on.
            saveToken(SpotifyToken(accessToken: token, expiresAt: now().addingTimeInterval(expiresIn),
                                   refreshToken: tokens.load()?.refreshToken))
            beginConnecting(token: token, userInitiated: true)
        case .failed(let message):
            status = .disconnected(message)
        case .refused:
            enterLimited()
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
            proceed(userInitiated: false)
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
            // Signed out while App Remote was still connecting: don't stay connected.
            guard !hasSignedOut else {
                backend.disconnect()
                return
            }
            status = .connected
            userInitiated = false
            if !hasLoadedLibrary { Task { await loadLibrary() } }
        case .connectionFailed(let reason):
            timeoutTask?.cancel()
            if hasWoken && SpotifyRefusal.isNotAllowed(reason) {
                // Spotify is running and still says no to this account.
                enterLimited()
            } else if userInitiated && !hasWoken {
                // Spotify isn't running, or the token was refused: go through
                // Spotify, which starts it and hands back a fresh token.
                wake()
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
