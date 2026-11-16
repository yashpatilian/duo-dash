import SwiftUI

/// Compact Dashboard card with up to three favourite Home actions (garage first).
struct HomeDashboardCard: View {
    @Environment(HomeModel.self) private var model
    /// Opens the full Home screen (header tap / empty state).
    var onOpen: (() -> Void)? = nil
    @State private var pendingUnlock: HomeAccessory?

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                header
                switch model.status {
                case .ready:
                    let tiles = model.dashboardTiles
                    if tiles.isEmpty {
                        note("Hold a tile in Home to add it here.")
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Theme.gap) { items(tiles) }
                            VStack(spacing: Theme.gap) { items(tiles) }
                        }
                    }
                case .notEnabled:
                    note("Turn on HomeKit for this build (scripts/setup.sh --homekit).")
                case .loading:
                    note("Loading…")
                case .denied:
                    note("Allow Home access to control your garage and lights.")
                case .restricted:
                    note("Home access is restricted on this iPhone.")
                case .noHomes:
                    note("Set up a home in Apple's Home app.")
                }
            }
        }
        .modifier(HomeUnlockConfirmation(model: model, pending: $pendingUnlock))
        .onAppear { model.start() }
        .accessibilityIdentifier("homekit.card")
    }

    private var header: some View {
        Button {
            onOpen?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "house.fill").foregroundStyle(Theme.warning)
                Text(model.selectedHome?.name ?? "Home")
                    .font(.dashBody)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .accessibilityIdentifier("homekit.card.open")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.dashCaption)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch, alignment: .leading)
    }

    @ViewBuilder private func items(_ tiles: [HomeTile]) -> some View {
        ForEach(tiles) { tile in
            CompactHomeButton(tile: tile,
                              stateText: model.stateText(for: tile),
                              isPending: model.pendingIDs.contains(tile.id),
                              isResponding: model.isResponding(tile)) {
                model.handleTap(tile) { pendingUnlock = $0 }
            }
        }
    }
}

/// One favourite on the card: icon, name, state, 60 pt tall.
private struct CompactHomeButton: View {
    let tile: HomeTile
    let stateText: String
    let isPending: Bool
    let isResponding: Bool
    let action: () -> Void

    private var symbol: String {
        switch tile {
        case let .accessory(accessory): accessory.symbol
        case let .scene(scene): scene.symbol
        }
    }

    private var tint: Color {
        guard isResponding else { return Theme.textSecondary }
        if case let .accessory(accessory) = tile {
            if accessory.needsAttention { return Theme.danger }
            return accessory.isActive ? Theme.warning : Theme.accent
        }
        return Theme.accent
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if isPending {
                        ProgressView().tint(Theme.textSecondary)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.name)
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(stateText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isResponding ? Theme.textSecondary : Theme.danger)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(tile.name)
        .accessibilityValue(stateText)
        .accessibilityIdentifier("homekit.card.\(tile.id)")
    }
}
