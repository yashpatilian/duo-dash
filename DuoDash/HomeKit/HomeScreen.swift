import SwiftUI
import UIKit

/// The Home app screen: big tiles for accessories and scenes, like CarPlay's
/// Home app. Tap to act, hold to add to or remove from the Dashboard.
/// Layout depends only on the space it is given (340×600 up to 1300×900).
struct HomeScreen: View {
    @Environment(HomeModel.self) private var model
    @State private var pendingUnlock: HomeAccessory?
    @State private var toast: String?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let compact = width < 520
            Group {
                switch model.status {
                case .notEnabled:
                    EmptyStateView(symbol: "house.badge.exclamationmark",
                                   title: "Turn on HomeKit for this build",
                                   message: "Home control needs Apple's HomeKit capability, which needs your own app ID. Sign in to Xcode (Settings → Accounts), then run scripts/setup.sh --homekit --install on your Mac.")
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("homekit.state.notEnabled")
                case .loading:
                    ProgressView("Loading your home…")
                        .tint(Theme.textSecondary)
                        .font(.dashBody)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("homekit.state.loading")
                case .denied:
                    EmptyStateView(symbol: "house.slash",
                                   title: "Allow Home access",
                                   message: "Duo Dash needs access to your home to show your garage door, locks and lights. Turn on Duo Dash in Settings → Privacy & Security → HomeKit.",
                                   actionTitle: "Open Settings") { Self.openSettings() }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("homekit.state.denied")
                case .restricted:
                    EmptyStateView(symbol: "lock.shield",
                                   title: "Home access is restricted",
                                   message: "Screen Time or device management is blocking Home on this iPhone. Check Settings → Screen Time → Content & Privacy Restrictions.")
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("homekit.state.restricted")
                case .noHomes:
                    EmptyStateView(symbol: "house",
                                   title: "No home set up",
                                   message: "Set up a home and add your garage door, locks and lights in Apple's Home app. They'll show here straight away.")
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("homekit.state.noHomes")
                case .ready:
                    content(width: width, compact: compact)
                }
            }
        }
        .background(DashBackground())
        .overlay(alignment: .bottom) { messages }
        .modifier(HomeUnlockConfirmation(model: model, pending: $pendingUnlock))
        .onAppear { model.start() }
        // A marker element names the screen, so it doesn't merge with (and overwrite) the ids of
        // the state views and tiles inside.
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Home")
                .accessibilityIdentifier("homekit.screen")
                .allowsHitTesting(false)
        }
    }

    // MARK: Tiles

    private func content(width: CGFloat, compact: Bool) -> some View {
        let tileMin: CGFloat = compact ? 150 : (width > 1000 ? 210 : 180)
        let tileHeight: CGFloat = compact ? 118 : 140
        let columns = [GridItem(.adaptive(minimum: tileMin), spacing: Theme.gap * 1.5)]
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.tiles.isEmpty {
                    EmptyStateView(symbol: "house",
                                   title: "Nothing to control yet",
                                   message: "Add a garage door, lock, light, switch or scene in Apple's Home app and it will appear here.")
                        .frame(minHeight: 260)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("homekit.state.noAccessories")
                } else {
                    if !model.scenes.isEmpty {
                        section("Scenes", tiles: model.scenes.map(HomeTile.scene), columns: columns, height: tileHeight * 0.8)
                    }
                    if !model.accessories.isEmpty {
                        section("Accessories", tiles: model.accessories.map(HomeTile.accessory), columns: columns, height: tileHeight)
                    }
                }
                HomeArrivalSettingsView()
                if model.isDemo { demoControls }
            }
            .padding(compact ? 12 : 20)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedHome?.name ?? "Home")
                    .font(.dashHero)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("Hold a tile to add it to the Dashboard")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if model.homes.count > 1 {
                Menu {
                    ForEach(model.homes) { home in
                        Button {
                            model.selectHome(home.id)
                        } label: {
                            if home.id == model.selectedHome?.id {
                                Label(home.name, systemImage: "checkmark")
                            } else {
                                Text(home.name)
                            }
                        }
                    }
                } label: {
                    Label("Homes", systemImage: "house.and.flag.fill")
                        .font(.dashBody)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 18)
                        .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
                .accessibilityIdentifier("homekit.homePicker")
            }
        }
    }

    private func section(_ title: String, tiles: [HomeTile], columns: [GridItem], height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.dashTitle)
                .foregroundStyle(Theme.textPrimary)
            LazyVGrid(columns: columns, spacing: Theme.gap * 1.5) {
                ForEach(tiles) { tile in
                    HomeTileView(tile: tile,
                                 stateText: model.stateText(for: tile),
                                 isPending: model.pendingIDs.contains(tile.id),
                                 isResponding: model.isResponding(tile),
                                 isFavourite: model.isFavourite(tile.id),
                                 height: height,
                                 onTap: { model.handleTap(tile) { pendingUnlock = $0 } },
                                 onLongPress: { toggleFavourite(tile) })
                }
            }
        }
    }

    private func toggleFavourite(_ tile: HomeTile) {
        let wasFavourite = model.isFavourite(tile.id)
        model.toggleFavourite(tile.id)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        toast = wasFavourite ? "Removed \(tile.name) from the Dashboard"
            : model.dashboardTiles.contains(where: { $0.id == tile.id }) ? "Added \(tile.name) to the Dashboard"
            : "Added \(tile.name). The Dashboard shows the first \(HomeModel.maxDashboardItems)."
    }

    // MARK: Messages

    @ViewBuilder private var messages: some View {
        VStack(spacing: 8) {
            if let toast {
                banner(toast, symbol: "pin.fill", tint: Theme.surfaceRaised)
                    .accessibilityIdentifier("homekit.toast")
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(2.5))
                        self.toast = nil
                    }
            }
            if let error = model.errorMessage {
                banner(error, symbol: "exclamationmark.triangle.fill", tint: Theme.danger.opacity(0.9))
                    .accessibilityIdentifier("homekit.error")
                    .onTapGesture { model.errorMessage = nil }
                    .task(id: error) {
                        try? await Task.sleep(for: .seconds(5))
                        if model.errorMessage == error { model.errorMessage = nil }
                    }
            }
        }
        .padding(16)
        .animation(.easeOut(duration: 0.2), value: toast)
        .animation(.easeOut(duration: 0.2), value: model.errorMessage)
    }

    private func banner(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.dashCaption)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .background(tint, in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Demo

    /// Only with the demo home: block the garage door's beam to see "Obstructed".
    private var demoControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Demo home")
                .font(.dashTitle)
                .foregroundStyle(Theme.textPrimary)
            Toggle(isOn: Binding(get: { model.demo?.isObstructed ?? false },
                                 set: { model.demo?.setObstructed($0) })) {
                Text("Something is blocking the garage door")
                    .font(.dashBody)
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .frame(minHeight: Theme.minTouch)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityIdentifier("homekit.demo.obstruction")
        }
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// The arrival settings: auto-open (off by default) and how close counts as
/// arriving. Shown on the Home screen; can also go in Settings.
struct HomeArrivalSettingsView: View {
    @Environment(HomeModel.self) private var model

    private static let distances: [Double] = [150, 300, 500, 1000]

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text("Arriving home")
                .font(.dashTitle)
                .foregroundStyle(Theme.textPrimary)
            Toggle(isOn: $model.autoOpenGarageOnArrival) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open garage automatically when arriving")
                        .font(.dashBody)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Off: Duo Dash asks first. Doors are never unlocked automatically.")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.positive)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: Theme.minTouch)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityIdentifier("homekit.autoOpen")

            HStack(spacing: 12) {
                Text("Offer within")
                    .font(.dashBody)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Picker("Offer within", selection: $model.arrivalDistance) {
                    ForEach(Self.distances, id: \.self) { distance in
                        Text(Measurement(value: distance, unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .road)))
                            .tag(distance)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.positive)
                .frame(minHeight: Theme.minTouch)
                .accessibilityIdentifier("homekit.arrivalDistance")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: Theme.minTouch)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

#Preview("Home screen", traits: .landscapeLeft) {
    HomeScreen()
        .environment(HomeModel(backend: DemoHomeBackend(), resetState: false))
        .preferredColorScheme(.dark)
}
