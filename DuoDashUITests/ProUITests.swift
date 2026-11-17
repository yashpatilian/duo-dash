import XCTest

/// Duo Dash Pro: with `-ProUnlocked` the theme and Home layout change and survive a relaunch;
/// without it, locked controls open the paywall, which closes again. The App Store edition
/// locks the whole dashcam.
final class ProUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String], reset: Bool, canvas: String? = nil) {
        app.launchArguments = ["-UITest", "-AssistantLocal"] + (reset ? ["-ResetState"] : []) + arguments
        if let canvas { app.launchEnvironment["DUODASH_CANVAS"] = canvas }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { break }
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); break
            }
        }
    }

    private func openProSettings() {
        XCTAssertTrue(app.buttons["dock.settings"].waitForExistence(timeout: 10))
        app.tapDock("settings")
        let section = app.buttons["settings.section.pro"]
        XCTAssertTrue(section.waitForExistence(timeout: 5), "Duo Dash Pro missing from Settings")
        section.tap()
    }

    /// Scrolls the Settings page until `element` is on screen.
    private func reveal(_ element: XCUIElement) {
        let window = app.windows.firstMatch
        for _ in 0..<10 where !(element.exists && window.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))) {
            app.swipeUp(velocity: .slow)
        }
    }

    private func cardOrder() -> [String] {
        ["map", "nowPlaying", "nextTurn", "extra"]
            .map { ($0, app.descendants(matching: .any)["pro.homeCard.\($0)"].frame.minY) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    func testProChangesPersistAcrossRelaunch() {
        launch(["-ProUnlocked"], reset: true)
        openProSettings()
        XCTAssertTrue(app.descendants(matching: .any)["pro.status.active"].waitForExistence(timeout: 5))

        // Accent → purple.
        let purple = app.buttons["pro.accent.purple"]
        reveal(purple)
        purple.tap()
        XCTAssertTrue(purple.isSelected)

        // Drag the map card to the bottom of the Home layout list.
        let map = app.descendants(matching: .any)["pro.homeCard.map"]
        reveal(app.descendants(matching: .any)["pro.homeCard.extra"])
        XCTAssertEqual(cardOrder(), ["map", "nowPlaying", "nextTurn", "extra"])
        let grip = app.buttons["pro.homeCard.grip.map"]
        let lastGrip = app.buttons["pro.homeCard.grip.extra"]
        XCTAssertTrue(grip.waitForExistence(timeout: 5), "no reorder grips")
        let start = grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = lastGrip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 10))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: 200, thenHoldForDuration: 0.5)
        let moved = cardOrder()
        XCTAssertNotEqual(moved.first, "map", "map card didn't move: \(moved)")
        XCTAssertTrue(map.exists)

        // Third card → Weather.
        let weather = app.buttons["pro.extra.weather"]
        reveal(weather)
        weather.tap()
        XCTAssertTrue(weather.isSelected)

        // Relaunch: still there.
        app.terminate()
        launch(["-ProUnlocked"], reset: false)
        if !app.buttons["settings.section.pro"].exists { openProSettings() } else { app.buttons["settings.section.pro"].tap() }
        let purpleAgain = app.buttons["pro.accent.purple"]
        reveal(purpleAgain)
        XCTAssertTrue(purpleAgain.isSelected, "accent not saved")
        reveal(app.descendants(matching: .any)["pro.homeCard.extra"])
        XCTAssertEqual(cardOrder(), moved, "card order not saved")
        let weatherAgain = app.buttons["pro.extra.weather"]
        reveal(weatherAgain)
        XCTAssertTrue(weatherAgain.isSelected, "third card not saved")
    }

    func testLockedControlOpensPaywallWhichCloses() {
        launch([], reset: true)
        openProSettings()
        let locked = app.buttons["pro.locked.themes"]
        reveal(locked)
        XCTAssertTrue(locked.waitForExistence(timeout: 5), "themes aren't locked without Pro")
        locked.tap()
        let paywall = app.descendants(matching: .any)["paywall"]
        XCTAssertTrue(paywall.waitForExistence(timeout: 5), "paywall didn't open")
        XCTAssertTrue(app.buttons["paywall.restore"].exists || app.buttons["paywall.restore"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["paywall.close"].exists)
        app.buttons["paywall.close"].tap()
        XCTAssertTrue(paywall.waitForNonExistence(timeout: 5), "paywall didn't close")
    }

    /// CAPTURE=1: the App Store edition's paywall, for the in-app purchase review screenshots.
    func testCapturePaywall() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPTURE"] == "1", "capture run only")
        XCUIDevice.shared.orientation = .portrait
        launch(["-Edition", "commercial"], reset: true)
        openProSettings()
        let unlock = app.buttons["pro.unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        unlock.tap()
        XCTAssertTrue(app.buttons["paywall.option.yearly"].waitForExistence(timeout: 5), "prices missing")
        Thread.sleep(forTimeInterval: 2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "paywall"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPaywallFitsTheCoverScreen() {
        launch([], reset: true, canvas: "466x678")
        openProSettings()
        let unlock = app.buttons["pro.unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        unlock.tap()
        XCTAssertTrue(app.descendants(matching: .any)["paywall"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["paywall.option.yearly"].waitForExistence(timeout: 5), "prices missing")
        // Everything down to the legal links is reachable by scrolling inside the sheet.
        // Prices come first on a narrow sheet: visible without scrolling.
        let paywall = app.descendants(matching: .any)["paywall"]
        XCTAssertLessThan(app.buttons["paywall.option.lifetime"].frame.maxY, paywall.frame.maxY, "prices below the fold")
        let terms = app.buttons["paywall.terms"]
        for _ in 0..<8 where terms.frame.maxY > paywall.frame.maxY - 10 {
            paywall.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: paywall.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        }
        XCTAssertLessThan(terms.frame.maxY, paywall.frame.maxY, "Terms of Use not reachable")
        XCTAssertTrue(app.buttons["paywall.privacy"].exists)
        app.buttons["paywall.close"].tap()
    }

    func testCommercialDashcamNeedsPro() {
        launch(["-Edition", "commercial"], reset: true)
        app.tapDock("dashcam")
        XCTAssertTrue(app.descendants(matching: .any)["dashcam.upsell"].waitForExistence(timeout: 5), "no upsell without Pro")
        XCTAssertFalse(app.descendants(matching: .any)["dashcam"].exists, "camera shown without Pro")
        app.buttons["dashcam.upsell.unlock"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["paywall"].waitForExistence(timeout: 5))
        app.buttons["paywall.close"].tap()

        app.terminate()
        launch(["-Edition", "commercial", "-ProUnlocked"], reset: true)
        app.tapDock("dashcam")
        XCTAssertTrue(app.descendants(matching: .any)["dashcam"].waitForExistence(timeout: 5), "camera missing with Pro")
        XCTAssertFalse(app.descendants(matching: .any)["dashcam.upsell"].exists)
    }
}
