import XCTest

/// Phone and Messages with seeded fake contacts (`-SeedContacts`), so nothing
/// needs the real Contacts database or Apple's picker.
final class PhoneMessagesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["-UITest", "-ResetState", "-SeedContacts"]
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

    private func launch(canvas: String? = nil) {
        if let canvas { app.launchEnvironment["DUODASH_CANVAS"] = canvas }
        app.launch()
        // Location prompt from the map, if it appears.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); break
            }
        }
        XCTAssertTrue(app.buttons["dock.home"].waitForExistence(timeout: 10))
    }

    private func open(_ id: String) {
        let button = app.buttons["dock.\(id)"]
        // Home is a toggle (Dashboard / app grid): already there means nothing to do.
        if id == "home", button.exists, button.isSelected, app.descendants(matching: .any)["screen.home"].exists { return }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        app.tapDockButton(button)
        XCTAssertTrue(app.descendants(matching: .any)["screen.\(id)"].waitForExistence(timeout: 5))
    }

    private func tab(_ id: String) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(id) missing")
        button.tap()
        let selected = NSPredicate(format: "isSelected == true")
        let became = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: button)], timeout: 3)
        XCTAssertEqual(became, .completed, "\(id) not selected")
    }

    func testPhoneTabsSwitchAndSeededFavouriteShows() {
        launch()
        open("phone")
        let fav = app.buttons["phone.fav.0"]
        XCTAssertTrue(fav.waitForExistence(timeout: 5), "seeded favourite missing")
        XCTAssertEqual(fav.label, "Alex Chen")
        XCTAssertTrue(app.buttons["phone.add"].exists)

        tab("phone.tab.recents")
        XCTAssertTrue(app.staticTexts["phone.recents.title"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["phone.recent.0"].exists, "seeded call recent missing")

        tab("phone.tab.contacts")
        XCTAssertTrue(app.textFields["phone.contacts.search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["phone.contacts.dictate"].exists, "voice button missing")
        app.textFields["phone.contacts.search"].tap()
        app.textFields["phone.contacts.search"].typeText("Jordan")
        XCTAssertTrue(app.buttons["phone.contact.0"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["phone.contact.1"].exists, "search did not filter")

        tab("phone.tab.keypad")
        XCTAssertTrue(app.buttons["phone.call"].waitForExistence(timeout: 3))
        tab("phone.tab.favourites")
        XCTAssertTrue(app.buttons["phone.fav.0"].waitForExistence(timeout: 3))
    }

    func testKeypadDigitEntry() {
        launch()
        open("phone")
        tab("phone.tab.keypad")
        for digit in ["0", "4", "1", "2", "star", "hash"] {
            let key = app.buttons["phone.keypad.\(digit)"]
            XCTAssertTrue(key.waitForExistence(timeout: 3), "key \(digit) missing")
            XCTAssertTrue(key.waitForHittable(), "key \(digit) not hittable")
            key.tap()
        }
        let display = app.staticTexts["phone.keypad.display"]
        XCTAssertEqual(display.label, "0412*#")
        app.buttons["phone.keypad.delete"].tap()
        XCTAssertEqual(display.label, "0412*")
        XCTAssertTrue(app.buttons["phone.call"].isEnabled)
    }

    func testMessagesComposeQuickReplyAndNoCrashWithoutSMS() {
        launch()
        open("messages")
        tab("messages.tab.recents")
        XCTAssertTrue(app.buttons["messages.recent.0"].waitForExistence(timeout: 3), "seeded message recent missing")
        tab("messages.tab.new")
        XCTAssertTrue(app.buttons["messages.new.pick"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["messages.new.dictate"].exists, "voice button missing on number field")
        tab("messages.tab.favourites")

        let fav = app.buttons["messages.fav.1"]
        XCTAssertTrue(fav.waitForExistence(timeout: 5))
        fav.tap()
        let field = app.textFields["messages.compose.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "compose did not open")
        XCTAssertTrue(app.buttons["messages.compose.dictate"].exists, "voice button missing on compose")
        XCTAssertFalse(app.buttons["messages.compose.send"].isEnabled, "send enabled with no text")

        app.buttons["messages.quick.1"].tap()
        XCTAssertEqual(field.value as? String, "Running late")
        app.buttons["messages.quick.0"].tap()
        XCTAssertEqual(field.value as? String, "On my way")

        // The Simulator can't send texts: a clear message, not a crash.
        let send = app.buttons["messages.compose.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any)["messages.compose.unavailable"].waitForExistence(timeout: 5)
                      || app.navigationBars.firstMatch.waitForExistence(timeout: 2),
                      "neither the compose sheet nor the unavailable message appeared")
        XCTAssertEqual(app.state, .runningForeground)

        app.buttons["messages.compose.back"].tap()
        XCTAssertTrue(app.buttons["messages.fav.0"].waitForExistence(timeout: 3))
    }

    func testNarrowSplitViewLayout() {
        XCUIDevice.shared.orientation = .portrait
        launch(canvas: "340x600")
        open("phone")
        XCTAssertTrue(app.buttons["phone.fav.0"].waitForExistence(timeout: 5))
        for id in ["favourites", "recents", "contacts", "keypad"] {
            XCTAssertTrue(app.buttons["phone.tab.\(id)"].isHittable, "phone.tab.\(id) off screen")
        }
        tab("phone.tab.keypad")
        app.buttons["phone.keypad.5"].tap()
        XCTAssertTrue(app.buttons["phone.call"].isHittable, "call button off screen")
        open("messages")
        tab("messages.tab.favourites")
        app.buttons["messages.fav.0"].tap()
        XCTAssertTrue(app.buttons["messages.compose.send"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["messages.quick.3"].isHittable, "quick replies off screen")
    }

    /// Screens at every window shape, attached for review (no assertions beyond
    /// the controls being on screen).
    func testLayoutSweepScreenshots() {
        let canvases = [("splitview-third", "340x600"), ("cover-portrait", "466x678"),
                        ("cover-landscape", "678x466"), ("inner-landscape", "870x610")]
        for (name, canvas) in canvases {
            XCUIDevice.shared.orientation = name.contains("landscape") ? .landscapeLeft : .portrait
            app = XCUIApplication()
            app.launchArguments = ["-UITest", "-ResetState", "-SeedContacts"]
            launch(canvas: canvas)
            open("phone")
            for id in ["favourites", "recents", "contacts", "keypad"] {
                tab("phone.tab.\(id)")
                if id == "keypad" {
                    for digit in ["0", "4", "1", "2"] { app.buttons["phone.keypad.\(digit)"].tap() }
                    XCTAssertTrue(app.buttons["phone.call"].isHittable, "\(name): call off screen")
                    XCTAssertTrue(app.buttons["phone.keypad.hash"].isHittable, "\(name): # off screen")
                }
                shot("\(name)-phone-\(id)")
            }
            open("messages")
            tab("messages.tab.new")
            shot("\(name)-messages-new")
            tab("messages.tab.favourites")
            shot("\(name)-messages-favourites")
            app.buttons["messages.fav.0"].tap()
            XCTAssertTrue(app.buttons["messages.quick.0"].waitForExistence(timeout: 5))
            app.buttons["messages.quick.0"].tap()
            XCTAssertTrue(app.buttons["messages.compose.send"].isHittable, "\(name): send off screen")
            shot("\(name)-messages-compose")
            app.terminate()
        }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
