import XCTest
import CoreLocation

/// The Home (HomeKit) screen against the demo home. Skips until the screen is
/// wired into the dock (`dock.home-control` or `dock.homekit`).
final class HomeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.3326, longitude: -122.0053))
        app = XCUIApplication()
        app.launchArguments = ["-UITest", "-ResetState", "-DemoHome"]
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

    private var dockButton: XCUIElement? {
        for id in ["dock.home-control", "dock.homekit", "dock.homeControl"] where app.buttons[id].exists {
            return app.buttons[id]
        }
        return nil
    }

    /// Opens the Home screen, or skips if it isn't in the dock yet.
    private func openHome() throws {
        let button = try XCTUnwrap(dockButton)
        app.tapDockButton(button)
        let screen = app.descendants(matching: .any)
        XCTAssertTrue(screen["screen.homekit"].waitForExistence(timeout: 5) || screen["homekit.screen"].exists,
                      "Home (HomeKit) screen did not open")
    }

    private func launchAndOpen(extra: [String] = [], canvas: String? = nil) throws {
        launch(extra: extra, canvas: canvas)
        try XCTSkipUnless(dockButton != nil, "Home isn't in the dock yet")
        try openHome()
    }

    /// A tile, scrolling the Home screen to it if it's below the fold (cover screen).
    private func tile(_ id: String) -> XCUIElement {
        let tile = app.buttons["homekit.tile.\(id)"]
        var tries = 0
        while !(tile.exists && tile.isHittable) && tries < 6 {
            let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6))
            start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)))
            tries += 1
        }
        return tile
    }

    func testGarageOpensAndShowsStates() throws {
        try launchAndOpen()
        let garage = tile("demo-garage")
        XCTAssertTrue(garage.waitForExistence(timeout: 5))
        XCTAssertEqual(garage.value as? String, "Closed")
        garage.tap()
        XCTAssertTrue(NSPredicate(format: "value == 'Opening…'").evaluate(with: garage) ||
                      garage.value as? String == "Open")
        let open = expectation(for: NSPredicate(format: "value == 'Open'"), evaluatedWith: garage)
        wait(for: [open], timeout: 8)
        XCTAssertEqual(tile("demo-gate").value as? String, "Not responding")
    }

    func testObstruction() throws {
        try launchAndOpen()
        let toggle = app.switches["homekit.demo.obstruction"]
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        // Tap the switch itself (on the right), not the label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        for _ in 0..<5 where !tile("demo-garage").isHittable { app.swipeDown() }
        tile("demo-garage").tap()
        let obstructed = expectation(for: NSPredicate(format: "value == 'Obstructed'"), evaluatedWith: tile("demo-garage"))
        wait(for: [obstructed], timeout: 5)
    }

    func testUnlockAsksFirst() throws {
        try launchAndOpen()
        let lock = tile("demo-front-lock")
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        lock.tap()
        // A confirmation dialog can surface its button twice in the tree (sheet + popover form).
        let confirm = app.buttons["homekit.confirmUnlock"].exists ? app.buttons["homekit.confirmUnlock"].firstMatch
                                                                   : app.buttons["Unlock"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "unlocking must ask")
        XCTAssertEqual(lock.value as? String, "Locked")
        confirm.tap()
        let unlocked = expectation(for: NSPredicate(format: "value == 'Unlocked'"), evaluatedWith: lock)
        wait(for: [unlocked], timeout: 5)
    }

    func testLongPressAddsToDashboard() throws {
        try launchAndOpen()
        let porch = tile("demo-porch-light")
        XCTAssertTrue(porch.waitForExistence(timeout: 5))
        porch.press(forDuration: 1.0)
        XCTAssertTrue(app.descendants(matching: .any)["homekit.toast"].waitForExistence(timeout: 3))
        XCTAssertEqual(porch.value as? String, "Off", "a long press doesn't toggle")
    }

    func testDeniedState() throws {
        try launchAndOpen(extra: ["-DemoHomeDenied"])
        XCTAssertTrue(app.descendants(matching: .any)["homekit.state.denied"].waitForExistence(timeout: 5))
    }

    func testNoHomesState() throws {
        try launchAndOpen(extra: ["-DemoHomeNoHomes"])
        XCTAssertTrue(app.descendants(matching: .any)["homekit.state.noHomes"].waitForExistence(timeout: 5))
    }

    func testCoverScreenLayout() throws {
        try launchAndOpen(canvas: "340x600")
        XCTAssertTrue(tile("demo-garage").waitForExistence(timeout: 5))
        XCTAssertTrue(tile("demo-garage").isHittable)
        XCTAssertGreaterThanOrEqual(tile("demo-garage").frame.height, 60)
    }
}
