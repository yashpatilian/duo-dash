import SwiftUI
import MapKit

/// A saved place's icon: its emoji (always drawn in grey, like the symbols) or its SF Symbol.
struct PlaceIcon: View {
    let place: Favourite
    var size: CGFloat = 24
    /// Dimmed like an unset tile.
    var dimmed = false

    var body: some View {
        if let emoji = place.emoji {
            GreyEmoji(emoji: emoji, size: size, dimmed: dimmed)
        } else {
            Image(systemName: place.displaySymbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(dimmed ? Theme.textSecondary : Theme.textPrimary)
        }
    }
}

/// An emoji flattened to the same grey as the SF Symbol tiles: no colour, lifted
/// towards white for a set place, the secondary-text grey for an unset one.
struct GreyEmoji: View {
    let emoji: String
    var size: CGFloat = 24
    var dimmed = false

    var body: some View {
        Text(emoji)
            .font(.system(size: size * 1.05))
            .grayscale(1)
            .brightness(dimmed ? 0.12 : 0.32)
            .contrast(0.9)
            .opacity(dimmed ? 0.6 : 1)
            .accessibilityHidden(true)
    }
}

/// One saved-place tile. Tap to go (or to set it up); long-press to edit.
struct FavouriteButton: View {
    let place: Favourite
    let action: () -> Void
    let onEdit: () -> Void

    @State private var pressed = false

    var body: some View {
        // Not a Button: a Button still fires its tap when a long press ends, which
        // would start a route as well as opening the editor. These two are exclusive.
        tile
            .scaleEffect(pressed ? 0.95 : 1)
            .opacity(pressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.5, perform: onEdit) { pressing in pressed = pressing }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(place.isSet ? place.name : "\(place.name), not set")
            .accessibilityIdentifier(place.tileIdentifier)
            .accessibilityAction { action() }
            .accessibilityAction(named: "Edit") { onEdit() }
    }

    private var tile: some View {
        VStack(spacing: 4) {
            PlaceIcon(place: place, dimmed: !place.isSet)
                .frame(height: 28)
            Text(place.name).font(.dashCaption).lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: Theme.minTouch + 12)
        .foregroundStyle(place.isSet ? Theme.textPrimary : Theme.textSecondary)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if !place.isSet {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .padding(6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The row of saved-place tiles used on Home and in Maps search. Three tiles fill
/// the width (the size they've always been); more scroll sideways.
struct FavouritesRow: View {
    /// A set place was tapped.
    let onGo: (MKMapItem) -> Void
    /// Open the editor, at a place (nil for the list).
    let onEdit: (String?) -> Void
    /// The padding around the row in its card: the row scrolls out to the card's
    /// edges so the next tile peeks in, while the tiles keep their usual size.
    var bleed: CGFloat = 16

    @Environment(FavouritesStore.self) private var favourites

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(favourites.places) { place in
                    FavouriteButton(place: place) {
                        if let item = place.mapItem() {
                            onGo(item)
                        } else {
                            onEdit(place.id)
                        }
                    } onEdit: {
                        onEdit(place.id)
                    }
                    .containerRelativeFrame(.horizontal, count: 3, spacing: 10)
                }
                if favourites.places.isEmpty {
                    addTile.containerRelativeFrame(.horizontal, count: 3, spacing: 10)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, bleed, for: .scrollContent)
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .padding(.horizontal, -bleed)
        .clipShape(Rectangle())
        .accessibilityIdentifier("fav.row")
    }

    private var addTile: some View {
        Button { onEdit(nil) } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 24, weight: .semibold)).frame(height: 28)
                Text("Add place").font(.dashCaption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch + 12)
            .foregroundStyle(Theme.accent)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("fav.add")
    }
}

/// "Edit" text button for a card header, CarPlay style, with a full-size touch target.
struct EditPlacesButton: View {
    var identifier = "fav.edit"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Edit")
                .font(.dashBody)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit places")
        .accessibilityIdentifier(identifier)
    }
}
