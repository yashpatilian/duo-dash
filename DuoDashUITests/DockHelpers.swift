import XCTest

extension XCUIApplication {
    /// The dock keeps full-size icons and scrolls when there are more apps than fit, so an
    /// icon can be out of view. Scrolls the dock toward `button` until its centre is inside
    /// the dock's visible area. Uses frames rather than `isHittable`, which throws for
    /// elements scrolled fully out of view.
    @discardableResult
    func revealInDock(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let strip = scrollViews["dock.scroll"]
        guard button.waitForExistence(timeout: 5), strip.exists else { return true }
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
