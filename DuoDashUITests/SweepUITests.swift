import XCTest
import CoreLocation

/// The "try to break it" sweep: every app at every window size the Duo (and other devices) can
/// produce, rotation while open, and a long run of random taps. Fails on a crash, a screen that
/// doesn't appear, or the app hanging.
final class SweepUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Window sizes in points: cover screen both ways, inner screen both ways, a Split View half,
    /// a phone, an iPad. The canvas is fitted onto whatever simulator runs the test.
    private let sizes = ["466x678", "678x466", "951x669", "669x951", "475x669", "390x844", "1032x1376"]
    private let apps = ["home", "maps", "music", "spotify", "phone", "messages", "calendar", "weather",
                        "car", "homekit", "dashcam", "settings"]

    override func setUpWithError() throws {
        continueAfterFailure = true
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.3326, longitude: -122.0053))
    }

    private func launch(canvas: String?, extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-UITest", "-ResetState", "-SeedContacts", "-SeedPlaces", "-DemoSpotify", "-DemoCar",
                               "-AssistantLocal"] + extra
        if let canvas { app.launchEnvironment["DUODASH_CANVAS"] = canvas }
        app.launch()
        dismissSystemAlerts()
        XCTAssertTrue(app.buttons["dock.home"].waitForExistence(timeout: 15), "dock did not appear (\(canvas ?? "full screen"))")
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<4 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 1) else { break }
            for label in ["Allow While Using App", "Allow Full Access", "Allow", "OK", "Don't Allow", "Cancel"]
            where alert.buttons[label].exists {
                alert.buttons[label].firstMatch.tap(); break
            }
        }
    }

    private func assertAlive(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(app.state, .notRunning, "crashed: \(context)", file: file, line: line)
    }

    /// Every dock app opens at every window size and shows its screen.
    func testEveryAppAtEverySize() {
        for size in sizes {
            launch(canvas: size)
            for id in apps {
                if id == "home" {
                    app.buttons["dock.home"].tap()
                } else {
                    app.tapDock(id)
                }
                dismissSystemAlerts()
                XCTAssertTrue(app.descendants(matching: .any)["screen.\(id)"].waitForExistence(timeout: 6),
                              "screen.\(id) did not appear at \(size)")
                assertAlive("\(id) at \(size)")
            }
            // Home's second tap is CarPlay's app grid; a third goes back.
            app.tapDock("home")
            app.buttons["dock.home"].tap()
            app.buttons["dock.home"].tap()
            assertAlive("home grid toggle at \(size)")
            app.terminate()
        }
    }

    /// Full-screen on the simulator, rotating between portrait and landscape with each app open
    /// (on a Duo simulator these are the real window-size changes of turning the phone).
    func testRotateWithEveryAppOpen() {
        launch(canvas: nil)
        let orientations: [UIDeviceOrientation] = [.portrait, .landscapeLeft, .portrait, .landscapeRight, .portrait]
        for id in apps {
            if id == "home" { app.buttons["dock.home"].tap() } else { app.tapDock(id) }
            for orientation in orientations {
                XCUIDevice.shared.orientation = orientation
                assertAlive("\(id) rotated to \(orientation.rawValue)")
            }
            XCTAssertTrue(app.descendants(matching: .any)["screen.\(id)"].waitForExistence(timeout: 6),
                          "screen.\(id) lost after rotating")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// 300 random taps, swipes and dock jumps across the whole app. Leaving the app on purpose
    /// (dialler, App Store, Settings, Spotify) is fine: we come back. Crashing is not.
    func testRandomTapsDontCrash() {
        launch(canvas: "951x669")
        var rng = SystemRandomNumberGenerator()
        let canvas = app.descendants(matching: .any)["canvas"].firstMatch
        let area = canvas.exists ? canvas : app.windows.firstMatch
        for step in 0..<300 {
            if app.state != .runningForeground {
                XCTAssertNotEqual(app.state, .notRunning, "crashed at step \(step)")
                app.activate()
                _ = app.wait(for: .runningForeground, timeout: 5)
            }
            dismissSystemAlerts()
            switch Int.random(in: 0..<10, using: &rng) {
            case 0, 1:
                app.tapDock(apps.randomElement(using: &rng)!)
            case 2:
                let from = area.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: Double.random(in: 0.3...0.7, using: &rng)))
                from.press(forDuration: 0.02, thenDragTo: from.withOffset(CGVector(dx: Double.random(in: -200...200, using: &rng),
                                                                                    dy: Double.random(in: -200...200, using: &rng))))
            default:
                let point = area.coordinate(withNormalizedOffset: CGVector(dx: Double.random(in: 0.03...0.9, using: &rng),
                                                                           dy: Double.random(in: 0.05...0.95, using: &rng)))
                point.tap()
            }
            // Out-of-process sheets (contact picker, share sheet) and our own sheets: back out sometimes.
            if step % 25 == 24 {
                let cancel = app.buttons["Cancel"].firstMatch
                if cancel.exists && cancel.isHittable { cancel.tap() }
                app.tapDock("home")
            }
        }
        XCTAssertNotEqual(app.state, .notRunning, "crashed during the random run")
    }

    // MARK: - Onboarding chaos

    private func onboardingVisible() -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'onboarding.page.'")).count > 0
    }

    /// Random taps through the welcome tour: answers in any order, Back, Skip, permission buttons,
    /// stray taps, quitting halfway and relaunching (the tour must resume), at the cover-screen and
    /// inner-screen sizes. It must never crash, and it must always be possible to finish.
    func testOnboardingChaos() {
        var rng = SystemRandomNumberGenerator()
        let ids = ["onboarding.next", "onboarding.back", "onboarding.skip", "onboarding.carplay.yes", "onboarding.carplay.no",
                   "onboarding.music.appleMusic", "onboarding.music.spotify", "onboarding.music.both", "onboarding.music.neither",
                   "onboarding.spotify.now", "onboarding.spotify.later", "onboarding.permission.location",
                   "onboarding.permission.contacts", "onboarding.permission.microphone"]
        for canvas in ["951x669", "466x678", "678x466"] {
            app = XCUIApplication()
            app.launchArguments = ["-UITest", "-ResetState", "-Onboarding"]
            app.launchEnvironment["DUODASH_CANVAS"] = canvas
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["onboarding.page.welcome"].waitForExistence(timeout: 10),
                          "tour didn't start at \(canvas)")
            for step in 0..<60 {
                dismissSystemAlerts()
                if app.state != .runningForeground {
                    XCTAssertNotEqual(app.state, .notRunning, "crashed in the tour at step \(step), \(canvas)")
                    app.activate()
                }
                // Quit halfway once: relaunching (without -ResetState) must resume the tour.
                if step == 25 {
                    app.terminate()
                    app.launchArguments = ["-UITest", "-Onboarding"]
                    app.launch()
                    XCTAssertTrue(onboardingVisible(), "tour didn't resume after quitting at \(canvas)")
                    continue
                }
                if Int.random(in: 0..<5, using: &rng) == 0 {
                    // A stray tap anywhere.
                    let window = app.windows.firstMatch
                    window.coordinate(withNormalizedOffset: CGVector(dx: Double.random(in: 0.05...0.95, using: &rng),
                                                                     dy: Double.random(in: 0.05...0.95, using: &rng))).tap()
                } else if let id = ids.shuffled(using: &rng).first(where: { app.buttons[$0].exists && app.buttons[$0].isHittable }) {
                    app.buttons[id].tap()
                }
                if !onboardingVisible() { break }   // finished early (e.g. Skip → Not now)
            }
            // However it got here, Skip and Not now always end the tour.
            dismissSystemAlerts()
            if onboardingVisible() {
                if app.buttons["onboarding.skip"].exists { app.buttons["onboarding.skip"].tap() }
                let notNow = app.buttons["dock.promo.notNow"]
                XCTAssertTrue(notNow.waitForExistence(timeout: 5), "Duo Dock card missing at the end, \(canvas)")
                notNow.tap()
            }
            XCTAssertTrue(app.buttons["dock.home"].waitForExistence(timeout: 8), "dashboard didn't appear after the tour, \(canvas)")
            XCTAssertNotEqual(app.state, .notRunning)
            app.terminate()
        }
    }
}
