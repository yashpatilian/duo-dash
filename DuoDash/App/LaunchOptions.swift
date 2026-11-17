import SwiftUI

/// Switches read from launch arguments / environment. Used by UI tests and for
/// running in the Simulator, which has no Music app.
enum LaunchOptions {
    private static let arguments = ProcessInfo.processInfo.arguments
    private static let environment = ProcessInfo.processInfo.environment

    /// Running under XCUITest.
    static var isUITesting: Bool { arguments.contains("-UITest") }

    /// Marketing captures (README / video): no test border around the canvas.
    static var isCapture: Bool { arguments.contains("-Capture") }

    /// Wipe saved favourites / tab / route on launch (clean test runs).
    static var resetState: Bool { arguments.contains("-ResetState") }

    /// Pretend a few catalogue apps (Google Maps, Waze, WhatsApp…) are installed and put
    /// them in the dock: screenshots and UI tests of the "Apps on this iPhone" tiles.
    static var demoExternalApps: Bool { arguments.contains("-DemoExternalApps") }

    /// Use the built-in demo music library instead of the Music app.
    static var usesDemoMusic: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return arguments.contains("-DemoMusic")
        #endif
    }

    /// Render the app inside a fixed canvas, e.g. `DUODASH_CANVAS=466x678`, to
    /// exercise the cover-screen and Split View layouts on any simulator.
    static var forcedCanvas: CGSize? {
        guard let raw = environment["DUODASH_CANVAS"] else { return nil }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 100, parts[1] > 100 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}

/// Size-driven layout decisions. Folded, unfolded, rotated and Split View all just
/// change the window size, so nothing here looks at device orientation.
struct DashMetrics: Equatable {
    var size: CGSize
    /// The system's safe-area insets. The shell draws edge to edge and only keeps
    /// the clock, status and dock tiles clear of the camera cutout.
    var insets = EdgeInsets()

    /// CarPlay-style sidebar on the right when the window is wider than tall;
    /// otherwise a bottom dock (portrait, cover screen, Split View half).
    var usesSidebar: Bool { size.width > size.height }

    /// Small windows: cover screen or Split View.
    var isCompact: Bool { min(size.width, size.height) < 520 }

    /// The dock sits on the right edge, so it widens to absorb a camera column there.
    var sidebarWidth: CGFloat { (isCompact ? 82 : 96) + max(0, insets.trailing - 10) }
    var bottomDockHeight: CGFloat { isCompact ? 78 : 86 }
    var dockThickness: CGFloat { usesSidebar ? sidebarWidth : bottomDockHeight }

    /// Home shows map + a column of widgets side by side (CarPlay dashboard) only
    /// in sidebar mode with room for both; otherwise the map sits above one widget.
    /// Decided from the window alone, so hiding the now-playing bar can't flip it.
    var homeIsSplit: Bool { usesSidebar && size.width - sidebarWidth - insets.leading - 2 * Theme.gap >= 560 }

    /// Whole-UI zoom: 1 on phones and the Duo, growing on bigger windows (iPad) so the
    /// layout is designed once at about 720 pt on the short side and scaled up from there.
    var scale: CGFloat = 1
    static let designShortSide: CGFloat = 720
    static func displayScale(for size: CGSize) -> CGFloat {
        let short = min(size.width, size.height)
        return min(1.45, max(1, (short / designShortSide * 100).rounded() / 100))
    }
    /// The metrics the layout sees after zooming: a smaller logical window, same shape.
    func scaledForDisplay() -> DashMetrics {
        let s = Self.displayScale(for: size)
        guard s > 1 else { return self }
        var m = self
        m.scale = s
        m.size = CGSize(width: size.width / s, height: size.height / s)
        m.insets = EdgeInsets(top: insets.top / s, leading: insets.leading / s,
                              bottom: insets.bottom / s, trailing: insets.trailing / s)
        return m
    }

    /// Height of the status row used with the bottom dock. Tall enough that the
    /// cover screen's camera (top right) sits inside it.
    var statusHeight: CGFloat { 54 }
}

private struct DashMetricsKey: EnvironmentKey {
    static let defaultValue = DashMetrics(size: CGSize(width: 900, height: 620))
}

extension EnvironmentValues {
    var dashMetrics: DashMetrics {
        get { self[DashMetricsKey.self] }
        set { self[DashMetricsKey.self] = newValue }
    }
}
