import XCTest
import SwiftUI
import MapKit
@testable import DuoDash

@MainActor
final class LayoutTests: XCTestCase {
    func testInnerLandscapeUsesSidebar() {
        let m = DashMetrics(size: CGSize(width: 870, height: 610))
        XCTAssertTrue(m.usesSidebar)
        XCTAssertFalse(m.isCompact)
    }

    func testInnerPortraitUsesBottomDock() {
        let m = DashMetrics(size: CGSize(width: 610, height: 870))
        XCTAssertFalse(m.usesSidebar)
        XCTAssertFalse(m.isCompact)
    }

    func testHomeSplitsOnlyWithSidebarAndRoom() {
        XCTAssertTrue(DashMetrics(size: CGSize(width: 870, height: 610)).homeIsSplit, "inner landscape")
        XCTAssertTrue(DashMetrics(size: CGSize(width: 678, height: 466)).homeIsSplit, "cover landscape")
        XCTAssertFalse(DashMetrics(size: CGSize(width: 466, height: 678)).homeIsSplit, "cover portrait")
        XCTAssertFalse(DashMetrics(size: CGSize(width: 610, height: 870)).homeIsSplit, "inner portrait")
        XCTAssertFalse(DashMetrics(size: CGSize(width: 420, height: 600)).homeIsSplit, "Split View half")
    }

    func testSidebarGrowsOnlyForACameraInsetOnItsOwnEdge() {
        // The sidebar sits on the right edge (iPhone Duo convention).
        let plain = DashMetrics(size: CGSize(width: 678, height: 466))
        let camera = DashMetrics(size: CGSize(width: 678, height: 466), insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 84))
        XCTAssertEqual(camera.sidebarWidth - plain.sidebarWidth, 74)
        let farSide = DashMetrics(size: CGSize(width: 678, height: 466), insets: EdgeInsets(top: 0, leading: 84, bottom: 21, trailing: 0))
        XCTAssertEqual(farSide.sidebarWidth, plain.sidebarWidth, "camera on the content side must not widen the dock")
    }

    func testDockOrderRestoresDropsUnknownAndAppendsNewApps() {
        XCTAssertEqual(AppModel.resolvedOrder(saved: nil), DockItem.apps)
        let saved = ["messages", "maps", "bogus", "maps", "home"]
        let order = AppModel.resolvedOrder(saved: saved)
        XCTAssertEqual(Array(order.prefix(2)), [.messages, .maps], "saved order kept, duplicates and unknowns dropped")
        XCTAssertEqual(Set(order), Set(DockItem.apps), "every app present exactly once")
        XCTAssertFalse(order.contains(.home), "the dashboard button is pinned, not reorderable")
    }

    @MainActor
    func testDockReorderPersists() {
        let defaults = UserDefaults(suiteName: "dock-order-test")!
        defaults.removePersistentDomain(forName: "dock-order-test")
        let model = AppModel(defaults: defaults)
        model.moveDockItem(.phone, to: .maps)
        XCTAssertEqual(model.dockOrder.first, .phone)
        XCTAssertEqual(AppModel(defaults: defaults).dockOrder.first, .phone, "order survives relaunch")
    }

    func testCoverAndSplitViewAreCompact() {
        for size in [CGSize(width: 450, height: 660), CGSize(width: 660, height: 450), CGSize(width: 430, height: 610)] {
            XCTAssertTrue(DashMetrics(size: size).isCompact, "\(size)")
        }
        XCTAssertTrue(DashMetrics(size: CGSize(width: 660, height: 450)).usesSidebar)
        XCTAssertFalse(DashMetrics(size: CGSize(width: 430, height: 610)).usesSidebar)
    }

    func testHomeSplitWithoutFold() {
        let s = HomeView.splitWidths(width: 800, fold: nil)
        XCTAssertEqual(s.map + s.cards + s.gap, 800, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(s.cards, 250)
    }

    func testHomeSplitAlignsToVerticalFold() {
        let fold = CGRect(x: 395, y: 0, width: 10, height: 600)
        let s = HomeView.splitWidths(width: 800, fold: fold)
        XCTAssertEqual(s.map, 395)
        XCTAssertEqual(s.cards, 395)
        XCTAssertEqual(s.gap, 10)
    }

    func testHomeSplitIgnoresHorizontalFold() {
        let fold = CGRect(x: 0, y: 300, width: 800, height: 10)
        let s = HomeView.splitWidths(width: 800, fold: fold)
        XCTAssertEqual(s.gap, Theme.gap)
    }
}

