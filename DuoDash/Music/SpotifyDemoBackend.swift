import UIKit

/// A silent, deterministic stand-in for the Spotify app. Used in the Simulator
/// (which has no Spotify) and in tests, so the Spotify screen, its connect /
/// reconnect states and the shared now playing can be exercised end to end.
@MainActor
final class DemoSpotifyBackend: SpotifyBackend {
    let isDemo = true
    var isConfigured = true
    var onEvent: (@MainActor (SpotifyBackendEvent) -> Void)?
    let appStoreURL = URL(string: "itms-apps://apps.apple.com/app/id324684580")!

    /// The Spotify app is on the phone.
    var isInstalled: Bool
    /// The Spotify app is running, so `connect` works without authorising again.
    /// Authorising launches it.
    private(set) var isSpotifyRunning = false
    /// The user taps "Cancel" in Spotify's authorisation sheet.
    var authorizationDenied = false
    /// The user leaves Spotify without approving, so no redirect arrives.
    var authorizationAbandoned = false
    private(set) var isConnected = false
    private(set) var authorizeCount = 0
    private(set) var connectCount = 0
    private(set) var playedURIs: [String] = []

    private struct Song { let uri: String; let title: String; let artist: String; let album: String; let duration: TimeInterval }
    private var containers: [String: (item: SpotifyItem, songs: [Song])] = [:]
    private var sections: [(item: SpotifyItem, children: [SpotifyItem])] = []

    private var queue: [Song] = []
    private var index = 0
    private var isPaused = true
    private var elapsed: TimeInterval = 0
    private var startedAt: Date?
    private var shuffle = false
    private var repeatSetting: RepeatSetting = .off

    init(installed: Bool = true, spotifyRunning: Bool = false) {
        isInstalled = installed
        isSpotifyRunning = spotifyRunning
        buildLibrary()
    }

    func isSpotifyInstalled() -> Bool { isInstalled }

    // MARK: Connection

    func authorize(playURI: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard isInstalled else { completion(false); return }
        authorizeCount += 1
        completion(true)
        guard !authorizationAbandoned else { return }
        // Spotify opens, the user agrees, Spotify starts playing (App Remote
        // needs it to) and opens our redirect URL.
        let denied = authorizationDenied
        deliver {
            if denied {
                self.onEvent?(.redirect(URL(string: "duodash://spotify-callback?error=access_denied")!))
            } else {
                self.isSpotifyRunning = true
                if self.queue.isEmpty { self.load(self.containers["spotify:playlist:demo-drive"]?.songs ?? [], at: 0) }
                self.isPaused = false
                self.startedAt = .now
                self.onEvent?(.redirect(URL(string: "duodash://spotify-callback#access_token=demo-token&expires_in=3600")!))
            }
        }
    }

    func authorizationResult(from url: URL) -> SpotifyAuthResult? {
        guard url.scheme == "duodash", url.host == "spotify-callback" else { return nil }
        let pairs = (url.fragment ?? url.query ?? "").split(separator: "&").map { $0.split(separator: "=", maxSplits: 1) }
        let values = Dictionary(pairs.compactMap { $0.count == 2 ? (String($0[0]), String($0[1])) : nil }) { a, _ in a }
        if let token = values["access_token"] {
            return .token(token, expiresIn: values["expires_in"].flatMap(TimeInterval.init) ?? 3600)
        }
        return .failed(values["error"] == "access_denied" ? "Spotify access wasn't allowed." : "Spotify didn't allow the connection.")
    }

    func connect(accessToken: String) {
        connectCount += 1
        deliver {
            guard self.isSpotifyRunning, !accessToken.isEmpty else {
                self.onEvent?(.connectionFailed("Spotify isn't running."))
                return
            }
            self.isConnected = true
            self.onEvent?(.connected)
            self.emitState()
        }
    }

    func disconnect() {
        guard isConnected else { return }
        isConnected = false
        deliver { self.onEvent?(.disconnected(nil)) }
    }

    /// Test hook: Spotify is killed (or a phone call ends the connection).
    func simulateSpotifyQuit() {
        isSpotifyRunning = false
        isConnected = false
        deliver { self.onEvent?(.disconnected("Spotify stopped.")) }
    }

