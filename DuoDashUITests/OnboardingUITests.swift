import XCTest

/// The first-launch welcome tour: both main paths, the Duo Dock sheet, and replaying it from
/// Settings. Other UI suites pass -UITest, which hides the tour unless -Onboarding is given.
final class OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String], canvas: String = "960x680") {
        app.launchArguments = arguments
        app.launchEnvironment["DUODASH_CANVAS"] = canvas
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func expectPage(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element("onboarding.page.\(id)").waitForExistence(timeout: 8), "page \(id) not shown", file: file, line: line)
    }

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 8), "\(id) missing", file: file, line: line)
        button.tap()
    }

    /// Tap any system permission alert (Allow), in case the Simulator asks.
    private func dismissAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 1.5) else { break }
            for label in ["Allow", "Allow Full Access", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); break
            }
        }
    }

    /// Permissions page (only when something is still undecided), then the Duo Dock sheet.
    private func passPermissionsToPromo() {
        let permissions = element("onboarding.page.permissions")
        let promo = element("dock.promo.headline")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && !permissions.exists && !promo.exists { usleep(200_000) }
        if permissions.exists { tap("onboarding.next") }
        XCTAssertTrue(promo.waitForExistence(timeout: 8), "Duo Dock sheet not shown")
    }

    func testUsedCarPlayWithAppleMusic() {
        launch(["-UITest", "-ResetState", "-Onboarding"])
        expectPage("welcome")
        XCTAssertFalse(app.buttons["onboarding.back"].exists, "no Back on the first page")
        tap("onboarding.carplay.yes")
        expectPage("music")
        tap("onboarding.music.appleMusic")
        dismissAlerts()
        expectPage("whatsNew")
        tap("onboarding.next")
        passPermissionsToPromo()
        tap("dock.promo.notNow")
        XCTAssertTrue(element("dock.promo.headline").waitForNonExistence(timeout: 5), "tour didn't close")
        XCTAssertTrue(app.buttons["dock.maps"].waitForExistence(timeout: 5), "dashboard not shown after the tour")
    }

    func testNewToCarPlayWithSpotifyLater() {
        launch(["-UITest", "-ResetState", "-Onboarding"], canvas: "466x678")
        expectPage("welcome")
        tap("onboarding.carplay.no")
        expectPage("music")
        tap("onboarding.music.spotify")
        expectPage("spotifyIntro")
        // Back returns to the question, keeping the flow.
        tap("onboarding.back")
        expectPage("music")
        tap("onboarding.music.spotify")
        expectPage("spotifyIntro")
        tap("onboarding.spotify.later")
        for page in ["tour.dock", "tour.maps", "tour.phone", "tour.settings"] {
            expectPage(page)
            tap("onboarding.next")
        }
        passPermissionsToPromo()
        let get = app.buttons["dock.promo.get"]
        XCTAssertTrue(get.exists && get.isHittable, "Get Duo Dock missing")
        XCTAssertTrue(app.buttons["dock.promo.notNow"].isHittable)
        XCTAssertTrue(element("dock.promo.headline").exists)
    }

    func testSpotifySetupNowWalkthrough() {
        launch(["-UITest", "-ResetState", "-Onboarding"])
        tap("onboarding.carplay.yes")
        tap("onboarding.music.both")
        dismissAlerts()
        tap("onboarding.spotify.now")
        for step in 1...7 {
            expectPage("spotify.\(step)")
            tap("onboarding.next")
        }
        expectPage("spotifyFinish")
        XCTAssertTrue(element("onboarding.spotify.qr").exists, "QR code missing")
        XCTAssertTrue(element("onboarding.spotify.video").exists, "video slot missing")
        tap("onboarding.next")
        expectPage("whatsNew")
    }

    func testTourHiddenUnderUITestAndReplayableFromSettings() {
        launch(["-UITest", "-ResetState"], canvas: "820x580")
        XCTAssertTrue(app.buttons["dock.maps"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("onboarding.page.welcome").exists, "tour must not appear under -UITest")

        // Settings → About → Show the welcome tour.
        let settings = app.buttons["dock.settings"]
        let strip = app.scrollViews["dock.scroll"]
        var tries = 0
        while !settings.isHittable && tries < 6 && strip.exists {
            let start = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -150)))
            tries += 1
        }
        settings.tap()
        tap("settings.section.duoDock")
        XCTAssertTrue(app.buttons["settings.dock.visit"].waitForExistence(timeout: 5), "Duo Dock website button missing")
        tap("settings.section.about")
        tap("onboarding.showAgain")
        expectPage("welcome")
    }
}
