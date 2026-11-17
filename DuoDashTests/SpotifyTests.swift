import XCTest
@testable import DuoDash

@MainActor
final class SpotifyModelTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func make(_ backend: DemoSpotifyBackend, token: SpotifyToken? = nil,
                      nowPlaying: NowPlayingModel? = nil) -> (SpotifyModel, MemorySpotifyTokenStore) {
        let nowPlaying = nowPlaying ?? NowPlayingModel()
        let store = MemorySpotifyTokenStore(token: token)
        let model = SpotifyModel(nowPlaying: nowPlaying, backend: backend, tokens: store, observesLifecycle: false)
        return (model, store)
    }

    private func isDisconnected(_ status: SpotifyStatus) -> Bool {
        if case .disconnected = status { return true }
        return false
    }

    /// not installed → install → connect (via Spotify) → connected → Spotify
    /// quits → quiet reconnect fails → Reconnect goes through Spotify again.
    func testConnectionStateMachine() async {
        let backend = DemoSpotifyBackend(installed: false)
        let nowPlaying = NowPlayingModel()
        let (model, store) = make(backend, nowPlaying: nowPlaying)
        XCTAssertEqual(model.status, .notInstalled)
        model.connect()
        XCTAssertEqual(model.status, .notInstalled, "can't connect without the app")

        backend.isInstalled = true
        model.appDidBecomeActive()
        XCTAssertEqual(model.status, .notConnected)

        model.connect()
        XCTAssertEqual(model.status, .connecting)
        // Signs in first (PKCE), then opens Spotify to start it.
        await waitUntil { model.isAwaitingRedirect || model.status == .connected }
        await waitUntil { model.status == .connected }
        XCTAssertEqual(model.status, .connected)
        XCTAssertEqual(backend.authorizeCount, 1)
        XCTAssertEqual(store.token?.accessToken, "demo-token")
        XCTAssertTrue(store.token?.isValid() ?? false)
        await waitUntil { model.track != nil }
        XCTAssertEqual(nowPlaying.source, .spotify)
        XCTAssertEqual(model.track?.isPlaying, true)

        backend.simulateSpotifyQuit()
        await waitUntil { self.isDisconnected(model.status) }
        XCTAssertTrue(isDisconnected(model.status), "a drop must show Reconnect")
        XCTAssertNil(model.track)
        XCTAssertEqual(nowPlaying.source, .none)

        // Coming back to the app tries quietly with the saved token; Spotify
        // isn't running, so it stays on Reconnect without opening Spotify.
        model.appDidBecomeActive()
        XCTAssertEqual(model.status, .connecting)
        await waitUntil { model.status != .connecting }
        XCTAssertTrue(isDisconnected(model.status))
        XCTAssertEqual(backend.authorizeCount, 1)

        // Reconnect: the token alone fails, so it goes through Spotify.
        model.connect()
        await waitUntil { model.status == .connected }
        XCTAssertEqual(model.status, .connected)
        XCTAssertEqual(backend.authorizeCount, 2)
        XCTAssertEqual(backend.connectCount, 4)
    }

    func testValidSavedTokenReconnectsWithoutOpeningSpotify() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        let token = SpotifyToken(accessToken: "saved", expiresAt: .now.addingTimeInterval(1800))
        let (model, _) = make(backend, token: token)
        XCTAssertEqual(model.status, .connecting, "connects on launch with a saved token")
        await waitUntil { model.status == .connected }
        XCTAssertEqual(model.status, .connected)
        XCTAssertEqual(backend.authorizeCount, 0)
    }

    func testExpiredTokenNeedsSpotify() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        let token = SpotifyToken(accessToken: "old", expiresAt: .now.addingTimeInterval(30))
        let (model, store) = make(backend, token: token)
        XCTAssertEqual(model.status, .notConnected, "a token about to expire isn't used")
        XCTAssertEqual(backend.connectCount, 0)
        model.connect()
        await waitUntil { model.status == .connected }
        XCTAssertEqual(backend.authorizeCount, 1)
        XCTAssertEqual(store.token?.accessToken, "demo-token")
    }

    func testDeniedAuthorizationShowsReason() async {
        let backend = DemoSpotifyBackend()
        backend.authorizationDenied = true
        let (model, store) = make(backend)
        model.connect()
        await waitUntil { model.status != .connecting }
        XCTAssertEqual(model.status, .disconnected("Spotify access wasn't allowed."))
        XCTAssertNil(store.token)
    }

    func testAbandonedAuthorizationTimesOut() async {
        let backend = DemoSpotifyBackend()
        backend.authorizationAbandoned = true
        let (model, _) = make(backend)
        model.redirectTimeout = .milliseconds(100)
        model.connect()
        XCTAssertEqual(model.status, .connecting)
        await waitUntil { model.isAwaitingRedirect } // signed in, Spotify opened
        XCTAssertTrue(model.isAwaitingRedirect)
        model.appDidBecomeActive() // back from Spotify with no redirect
        await waitUntil { model.status != .connecting }
        XCTAssertTrue(isDisconnected(model.status))
        XCTAssertFalse(model.isAwaitingRedirect)
    }

    func testIgnoresOtherURLs() {
        let (model, _) = make(DemoSpotifyBackend())
        XCTAssertFalse(model.handleOpenURL(URL(string: "duodash://something-else")!))
        XCTAssertFalse(model.handleOpenURL(URL(string: "https://example.com")!))
        XCTAssertEqual(model.status, .notConnected)
    }

    func testLibraryBrowseAndPlay() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        let token = SpotifyToken(accessToken: "saved", expiresAt: .now.addingTimeInterval(1800))
        let (model, _) = make(backend, token: token)
        await waitUntil { model.hasLoadedLibrary }
        XCTAssertFalse(model.recents.isEmpty)
        XCTAssertEqual(model.shelves.map(\.section.title), ["Your playlists", "Made for you"])

        let playlist = model.shelves[0].items[1]
        await model.loadChildren(of: playlist)
        let songs = model.children[playlist.id] ?? []
        XCTAssertFalse(songs.isEmpty)
        model.play(songs[2])
        await waitUntil { model.pendingItemID == nil && model.track?.title == songs[2].title }
        XCTAssertEqual(model.track?.title, songs[2].title)
        XCTAssertEqual(model.track?.isPlaying, true)

        model.toggleShuffle()
        await waitUntil { model.snapshot.shuffle }
        XCTAssertTrue(model.snapshot.shuffle)
        model.cycleRepeat()
        await waitUntil { model.snapshot.repeatSetting == .all }
        XCTAssertEqual(model.snapshot.repeatSetting, .all)
    }

    func testKeychainTokenRoundTrip() {
        let store = KeychainSpotifyTokenStore(service: "duodash.spotify.tests", account: "token-\(UUID().uuidString)")
        XCTAssertNil(store.load())
        let token = SpotifyToken(accessToken: "abc", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        store.save(token)
        XCTAssertEqual(store.load(), token)
        let renewed = SpotifyToken(accessToken: "def", expiresAt: Date(timeIntervalSince1970: 2_000_003_600))
        store.save(renewed)
        XCTAssertEqual(store.load(), renewed, "saving again replaces the token")
        store.clear()
        XCTAssertNil(store.load())
    }

    func testTokenValidity() {
        let now = Date()
        XCTAssertTrue(SpotifyToken(accessToken: "a", expiresAt: now.addingTimeInterval(3600)).isValid(at: now))
        XCTAssertFalse(SpotifyToken(accessToken: "a", expiresAt: now.addingTimeInterval(30)).isValid(at: now))
        XCTAssertFalse(SpotifyToken(accessToken: "a", expiresAt: now.addingTimeInterval(-10)).isValid(at: now))
    }

    /// Apple Music and Spotify share the bar: whichever started last is in charge.
    func testArbitrationWithAppleMusic() async {
        let nowPlaying = NowPlayingModel()
        let music = AppleMusicModel(nowPlaying: nowPlaying, backend: DemoMusicBackend())
        await music.prepare()
        music.play(music.library.playlists[0])
        await waitUntil { music.track?.isPlaying == true }
        XCTAssertEqual(nowPlaying.source, .appleMusic)

        // Spotify starts playing; iOS pauses the Music app.
        music.togglePlayPause()
        let backend = DemoSpotifyBackend()
        let (spotify, _) = make(backend, nowPlaying: nowPlaying)
        spotify.connect()
        await waitUntil { spotify.track?.isPlaying == true }
        XCTAssertEqual(nowPlaying.source, .spotify)
        XCTAssertEqual(nowPlaying.title, spotify.track?.title)

        // The shared controls drive Spotify, not the Music app.
        let first = spotify.track?.title
        nowPlaying.skipToNext()
        await waitUntil { spotify.track?.title != first }
        XCTAssertNotEqual(spotify.track?.title, first)
        XCTAssertEqual(nowPlaying.title, spotify.track?.title)
        nowPlaying.togglePlayPause()
        await waitUntil { spotify.track?.isPlaying == false }
        XCTAssertEqual(spotify.track?.isPlaying, false)
        XCTAssertEqual(nowPlaying.source, .spotify, "a paused source stays in charge")
        XCTAssertEqual(music.track?.isPlaying, false)

        // Apple Music starts again: it takes over.
        music.togglePlayPause()
        XCTAssertEqual(nowPlaying.source, .appleMusic)

        // Spotify dropping doesn't disturb Apple Music.
        backend.simulateSpotifyQuit()
        await waitUntil { spotify.status != .connected }
        XCTAssertEqual(nowPlaying.source, .appleMusic)
    }

    /// App Remote doesn't flag playlists or albums as containers; tapping them must still
    /// open their page (the bug: Recents and playlists played instead of opening).
    func testPlaylistsAndAlbumsOpenTracksPlay() {
        func item(_ uri: String, container: Bool = false) -> SpotifyItem {
            SpotifyItem(identifier: uri, uri: uri, title: "x", isContainer: container)
        }
        XCTAssertTrue(item("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M").opensAsPage)
        XCTAssertTrue(item("spotify:user:someone:playlist:abc").opensAsPage)
        XCTAssertTrue(item("spotify:album:4aawyAB9vmqN3uQ7FjRGTy").opensAsPage)
        XCTAssertTrue(item("spotify:artist:0OdUWJ0sBjDrqHygGUXeCF").opensAsPage)
        XCTAssertTrue(item("spotify:user:someone:collection").opensAsPage)
        XCTAssertTrue(item("spotify:show:abc").opensAsPage)
        XCTAssertFalse(item("spotify:track:11dFghVXANMlKmJXsNCbNl").opensAsPage)
        XCTAssertFalse(item("spotify:episode:abc").opensAsPage)
        XCTAssertTrue(item("section:recent", container: true).opensAsPage)
    }
}
