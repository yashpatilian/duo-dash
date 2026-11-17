import SwiftUI

/// Shared styling, modelled on CarPlay: true black, dark grey tiles, SF Pro,
/// system blue for anything selected or primary, full-colour app tiles.
enum Theme {
    static let background = Color.black
    /// Sidebar / bottom bar behind the app tiles.
    static let chrome = Color(red: 0.086, green: 0.086, blue: 0.094)
    /// Dashboard tiles and list rows (#1C1C1E).
    static let surface = Color(red: 0.110, green: 0.110, blue: 0.118)
    /// Controls sitting on a tile (#2C2C2E).
    static let surfaceRaised = Color(red: 0.173, green: 0.173, blue: 0.180)
    /// System blue by default; Duo Dash Pro → Themes can change it (`ThemeSettings`).
    /// Read from a view's `body`, so the view redraws when the theme changes.
    @MainActor static var accent: Color { ThemeSettings.shared.accentColor }
    @MainActor static var onAccent: Color { ThemeSettings.shared.effectiveAccent.onColor }
    /// System blue, for the few places that keep it whatever the theme (calendar default colour).
    static let systemBlue = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let route = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let positive = Color(red: 0.188, green: 0.820, blue: 0.345)  // system green
    static let warning = Color(red: 1.0, green: 0.624, blue: 0.039)
    static let danger = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.92).opacity(0.6)
    static let separator = Color.white.opacity(0.12)

    /// Smallest tappable size anywhere in the app.
    static let minTouch: CGFloat = 60
    static let corner: CGFloat = 20
    static let gap: CGFloat = 8
}

extension Font {
    static let dashHero = Font.system(size: 34, weight: .bold)
    static let dashTitle = Font.system(size: 22, weight: .bold)
    static let dashBody = Font.system(size: 19, weight: .semibold)
    static let dashCaption = Font.system(size: 15, weight: .medium)
}

/// Plain black, like a CarPlay screen.
struct DashBackground: View {
    var body: some View {
        Theme.background.ignoresSafeArea()
    }
}
