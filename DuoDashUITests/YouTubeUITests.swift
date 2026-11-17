import XCTest
import CoreLocation

/// The YouTube screen and the "Apps on this iPhone" dock tiles. No network assertions: the
/// web pages may or may not load on the test machine.
final class YouTubeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.3326, longitude: -122.0053))
    }

    private func launch(canvas: String, extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-UITest", "-ResetState", "-AssistantLocal"] + extra
        app.launchEnvironment["DUODASH_CANVAS"] = canvas
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { break }
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); break
            }
        }
        XCTAssertTrue(app.buttons["dock.home"].waitForExistence(timeout: 15))
    }

    /// Keeps a screenshot of the canvas; with SHOT_DIR set (TEST_RUNNER_SHOT_DIR), also as a PNG there.
    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 2)
        let canvas = app.descendants(matching: .any)["canvas"].firstMatch
        let image = canvas.exists ? canvas.screenshot() : XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testYouTubeOpensAtTheInnerScreenSize() {
        launch(canvas: "951x669")
        app.open(URL(string: "duodash://open/youtube")!)
        XCTAssertTrue(app.descendants(matching: .any)["screen.youtube"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.textFields["youtube.search"].waitForExistence(timeout: 5), "search field")
        XCTAssertTrue(app.buttons["youtube.home"].exists)
        XCTAssertTrue(app.buttons["youtube.reload"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["youtube.placeholder"].exists, "wide layout keeps a video half")
        // The passenger notice shows once, and can be dismissed.
        let dismiss = app.buttons["youtube.safety.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3), "passenger notice")
        shot("youtube-951x669")
        dismiss.tap()
        XCTAssertFalse(dismiss.waitForExistence(timeout: 1))
        // Reached from the dock too.
        app.tapDock("home")
        app.tapDock("youtube")
        XCTAssertTrue(app.descendants(matching: .any)["screen.youtube"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["youtube.safety.dismiss"].exists, "once per session")
    }

    func testYouTubeOnTheCoverScreen() {
        launch(canvas: "466x678")
        app.tapDock("youtube")
        XCTAssertTrue(app.descendants(matching: .any)["screen.youtube"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.textFields["youtube.search"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["youtube.placeholder"].exists, "stacked: no empty video half")
        shot("youtube-466x678")
    }

    func testInstalledAppsInDockAndSettings() {
        launch(canvas: "951x669", extra: ["-DemoExternalApps"])
        for id in ["googlemaps", "waze", "whatsapp"] {
            XCTAssertTrue(app.buttons["dock.ext.\(id)"].waitForExistence(timeout: 5), "\(id) tile in the dock")
        }
        app.revealInDock(app.buttons["dock.ext.whatsapp"])
        shot("dock-external-951x669")
        // App grid lists every installed one, in the dock or not.
        app.buttons["dock.home"].tap()
        XCTAssertTrue(app.buttons["grid.ext.audible"].waitForExistence(timeout: 5), "installed apps in the grid")
        shot("grid-external-951x669")
        app.buttons["dock.home"].tap()

        app.tapDock("settings")
        app.buttons["settings.section.dock"].tap()
        let audible = app.switches["settings.dock.ext.audible"]
        XCTAssertTrue(audible.waitForExistence(timeout: 5))
        XCTAssertEqual(audible.value as? String, "0")
        audible.tap()
        XCTAssertTrue(app.buttons["dock.ext.audible"].waitForExistence(timeout: 5), "added to the dock")

        app.buttons["settings.section.navigation"].tap()
        let waze = app.buttons["settings.navApp.waze"]
        XCTAssertTrue(waze.waitForExistence(timeout: 5))
        waze.tap()
        XCTAssertTrue(waze.isSelected)

        // Both choices survive a relaunch.
        app.terminate()
        app.launchArguments = ["-UITest", "-AssistantLocal", "-DemoExternalApps"]
        app.launch()
        XCTAssertTrue(app.buttons["dock.ext.audible"].waitForExistence(timeout: 10))
        app.tapDock("settings")
        app.buttons["settings.section.navigation"].tap()
        XCTAssertTrue(app.buttons["settings.navApp.waze"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.navApp.waze"].isSelected)
    }

    func testDockTilesOnTheCoverScreen() {
        launch(canvas: "466x678", extra: ["-DemoExternalApps"])
        let tile = app.buttons["dock.ext.googlemaps"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        app.revealInDock(tile)
        shot("dock-external-466x678")
    }
}