final class FormattingTests: XCTestCase {
    func testDistanceRounding() {
        XCTAssertEqual(DistanceText.rounded(4), 10)
        XCTAssertEqual(DistanceText.rounded(87), 90)
        XCTAssertEqual(DistanceText.rounded(420), 400)
        XCTAssertEqual(DistanceText.rounded(476), 500)
        XCTAssertEqual(DistanceText.rounded(2345), 2345)
    }

    func testManeuverSymbols() {
        XCTAssertEqual(Maneuver.symbol(for: "Turn left onto Smith St"), "arrow.turn.up.left")
        XCTAssertEqual(Maneuver.symbol(for: "Turn right onto Main Rd"), "arrow.turn.up.right")
        XCTAssertEqual(Maneuver.symbol(for: "Keep left at the fork"), "arrow.up.left")
        XCTAssertEqual(Maneuver.symbol(for: "At the roundabout, take the 2nd exit"), "arrow.clockwise")
        XCTAssertEqual(Maneuver.symbol(for: "Make a U-turn"), "arrow.uturn.left")
        XCTAssertEqual(Maneuver.symbol(for: "Arrive at destination"), "flag.checkered")
        XCTAssertEqual(Maneuver.symbol(for: "Continue on Princes Hwy"), "arrow.up")
    }

    func testTripDuration() {
        XCTAssertEqual(TripSummaryView.duration(59), "1 min")
        XCTAssertEqual(TripSummaryView.duration(3 * 3600 + 5 * 60), "3 h 5 min")
        XCTAssertEqual(TripSummaryView.duration(-20), "0 min")
    }
}

@MainActor
final class PersistenceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testFavouritesRoundTrip() {
        let d = freshDefaults()
        let store = FavouritesStore(defaults: d)
        store.setLocation("work", coordinate: CLLocationCoordinate2D(latitude: -37.9, longitude: 145.1))
        let reloaded = FavouritesStore(defaults: d)
        XCTAssertEqual(reloaded.place(id: "work")?.location?.latitude ?? 0, -37.9, accuracy: 1e-9)
        reloaded.clearLocation("work")
        XCTAssertNil(FavouritesStore(defaults: d).place(id: "work")?.location)
    }

    func testSelectedTabRestores() {
        let d = freshDefaults()
        let app = AppModel(defaults: d)
        XCTAssertEqual(app.selected, .home)
        app.open(.music)
        let restored = AppModel(defaults: d)
        XCTAssertEqual(restored.selected, .music)
        XCTAssertTrue(restored.visited.contains(.music))
    }
}

/// A controllable fake source for arbitration tests.
@MainActor
private final class FakeController: NowPlayingController {
    var toggles = 0
    func togglePlayPause() { toggles += 1 }
    func skipToNext() {}
    func skipToPrevious() {}
}

