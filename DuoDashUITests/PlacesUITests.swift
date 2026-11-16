import XCTest
import CoreLocation

/// Saved places editor and the map orientation switch.
final class PlacesUITests: XCTestCase {
    private var app: XCUIApplication!

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

    private func launch() {
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

    private func open(_ id: String) {
        app.buttons["dock.\(id)"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.\(id)"].waitForExistence(timeout: 5))
    }

    /// The orientation switch on the given screen (screens stay alive, so both maps have one).
    private func orientationButton(on screen: String) -> XCUIElement {
        app.descendants(matching: .any)["screen.\(screen)"].buttons["map.orientation"]
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEditPlacesFromHome() {
        launch()
        open("home")
        XCTAssertTrue(app.buttons["fav.home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fav.home-2"].exists, "migration adds Home 2")
        XCTAssertTrue(app.buttons["fav.work"].exists)
        snapshot("places-home-tiles")

        // Edit → list → Home 2.
        app.buttons["home.fav.edit"].tap()
        let row = app.buttons["places.row.home-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        snapshot("places-editor-list")
        row.tap()

        let name = app.textFields["place.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["place.name.dictate"].exists, "name field has a voice button")
        XCTAssertTrue(app.buttons["place.search.dictate"].exists, "search field has a voice button")
        XCTAssertTrue(app.buttons["place.emoji.dictate"].exists, "emoji field has a voice button")

        // Rename to "Mum's".
        name.tap()
        name.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText(XCUIKeyboardKey.delete.rawValue)
        name.typeText("Mums\n")

        // Pick the coffee emoji.
        let coffee = app.buttons["place.icon.coffee"]
        XCTAssertTrue(coffee.waitForExistence(timeout: 3))
        coffee.tap()
        XCTAssertTrue(coffee.isSelected)
        snapshot("places-editor-detail")

        // Set it to where we are.
        let useHere = app.buttons["place.useCurrent"]
        for _ in 0..<3 where !useHere.isHittable { app.swipeUp() }
        useHere.tap()
        XCTAssertTrue(app.buttons["place.location.clear"].waitForExistence(timeout: 15), "current location not saved")
        snapshot("places-editor-location")

        app.buttons["places.done"].tap()
        let mums = app.buttons["fav.mums"]
        XCTAssertTrue(mums.waitForExistence(timeout: 5), "renamed tile shows on Home")
        XCTAssertFalse(app.buttons["fav.home-2"].exists)
        snapshot("places-home-emoji")

        // Long-pressing a set tile opens the editor on it without starting a route.
        mums.press(forDuration: 1.0)
        XCTAssertTrue(app.textFields["place.name"].waitForExistence(timeout: 5), "long-press opens the editor")
        XCTAssertEqual(app.textFields["place.name"].value as? String, "Mums")
        app.buttons["places.done"].tap()
        XCTAssertTrue(app.buttons["home.fav.edit"].waitForExistence(timeout: 5),
                      "long-press must not also start navigation")

        // Long-press an unset tile too.
        app.buttons["fav.work"].press(forDuration: 1.0)
        XCTAssertTrue(app.textFields["place.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["place.name"].value as? String, "Work")
        app.buttons["places.done"].tap()

        // Add a place from the list, then delete it.
        app.buttons["home.fav.edit"].tap()
        XCTAssertTrue(app.buttons["places.add"].waitForExistence(timeout: 5))
        app.buttons["places.add"].tap()
        XCTAssertEqual(app.textFields["place.name"].value as? String, "New place")
        let delete = app.buttons["place.delete"]
        if !delete.isHittable { app.swipeUp() }
        delete.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.buttons["places.row.home"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["places.row.new-place"].exists)
        app.buttons["places.done"].tap()
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testMapOrientationTogglePersists() {
        launch()
        open("maps")
        let toggle = orientationButton(on: "maps")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "Heading up")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "North up")
        snapshot("maps-north-up")

        open("home")
        XCTAssertEqual(orientationButton(on: "home").value as? String, "North up", "Home map shares the setting")
        snapshot("home-north-up")

        app.terminate()
        app.launchArguments = ["-UITest"]
        launch()
        open("maps")
        let relaunched = orientationButton(on: "maps")
        XCTAssertTrue(relaunched.waitForExistence(timeout: 5))
        XCTAssertEqual(relaunched.value as? String, "North up", "setting survives relaunch")
        relaunched.tap()
        XCTAssertEqual(relaunched.value as? String, "Heading up")
    }
}