    /// Events arrive asynchronously, like App Remote's.
    private func deliver(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    // MARK: Player

    private func requireConnection() throws {
        guard isConnected else { throw SpotifyError.notConnected }
    }

    func resume() async throws {
        try requireConnection()
        guard isPaused, !queue.isEmpty else { return }
        isPaused = false
        startedAt = .now
        emitState()
    }

    func pause() async throws {
        try requireConnection()
        guard !isPaused else { return }
        elapsed = currentElapsed
        isPaused = true
        startedAt = nil
        emitState()
    }

    func skipToNext() async throws {
        try requireConnection()
        guard !queue.isEmpty else { return }
        if repeatSetting != .one { index = (index + 1) % queue.count }
        restartTrack()
    }

    func skipToPrevious() async throws {
        try requireConnection()
        guard !queue.isEmpty else { return }
        if currentElapsed < 3 { index = (index - 1 + queue.count) % queue.count }
        restartTrack()
    }

    func setShuffle(_ on: Bool) async throws {
        try requireConnection()
        shuffle = on
        emitState()
    }

    func setRepeat(_ setting: RepeatSetting) async throws {
        try requireConnection()
        repeatSetting = setting
        emitState()
    }

    func play(_ item: SpotifyItem) async throws {
        try requireConnection()
        try await Task.sleep(for: .milliseconds(150))
        playedURIs.append(item.uri)
        if let container = containers[item.uri] {
            load(container.songs, at: 0)
        } else if let owner = containers.values.first(where: { $0.songs.contains { $0.uri == item.uri } }),
                  let at = owner.songs.firstIndex(where: { $0.uri == item.uri }) {
            load(owner.songs, at: at)
        } else {
            throw SpotifyError.failed("Couldn't play “\(item.title)”.")
        }
        isPaused = false
        startedAt = .now
        emitState()
    }

    private func load(_ songs: [Song], at start: Int) {
        queue = songs
        index = min(start, max(songs.count - 1, 0))
        elapsed = 0
    }

    private func restartTrack() {
        elapsed = 0
        startedAt = isPaused ? nil : .now
        emitState()
    }

    private var currentElapsed: TimeInterval {
        elapsed + (startedAt.map { Date.now.timeIntervalSince($0) } ?? 0)
    }

    private func emitState() {
        guard isConnected, queue.indices.contains(index) else { return }
        let song = queue[index]
        onEvent?(.playerState(SpotifyPlayerState(trackURI: song.uri, title: song.title, artist: song.artist,
                                                 album: song.album, imageIdentifier: song.uri,
                                                 isPaused: isPaused, position: currentElapsed,
                                                 duration: song.duration, shuffle: shuffle,
                                                 repeatSetting: repeatSetting)))
    }

    // MARK: Content

    func recommendedItems(flatten: Bool) async throws -> [SpotifyItem] {
        try requireConnection()
        return flatten ? sections.flatMap(\.children) : sections.map(\.item)
    }

    func children(of item: SpotifyItem) async throws -> [SpotifyItem] {
        try requireConnection()
        if let section = sections.first(where: { $0.item.identifier == item.identifier }) { return section.children }
        guard let container = containers[item.uri] else { throw SpotifyError.failed("Couldn't open “\(item.title)”.") }
        return container.songs.map {
            SpotifyItem(identifier: $0.uri, uri: $0.uri, title: $0.title, subtitle: $0.artist, imageIdentifier: $0.uri)
        }
    }

    func image(for imageIdentifier: String, size: CGSize) async -> UIImage? {
        // A stable seed per item, so the same playlist always gets the same cover.
        let seed = UInt64(imageIdentifier.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF })
        return DemoMusicBackend.makeArtwork(seed: seed, size: max(size.width, 60))
    }

    // MARK: Demo library

    private func buildLibrary() {
        let artists = ["Coastal Lights", "Nova Rae", "Harbour Line", "Kestrel", "June Avenue", "Atlas Grey"]
        let words = ["Midnight", "Highway", "Static", "Golden", "Lanes", "Northern", "Echo", "Runway",
                     "Tidal", "Ember", "Satellite", "Overpass", "Glass", "Harbour", "Arrival", "Sundown"]
        var counter = 0
        func songs(_ count: Int, album: String) -> [Song] {
            (0..<count).map { n in
                defer { counter += 1 }
                let title = "\(words[counter % words.count]) \(words[(counter * 5 + 3) % words.count])"
                return Song(uri: "spotify:track:demo-\(counter)", title: title,
                            artist: artists[(counter + n) % artists.count], album: album,
                            duration: 160 + Double((counter * 41) % 120))
            }
        }
        func container(_ uri: String, _ title: String, _ subtitle: String, count: Int) -> SpotifyItem {
            let item = SpotifyItem(identifier: uri, uri: uri, title: title, subtitle: subtitle,
                                   imageIdentifier: uri, isContainer: false, isPlayable: true)   // as App Remote reports them
            containers[uri] = (item, songs(count, album: title))
            return item
        }

        let drive = container("spotify:playlist:demo-drive", "Night Drive", "Playlist · Demo", count: 14)
        let commute = container("spotify:playlist:demo-commute", "Morning Commute", "Playlist · Demo", count: 10)
        let roadTrip = container("spotify:playlist:demo-roadtrip", "Road Trip", "Playlist · Demo", count: 22)
        let liked = container("spotify:collection:demo-liked", "Liked Songs", "Playlist · 40 songs", count: 40)
        let album = container("spotify:album:demo-signals", "Signals", "Album · Nova Rae", count: 11)
        let mix = container("spotify:playlist:demo-mix1", "Daily Mix 1", "Made for you", count: 18)
        let discover = container("spotify:playlist:demo-discover", "Discover Weekly", "Made for you", count: 30)
        let chill = container("spotify:playlist:demo-chill", "Chill Drive", "Playlist · Demo", count: 16)

        func section(_ id: String, _ title: String, _ children: [SpotifyItem]) -> (item: SpotifyItem, children: [SpotifyItem]) {
            (SpotifyItem(identifier: id, uri: id, title: title, subtitle: "\(children.count) items",
                         isContainer: true, isPlayable: false), children)
        }
        sections = [
            section("demo-section:recent", "Recently played", [drive, album, liked, commute]),
            section("demo-section:playlists", "Your playlists", [liked, drive, commute, roadTrip, chill]),
            section("demo-section:made", "Made for you", [mix, discover]),
        ]
    }
}
