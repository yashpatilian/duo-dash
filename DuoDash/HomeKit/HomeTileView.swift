import SwiftUI

/// A CarPlay Home-style tile: icon, name, state. Tap acts, hold adds to or
/// removes from the Dashboard.
struct HomeTileView: View {
    let tile: HomeTile
    var stateText: String
    var isPending = false
    var isResponding = true
    var isFavourite = false
    var height: CGFloat = 130
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var isPressing = false

    private var iconTint: Color {
        guard isResponding else { return Theme.textSecondary }
        switch tile {
        case let .accessory(accessory):
            if accessory.needsAttention { return Theme.danger }
            switch accessory.kind {
            case .garageDoor, .gate: return accessory.isActive ? Theme.accent : Theme.textPrimary
            case .lock: return accessory.isActive ? Theme.warning : Theme.accent
            case .light, .switchPower, .outlet: return accessory.isActive ? Theme.warning : Theme.textPrimary
            }
        case .scene:
            return Theme.accent
        }
    }

    private var symbol: String {
        switch tile {
        case let .accessory(accessory): accessory.symbol
        case let .scene(scene): scene.symbol
        }
    }

    private var background: Color {
        if case let .accessory(accessory) = tile, accessory.isActive, isResponding { return Theme.surfaceRaised }
        return Theme.surface
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 44, height: 44)
                    .background(iconTint.opacity(0.16), in: Circle())
                Spacer(minLength: 0)
                if isPending {
                    ProgressView().tint(Theme.textSecondary)
                } else if isFavourite {
                    Image(systemName: "pin.fill")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
            Text(tile.name)
                .font(.dashBody)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(stateText)
                .font(.dashCaption)
                .foregroundStyle(stateColor)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: max(height, Theme.minTouch), alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .opacity(isResponding ? 1 : 0.7)
        .scaleEffect(isPressing ? 0.95 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressing)
        .contentShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.5, perform: onLongPress) { isPressing = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(tile.name)
        .accessibilityValue(stateText)
        .accessibilityHint(isFavourite ? "On the Dashboard" : "")
        .accessibilityAction(.default, onTap)
        .accessibilityAction(named: isFavourite ? "Remove from Dashboard" : "Add to Dashboard", onLongPress)
        .accessibilityIdentifier("homekit.tile.\(tile.id)")
    }

    private var stateColor: Color {
        if !isResponding { return Theme.danger }
        if case let .accessory(accessory) = tile, accessory.needsAttention { return Theme.danger }
        return Theme.textSecondary
    }
}

/// Asks before unlocking a door from the car.
struct HomeUnlockConfirmation: ViewModifier {
    let model: HomeModel
    @Binding var pending: HomeAccessory?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Unlock \(pending?.name ?? "door")?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unlock", role: .destructive) {
                if let pending { model.unlock(pending.id) }
                pending = nil
            }
            .accessibilityIdentifier("homekit.confirmUnlock")
            Button("Cancel", role: .cancel) { pending = nil }
        }
    }
}

extension HomeModel {
    /// Tap handling shared by the screen and the card: unlocking asks first.
    func handleTap(_ tile: HomeTile, confirmUnlock: (HomeAccessory) -> Void) {
        if needsConfirmation(tile), case let .accessory(accessory) = tile {
            confirmUnlock(accessory)
        } else {
            perform(tile)
        }
    }

    /// The status line for any tile.
    func stateText(for tile: HomeTile) -> String {
        switch tile {
        case let .accessory(accessory): stateText(for: accessory)
        case .scene: pendingIDs.contains(tile.id) ? "Running…" : "Scene"
        }
    }

    func isResponding(_ tile: HomeTile) -> Bool {
        if case let .accessory(accessory) = tile { return isResponding(accessory) }
        return true
    }
}
