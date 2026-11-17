import XCTest

extension XCUIApplication {
    /// The dock keeps full-size icons and scrolls when there are more apps than fit, so an
    /// icon can be out of view. Scrolls the dock toward `button` until its centre is inside
    /// the dock's visible area. Uses frames rather than `isHittable`, which throws for
    /// elements scrolled fully out of view.
    @discardableResult
    func revealInDock(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let strip = scrollViews["dock.scroll"]
        guard button.waitForExistence(timeout: 5), strip.exists, !strip.frame.isEmpty else { return true }
        // Scaled test canvases can leave the strip with no visible frame: swiping it throws, so
        // report "not revealed" and let tapDockButton open the app by its link instead.
        guard strip.isHittable else { return strip.buttons[button.identifier].exists ? false : true }
        // The Home button sits outside the scrolling part; nothing to reveal.
        guard strip.buttons[button.identifier].exists else { return true }
        let vertical = strip.frame.height > strip.frame.width
        func inView() -> Bool {
            let f = button.frame, s = strip.frame   // centre inside the strip = tappable (no margin)
            guard !f.isEmpty else { return false }
            return s.contains(CGPoint(x: f.midX, y: f.midY))
        }
        var tries = 0
        while !inView() && tries < 12 {
            let f = button.frame, s = strip.frame
            // Past the far end: scroll toward it. A quick swipe scrolls; a slow press-and-drag
            // would start the dock's drag-to-reorder instead.
            // Off-screen icons can report an empty frame: then sweep toward the end, then back.
            let pastEnd = f.isEmpty || (f.midX == 0 && f.midY == 0) ? tries < 8 : (vertical ? f.midY > s.maxY : f.midX > s.maxX)
            switch (vertical, pastEnd) {
            case (true, true): strip.swipeUp(velocity: .slow)
            case (true, false): strip.swipeDown(velocity: .slow)
            case (false, true): strip.swipeLeft(velocity: .slow)
            case (false, false): strip.swipeRight(velocity: .slow)
            }
            tries += 1
        }
        return inView()
    }

    /// Taps a dock icon: scrolls it into view, or, if scrolling can't line it up (scaled test
    /// canvases report shifted frames), opens the app with the app's own duodash://open/<id> link.
    func tapDockButton(_ button: XCUIElement) {
        if revealInDock(button) {
            button.tap()
        } else {
            let id = button.identifier.replacingOccurrences(of: "dock.", with: "")
            open(URL(string: "duodash://open/\(id)")!)
        }
    }

    /// Reveals and taps a dock icon by id ("maps", "settings", …).
    func tapDock(_ id: String) { tapDockButton(buttons["dock.\(id)"]) }
}

extension XCUIElement {
    /// `isHittable` as soon as it holds, for elements still sliding in after a transition.
    func waitForHittable(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists && isHittable { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return exists && isHittable
    }
}

extension XCUIElementQuery {
    /// The match that is on screen. Kept-alive screens stay in XCUITest's tree on iOS 27
    /// (opacity 0, hit testing and accessibility off), so an identifier used on two screens,
    /// such as the assistant button on Home and Maps, can match twice.
    func onScreen(_ identifier: String, timeout: TimeInterval = 5) -> XCUIElement {
        let matches = matching(identifier: identifier)
        _ = matches.firstMatch.waitForExistence(timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let hit = matches.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return hit }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return matches.firstMatch
    }
}

extension XCUIElement {
    /// A real touch at the element's centre. For controls XCUITest wrongly reports as not
    /// hittable on iOS 27 (the Music tab bar at the top of the screen) although a finger works.
    func tapCentre() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