@MainActor
final class NowPlayingArbitrationTests: XCTestCase {
    func testMostRecentlyStartedSourceWins() {
        let model = NowPlayingModel()
        let music = FakeController(), spotify = FakeController()
        model.register(.appleMusic, controller: music)
        model.register(.spotify, controller: spotify)

        model.update(.appleMusic, track: TrackInfo(title: "A", artist: "x", isPlaying: true))
        XCTAssertEqual(model.source, .appleMusic)

        // Spotify loads something paused: Apple Music stays active.
        model.update(.spotify, track: TrackInfo(title: "S", artist: "y", isPlaying: false))
        XCTAssertEqual(model.source, .appleMusic)

        // Spotify starts playing (Music is paused by iOS): Spotify takes over.
        model.update(.spotify, track: TrackInfo(title: "S", artist: "y", isPlaying: true))
        model.update(.appleMusic, track: TrackInfo(title: "A", artist: "x", isPlaying: false))
        XCTAssertEqual(model.source, .spotify)
        XCTAssertEqual(model.title, "S")

        model.togglePlayPause()
        XCTAssertEqual(spotify.toggles, 1)
        XCTAssertEqual(music.toggles, 0)

        // Spotify unloads: falls back to Apple Music's paused track.
        model.update(.spotify, track: nil)
        XCTAssertEqual(model.source, .appleMusic)
        XCTAssertEqual(model.title, "A")
        XCTAssertFalse(model.isPlaying)
    }
}

