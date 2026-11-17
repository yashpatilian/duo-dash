import SwiftUI

/// CarPlay-style dock, flush to the screen edge.
/// Wide windows: a full-height sidebar on the right with the clock on top, the app
/// tiles, and the dashboard button at the bottom. Tall or narrow windows: the same
/// tiles in a bar along the bottom. Tiles keep their size and the strip scrolls;
/// press and hold a tile and drag it to reorder (saved across launches).
struct DockView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dashMetrics) private var metrics
    @State private var dragging: DockEntry?
    /// Fade an end of the strip only when icons are actually hidden past it.
    @State private var hiddenBefore = false
    @State private var hiddenAfter = false

    var body: some View {
        GeometryReader { proxy in
            let vertical = metrics.usesSidebar
            let insets = metrics.insets
            // Keep tiles clear of the camera / rounded corners on the edge the dock touches.
            let inner = EdgeInsets(top: vertical ? max(10, insets.top) : 8,
                                   leading: vertical ? 10 : max(10, insets.leading),
                                   bottom: vertical ? 10 : max(8, min(insets.bottom, 14)),
                                   trailing: vertical ? max(10, insets.trailing) : 10)
            let across = vertical ? proxy.size.width - inner.leading - inner.trailing
                                  : proxy.size.height - inner.top - inner.bottom
            // Icons never shrink to fit; the strip scrolls instead.
            let tile = max(44, min(across - 6, metrics.isCompact ? 60 : 66))
            let showsClock = vertical && proxy.size.height >= 300

            Group {
                if vertical {
                    VStack(spacing: 6) {
                        if showsClock { SidebarClock().frame(height: 60) }
                        ScrollView(.vertical) {
                            VStack(spacing: 6) { tiles(tile: tile) }
                                .frame(maxWidth: .infinity)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .onScrollGeometryChange(for: [Bool].self) { geometry in
                            let offset = geometry.contentOffset.y + geometry.contentInsets.top
                            let visible = geometry.containerSize.height
                            let content = geometry.contentSize.height
                            return [offset > 1, offset + visible < content - 1]
                        } action: { _, edges in
                            hiddenBefore = edges[0]
                            hiddenAfter = edges[1]
                        }
                        .mask(edgeFade(vertical: true))
                        .accessibilityIdentifier("dock.scroll")
                        DockButton(entry: .app(.home), tile: tile, isSelected: app.selected == .home) { app.homeButtonTapped() }
                            .frame(height: tile + 12)
                    }
                } else {
                    HStack(spacing: 6) {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) { tiles(tile: tile) }
                                .frame(maxHeight: .infinity)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .onScrollGeometryChange(for: [Bool].self) { geometry in
                            let offset = geometry.contentOffset.x + geometry.contentInsets.leading
                            let visible = geometry.containerSize.width
                            let content = geometry.contentSize.width
                            return [offset > 1, offset + visible < content - 1]
                        } action: { _, edges in
                            hiddenBefore = edges[0]
                            hiddenAfter = edges[1]
                        }
                        .mask(edgeFade(vertical: false))
                        .accessibilityIdentifier("dock.scroll")
                        DockButton(entry: .app(.home), tile: tile, isSelected: app.selected == .home) { app.homeButtonTapped() }
                            .frame(width: tile + 12)
                    }
                }
            }
            .padding(inner)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Theme.chrome)
        }
    }

    /// The reorderable app tiles. Press and hold a tile, then drag it onto another.
    @ViewBuilder
    private func tiles(tile: CGFloat) -> some View {
        // Duo Dash's screens and any apps on this phone added in Settings → Dock.
        ForEach(app.visibleDockEntries) { entry in
            DockButton(entry: entry, tile: tile, isSelected: entry.dockItem.map { app.selected == $0 } ?? false) { app.open(entry) }
                .frame(width: tile + 12, height: tile + 12)
                .onDrag {
                    dragging = entry
                    return NSItemProvider(object: entry.id as NSString)
                } preview: {
                    DockEntryTile(entry: entry, size: tile)
                }
                .onDrop(of: [.text], delegate: DockReorderDelegate(target: entry, dragging: $dragging, app: app))
        }
    }

    /// Soft fade at an end of the strip, only where more icons are scrolled out
    /// of view; when everything fits, nothing fades.
    private func edgeFade(vertical: Bool) -> some View {
        LinearGradient(stops: [.init(color: hiddenBefore ? .clear : .black, location: 0),
                               .init(color: .black, location: 0.06),
                               .init(color: .black, location: 0.94),
                               .init(color: hiddenAfter ? .clear : .black, location: 1)],
                       startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
            .animation(.easeOut(duration: 0.15), value: [hiddenBefore, hiddenAfter])
    }
}

/// Live reordering while a tile is dragged over the others.
private struct DockReorderDelegate: DropDelegate {
    let target: DockEntry
    @Binding var dragging: DockEntry?
    let app: AppModel

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy(duration: 0.2)) { app.moveDockEntry(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// One app tile: a coloured rounded square with a white glyph, like an app icon.
private struct DockButton: View {
    let entry: DockEntry
    let tile: CGFloat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DockEntryTile(entry: entry, size: tile)
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: tile * 0.225 + 3, style: .continuous)
                        .strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(entry.title)
        .accessibilityIdentifier("dock.\(entry.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The app's icon in the dock. Uses the official icon when it has been rendered
/// into the asset catalog by `scripts/extract-app-icons.swift` (kept out of git);
/// otherwise a drawn tile in the same colours.
struct AppTile: View {
    let item: DockItem
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let name = item.officialIconAsset, let image = UIImage(named: name) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                shape
                    .fill(LinearGradient(colors: item.tileColors, startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Image(systemName: item.symbol)
                            .font(.system(size: size * 0.46, weight: .semibold))
                            .foregroundStyle(item.glyphColor)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

/// Time and battery at the top of the sidebar, like CarPlay's status column.
private struct SidebarClock: View {
    @Environment(AppModel.self) private var app
    @State private var battery = BatteryMonitor()

    var body: some View {
        VStack(spacing: 4) {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Image(systemName: battery.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(battery.tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status.clock")
        // Hidden developer tool: long-press the clock to see the real screen size.
        .onLongPressGesture(minimumDuration: 0.8) { app.showScreenInfo.toggle() }
    }
}
