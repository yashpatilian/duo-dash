import XCTest
import CoreLocation

/// Screenshots for the README and the demo video. Not part of the normal suite:
/// runs only with `TEST_RUNNER_CAPTURE=1 xcodebuild test -only-testing:DuoDashUITests/MarketingCaptureTests`.
/// Uses sample data only (demo music, sample contacts and places around Apple Park).
final class MarketingCaptureTests: XCTestCase {
    /// The unfolded iPhone Duo's inner screen, in points (landscape).
    private let inner = "951x669"   // the Duo's inner screen in points (2853×2007 px @3x)
    /// NATIVE=1: the simulator is unfolded, so capture the real inner screen at full resolution.
    private var innerCanvas: String? { ProcessInfo.processInfo.environment["NATIVE"] == "1" ? nil : inner }
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPTURE"] == "1", "capture run only")
        continueAfterFailure = true
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.3326, longitude: -122.0053))
    }

    private func launch(_ extra: [String] = [], canvas: String?, landscape: Bool = true) {
        // Only rotate a real (unfolded) Duo; on other simulators the canvas already has the Duo's
        // size and an upright device keeps element screenshots upright.
        let native = ProcessInfo.processInfo.environment["NATIVE"] == "1"
        XCUIDevice.shared.orientation = landscape && native ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["-UITest", "-ResetState", "-SeedContacts", "-SeedPlaces", "-Capture", "-AssistantLocal"] + extra
        if let canvas { app.launchEnvironment["DUODASH_CANVAS"] = canvas }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<4 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { break }
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); break
            }
        }
        XCTAssertTrue(app.buttons["dock.home"].waitForExistence(timeout: 10))
    }

    private func open(_ id: String) {
        let button = app.buttons["dock.\(id)"]
        // Home is a toggle (Dashboard / app grid): already there means nothing to do.
        if id == "home", button.exists, button.isSelected, app.descendants(matching: .any)["screen.home"].exists { return }
        app.tapDockButton(button)
        _ = app.descendants(matching: .any)["screen.\(id)"].waitForExistence(timeout: 5)
    }

    /// Saves the app window (the canvas when one is set) as a named attachment.
    private func shot(_ name: String, settle: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: settle)
        let canvas = app.descendants(matching: .any)["canvas"].firstMatch
        let image = canvas.exists ? canvas.screenshot() : XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "capture-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func playFavourites() {
        open("music")
        app.buttons["music.tab.playlists"].tap()
        let row = app.buttons["music.row.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let play = app.buttons["music.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        _ = app.staticTexts["music.np.title"].waitForExistence(timeout: 5)
    }

    func testCaptureUnfolded() {
        launch(canvas: innerCanvas)
        playFavourites()
        shot("music-player")
        open("home")
        shot("home-unfolded")
        // CarPlay's Home screen: the dock's bottom button switches to the app grid and back.
        app.buttons["dock.home"].tap()
        if app.descendants(matching: .any)["home.grid"].waitForExistence(timeout: 3) { shot("home-grid") }
        app.buttons["dock.home"].tap()
        open("phone")
        shot("phone")
        open("messages")
        let fav = app.buttons["messages.fav.0"]
        if fav.waitForExistence(timeout: 5) {
            fav.tap()
            let quick = app.buttons["messages.quick.0"]
            if quick.waitForExistence(timeout: 5) { quick.tap() }
        }
        shot("messages")
        open("settings")
        shot("settings")
        open("maps")
        shot("maps-search")
    }

    func testCaptureAssistantAndRoute() {
        launch(["-AssistantTranscript", "I want to go to Stanford University but stop for petrol on the way"], canvas: innerCanvas)
        playFavourites()
        open("maps")
        app.buttons["assistant.open"].firstMatch.tap()
        let plan = app.descendants(matching: .any)["assistant.plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 45), "no planned route (network?)")
        shot("assistant", settle: 3)
        let start = app.buttons["assistant.plan.start"]
        if start.exists { start.tap() }
        _ = app.descendants(matching: .any)["nav.banner"].waitForExistence(timeout: 15)
        _ = app.buttons["assistant.open"].waitForExistence(timeout: 8)   // the panel steps aside
        shot("maps-route", settle: 3)
        open("home")
        shot("home-guiding", settle: 2)
    }

    /// The newer apps: Weather (sunny demo sky), Car (demo OBD data), Dashcam, Calendar, Home.
    func testCaptureNewApps() {
        launch(["-DemoWeatherSky", "clear", "-DemoCar"], canvas: innerCanvas)
        playFavourites()
        for (id, name) in [("weather", "weather"), ("car", "car"), ("dashcam", "dashcam"),
                           ("calendar", "calendar"), ("homekit", "home-control")] {
            open(id)
            // Show the dashcam recording (the demo recorder in the Simulator).
            if id == "dashcam", app.buttons["dashcam.startHint"].waitForExistence(timeout: 3) {
                app.buttons["dashcam.startHint"].tap()
            }
            shot(name, settle: 3)
        }
    }

    /// Guidance while folded: the cover screen in portrait and in landscape.
    func testCaptureFoldedGuidance() {
        for canvas in ["466x678", "678x466"] {
            launch(["-AssistantTranscript", "take me to Stanford University"], canvas: canvas)
            playFavourites()
            open("maps")
            // Screens stay alive while hidden, so pick the Assistant button that's on screen.
            app.buttons.matching(identifier: "assistant.open").allElementsBoundByIndex.first { $0.isHittable }?.tap()
            let start = app.buttons["assistant.plan.start"]
            if start.waitForExistence(timeout: 45) { start.tap() }
            XCTAssertTrue(app.descendants(matching: .any)["nav.banner"].waitForExistence(timeout: 20), "no guidance (network?)")
            _ = app.buttons["assistant.open"].waitForExistence(timeout: 8)
            shot("guide-\(canvas)", settle: 3)
            open("home")
            shot("guide-home-\(canvas)", settle: 2)
            app.terminate()
        }
    }

    func testCaptureSpotify() {
        launch(["-DemoSpotify"], canvas: innerCanvas)
        open("spotify")
        let connect = app.buttons["spotify.connect"]
        if connect.waitForExistence(timeout: 5) { connect.tap() }
        let playlists = app.buttons["spotify.tab.playlists"]
        XCTAssertTrue(playlists.waitForExistence(timeout: 5))
        playlists.tap()
        let playlist = app.buttons["spotify.shelf0.row.1"]
        if playlist.waitForExistence(timeout: 5) { playlist.tap() }
        shot("spotify-playlist", settle: 1.5)
        let song = app.buttons["spotify.song.2"]
        if song.waitForExistence(timeout: 5) { song.tap() }
        _ = app.staticTexts["spotify.np.title"].waitForExistence(timeout: 5)
        shot("spotify", settle: 2.5)
    }

    func testCaptureFolded() {
        // On an unfolded Duo simulator use the real cover screen; elsewhere the cover's size in points.
        launch(canvas: ProcessInfo.processInfo.environment["NATIVE"] == "1" ? nil : "466x678", landscape: false)
        playFavourites()
        open("home")
        shot("folded")
        open("music")
        shot("folded-music")
    }
}
