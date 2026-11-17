import SwiftUI
import UIKit

/// A popular app on the phone that Duo Dash can open from the dock and the app grid. Drawn as
/// Duo Dash's own tile (an SF Symbol on the brand colour, with the app's name): no third-party
/// logos are bundled or scraped, in any edition.
struct ExternalApp: Identifiable, Hashable, Sendable {
    /// Stable id, saved in the dock order as "ext.<id>". Never rename one.
    let id: String
    let name: String
    /// URL scheme without "://". Every scheme is listed in LSApplicationQueriesSchemes.
    let scheme: String
    let symbol: String
    /// Tile gradient, top and bottom, as RGB.
    let top: RGB
    let bottom: RGB
    var glyph: RGB = RGB(1, 1, 1)

    struct RGB: Hashable, Sendable {
        let r, g, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        var color: Color { Color(red: r, green: g, blue: b) }
    }

    /// What `UIApplication.open` launches, and what `canOpenURL` asks about.
    var url: URL { URL(string: "\(scheme)://")! }
    var tileColors: [Color] { [top.color, bottom.color] }
    var glyphColor: Color { glyph.color }

    static func == (a: ExternalApp, b: ExternalApp) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ExternalAppCatalog {
    /// Popular driving, music, podcast and messaging apps. Keep LSApplicationQueriesSchemes in
    /// Config/Info.plist in step (iOS answers `canOpenURL` only for listed schemes, at most 50).
    static let all: [ExternalApp] = [
        ExternalApp(id: "googlemaps", name: "Google Maps", scheme: "comgooglemaps", symbol: "map.fill",
                    top: .init(0.30, 0.69, 0.42), bottom: .init(0.10, 0.52, 0.30)),
        ExternalApp(id: "waze", name: "Waze", scheme: "waze", symbol: "location.north.circle.fill",
                    top: .init(0.40, 0.84, 1.00), bottom: .init(0.20, 0.66, 0.92)),
        ExternalApp(id: "youtube", name: "YouTube app", scheme: "youtube", symbol: "play.rectangle.fill",
                    top: .init(1.00, 0.22, 0.20), bottom: .init(0.80, 0.05, 0.05)),
        ExternalApp(id: "youtubemusic", name: "YouTube Music", scheme: "youtubemusic", symbol: "play.circle.fill",
                    top: .init(0.20, 0.20, 0.22), bottom: .init(0.06, 0.06, 0.07), glyph: .init(1.00, 0.20, 0.20)),
        ExternalApp(id: "podcasts", name: "Podcasts", scheme: "podcasts", symbol: "antenna.radiowaves.left.and.right",
                    top: .init(0.80, 0.45, 1.00), bottom: .init(0.55, 0.20, 0.85)),
        ExternalApp(id: "audible", name: "Audible", scheme: "audible", symbol: "book.fill",
                    top: .init(1.00, 0.66, 0.20), bottom: .init(0.95, 0.47, 0.05)),
        ExternalApp(id: "whatsapp", name: "WhatsApp", scheme: "whatsapp", symbol: "phone.bubble.fill",
                    top: .init(0.35, 0.86, 0.45), bottom: .init(0.12, 0.66, 0.30)),
        ExternalApp(id: "telegram", name: "Telegram", scheme: "tg", symbol: "paperplane.fill",
                    top: .init(0.35, 0.72, 0.98), bottom: .init(0.15, 0.55, 0.88)),
        ExternalApp(id: "messenger", name: "Messenger", scheme: "fb-messenger", symbol: "bolt.horizontal.circle.fill",
                    top: .init(0.65, 0.40, 1.00), bottom: .init(0.95, 0.30, 0.60)),
        ExternalApp(id: "uber", name: "Uber", scheme: "uber", symbol: "car.side.fill",
                    top: .init(0.22, 0.22, 0.22), bottom: .init(0.02, 0.02, 0.02)),
        ExternalApp(id: "pocketcasts", name: "Pocket Casts", scheme: "pktc", symbol: "dot.radiowaves.left.and.right",
                    top: .init(0.98, 0.32, 0.30), bottom: .init(0.85, 0.15, 0.15)),
        ExternalApp(id: "overcast", name: "Overcast", scheme: "overcast", symbol: "dot.radiowaves.up.forward",
                    top: .init(1.00, 0.60, 0.20), bottom: .init(0.96, 0.43, 0.05)),
        ExternalApp(id: "amazonmusic", name: "Amazon Music", scheme: "amznmp3", symbol: "music.note.list",
                    top: .init(0.20, 0.82, 0.90), bottom: .init(0.10, 0.45, 0.75)),
        ExternalApp(id: "deezer", name: "Deezer", scheme: "deezer", symbol: "waveform",
                    top: .init(0.60, 0.35, 1.00), bottom: .init(0.38, 0.15, 0.85)),
        ExternalApp(id: "tidal", name: "Tidal", scheme: "tidal", symbol: "hifispeaker.fill",
                    top: .init(0.22, 0.22, 0.24), bottom: .init(0.04, 0.04, 0.05)),
        ExternalApp(id: "plexamp", name: "Plexamp", scheme: "plexamp", symbol: "music.note",
                    top: .init(0.98, 0.72, 0.15), bottom: .init(0.90, 0.55, 0.05), glyph: .init(0.08, 0.08, 0.08)),
    ]

    static func app(id: String) -> ExternalApp? { all.first { $0.id == id } }

    /// The catalogue apps that are on this phone, in catalogue order.
    static func installed(canOpen: (URL) -> Bool) -> [ExternalApp] {
        all.filter { canOpen($0.url) }
    }

    /// `-DemoExternalApps` (screenshots, UI tests): pretend these are installed.
    static let demoInstalledIDs: Set<String> = ["googlemaps", "waze", "whatsapp", "youtube", "audible"]
}

/// One tile in the dock: a Duo Dash screen, or another app on the phone.
/// Saved in the dock order as the screen's raw value, or "ext.<id>" for an app, so orders
/// saved before external apps existed still load unchanged.
enum DockEntry: Hashable, Identifiable {
    case app(DockItem)
    case external(ExternalApp)

