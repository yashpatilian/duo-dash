import XCTest
import CoreLocation

/// The voice assistant on the Maps screen, driven through a launch-argument hook
/// instead of the microphone. Needs network (MapKit search + directions).
final class AssistantUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.3326, longitude: -122.0053))
        app = XCUIApplication()
    }

    override func tearDown() {
        if let app, app.state != .notRunning {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "teardown-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        app = nil
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(transcript: String?, canvas: String? = nil) {
        var arguments = ["-UITest", "-ResetState", "-AssistantLocal"]
        if let transcript { arguments += ["-AssistantTranscript", transcript] }
        app.launchArguments = arguments
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
        let maps = app.buttons["dock.maps"]
        XCTAssertTrue(maps.waitForExistence(timeout: 10))
        maps.tap()
    }

    func testAssistantPlansAndStartsARouteFromATranscript() throws {
        launch(transcript: "take me to Apple Park Visitor Center")
        let open = app.buttons["assistant.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "assistant button missing on Maps")
        XCTAssertTrue(open.isHittable)
        open.tap()

        let panel = app.descendants(matching: .any)["assistant.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "assistant panel did not open")
        XCTAssertTrue(app.descendants(matching: .any)["assistant.heard"].waitForExistence(timeout: 5))
        snapshot("assistant-thinking")

        // "Take me to" starts guidance straight away; a preview counts too.
        let banner = app.descendants(matching: .any)["nav.banner"]
        let plan = app.descendants(matching: .any)["assistant.plan"]
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline && !banner.exists && !plan.exists {
            let reply = app.staticTexts["assistant.reply"]
            if reply.exists, reply.label.contains("couldn't") || reply.label.contains("Couldn't") {
                snapshot("assistant-no-route")
                throw XCTSkip("No route from MapKit (no network?): \(reply.label)")
            }
            sleep(1)
        }
        snapshot("assistant-route")
        XCTAssertTrue(banner.exists || plan.exists, "no route preview or guidance appeared")
        if banner.exists {
            let reply = app.staticTexts["assistant.reply"]
            if reply.exists { XCTAssertTrue(reply.label.contains("Apple Park"), reply.label) }
            // The panel steps aside so the turn banner is visible.
            XCTAssertTrue(app.buttons["assistant.open"].waitForExistence(timeout: 8), "panel didn't get out of the way")
            app.buttons["nav.end"].tap()
        }
    }

    func testPlaceSearchShowsCardsOnWideWindow() throws {
        launch(transcript: "find coffee near me", canvas: "820x580")
        app.buttons["assistant.open"].tap()
        let card = app.descendants(matching: .any)["assistant.result"].firstMatch
        guard card.waitForExistence(timeout: 40) else {
            snapshot("assistant-no-results")
            throw XCTSkip("MapKit search returned nothing (no network?)")
        }
        XCTAssertTrue(app.buttons["assistant.result.go"].firstMatch.exists)
        XCTAssertTrue(app.buttons["assistant.result.details"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["assistant.map"].exists)
        snapshot("assistant-wide-results")
    }

    func testPanelOpensAndClosesOnNarrowWindow() {
        launch(transcript: nil, canvas: "340x600")
        let open = app.buttons["assistant.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["assistant.panel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistant.mic"].isHittable)
        let field = app.textFields["assistant.field"]
        XCTAssertTrue(field.exists)
        snapshot("assistant-narrow")
        app.buttons["assistant.close"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }
}
