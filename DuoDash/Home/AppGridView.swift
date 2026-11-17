import SwiftUI

/// CarPlay's Home screen: big app icons with names on a soft wallpaper. The dock's
/// bottom button switches between this and the Dashboard, as in CarPlay.
struct AppGridView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { proxy in
            // Duo Dash's screens and added apps in dock order, then every other catalogue app on this phone.
            let items = app.visibleDockEntries + app.installedApps.filter { !app.isInDock($0) }.map(DockEntry.external)
            let columns = proxy.size.width > proxy.size.height ? min(4, items.count) : 3
            let rows = Int(ceil(Double(items.count) / Double(columns)))
            // Icons as large as the space allows: CarPlay's are big, finger-friendly squares.
            let byWidth = (proxy.size.width - 40) / CGFloat(columns) - 36
            let byHeight = (proxy.size.height - 40) / CGFloat(rows) - 52
            let icon = max(Theme.minTouch + 12, min(124, byWidth, byHeight))
            ZStack {
                CarPlayWallpaper()
                // More apps than fit (small windows): scroll, like CarPlay's home screen pages.
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 22) {
                        ForEach(items) { item in
                            AppGridIcon(entry: item, size: icon) { app.open(item) }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.grid")
    }
}

private struct AppGridIcon: View {
    let entry: DockEntry
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let asset = entry.dockItem?.officialIconAsset {
                        Image(asset).resizable().scaledToFit()
                    } else {
                        DockEntryTile(entry: entry, size: size)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                Text(entry.title)
                    .font(.system(size: max(15, min(19, size * 0.16)), weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(entry.title)
        .accessibilityIdentifier("grid.\(entry.id)")
    }
}

/// A dark, softly lit wallpaper in the spirit of CarPlay's default ones. Duo Dash Pro → Themes
/// can swap it for another (`ThemeSettings.wallpaper`).
struct CarPlayWallpaper: View {
    var body: some View {
        WallpaperView(wallpaper: ThemeSettings.shared.effectiveWallpaper)
            .ignoresSafeArea()
    }
}