@MainActor
final class MusicModelTests: XCTestCase {
    private func makeModel() async -> (AppleMusicModel, NowPlayingModel) {
        let nowPlaying = NowPlayingModel()
        let model = AppleMusicModel(nowPlaying: nowPlaying, backend: DemoMusicBackend())
        await model.prepare()
        return (model, nowPlaying)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func testLibraryLoads() async {
        let (model, _) = await makeModel()
        XCTAssertEqual(model.access, .authorized)
        XCTAssertFalse(model.library.playlists.isEmpty)
        XCTAssertFalse(model.library.albums.isEmpty)
    }

    func testPlayPauseSkip() async {
        let (model, nowPlaying) = await makeModel()
        model.play(model.library.playlists[0])
        await waitUntil { model.track?.isPlaying == true }
        XCTAssertEqual(nowPlaying.source, .appleMusic)
        let first = model.track?.title

        nowPlaying.togglePlayPause()
        XCTAssertEqual(model.track?.isPlaying, false)
        nowPlaying.togglePlayPause()
        XCTAssertEqual(model.track?.isPlaying, true)

        nowPlaying.skipToNext()
        XCTAssertNotEqual(model.track?.title, first)
        nowPlaying.skipToPrevious()
        XCTAssertEqual(model.track?.title, first)
    }

    func testRapidTapsLastOneWins() async {
        let (model, _) = await makeModel()
        let lists = model.library.playlists
        for entry in lists { model.play(entry) }
        await waitUntil { model.pendingEntryID == nil && model.track != nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.track?.isPlaying ?? false)
    }

    func testSearchDebounce() async {
        let (model, _) = await makeModel()
        model.search("Ni")
        model.search("Night")
        await waitUntil { !model.isSearching }
        XCTAssertFalse(model.searchResults.isEmpty)
        XCTAssertTrue(model.searchResults.allSatisfy { $0.title.contains("Night") || $0.subtitle.contains("Night") })
        model.search("")
        XCTAssertTrue(model.searchResults.isEmpty)
    }

    func testRepeatAndShuffleCycle() async {
        let (model, _) = await makeModel()
        model.play(model.library.albums[0])
        await waitUntil { model.track != nil }
        model.cycleRepeat()
        XCTAssertEqual(model.snapshot.repeatSetting, .all)
        model.cycleRepeat()
        XCTAssertEqual(model.snapshot.repeatSetting, .one)
        model.cycleRepeat()
        XCTAssertEqual(model.snapshot.repeatSetting, .off)
        model.toggleShuffle()
        XCTAssertTrue(model.snapshot.shuffle)
    }
}

/// Playlist/album pages and queueing from a song, on the demo backend.
@MainActor
final class MusicCollectionTests: XCTestCase {
    private func makeModel() async -> (AppleMusicModel, DemoMusicBackend) {
        let backend = DemoMusicBackend()
        let model = AppleMusicModel(nowPlaying: NowPlayingModel(), backend: backend)
        await model.prepare()
        return (model, backend)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(30)) }
    }

    private func loaded(_ model: AppleMusicModel, _ entry: MusicEntry) async -> MusicCollection {
        await model.loadCollection(entry)
        guard let collection = model.collections[entry.id] else {
            XCTFail("\(entry.title) did not load: \(model.collectionErrors[entry.id] ?? "")")
            return MusicCollection(entry: entry, title: "", subtitle: "", tracks: [])
        }
        return collection
    }

    func testLongPlaylistLoadsEverySongInOrder() async {
        let (model, _) = await makeModel()
        let favourites = model.library.playlists[0]
        XCTAssertEqual(favourites.title, "Favourite Songs")
        let collection = await loaded(model, favourites)
        XCTAssertEqual(collection.tracks.count, 300)
        XCTAssertEqual(collection.tracks.map(\.position), Array(0..<300))
        XCTAssertTrue(collection.summary.hasPrefix("300 songs, "), collection.summary)
        XCTAssertGreaterThan(collection.totalDuration, 300 * 150)
        XCTAssertEqual(Set(collection.tracks.map(\.artist)).count, 13, "the long playlist should mix every artist")
    }

    func testEveryPlaylistAndAlbumHasSeveralSongs() async {
        let (model, _) = await makeModel()
        for entry in model.library.playlists + model.library.albums {
            let collection = await loaded(model, entry)
            XCTAssertGreaterThanOrEqual(collection.tracks.count, 9, entry.title)
        }
    }

    func testAlbumTracksAreNumberedWithArtistAndYear() async {
        let (model, _) = await makeModel()
        let album = model.library.albums[0]
        let collection = await loaded(model, album)
        XCTAssertEqual(collection.tracks.compactMap(\.trackNumber), Array(1...collection.tracks.count))
        XCTAssertTrue(collection.subtitle.hasPrefix(album.subtitle), collection.subtitle)
        XCTAssertTrue(collection.tracks.allSatisfy { $0.artist == album.subtitle })
    }

    func testTappingASongQueuesTheWholePlaylistFromThere() async {
        let (model, backend) = await makeModel()
        let playlist = model.library.playlists[0]
        let tracks = await loaded(model, playlist).tracks
        let start = tracks[250]

        model.play(start, in: playlist)
        XCTAssertEqual(model.pendingEntryID, AppleMusicModel.pendingID(for: start, in: playlist))
        await waitUntil { model.pendingEntryID == nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.track?.title, start.title)
        XCTAssertEqual(model.track?.isPlaying, true)
        XCTAssertFalse(model.snapshot.shuffle)

        // The whole playlist, in order, positioned at the tapped song.
        XCTAssertEqual(backend.queue, tracks.map(\.persistentID))
        XCTAssertEqual(backend.index, 250)

        model.skipToNext()
        XCTAssertEqual(model.track?.title, tracks[251].title)
        model.skipToPrevious()
        model.skipToPrevious()
        XCTAssertEqual(model.track?.title, tracks[249].title, "earlier songs stay queued before it")
    }

    func testPlayStartsAtTheTop() async {
        let (model, backend) = await makeModel()
        let album = model.library.albums[2]
        let tracks = await loaded(model, album).tracks
        model.playCollection(album)
        await waitUntil { model.pendingEntryID == nil }
        XCTAssertEqual(model.track?.title, tracks[0].title)
        XCTAssertEqual(backend.queue, tracks.map(\.persistentID))
        XCTAssertEqual(backend.index, 0)
    }

    func testShuffleQueuesEverySongOnce() async {
        let (model, backend) = await makeModel()
        let playlist = model.library.playlists[0]
        let tracks = await loaded(model, playlist).tracks
        model.playCollection(playlist, shuffle: true)
        await waitUntil { model.pendingEntryID == nil }
        XCTAssertTrue(model.snapshot.shuffle)
        XCTAssertEqual(backend.queue.count, tracks.count)
        XCTAssertEqual(backend.queue.sorted(), tracks.map(\.persistentID).sorted())
        XCTAssertNotEqual(backend.queue, tracks.map(\.persistentID), "300 songs came out in playlist order")

        // Tapping a song afterwards plays in order again.
        model.play(tracks[10], in: playlist)
        await waitUntil { model.pendingEntryID == nil }
        XCTAssertFalse(model.snapshot.shuffle)
        XCTAssertEqual(backend.queue, tracks.map(\.persistentID))
        XCTAssertEqual(backend.index, 10)
    }

    func testRowShuffleQuickActionStillPlaysTheCollection() async {
        let (model, backend) = await makeModel()
        let album = model.library.albums[1]
        model.play(album, shuffle: true)
        await waitUntil { model.pendingEntryID == nil }
        let tracks = await loaded(model, album).tracks
        XCTAssertTrue(model.snapshot.shuffle)
        XCTAssertEqual(backend.queue.sorted(), tracks.map(\.persistentID).sorted())
    }

    func testSongsInRecentsPlayDirectly() async {
        let (model, backend) = await makeModel()
        guard let song = model.library.recents.first(where: { $0.kind == .song }) else {
            return XCTFail("demo recents should include songs")
        }
        model.play(song)
        await waitUntil { model.pendingEntryID == nil }
        XCTAssertEqual(model.track?.title, song.title)
        XCTAssertEqual(backend.queue, [song.persistentID])
    }

    func testMissingCollectionAndStaleSongReportErrors() async {
        let (model, _) = await makeModel()
        let gone = MusicEntry(kind: .playlist, persistentID: 999_999, title: "Deleted", subtitle: "")
        await model.loadCollection(gone)
        XCTAssertNil(model.collections[gone.id])
        XCTAssertNotNil(model.collectionErrors[gone.id])

        let playlist = model.library.playlists[1]
        let stale = MusicTrack(position: 3, persistentID: 424_242, title: "Removed", artist: "", duration: 100)
        model.play(stale, in: playlist)
        await waitUntil { model.pendingEntryID == nil }
        XCTAssertNotNil(model.errorMessage)
    }

    func testQueueOrder() {
        XCTAssertEqual(MusicQueue.order(count: 5, start: 3, shuffle: false).order, [0, 1, 2, 3, 4])
        XCTAssertEqual(MusicQueue.order(count: 5, start: 3, shuffle: false).index, 3)
        XCTAssertEqual(MusicQueue.order(count: 5, start: nil, shuffle: false).index, 0)
        XCTAssertEqual(MusicQueue.order(count: 3, start: 9, shuffle: false).index, 2, "start is clamped")
        XCTAssertTrue(MusicQueue.order(count: 0, start: 0, shuffle: true).order.isEmpty)

        for _ in 0..<20 {
            let shuffled = MusicQueue.order(count: 50, start: 17, shuffle: true)
            XCTAssertEqual(shuffled.index, 0)
            XCTAssertEqual(shuffled.order.first, 17, "shuffling from a song plays that song first")
            XCTAssertEqual(shuffled.order.sorted(), Array(0..<50))
        }
        let all = MusicQueue.order(count: 50, start: nil, shuffle: true)
        XCTAssertEqual(all.order.sorted(), Array(0..<50))
    }

    func testDurationFormatting() {
        XCTAssertEqual(MusicFormat.duration(187), "3:07")
        XCTAssertEqual(MusicFormat.duration(3723), "1:02:03")
        XCTAssertEqual(MusicFormat.duration(0), "")
        XCTAssertEqual(MusicFormat.totalDuration(42 * 60), "42 min")
        XCTAssertEqual(MusicFormat.totalDuration(65 * 60), "1 hr 5 min")
        XCTAssertEqual(MusicFormat.totalDuration(120 * 60), "2 hr")
    }
}
