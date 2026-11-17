import SwiftUI
import UIKit
import Observation

/// The screens reachable from the dock.
enum DockItem: String, CaseIterable, Identifiable {
    case home, maps, music, spotify, phone, messages, calendar, weather, car, homekit, dashcam, youtube, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .maps: "Maps"
        case .music: "Music"
        case .spotify: "Spotify"
        case .phone: "Phone"
        case .messages: "Messages"
        case .calendar: "Calendar"
        case .weather: "Weather"
        case .car: "Car"
        case .homekit: "Home"
        case .dashcam: "Dashcam"
        case .youtube: "YouTube"
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
        case .calendar: "calendar"
        case .weather: "cloud.sun.fill"
        case .car: "car.fill"
        case .homekit: "house.fill"
        case .dashcam: "video.fill"
        case .youtube: "play.rectangle.fill"
        case .settings: "gearshape.fill"
        }
    }
}

extension DockItem {
    /// The app tiles in the dock, in CarPlay order. Home (the dashboard) sits apart.
    static let apps: [DockItem] = [.maps, .music, .spotify, .phone, .messages, .calendar, .weather, .car, .homekit, .dashcam, .youtube, .settings]

    /// Top and bottom colours of the app tile, like an iOS app icon.
    var tileColors: [Color] {
        switch self {
        case .home: [Color(white: 0.30), Color(white: 0.18)]
        case .maps: [Color(red: 0.36, green: 0.78, blue: 0.98), Color(red: 0.10, green: 0.48, blue: 0.95)]
        case .music: [Color(red: 1.00, green: 0.38, blue: 0.47), Color(red: 0.96, green: 0.16, blue: 0.29)]
        case .spotify: [Color(red: 0.16, green: 0.20, blue: 0.18), Color(red: 0.05, green: 0.06, blue: 0.06)]
        case .phone: [Color(red: 0.40, green: 0.89, blue: 0.43), Color(red: 0.16, green: 0.73, blue: 0.29)]
        case .messages: [Color(red: 0.40, green: 0.89, blue: 0.43), Color(red: 0.16, green: 0.73, blue: 0.29)]
        case .calendar: [Color(white: 1.0), Color(white: 0.93)]
        case .weather: [Color(red: 0.30, green: 0.62, blue: 0.98), Color(red: 0.12, green: 0.40, blue: 0.85)]
        case .car: [Color(red: 0.30, green: 0.62, blue: 1.0), Color(red: 0.08, green: 0.36, blue: 0.86)]
        case .homekit: [Color(red: 1.00, green: 0.70, blue: 0.20), Color(red: 0.98, green: 0.52, blue: 0.10)]
        case .dashcam: [Color(red: 0.25, green: 0.25, blue: 0.28), Color(red: 0.08, green: 0.08, blue: 0.10)]
        case .youtube: [Color(red: 1.00, green: 0.22, blue: 0.20), Color(red: 0.80, green: 0.05, blue: 0.05)]
        case .settings: [Color(white: 0.62), Color(white: 0.42)]
        }
    }

    /// Asset name of the official app icon. Personal builds use them all; the commercial
    /// edition keeps only the music services' icons (Spotify, Apple Music) and draws its own
    /// SF Symbol tiles for the rest, whose images it doesn't ship.
    var officialIconAsset: String? {
        guard let asset = bundledIconAsset else { return nil }
        if Edition.current.usesOfficialIcons { return asset }
        return Edition.partnerIconAssets.contains(asset) ? asset : nil
    }

    /// The official icon's name in BrandedIcons.xcassets, whatever the edition.
    var bundledIconAsset: String? {
        switch self {
        case .home: nil   // the dashboard button is a plain grid, as in CarPlay
        case .maps: "AppIconMaps"
        case .music: "AppIconMusic"
        case .spotify: "AppIconSpotify"
        case .phone: "AppIconPhone"
        case .messages: "AppIconMessages"
        case .calendar: "AppIconCalendar"
        case .weather: "AppIconWeather"
        case .car: nil
        case .homekit: "AppIconHome"
        case .dashcam: nil
        case .youtube: nil   // Duo Dash's own red tile; no YouTube logo is bundled
        case .settings: "AppIconSettings"
        }
    }

