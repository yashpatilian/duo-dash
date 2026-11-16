import XCTest
import CoreLocation

/// Screenshots for the README and the demo video. Not part of the normal suite:
/// runs only with `TEST_RUNNER_CAPTURE=1 xcodebuild test -only-testing:DuoDashUITests/MarketingCaptureTests`.
/// Uses sample data only (demo music, sample contacts and places around Apple Park).
final class MarketingCaptureTests: XCTestCase {
    /// The unfolded iPhone Duo's inner screen, in points (landscape).
    private let inner = "960x680"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPTURE"] == "1", "capture run only")
        continueAfterFailure = true
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.3326, longitude: -122.0053))
    }

    private func launch(_ extra: [String] = [], canvas: String?, landscape: Bool = true) {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
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
        let strip = app.scrollViews["dock.scroll"]
        var tries = 0
        while !button.isHittable && tries < 6 && strip.exists {
            let c = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let vertical = strip.frame.height > strip.frame.width
            c.press(forDuration: 0.01, thenDragTo: c.withOffset(vertical ? CGVector(dx: 0, dy: tries < 3 ? -150 : 150)
                                                                         : CGVector(dx: tries < 3 ? -150 : 150, dy: 0)))
            tries += 1
        }
        button.tap()
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
        launch(canvas: inner)
        playFavourites()
        shot("music-player")
        open("home")
        shot("home-unfolded")
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
        launch(["-AssistantTranscript", "I want to go to Stanford University but stop for petrol on the way"], canvas: inner)
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

    func testCaptureSpotify() {
        launch(["-DemoSpotify"], canvas: inner)
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
        launch(canvas: nil, landscape: false)
        playFavourites()
        open("home")
        shot("folded")
        open("music")
        shot("folded-music")
    }
}
