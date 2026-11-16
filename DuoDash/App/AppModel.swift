import SwiftUI
import UIKit
import Observation

/// The screens reachable from the dock.
enum DockItem: String, CaseIterable, Identifiable {
    case home, maps, music, spotify, phone, messages, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .maps: "Maps"
        case .music: "Music"
        case .spotify: "Spotify"
        case .phone: "Phone"
        case .messages: "Messages"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "square.grid.2x2.fill"
        case .maps: "map.fill"
        case .music: "music.note"
        case .spotify: "headphones"
        case .phone: "phone.fill"
        case .messages: "message.fill"
        case .settings: "gearshape.fill"
        }
    }
}

extension DockItem {
    /// The app tiles in the dock, in CarPlay order. Home (the dashboard) sits apart.
    static let apps: [DockItem] = [.maps, .music, .spotify, .phone, .messages, .settings]

    /// Top and bottom colours of the app tile, like an iOS app icon.
    var tileColors: [Color] {
        switch self {
        case .home: [Color(white: 0.30), Color(white: 0.18)]
        case .maps: [Color(red: 0.36, green: 0.78, blue: 0.98), Color(red: 0.10, green: 0.48, blue: 0.95)]
        case .music: [Color(red: 1.00, green: 0.38, blue: 0.47), Color(red: 0.96, green: 0.16, blue: 0.29)]
        case .spotify: [Color(red: 0.16, green: 0.20, blue: 0.18), Color(red: 0.05, green: 0.06, blue: 0.06)]
        case .phone: [Color(red: 0.40, green: 0.89, blue: 0.43), Color(red: 0.16, green: 0.73, blue: 0.29)]
        case .messages: [Color(red: 0.40, green: 0.89, blue: 0.43), Color(red: 0.16, green: 0.73, blue: 0.29)]
        case .settings: [Color(white: 0.62), Color(white: 0.42)]
        }
    }

    /// Asset name of the official app icon, if one is rendered locally.
    var officialIconAsset: String? {
        switch self {
        case .home: nil   // the dashboard button is a plain grid, as in CarPlay
        case .maps: "AppIconMaps"
        case .music: "AppIconMusic"
        case .spotify: "AppIconSpotify"
        case .phone: "AppIconPhone"
        case .messages: "AppIconMessages"
        case .settings: "AppIconSettings"
        }
    }

    /// Glyph colour on the tile.
    var glyphColor: Color {
        self == .spotify ? Color(red: 0.12, green: 0.84, blue: 0.38) : .white
    }
}

/// App-wide UI state: which screen is showing, and which screens have been built.
@MainActor
@Observable
final class AppModel {
    var selected: DockItem {
        didSet {
            visited.insert(selected)
            defaults.set(selected.rawValue, forKey: Self.selectedKey)
        }
    }

    /// Screens stay alive once they have been opened, so switching back is instant
    /// and keeps scroll position, map camera and search text.
    private(set) var visited: Set<DockItem>

    /// Developer overlay with the real screen/window size (long-press the clock).
    var showScreenInfo = false

    /// The Music screen is showing its full player, so the mini bar steps aside.
    var isPlayerOpen = false

    /// The user's order of app tiles in the dock (Home/dashboard is pinned apart).
    /// Saved across launches; apps added in later versions are appended.
    private(set) var dockOrder: [DockItem] {
        didSet { defaults.set(dockOrder.map(\.rawValue), forKey: Self.orderKey) }
    }

    private let defaults: UserDefaults
    private static let selectedKey = "app.selectedTab"
    private static let orderKey = "dock.order"

    /// Restores a saved order: unknown/removed apps are dropped, new apps appended.
    static func resolvedOrder(saved: [String]?) -> [DockItem] {
        let known = (saved ?? []).compactMap(DockItem.init(rawValue:)).filter { DockItem.apps.contains($0) }
        var seen = Set<DockItem>()
        let unique = known.filter { seen.insert($0).inserted }
        return unique + DockItem.apps.filter { !seen.contains($0) }
    }

    /// Back to the default app order (Settings → Dock).
    func resetDockOrder() { dockOrder = DockItem.apps }

    /// Moves `item` to where `target` is (drag-to-reorder in the dock).
    func moveDockItem(_ item: DockItem, to target: DockItem) {
        guard item != target, let from = dockOrder.firstIndex(of: item),
              let to = dockOrder.firstIndex(of: target) else { return }
        var order = dockOrder
        order.remove(at: from)
        order.insert(item, at: to)
        dockOrder = order
    }

    /// The running app's model, so App Intents (Shortcuts) can switch screens.
    static weak var current: AppModel?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let restored = defaults.string(forKey: Self.selectedKey).flatMap(DockItem.init(rawValue:)) ?? .home
        selected = restored
        visited = [restored]
        dockOrder = Self.resolvedOrder(saved: defaults.stringArray(forKey: Self.orderKey))
        Self.current = self
    }

    func open(_ item: DockItem) {
        guard selected != item else { return }
        // Screens stay alive while hidden, so a text field on the old screen could
        // keep the keyboard (and pop it up again on return). Drop it on every switch.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        selected = item
    }
}
