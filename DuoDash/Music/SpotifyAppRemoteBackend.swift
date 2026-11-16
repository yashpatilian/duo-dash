import UIKit
import SpotifyiOS

/// Talks to the Spotify app through the Spotify iOS SDK (App Remote). Audio
/// stays in Spotify's process, so it keeps playing in the background and voice
/// directions duck it like Apple Music.
@MainActor
final class SpotifyAppRemoteBackend: NSObject, SpotifyBackend {
    let isDemo = false
    let isConfigured: Bool
    var onEvent: (@MainActor (SpotifyBackendEvent) -> Void)?

    private let redirectURL: URL
    private let appRemote: SPTAppRemote?
    /// Content items by identifier: `fetchChildren` and `playItem` want the
    /// SDK's own objects back.
    private var contentItems: [String: SPTAppRemoteContentItem] = [:]
    private var imageSources: [String: SPTAppRemoteImageRepresentable] = [:]

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let clientID = (info["SpotifyClientID"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let redirect = URL(string: info["SpotifyRedirectURI"] as? String ?? "") ?? URL(string: "duodash://spotify-callback")!
        redirectURL = redirect
        // An unset build setting comes through empty (or as the literal "$(…)").
        isConfigured = !clientID.isEmpty && !clientID.hasPrefix("$(")
        if isConfigured {
            let configuration = SPTConfiguration(clientID: clientID, redirectURL: redirect)
            // Blank: carry on with whatever the user last played in Spotify.
            configuration.playURI = ""
            appRemote = SPTAppRemote(configuration: configuration, logLevel: .error)
        } else {
            appRemote = nil
        }
        super.init()
        appRemote?.delegate = self
    }

    var appStoreURL: URL {
        let id = SPTAppRemote.spotifyItunesItemIdentifier().stringValue
        return URL(string: "itms-apps://apps.apple.com/app/id\(id)")!
    }

    func isSpotifyInstalled() -> Bool {
        guard let url = URL(string: "spotify:") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    // MARK: Connection

    func authorize(playURI: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard let appRemote else { completion(false); return }
        appRemote.authorizeAndPlayURI(playURI) { success in
            Self.onMain { completion(success) }
        }
    }

    func authorizationResult(from url: URL) -> SpotifyAuthResult? {
        guard url.scheme == redirectURL.scheme, url.host == redirectURL.host, let appRemote else { return nil }
        let parameters = appRemote.authorizationParameters(from: url) ?? [:]
        if let token = parameters[SPTAppRemoteAccessTokenKey], !token.isEmpty {
            let expiresIn = parameters["expires_in"].flatMap(TimeInterval.init) ?? 3600
            return .token(token, expiresIn: expiresIn)
        }
        return .failed(parameters[SPTAppRemoteErrorDescriptionKey] ?? "Spotify didn't allow the connection.")
    }

    func connect(accessToken: String) {
        guard let appRemote else { onEvent?(.connectionFailed("Spotify isn't set up in this build.")); return }
        appRemote.connectionParameters.accessToken = accessToken
        appRemote.connect()
    }

    func disconnect() {
        guard let appRemote, appRemote.isConnected else { return }
        appRemote.disconnect()
    }

    private func didConnect() {
        guard let player = appRemote?.playerAPI else { return }
        player.delegate = self
        player.subscribe(toPlayerState: nil)
        player.getPlayerState { [weak self] result, _ in
            guard let state = result as? SPTAppRemotePlayerState else { return }
            let snapshot = Self.snapshot(of: state)
            Self.onMain { self?.receive(state, snapshot: snapshot) }
        }
        onEvent?(.connected)
    }

    private func receive(_ state: SPTAppRemotePlayerState, snapshot: SpotifyPlayerState) {
        imageSources[state.track.imageIdentifier] = state.track
        onEvent?(.playerState(snapshot))
    }

    nonisolated private static func snapshot(of state: SPTAppRemotePlayerState) -> SpotifyPlayerState {
        let track = state.track
        let repeatSetting: RepeatSetting = switch state.playbackOptions.repeatMode {
        case .track: .one
        case .context: .all
        default: .off
        }
        return SpotifyPlayerState(trackURI: track.uri, title: track.name, artist: track.artist.name,
                                  album: track.album.name, imageIdentifier: track.imageIdentifier,
                                  isPaused: state.isPaused, position: TimeInterval(state.playbackPosition) / 1000,
                                  duration: TimeInterval(track.duration) / 1000,
                                  shuffle: state.playbackOptions.isShuffling, repeatSetting: repeatSetting)
    }

    /// App Remote calls back on the main thread; this makes that explicit.
    nonisolated private static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }

    // MARK: Player

    private var player: SPTAppRemotePlayerAPI {
        get throws {
            guard let appRemote, appRemote.isConnected, let player = appRemote.playerAPI else { throw SpotifyError.notConnected }
            return player
        }
    }

    /// Runs an App Remote call and waits for its callback.
    private func call(_ body: (@escaping SPTAppRemoteCallback) -> Void) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            body { result, error in
                if let error {
                    continuation.resume(throwing: SpotifyError.failed(error.localizedDescription))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func resume() async throws { let p = try player; _ = try await call { p.resume($0) } }
    func pause() async throws { let p = try player; _ = try await call { p.pause($0) } }
    func skipToNext() async throws { let p = try player; _ = try await call { p.skip(toNext: $0) } }
    func skipToPrevious() async throws { let p = try player; _ = try await call { p.skip(toPrevious: $0) } }
    func setShuffle(_ on: Bool) async throws { let p = try player; _ = try await call { p.setShuffle(on, callback: $0) } }

    func setRepeat(_ setting: RepeatSetting) async throws {
        let p = try player
        let mode: SPTAppRemotePlaybackOptionsRepeatMode = switch setting {
        case .off: .off
        case .all: .context
        case .one: .track
        }
        _ = try await call { p.setRepeatMode(mode, callback: $0) }
    }

    func play(_ item: SpotifyItem) async throws {
        let p = try player
        if let content = contentItems[item.identifier] {
            _ = try await call { p.play(content, callback: $0) }
        } else {
            _ = try await call { p.play(item.uri, callback: $0) }
        }
    }

    // MARK: Content

    private var content: SPTAppRemoteContentAPI {
        get throws {
            guard let appRemote, appRemote.isConnected, let api = appRemote.contentAPI else { throw SpotifyError.notConnected }
            return api
        }
    }

    func recommendedItems(flatten: Bool) async throws -> [SpotifyItem] {
        let api = try content
        let result = try await call {
            api.fetchRecommendedContentItems(forType: SPTAppRemoteContentTypeDefault, flattenContainers: flatten, callback: $0)
        }
        return remember(result as? [SPTAppRemoteContentItem] ?? [])
    }

    func children(of item: SpotifyItem) async throws -> [SpotifyItem] {
        let api = try content
        var parent = contentItems[item.identifier]
        if parent == nil {
            parent = try await call { api.fetchContentItem(forURI: item.uri, callback: $0) } as? SPTAppRemoteContentItem
        }
        guard let parent else { throw SpotifyError.failed("Couldn't open “\(item.title)”.") }
        // Some containers arrive with their children already filled in.
        if let children = parent.children, !children.isEmpty { return remember(children) }
        let result = try await call { api.fetchChildren(of: parent, callback: $0) }
        return remember(result as? [SPTAppRemoteContentItem] ?? [])
    }

    private func remember(_ items: [SPTAppRemoteContentItem]) -> [SpotifyItem] {
        items.map { item in
            contentItems[item.identifier] = item
            let imageID = item.imageIdentifier
            if !imageID.isEmpty { imageSources[imageID] = item }
            return SpotifyItem(identifier: item.identifier, uri: item.uri, title: item.title ?? "Untitled",
                               subtitle: item.subtitle ?? "", imageIdentifier: imageID.isEmpty ? nil : imageID,
                               isContainer: item.isContainer, isPlayable: item.isPlayable)
        }
    }

    func image(for imageIdentifier: String, size: CGSize) async -> UIImage? {
        guard let appRemote, appRemote.isConnected, let api = appRemote.imageAPI else { return nil }
        let source = imageSources[imageIdentifier] ?? ImageReference(imageIdentifier: imageIdentifier)
        return try? await call { api.fetchImage(forItem: source, with: size, callback: $0) } as? UIImage
    }
}

/// Lets the image API fetch artwork by identifier alone.
private final class ImageReference: NSObject, SPTAppRemoteImageRepresentable {
    let imageIdentifier: String
    init(imageIdentifier: String) { self.imageIdentifier = imageIdentifier }
}

extension SpotifyAppRemoteBackend: SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Self.onMain { [weak self] in self?.didConnect() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        let message = error?.localizedDescription
        Self.onMain { [weak self] in self?.onEvent?(.connectionFailed(message)) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        let message = error?.localizedDescription
        Self.onMain { [weak self] in self?.onEvent?(.disconnected(message)) }
    }

    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        let snapshot = Self.snapshot(of: playerState)
        nonisolated(unsafe) let state = playerState
        Self.onMain { [weak self] in self?.receive(state, snapshot: snapshot) }
    }
}