    /// Glyph colour on the tile.
    var glyphColor: Color {
        switch self {
        case .spotify: Color(red: 0.12, green: 0.84, blue: 0.38)
        case .calendar: Color(red: 0.98, green: 0.24, blue: 0.22)
        case .dashcam: Color(red: 1.0, green: 0.27, blue: 0.23)
        default: .white
        }
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

    /// The user's order of dock tiles (Home/dashboard is pinned apart): Duo Dash's screens and
    /// any apps on this phone added in Settings → Dock. Saved across launches as ids
    /// ("maps", "ext.waze"); screens added in later versions are appended.
    private(set) var dockEntries: [DockEntry] {
        didSet { defaults.set(dockEntries.map(\.id), forKey: Self.orderKey) }
    }

    /// Duo Dash's own screens, in dock order.
    var dockOrder: [DockItem] { dockEntries.compactMap(\.dockItem) }

    /// Catalogue apps installed on this phone (refreshed when the app comes to the front).
    private(set) var installedApps: [ExternalApp] = []

    /// What the dock shows: every screen, plus the added apps that are still installed.
    var visibleDockEntries: [DockEntry] {
        dockEntries.filter { entry in entry.externalApp.map { installedApps.contains($0) } ?? true }
    }

    private let defaults: UserDefaults
    @ObservationIgnored private let canOpenURL: @MainActor (URL) -> Bool
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    private static let selectedKey = "app.selectedTab"
    private static let orderKey = "dock.order"

    /// Restores a saved order: unknown/removed apps are dropped, new apps appended.
    static func resolvedOrder(saved: [String]?) -> [DockItem] {
        let known = (saved ?? []).compactMap(DockItem.init(rawValue:)).filter { DockItem.apps.contains($0) }
        var seen = Set<DockItem>()
        let unique = known.filter { seen.insert($0).inserted }
        return unique + DockItem.apps.filter { !seen.contains($0) }
    }

    /// Restores a saved dock: screens and catalogue apps in the saved order; unknown screens,
    /// apps no longer in the catalogue and duplicates dropped; screens missing from it appended.
    static func resolvedEntries(saved: [String]?) -> [DockEntry] {
        var seen = Set<DockEntry>()
        let known = (saved ?? []).compactMap(DockEntry.init(storageID:)).filter { seen.insert($0).inserted }
        return known + DockItem.apps.map(DockEntry.app).filter { !seen.contains($0) }
    }

    /// Back to the default app order (Settings → Dock). Added apps stay, after the screens.
    func resetDockOrder() {
        dockEntries = DockItem.apps.map(DockEntry.app) + dockEntries.filter { $0.externalApp != nil }
    }

    /// Moves `item` to where `target` is (drag-to-reorder in the dock).
    func moveDockItem(_ item: DockItem, to target: DockItem) {
        moveDockEntry(.app(item), to: .app(target))
    }

    /// Moves a tile (a screen or an added app) to where `target` is.
    func moveDockEntry(_ entry: DockEntry, to target: DockEntry) {
        guard entry != target, let from = dockEntries.firstIndex(of: entry),
              let to = dockEntries.firstIndex(of: target) else { return }
        var order = dockEntries
        order.remove(at: from)
        order.insert(entry, at: to)
        dockEntries = order
    }

    // MARK: Apps on this phone

    func isInDock(_ app: ExternalApp) -> Bool { dockEntries.contains(.external(app)) }

    /// Settings → Dock → Apps on this iPhone: adds the app at the end of the dock, or removes it.
    func setInDock(_ app: ExternalApp, _ inDock: Bool) {
        if inDock {
            guard !isInDock(app) else { return }
            dockEntries.append(.external(app))
        } else {
            dockEntries.removeAll { $0 == .external(app) }
        }
    }

    /// Asks iOS again which catalogue apps are installed (apps come and go while we're away).
    func refreshInstalledApps() {
        let now = ExternalAppCatalog.installed { canOpenURL($0) }
        if now != installedApps { installedApps = now }
    }

    /// Opens another app from its tile.
    func openExternal(_ app: ExternalApp) {
        openURL(app.url)
    }

    /// The running app's model, so App Intents (Shortcuts) can switch screens.
    static weak var current: AppModel?

    init(defaults: UserDefaults = .standard,
         canOpenURL: (@MainActor (URL) -> Bool)? = nil,
         openURL: (@MainActor (URL) -> Void)? = nil) {
        self.defaults = defaults
        self.canOpenURL = canOpenURL ?? { Self.systemCanOpen($0) }
        self.openURL = openURL ?? { UIApplication.shared.open($0) }
        let restored = defaults.string(forKey: Self.selectedKey).flatMap(DockItem.init(rawValue:)) ?? .home
        showsAppGrid = restored == .home && defaults.bool(forKey: Self.gridKey)
        selected = restored
        visited = [restored]
        dockEntries = Self.resolvedEntries(saved: defaults.stringArray(forKey: Self.orderKey))
        Self.current = self
        refreshInstalledApps()
        if LaunchOptions.demoExternalApps, canOpenURL == nil {
            for app in installedApps where ["googlemaps", "waze", "whatsapp"].contains(app.id) { setInDock(app, true) }
        }
    }

    /// `canOpenURL`, or with `-DemoExternalApps` (screenshots, UI tests) a few pretend-installed apps.
    private static func systemCanOpen(_ url: URL) -> Bool {
        if LaunchOptions.demoExternalApps {
            return ExternalAppCatalog.all.contains { $0.url == url && ExternalAppCatalog.demoInstalledIDs.contains($0.id) }
        }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Home shows CarPlay's app grid instead of the Dashboard (remembered).
    var showsAppGrid = false {
        didSet { defaults.set(showsAppGrid, forKey: Self.gridKey) }
    }
    private static let gridKey = "home.grid"

    /// The dock's bottom button, as in CarPlay: from an app it goes to the Dashboard;
    /// on Home it switches between the Dashboard and the app grid.
    func homeButtonTapped() {
        if selected == .home {
            withAnimation(.snappy(duration: 0.3)) { showsAppGrid.toggle() }
        } else {
            showsAppGrid = false
            open(.home)
        }
    }

    /// Taps on a dock or grid tile: switches screen, or opens the other app.
    func open(_ entry: DockEntry) {
        switch entry {
        case .app(let item): open(item)
        case .external(let app): openExternal(app)
        }
    }

    func open(_ item: DockItem) {
        if item != .home { showsAppGrid = false }
        guard selected != item else { return }
        // Screens stay alive while hidden, so a text field on the old screen could
        // keep the keyboard (and pop it up again on return). Drop it on every switch.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        selected = item
    }
}
