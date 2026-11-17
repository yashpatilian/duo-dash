import XCTest
import CoreLocation

/// The Spotify screen against the demo Spotify backend (the Simulator has no
/// Spotify app): connect states, browsing, playing, and the shared mini bar.
final class SpotifyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.3326, longitude: -122.0053))
        app = XCUIApplication()
        app.launchArguments = ["-UITest", "-ResetState", "-DemoSpotify"]
    }

    override func tearDown() {
        if let app, app.state != .notRunning {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "teardown-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app = nil
    }

    private func launch(extra: [String] = [], canvas: String? = nil) {
        app.launchArguments += extra
        if let canvas { app.launchEnvironment["DUODASH_CANVAS"] = canvas }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { break }
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                break
            }
        }
        XCTAssertTrue(app.buttons["dock.home"].waitForExistence(timeout: 10), "dock did not appear")
    }

    private func openSpotify() {
        let button = app.buttons["dock.spotify"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        app.tapDockButton(button)
        XCTAssertTrue(app.descendants(matching: .any)["screen.spotify"].waitForExistence(timeout: 5))
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForLabel(_ element: XCUIElement, toBe label: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, toChangeFrom label: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label != %@", label)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    // MARK: Tests

    func testNotInstalledOffersAppStore() {
        launch(extra: ["-DemoSpotifyNotInstalled"])
        openSpotify()
        XCTAssertTrue(app.staticTexts["spotify.notinstalled.title"].waitForExistence(timeout: 5))
        let get = app.buttons["spotify.appstore"]
        XCTAssertTrue(get.waitForHittable())
        XCTAssertGreaterThanOrEqual(get.frame.height, 60)
        screenshot("spotify-not-installed")
    }

    func testConnectBrowsePlayAndMiniBar() {
        launch()
        openSpotify()
        let connect = app.buttons["spotify.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "connect state missing")
        // Rounded: a button at a fractional y can measure 59.99999999999997.
        XCTAssertGreaterThanOrEqual(connect.frame.height.rounded(), 60)
        screenshot("spotify-connect")
        connect.tap()

        // Connected: tabs appear; Spotify resumed its last session on authorising.
        let playlists = app.buttons["spotify.tab.playlists"]
        XCTAssertTrue(playlists.waitForExistence(timeout: 5), "did not connect")
        XCTAssertTrue(app.buttons["spotify.row.0"].waitForExistence(timeout: 5), "recents did not load")
        screenshot("spotify-recents")

        // A recent playlist opens its page (it used to start playing instead).
        app.buttons["spotify.row.0"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["spotify.page.title"], toBe: "Night Drive"), "recent playlist did not open")
        XCTAssertTrue(app.buttons["spotify.song.0"].waitForExistence(timeout: 5), "recent playlist has no songs")
        app.buttons["spotify.back"].tap()
        XCTAssertTrue(app.buttons["spotify.row.0"].waitForExistence(timeout: 5), "back did not return to Recents")

        playlists.tap()
        let nightDrive = app.buttons["spotify.shelf0.row.1"]
        XCTAssertTrue(nightDrive.waitForExistence(timeout: 5))
        nightDrive.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["spotify.page.title"], toBe: "Night Drive"))
        let song = app.buttons["spotify.song.2"]
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        screenshot("spotify-playlist")
        let songTitle = song.label.components(separatedBy: ", ").first ?? ""
        song.tap()

        // Playing jumps to Now Playing, and the mini bar shows the same track.
        let title = app.staticTexts["spotify.np.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "player did not open")
        XCTAssertTrue(waitForLabel(title, toBe: songTitle))
        let bar = app.buttons["nowplaying.open"]
        XCTAssertTrue(bar.waitForExistence(timeout: 3))
        XCTAssertEqual(bar.label, songTitle)
        screenshot("spotify-nowplaying")

        let barPlayPause = app.buttons["nowplaying.playpause"]
        XCTAssertEqual(barPlayPause.label, "Pause")
        barPlayPause.tap()
        XCTAssertTrue(waitForLabel(barPlayPause, toBe: "Play"), "pause did not reach Spotify")
        XCTAssertTrue(waitForLabel(app.buttons["spotify.np.playpause"], toBe: "Play"))

        app.buttons["nowplaying.next"].tap()
        XCTAssertTrue(waitForLabel(bar, toChangeFrom: songTitle), "next did not change the track")
        XCTAssertEqual(title.label, bar.label)

        // The player's own controls drive Spotify too.
        app.buttons["spotify.np.playpause"].tap()
        XCTAssertTrue(waitForLabel(barPlayPause, toBe: "Pause"))
        app.buttons["spotify.np.shuffle"].tap()
        XCTAssertTrue(app.buttons["spotify.np.shuffle"].waitForExistence(timeout: 2))
    }

    /// Split View-sized window: every control stays on screen and tappable.
    func testNarrowWindow() {
        launch(canvas: "340x678")
        openSpotify()
        let connect = app.buttons["spotify.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertTrue(connect.isHittable)
        connect.tap()
        let playlists = app.buttons["spotify.tab.playlists"]
        XCTAssertTrue(playlists.waitForExistence(timeout: 5))
        for tab in ["nowPlaying", "recents", "playlists"] {
            XCTAssertTrue(app.buttons["spotify.tab.\(tab)"].isHittable, "\(tab) tab not reachable")
        }
        app.buttons["spotify.tab.recents"].tap()
        let row = app.buttons["spotify.row.0.play"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        screenshot("spotify-narrow-recents")
        // On a scaled test canvas isHittable misreports; check it's fully on screen instead.
        XCTAssertTrue(app.windows.firstMatch.frame.contains(row.frame), "row play button off screen: \(row.frame)")
        row.tap()
        XCTAssertTrue(app.staticTexts["spotify.np.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["spotify.np.playpause"].isHittable)
        screenshot("spotify-narrow")
    }
}
