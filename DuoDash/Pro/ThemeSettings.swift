import SwiftUI
import Observation

/// Duo Dash Pro → Themes: the accent colour and the app grid wallpaper.
///
/// `Theme.accent` reads `ThemeSettings.shared`, so every view that uses the accent follows it
/// (SwiftUI's observation tracking picks the read up from inside `body`). Without Pro the
/// defaults apply (system blue, the original wallpaper); the choices stay saved, so they come
/// back if Pro is bought again.
@MainActor
@Observable
final class ThemeSettings {
    /// The app's instance (also put in the environment). Tests make their own.
    static let shared = ThemeSettings()

    var accent: AccentChoice {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    var wallpaper: WallpaperChoice {
        didSet { defaults.set(wallpaper.rawValue, forKey: Keys.wallpaper) }
    }

    /// Mirrors `ProStore.isPro` (set by the app). Not saved.
    var isProActive = false

    /// What's on screen: the user's choice with Pro, the defaults without.
    var effectiveAccent: AccentChoice { isProActive ? accent : .blue }
    var effectiveWallpaper: WallpaperChoice { isProActive ? wallpaper : .aurora }
    var accentColor: Color { effectiveAccent.color }

    enum Keys {
        static let accent = "theme.accent"
        static let wallpaper = "theme.wallpaper"
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = defaults.string(forKey: Keys.accent).flatMap(AccentChoice.init(rawValue:)) ?? .blue
        wallpaper = defaults.string(forKey: Keys.wallpaper).flatMap(WallpaperChoice.init(rawValue:)) ?? .aurora
    }

    func reset() {
        accent = .blue
        wallpaper = .aurora
    }
}

/// Accent swatches, from the iOS system palette (dark appearance).
enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case blue, teal, green, yellow, orange, red, pink, purple, graphite

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: Color(red: 0.039, green: 0.518, blue: 1.0)
        case .teal: Color(red: 0.25, green: 0.78, blue: 0.88)
        case .green: Color(red: 0.188, green: 0.820, blue: 0.345)
        case .yellow: Color(red: 1.0, green: 0.84, blue: 0.04)
        case .orange: Color(red: 1.0, green: 0.62, blue: 0.04)
        case .red: Color(red: 1.0, green: 0.27, blue: 0.23)
        case .pink: Color(red: 1.0, green: 0.22, blue: 0.37)
        case .purple: Color(red: 0.75, green: 0.35, blue: 0.95)
        case .graphite: Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }

    /// Text and symbols drawn on the accent: dark on the light swatches so they stay readable.
    var onColor: Color {
        switch self {
        case .yellow, .teal, .green: .black
        default: .white
        }
    }
}

/// Wallpapers for the app grid: the original soft mesh, generated variants, or plain black.
enum WallpaperChoice: String, CaseIterable, Identifiable, Sendable {
    case aurora, ocean, sunset, forest, ember, nebula, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: "Midnight"
        case .ocean: "Ocean"
        case .sunset: "Dusk"
        case .forest: "Forest"
        case .ember: "Ember"
        case .nebula: "Nebula"
        case .black: "Black"
        }
    }

    /// 3×3 mesh colours, top-left to bottom-right; nil for plain black.
    var meshColors: [Color]? {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        switch self {
        case .aurora:
            return [c(0.03, 0.05, 0.12), c(0.06, 0.09, 0.22), c(0.02, 0.03, 0.08),
                    c(0.05, 0.14, 0.26), c(0.16, 0.12, 0.36), c(0.05, 0.08, 0.20),
                    c(0.01, 0.02, 0.05), c(0.04, 0.10, 0.18), c(0.02, 0.02, 0.06)]
        case .ocean:
            return [c(0.01, 0.06, 0.10), c(0.02, 0.14, 0.22), c(0.01, 0.05, 0.09),
                    c(0.02, 0.20, 0.28), c(0.04, 0.32, 0.40), c(0.02, 0.12, 0.20),
                    c(0.00, 0.03, 0.05), c(0.02, 0.10, 0.16), c(0.01, 0.03, 0.06)]
        case .sunset:
            return [c(0.10, 0.03, 0.10), c(0.22, 0.06, 0.18), c(0.08, 0.02, 0.08),
                    c(0.30, 0.10, 0.16), c(0.42, 0.16, 0.14), c(0.20, 0.05, 0.14),
                    c(0.05, 0.01, 0.05), c(0.14, 0.04, 0.10), c(0.04, 0.01, 0.04)]
        case .forest:
            return [c(0.02, 0.07, 0.05), c(0.04, 0.14, 0.09), c(0.01, 0.05, 0.04),
                    c(0.05, 0.20, 0.13), c(0.12, 0.28, 0.14), c(0.03, 0.12, 0.08),
                    c(0.01, 0.03, 0.02), c(0.03, 0.09, 0.06), c(0.01, 0.02, 0.02)]
        case .ember:
            return [c(0.10, 0.04, 0.02), c(0.20, 0.08, 0.03), c(0.07, 0.03, 0.02),
                    c(0.28, 0.12, 0.03), c(0.40, 0.20, 0.04), c(0.18, 0.07, 0.03),
                    c(0.05, 0.02, 0.01), c(0.12, 0.05, 0.02), c(0.04, 0.02, 0.01)]
        case .nebula:
            return [c(0.08, 0.03, 0.14), c(0.14, 0.05, 0.26), c(0.05, 0.02, 0.10),
                    c(0.10, 0.08, 0.30), c(0.30, 0.10, 0.40), c(0.12, 0.04, 0.24),
                    c(0.03, 0.01, 0.06), c(0.08, 0.04, 0.16), c(0.03, 0.01, 0.05)]
        case .black:
            return nil
        }
    }

    /// Where the bright middle point of the mesh sits, so variants don't look like recolours.
    var meshCentre: SIMD2<Float> {
        switch self {
        case .aurora: [0.62, 0.42]
        case .ocean: [0.38, 0.55]
        case .sunset: [0.55, 0.62]
        case .forest: [0.45, 0.38]
        case .ember: [0.66, 0.58]
        case .nebula: [0.35, 0.40]
        case .black: [0.5, 0.5]
        }
    }
}

/// Draws a wallpaper (the app grid background, and the swatches in Settings).
struct WallpaperView: View {
    let wallpaper: WallpaperChoice

    var body: some View {
        if let colors = wallpaper.meshColors {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], wallpaper.meshCentre, [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: colors)
        } else {
            Color.black
        }
    }
}