    static let externalPrefix = "ext."

    var id: String {
        switch self {
        case .app(let item): item.rawValue
        case .external(let app): Self.externalPrefix + app.id
        }
    }

    /// Parses a saved id. Unknown screens and apps no longer in the catalogue give nil.
    init?(storageID: String) {
        if storageID.hasPrefix(Self.externalPrefix) {
            guard let app = ExternalAppCatalog.app(id: String(storageID.dropFirst(Self.externalPrefix.count))) else { return nil }
            self = .external(app)
        } else {
            guard let item = DockItem(rawValue: storageID), DockItem.apps.contains(item) else { return nil }
            self = .app(item)
        }
    }

    var title: String {
        switch self {
        case .app(let item): item.title
        case .external(let app): app.name
        }
    }

    var dockItem: DockItem? {
        if case .app(let item) = self { item } else { nil }
    }

    var externalApp: ExternalApp? {
        if case .external(let app) = self { app } else { nil }
    }
}

/// The tile for another app: Duo Dash's own drawing (SF Symbol on the brand colour).
struct ExternalAppTile: View {
    let app: ExternalApp
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        shape
            .fill(LinearGradient(colors: app.tileColors, startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: app.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(app.glyphColor)
            }
            // A small arrow in the corner: this opens another app.
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: max(9, size * 0.15), weight: .heavy))
                    .foregroundStyle(app.glyphColor.opacity(0.75))
                    .padding(size * 0.09)
            }
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

/// A dock or grid tile for either kind of entry.
struct DockEntryTile: View {
    let entry: DockEntry
    let size: CGFloat

    var body: some View {
        switch entry {
        case .app(let item): AppTile(item: item, size: size)
        case .external(let app): ExternalAppTile(app: app, size: size)
        }
    }
}
