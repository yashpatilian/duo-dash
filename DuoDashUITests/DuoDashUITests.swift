import XCTest
import CoreLocation

/// End-to-end sweep: dock in random orders, background/foreground, kill/relaunch,
/// rotation, every window size the Duo can give us, music, maps and overlays.
final class DuoDashUITests: XCTestCase {
    private var app: XCUIApplication!
    private let screens = ["home", "maps", "music", "spotify", "phone", "messages"]

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.3326, longitude: -122.0053))
        app = XCUIApplication()
        app.launchArguments = ["-UITest", "-ResetState"]
    }

    override func tearDown() {
        if let app, app.state != .notRunning {
            snapshot("teardown-\(name)")
        }
        app = nil
    }

    // MARK: Helpers

    private func launch(arguments: [String]? = nil, canvas: String? = nil) {
        if let arguments { app.launchArguments = arguments }
        if let canvas { app.launchEnvironment["DUODASH_CANVAS"] = canvas }
        app.launch()
        allowSystemAlerts()
        XCTAssertTrue(dock("home").waitForExistence(timeout: 10), "dock did not appear")
    }

    /// Accepts location / media permission prompts if they appear.
    private func allowSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { return }
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK"] {
                let button = alert.buttons[label].firstMatch
                if button.exists { button.tap(); break }
            }
        }
    }

    private func dock(_ id: String) -> XCUIElement { app.buttons["dock.\(id)"] }

    /// The dock keeps full-size icons and scrolls, so an icon may be off-screen.
    private func scrollDockToReveal(_ button: XCUIElement) {
        app.revealInDock(button)
    }

    private func open(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = dock(id)
        // Home is a toggle (Dashboard / app grid): already there means nothing to do.
        if id == "home", button.exists, button.isSelected, app.descendants(matching: .any)["screen.home"].exists { return }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "dock.\(id) missing", file: file, line: line)
        app.tapDockButton(button)
        XCTAssertTrue(app.descendants(matching: .any)["screen.\(id)"].waitForExistence(timeout: 5),
                      "screen.\(id) did not show", file: file, line: line)
        XCTAssertTrue(button.isSelected, "dock.\(id) not selected", file: file, line: line)
    }

    private func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "app is not running (crash?)", file: file, line: line)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Title of what's playing: from the bar, or from the dashboard's media widget on Home.
    /// Title of what's playing: from the mini bar, the dashboard's media widget
    /// on Home, or the full player (which replaces the bar, as in Apple Music).
    private var nowPlayingTitle: String {
        let bar = app.buttons["nowplaying.open"]
        if bar.exists { return bar.label }
        let widget = app.buttons["home.nowplaying"]
        if widget.exists { return widget.label }
        return app.staticTexts["music.np.title"].label
    }

    /// The play/pause control for whatever is on screen: the mini bar, or the
    /// full player when it's open.
    private var playPauseControl: XCUIElement {
        let bar = app.buttons["nowplaying.playpause"]
        return bar.exists ? bar : app.buttons["music.np.playpause"]
    }

    private var musicDetail: XCUIElement { app.descendants(matching: .any)["music.detail"].firstMatch }

    /// Music → Playlists → opens playlist `row` (its page, not playback).
    private func openPlaylist(row: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        open("music", file: file, line: line)
        let tab = app.buttons["music.tab.playlists"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), file: file, line: line)
        tab.tapCentre()
        // A page left open on this tab: go back to the list first.
        let back = app.buttons["music.detail.back"]
        if back.exists { back.tap() }
        let rows = app.buttons.matching(identifier: "music.row.\(row)")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "playlist row \(row) missing", file: file, line: line)
        // Tap the one on screen (the id can appear in more than one section).
        // Kept-alive screens sit far off to the side; pick the copy inside the window.
        let window = app.windows.firstMatch.frame
        let visible = rows.allElementsBoundByIndex.filter { !$0.frame.isEmpty && window.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        let rowButton = visible.first { $0.isHittable } ?? visible.first ?? rows.firstMatch
        rowButton.tapCentre()
        XCTAssertTrue(musicDetail.waitForExistence(timeout: 5), "playlist page did not open", file: file, line: line)
        XCTAssertTrue(app.buttons["music.detail.play"].waitForExistence(timeout: 5), "playlist songs did not load", file: file, line: line)
    }

    /// Opens playlist `row` and taps Play: the player opens with its first song.
    private func startPlaylist(row: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        openPlaylist(row: row, file: file, line: line)
        // Short windows may have the first song below the header.
        let firstSong = app.buttons["music.song.0"].exists ? app.buttons["music.song.0"].label : nil
        let play = app.buttons["music.detail.play"]
        if play.isHittable {
            play.tap()
        } else {
            // The 430x640 test canvas is scaled and clipped on the cover screen, which
            // confuses XCUITest's hit test; touch the drawn button directly.
            play.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let title = app.staticTexts["music.np.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "now playing did not open", file: file, line: line)
        if let firstSong {
            XCTAssertEqual(title.label, firstSong, "Play did not start at the first song", file: file, line: line)
        }
    }

    /// Drags the song list up (no fling, so it can't overshoot) until `element` is hittable.
    private func scrollDetail(to element: XCUIElement, maxDrags: Int = 40) {
        var drags = 0
        while !(element.exists && element.isHittable) && drags < maxDrags {
            let start = musicDetail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let end = musicDetail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
            drags += 1
        }
    }

    // MARK: Tests

    func testDockRandomOrderSweep() {
        launch()
        var rng = SystemRandomNumberGenerator()
        var sequence = screens + screens.reversed()
        for _ in 0..<30 { sequence.append(screens.randomElement(using: &rng)!) }
        for id in sequence {
            open(id)
        }
        // Rapid double taps on the same item and fast hopping.
        for id in ["maps", "maps", "home", "music", "home", "music"] { dock(id).tap() }
        assertRunning()
        snapshot("dock-sweep")
    }

    func testBackgroundForegroundKeepsState() {
        launch()
        startPlaylist()
        let playing = nowPlayingTitle
        for id in ["maps", "music", "spotify", "home"] {
            open(id)
            XCUIDevice.shared.press(.home)
            sleep(2)
            app.activate()
            XCTAssertTrue(dock(id).waitForExistence(timeout: 5))
            XCTAssertTrue(dock(id).isSelected, "tab \(id) not kept after background")
            XCTAssertEqual(nowPlayingTitle, playing, "now playing changed after background")
            assertRunning()
        }
    }

    func testTerminateAndRelaunchRestoresTab() {
        launch()
        open("maps")
        app.terminate()
        launch(arguments: ["-UITest"])
        XCTAssertTrue(dock("maps").isSelected, "selected tab not restored after relaunch")
        open("music")
        app.terminate()
        launch(arguments: ["-UITest"])
        XCTAssertTrue(dock("music").isSelected)
        assertRunning()
    }

    func testRotationThroughAllOrientations() {
        launch()
        let orientations: [(UIDeviceOrientation, String)] = [
            (.landscapeLeft, "landscapeLeft"), (.portrait, "portrait"),
            (.landscapeRight, "landscapeRight"), (.portrait, "portrait2"), (.landscapeLeft, "landscapeLeft2"),
        ]
        for (orientation, name) in orientations {
            XCUIDevice.shared.orientation = orientation
            sleep(1)
            for id in screens { open(id) }
            open("home")
            snapshot("rotation-\(name)-home")
            open("music")
            snapshot("rotation-\(name)-music")
        }
        assertRunning()
    }

    func testMusicPlaybackControls() {
        launch()
        startPlaylist()
        let first = nowPlayingTitle
        XCTAssertNotEqual(first, "Not playing")
        snapshot("music-nowplaying")

        // The full player replaces the mini bar, like Apple Music.
        XCTAssertFalse(app.buttons["nowplaying.open"].exists, "mini bar should hide behind the full player")
        let playPause = app.buttons["music.np.playpause"]
        playPause.tap()
        XCTAssertEqual(playPause.label, "Play", "pause did not take")
        playPause.tap()
        XCTAssertEqual(playPause.label, "Pause", "play did not take")

        app.buttons["music.np.next"].tap()
        XCTAssertNotEqual(nowPlayingTitle, first, "next did not change track")
        app.buttons["music.np.previous"].tap()
        XCTAssertEqual(nowPlayingTitle, first, "previous did not go back")

        app.buttons["music.np.shuffle"].tap()
        app.buttons["music.np.repeat"].tap()
        app.buttons["music.np.repeat"].tap()
        app.buttons["music.np.repeat"].tap()

        // The dashboard's media widget controls the same source (it replaces the bar on Home, like CarPlay).
        open("home")
        XCTAssertFalse(app.buttons["nowplaying.open"].exists, "bar should give way to the Home media widget")
        let homePlay = app.buttons["home.playpause"]
        XCTAssertTrue(homePlay.waitForExistence(timeout: 3))
        XCTAssertEqual(homePlay.label, "Pause")
        homePlay.tap()
        XCTAssertEqual(homePlay.label, "Play", "pause from Home did not take")
        homePlay.tap()
        XCTAssertEqual(homePlay.label, "Pause", "play from Home did not take")
        XCTAssertEqual(nowPlayingTitle, first, "Home widget shows a different track from the bar")
        snapshot("home-playing")

        // Tapping the widget returns to the source.
        app.buttons["home.nowplaying"].tap()
        XCTAssertTrue(dock("music").isSelected)
        XCTAssertTrue(app.buttons["music.np.playpause"].waitForExistence(timeout: 3), "did not return to the player")
        XCTAssertEqual(app.buttons["music.np.playpause"].label, "Pause")
        assertRunning()
    }

    func testRapidPlaybackHammering() {
        launch()
        startPlaylist()
        // Hop between playlists, hammering Play, Shuffle and song rows without waiting.
        for (step, row) in [0, 1, 2, 1, 0, 2].enumerated() {
            app.buttons["music.tab.playlists"].tapCentre()
            let back = app.buttons["music.detail.back"]
            if back.exists && back.isHittable { back.tap() }
            let button = app.buttons["music.row.\(row)"]
            if button.exists && button.isHittable { button.tap() }
            for id in ["music.detail.play", "music.song.\(step)", "music.detail.shuffle"] {
                let control = app.buttons[id]
                if control.exists && control.isHittable { control.tap() }
            }
        }
        let play = playPauseControl
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        for _ in 0..<12 { playPauseControl.tap() }
        for _ in 0..<10 {
            let next = app.buttons["nowplaying.next"]
            (next.exists ? next : app.buttons["music.np.next"]).tap()
        }
        for id in ["home", "music", "maps", "music"] { open(id) }
        assertRunning()
        XCTAssertNotEqual(nowPlayingTitle, "Not playing")
    }

    func testMusicSearchAndAlbums() {
        launch()
        open("music")
        app.buttons["music.tab.albums"].tapCentre()
        XCTAssertTrue(app.buttons["music.row.0"].waitForExistence(timeout: 5))
        app.buttons["music.shuffle.0"].tap()
        XCTAssertTrue(app.staticTexts["music.np.title"].waitForExistence(timeout: 5))

        app.buttons["music.tab.search"].tapCentre()
        let field = app.textFields["music.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Night")
        let firstResult = app.buttons["music.row.0"]
        XCTAssertTrue(firstResult.waitForExistence(timeout: 5), "no search results")
        firstResult.tap()
        // Wait for the full player: the mini bar hides as it opens, which made
        // reading the title straight away racy.
        XCTAssertTrue(app.staticTexts["music.np.title"].waitForExistence(timeout: 5), "search result did not open the player")
        XCTAssertTrue(nowPlayingTitle.contains("Night"), "search result did not play: \(nowPlayingTitle)")
        snapshot("music-search")
        assertRunning()
    }

    /// Open a long playlist, scroll to a late song, play from it with the rest
    /// of the playlist queued, then come back to the list.
    func testPlaylistPageStartsAtSongWithPlaylistQueued() {
        launch()
        openPlaylist(row: 0)
        XCTAssertTrue(app.buttons["music.detail.play"].exists)
        XCTAssertTrue(app.buttons["music.detail.shuffle"].exists)
        let summary = app.staticTexts["music.detail.summary"]
        XCTAssertTrue(summary.exists)
        XCTAssertTrue(summary.label.hasPrefix("300 songs"), "unexpected summary: \(summary.label)")
        snapshot("music-detail-top")

        let target = 60
        let song = app.buttons["music.song.\(target)"]
        let following = app.buttons["music.song.\(target + 1)"]
        scrollDetail(to: following)
        XCTAssertTrue(song.isHittable, "song \(target) not reachable by scrolling")
        XCTAssertTrue(following.isHittable, "song \(target + 1) not reachable by scrolling")
        let songTitle = song.label, nextTitle = following.label
        XCTAssertNotEqual(songTitle, nextTitle)
        snapshot("music-detail-scrolled")

        song.tap()
        let title = app.staticTexts["music.np.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "now playing did not open after tapping a song")
        XCTAssertEqual(title.label, songTitle, "did not start at the tapped song")
        XCTAssertEqual(app.buttons["music.np.playpause"].label, "Pause", "tapped song is not playing")

        // The rest of the playlist is queued after it, in order.
        app.buttons["music.np.next"].tap()
        XCTAssertEqual(nowPlayingTitle, nextTitle, "next did not go to the following song in the playlist")
        app.buttons["music.np.previous"].tap()
        XCTAssertEqual(nowPlayingTitle, songTitle, "previous did not go back to the tapped song")

        // The page is still open on the Playlists tab, where it was left.
        app.buttons["music.tab.playlists"].tapCentre()
        XCTAssertTrue(musicDetail.waitForExistence(timeout: 3), "playlist page was not kept")
        XCTAssertTrue(song.isHittable, "playlist page lost its scroll position")

        // Back returns to the list.
        app.buttons["music.detail.back"].tap()
        XCTAssertTrue(app.buttons["music.row.0"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["music.row.0"].waitForHittable(), "list not shown after back")
        XCTAssertFalse(musicDetail.exists, "playlist page still showing after back")
        XCTAssertTrue(app.buttons["music.shuffle.0"].exists, "row shuffle quick action missing")
        assertRunning()
    }

    /// Albums open the same page; Shuffle plays; the filter finds a song in a long playlist.
    func testAlbumPageShuffleAndFilter() {
        launch(canvas: "340x600")
        open("music")
        app.buttons["music.tab.albums"].tapCentre()
        let album = app.buttons["music.row.0"]
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        XCTAssertTrue(musicDetail.waitForExistence(timeout: 5), "album page did not open")
        XCTAssertTrue(app.buttons["music.song.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["music.detail.play"].isHittable, "Play not hittable in a narrow window")
        XCTAssertTrue(app.buttons["music.detail.shuffle"].isHittable, "Shuffle not hittable in a narrow window")
        snapshot("music-album-narrow")
        app.buttons["music.detail.shuffle"].tap()
        XCTAssertTrue(app.staticTexts["music.np.title"].waitForExistence(timeout: 5), "shuffle did not play")
        XCTAssertEqual(app.buttons["music.np.playpause"].label, "Pause")

        // Re-tapping the tab you're on closes the page.
        app.buttons["music.tab.albums"].tapCentre()
        XCTAssertTrue(musicDetail.waitForExistence(timeout: 3))
        app.buttons["music.tab.albums"].tapCentre()
        XCTAssertTrue(app.buttons["music.row.0"].waitForExistence(timeout: 3))
        XCTAssertFalse(musicDetail.exists)

        // Filter a 300-song playlist down and play the match.
        openPlaylist(row: 0)
        let filter = app.textFields["music.detail.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3), "no filter field on a long playlist")
        XCTAssertTrue(app.buttons["music.detail.filter.dictate"].exists, "filter field has no voice button")
        filter.tap()
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        if XCTWaiter.wait(for: [expectation(for: focused, evaluatedWith: filter)], timeout: 2) != .completed {
            filter.tap()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: focused, evaluatedWith: filter)], timeout: 3), .completed,
                       "filter field did not take focus")
        filter.typeText("Lunar")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'music.song.'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 3), "filter found nothing")
        XCTAssertTrue(hit.label.contains("Lunar"), "filter result doesn't match: \(hit.label)")
        let hitTitle = hit.label
        snapshot("music-filter-narrow")
        hit.tap()
        XCTAssertTrue(app.staticTexts["music.np.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["music.np.title"].label, hitTitle)
        assertRunning()
    }

    func testScreenInfoOverlay() {
        launch()
        let clock = app.descendants(matching: .any)["status.clock"].firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        clock.press(forDuration: 1.2)
        let report = app.staticTexts["screeninfo.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5), "screen info did not open")
        snapshot("screen-info")
        print("SCREEN-INFO-REPORT\n\(report.label)\nEND-SCREEN-INFO-REPORT")
        app.buttons["screeninfo.close"].tap()
        XCTAssertFalse(report.waitForExistence(timeout: 1))
    }

    /// Every window size the Duo can hand us: cover portrait/landscape, Split View
    /// halves, inner portrait/landscape. Each screen must lay out with a usable dock.
    func testAllWindowSizes() {
        let canvases = [
            ("cover-portrait", "430x640"),
            ("cover-landscape", "640x430"),
            ("splitview-half", "420x600"),
            ("splitview-third", "340x600"),
            ("inner-portrait", "600x820"),
            ("inner-landscape", "820x580"),
        ]
        for (name, canvas) in canvases {
            XCUIDevice.shared.orientation = name.contains("portrait") || name.contains("split") ? .portrait : .landscapeLeft
            app = XCUIApplication()
            app.launchArguments = ["-UITest", "-ResetState"]
            launch(canvas: canvas)
            for id in screens { open(id) }
            open("home")
            snapshot("size-\(name)-home")
            open("maps")
            snapshot("size-\(name)-maps")
            startPlaylist()
            snapshot("size-\(name)-music")
            assertRunning()
            app.terminate()
        }
    }

    /// Needs network (MapKit search + directions).
    func testMapsSearchRouteSaveFavouriteAndResume() throws {
        launch()
        open("maps")
        let field = app.textFields["maps.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Stanford University\n")
        let result = app.buttons["maps.result"].firstMatch
        guard result.waitForExistence(timeout: 30) else {
            snapshot("maps-no-results")
            throw XCTSkip("MapKit search returned nothing (no network on this runner?)")
        }
        result.tap()
        let start = app.buttons["nav.start"]
        guard start.waitForExistence(timeout: 30) else {
            snapshot("maps-no-route")
            throw XCTSkip("No route returned (no network on this runner?)")
        }
        snapshot("maps-preview")

        // Save as Work from the star menu.
        app.buttons["nav.save"].tap()
        let saveWork = app.buttons["Save as Work"]
        if saveWork.waitForExistence(timeout: 3) { saveWork.tap() }

        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["nav.banner"].waitForExistence(timeout: 10))
        app.buttons["nav.voice"].tap()
        app.buttons["nav.voice"].tap()
        snapshot("maps-guidance")

        // Home shows the turn card while guiding.
        open("home")
        XCTAssertTrue(app.buttons["home.end"].waitForExistence(timeout: 5))
        snapshot("home-guidance")

        // Killed mid-route: offered a resume on relaunch.
        app.terminate()
        launch(arguments: ["-UITest"])
        open("home")
        XCTAssertTrue(app.buttons["home.resume"].waitForExistence(timeout: 5), "no resume offer after relaunch")
        app.buttons["home.resume.dismiss"].tap()

        // The saved favourite starts guidance in one tap.
        let work = app.buttons["fav.work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()
        XCTAssertTrue(app.buttons["home.end"].waitForExistence(timeout: 30), "favourite did not start guidance")
        app.buttons["home.end"].tap()
        assertRunning()
    }
}
