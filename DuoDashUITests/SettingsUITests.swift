import XCTest

/// Settings: reachable from the (scrolling) dock, and every change survives a relaunch.
final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    private func launch(reset: Bool) {
        app.launchArguments = reset ? ["-UITest", "-ResetState", "-AssistantLocal"] : ["-UITest", "-AssistantLocal"]
        app.launchEnvironment["DUODASH_CANVAS"] = "820x580"   // wide layout: section list + detail
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

    /// The dock scrolls when it's full, so bring the Settings icon into view first.
    private func openSettings() {
        let button = app.buttons["dock.settings"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Settings missing from the dock")
        app.tapDockButton(button)
        XCTAssertTrue(app.descendants(matching: .any)["settings"].waitForExistence(timeout: 5))
    }

    func testSettingsChangesPersistAcrossRelaunch() {
        launch(reset: true)
        openSettings()

        // Assistant provider → Claude.
        app.buttons["settings.provider.claude"].tap()
        XCTAssertTrue(app.buttons["settings.provider.claude"].isSelected)

        // Navigation: voice guidance on (off by default), map north up.
        app.buttons["settings.section.navigation"].tap()
        let voice = app.switches["settings.voiceGuidance"]
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertEqual(voice.value as? String, "0", "voice guidance should be off by default")
        voice.tap()
        XCTAssertEqual(voice.value as? String, "1")
        app.buttons["settings.mapOrientation.northUp"].tap()

        // Relaunch without resetting: everything is still set.
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(app.descendants(matching: .any)["settings"].waitForExistence(timeout: 10), "Settings tab not restored")
        XCTAssertTrue(app.buttons["settings.provider.claude"].isSelected, "provider not saved")
        app.buttons["settings.section.navigation"].tap()
        XCTAssertEqual(app.switches["settings.voiceGuidance"].value as? String, "1", "voice guidance not saved")
        XCTAssertTrue(app.buttons["settings.mapOrientation.northUp"].isSelected, "map orientation not saved")
    }

    func testPlacesEditorOpensFromSettings() {
        launch(reset: true)
        openSettings()
        app.buttons["settings.section.places"].tap()
        let edit = app.buttons["settings.places.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.staticTexts["Home 2"].waitForExistence(timeout: 5), "places editor didn't open with Home 2")
    }
}
