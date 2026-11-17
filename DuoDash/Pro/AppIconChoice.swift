import SwiftUI
import UIKit

/// Duo Dash Pro → App icon. The alternates live in Assets.xcassets (drawn by
/// scripts/make-alternate-icons.swift) and are listed in
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` (Config/Base.xcconfig).
enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case standard, midnight, silver, ocean, sunset

    var id: String { rawValue }

    /// The name passed to `setAlternateIconName`; nil is the build's own icon.
    var iconName: String? {
        switch self {
        case .standard: nil
        case .midnight: "AppIconMidnight"
        case .silver: "AppIconSilver"
        case .ocean: "AppIconOcean"
        case .sunset: "AppIconSunset"
        }
    }

    var title: String {
        switch self {
        case .standard: "Default"
        case .midnight: "Midnight"
        case .silver: "Silver"
        case .ocean: "Ocean"
        case .sunset: "Sunset"
        }
    }

    /// A small copy of the icon for Settings (an app icon set can't be loaded as an image).
    var previewAsset: String { (iconName ?? "AppIcon") + "Preview" }

    init(iconName: String?) {
        self = Self.allCases.first { $0.iconName == iconName } ?? .standard
    }
}

/// Reads and sets the Home Screen icon.
@MainActor
@Observable
final class AppIconModel {
    private(set) var current: AppIconChoice
    private(set) var error: String?

    init() {
        current = AppIconChoice(iconName: UIApplication.shared.alternateIconName)
    }

    var isSupported: Bool { UIApplication.shared.supportsAlternateIcons }

    func set(_ choice: AppIconChoice) async {
        guard choice != current else { return }
        error = nil
        do {
            try await UIApplication.shared.setAlternateIconName(choice.iconName)
            current = choice
        } catch {
            self.error = "Couldn't change the icon: \(error.localizedDescription)"
        }
    }
}
