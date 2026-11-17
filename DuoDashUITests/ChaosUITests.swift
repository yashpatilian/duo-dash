import XCTest
import CoreLocation

/// The harshest "try to break it" run: long random sessions mixing taps, swipes, dock drags,
/// rotation, leaving and coming back, deep links (valid and junk), typing odd text into whatever
/// field is on screen, and relaunching on saved state. Fails on a crash or a hang (the dock
/// stops answering). Seeded, so a failure can be replayed: the seed is in the failure message.
final class ChaosUITests: XCTestCase {
    private var app: XCUIApplication!
    private let apps = ["home", "maps", "music", "spotify", "phone", "messages", "calendar", "weather",
                        "car", "homekit", "dashcam", "youtube", "settings"]
    private let links = ["duodash://open/maps", "duodash://open/settings", "duodash://open/", "duodash://open/%00%ff",
                         "duodash://open/" + String(repeating: "x", count: 600), "duodash://", "duodash://open/weather?x=1#y",
                         "duodash://spotify-callback?error=access_denied", "duodash://spotify-callback#access_token=bogus",
                         "duodash://open/../../etc", "duodash://open/Car", "duodash://open/home/extra/path"]
    private let junkText = ["", " ", "🚗🚗🚗🚗🚗🚗🚗🚗", String(repeating: "W", count: 400), "'; DROP TABLE x;--",
                            "\u{202E}gnp.exe", "Take me to", "navigate to nowhere at all please", "0", "-1e309",
                            "स्टेशन", "\n\n\n"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.3326, longitude: -122.0053))
    }

    /// A deterministic generator so a failing run can be repeated with CHAOS_SEED.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func launch(canvas: String?, reset: Bool) {
        app = XCUIApplication()
        app.launchArguments = ["-UITest", "-SeedContacts", "-SeedPlaces", "-DemoSpotify", "-DemoCar", "-AssistantLocal"]
            + (reset ? ["-ResetState"] : [])
        if let canvas { app.launchEnvironment["DUODASH_CANVAS"] = canvas }
        app.launch()
        dismissSystemAlerts()
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 0.5) else { break }
            for label in ["Allow While Using App", "Allow Full Access", "Allow", "Open", "OK", "Don't Allow", "Cancel"]
            where alert.buttons[label].exists {
                alert.buttons[label].firstMatch.tap(); break
            }
        }
    }

    /// The app is running and answers: back in front, and the dock's Home button appears.
    private func assertResponsive(_ context: String) {
        if app.state == .notRunning { XCTFail("CRASH: \(context)"); return }
        if app.state != .runningForeground {
            app.activate()
            _ = app.wait(for: .runningForeground, timeout: 8)
        }
        dismissSystemAlerts()
        // Sheets and pickers cover the dock: back out of them before judging a hang.
        for label in ["Cancel", "Done", "Close", "Not now"] {
            let b = app.buttons[label].firstMatch
            if b.exists && b.isHittable { b.tap() }
        }
        if app.buttons["dock.promo.notNow"].exists { app.buttons["dock.promo.notNow"].tap() }
        if !app.buttons["dock.home"].waitForExistence(timeout: 12) {
            XCTAssertNotEqual(app.state, .notRunning, "CRASH: \(context)")
            XCTFail("HANG or stuck screen (no dock): \(context)")
        }
    }

    private func chaos(canvas: String?, steps: Int, seed: UInt64) {
        var rng = SplitMix(state: seed)
        launch(canvas: canvas, reset: true)
        assertResponsive("launch, seed \(seed)")
        let orientations: [UIDeviceOrientation] = [.portrait, .landscapeLeft, .landscapeRight, .portrait]
        for step in 0..<steps {
            let ctx = "step \(step), seed \(seed), canvas \(canvas ?? "full")"
            let window = app.windows.firstMatch
            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<22:   // a dock jump
                app.tapDock(apps.randomElement(using: &rng)!)
            case 22..<55:  // a tap anywhere
                window.coordinate(withNormalizedOffset: CGVector(dx: .random(in: 0.02...0.98, using: &rng),
                                                                 dy: .random(in: 0.02...0.98, using: &rng))).tap()
            case 55..<62:  // a quick double tap
                window.coordinate(withNormalizedOffset: CGVector(dx: .random(in: 0.05...0.95, using: &rng),
                                                                 dy: .random(in: 0.05...0.95, using: &rng))).doubleTap()
            case 62..<70:  // a swipe or drag (maps pans, sheets, scroll views)
                let from = window.coordinate(withNormalizedOffset: CGVector(dx: .random(in: 0.1...0.9, using: &rng),
                                                                            dy: .random(in: 0.1...0.9, using: &rng)))
                from.press(forDuration: [0.01, 0.05, 0.8].randomElement(using: &rng)!,
                           thenDragTo: from.withOffset(CGVector(dx: .random(in: -300...300, using: &rng),
                                                                dy: .random(in: -300...300, using: &rng))))
            case 70..<74:  // rotate
                XCUIDevice.shared.orientation = orientations.randomElement(using: &rng)!
            case 74..<78:  // leave the app and come back
                XCUIDevice.shared.press(.home)
                Thread.sleep(forTimeInterval: .random(in: 0.2...2.0, using: &rng))
                app.activate()
            case 78..<84:  // a deep link, valid or junk
                app.open(URL(string: links.randomElement(using: &rng)!) ?? URL(string: "duodash://open/home")!)
            case 84..<92:  // type junk into whatever field is showing
                let field = [app.textFields, app.searchFields, app.secureTextFields, app.textViews]
                    .map { $0.allElementsBoundByIndex.filter { $0.exists && $0.isHittable } }
                    .flatMap { $0 }.randomElement(using: &rng)
                if let field {
                    field.tap()
                    field.typeText(junkText.randomElement(using: &rng)!)
                    if Bool.random(using: &rng) { field.typeText("\n") }
                }
            case 92..<95:  // hammer one button
                if let button = app.buttons.allElementsBoundByIndex.prefix(40).filter({ $0.exists && $0.isHittable })
                    .randomElement(using: &rng) {
                    for _ in 0..<5 { button.tap() }
                }
            case 95..<97:  // relaunch on saved state (no reset): persistence must survive chaos
                app.terminate()
                launch(canvas: canvas, reset: false)
            default:       // reorder the dock by dragging an icon
                let icon = app.buttons["dock.\(apps.randomElement(using: &rng)!)"]
                if icon.exists && icon.isHittable {
                    let start = icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    start.press(forDuration: 0.8, thenDragTo: start.withOffset(CGVector(dx: .random(in: -200...200, using: &rng),
                                                                                         dy: .random(in: -200...200, using: &rng))))
                }
            }
            dismissSystemAlerts()
            if app.state == .notRunning { XCTFail("CRASH: \(ctx)"); return }
            if step % 40 == 39 { assertResponsive(ctx) }
        }
        XCUIDevice.shared.orientation = .portrait
        assertResponsive("end, seed \(seed)")
        app.terminate()
    }

    private var seed: UInt64 {
        ProcessInfo.processInfo.environment["CHAOS_SEED"].flatMap(UInt64.init) ?? UInt64.random(in: 1...UInt64.max / 2)
    }

    func testChaosFullScreen() { chaos(canvas: nil, steps: 400, seed: seed) }
    func testChaosInnerScreen() { chaos(canvas: "951x669", steps: 400, seed: seed) }
    func testChaosCoverScreen() { chaos(canvas: "466x678", steps: 300, seed: seed) }
}
