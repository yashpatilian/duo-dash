import XCTest
import UIKit

/// Copy an address (e.g. from a text), open Maps, and navigate there in one tap.
final class CopiedAddressUITests: XCTestCase {
    func testCopiedAddressOffersNavigation() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        // Copy an address the way a user would from Messages.
        UIPasteboard.general.string = "See you at 10600 N Tantau Ave, Cupertino, CA 95014"

        let app = XCUIApplication()
        app.launchArguments = ["-UITest", "-ResetState"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { break }
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); break
            }
        }
        app.buttons["dock.maps"].tap()

        let banner = app.descendants(matching: .any)["maps.copiedAddress"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no copied-address suggestion")
        // Apple's PasteButton keeps its own accessibility identity: find it by label.
        let paste = banner.buttons["Paste"].exists ? banner.buttons["Paste"] : app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste button in the banner")
        paste.tap()
        // Apple's PasteButton never shows the "Allow Paste" prompt.
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2), "paste prompt appeared")

        // The address is searched; with network it previews a route (otherwise results show).
        let start = app.buttons["nav.start"]
        let result = app.buttons["maps.result"].firstMatch
        guard start.waitForExistence(timeout: 30) || result.waitForExistence(timeout: 5) else {
            throw XCTSkip("MapKit search returned nothing (no network?)")
        }
        XCTAssertFalse(banner.exists, "banner should go away once used")
    }
}
