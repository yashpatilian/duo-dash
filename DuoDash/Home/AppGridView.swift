import SwiftUI

/// CarPlay's Home screen: big app icons with names on a soft wallpaper. The dock's
/// bottom button switches between this and the Dashboard, as in CarPlay.
struct AppGridView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { proxy in
            let items = app.dockOrder
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
                            AppGridIcon(item: item, size: icon) { app.open(item) }
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
    let item: DockItem
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let asset = item.officialIconAsset {
                        Image(asset).resizable().scaledToFit()
                    } else {
                        AppTile(item: item, size: size)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                Text(item.title)
                    .font(.system(size: max(15, min(19, size * 0.16)), weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("grid.\(item.rawValue)")
    }
}

/// A dark, softly lit wallpaper in the spirit of CarPlay's default ones.
struct CarPlayWallpaper: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.62, 0.42], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            Color(red: 0.03, green: 0.05, blue: 0.12), Color(red: 0.06, green: 0.09, blue: 0.22), Color(red: 0.02, green: 0.03, blue: 0.08),
            Color(red: 0.05, green: 0.14, blue: 0.26), Color(red: 0.16, green: 0.12, blue: 0.36), Color(red: 0.05, green: 0.08, blue: 0.20),
            Color(red: 0.01, green: 0.02, blue: 0.05), Color(red: 0.04, green: 0.10, blue: 0.18), Color(red: 0.02, green: 0.02, blue: 0.06),
        ])
        .ignoresSafeArea()
    }
}
