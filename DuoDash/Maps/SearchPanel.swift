import SwiftUI
import MapKit

/// Search field, favourites and results, shown on the Maps screen when no route is active.
struct SearchPanel: View {
    @Bindable var search: SearchModel
    var maxHeight: CGFloat = 600
    /// A result was chosen; preview a route to it.
    let onPick: (MKMapItem) -> Void

    @Environment(NavigationModel.self) private var navigation
    @Environment(LocationManager.self) private var location
    @FocusState private var fieldFocused: Bool
    @State private var editor: PlacesEditorTarget?
    @Environment(CopiedAddressWatcher.self) private var copied

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            CopiedAddressBanner { address in
                // Search the copied address; a single clear match goes straight to the route preview.
                search.query = address
                Task {
                    await search.submit()
                    if search.results.count == 1, let item = search.results.first { onPick(item) }
                }
            }
            searchField

            if search.query.isEmpty {
                favouritesRow
            } else {
                resultsList
            }

            if let message = search.errorMessage ?? navigation.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .animation(.snappy, value: copied.hasAddress)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.dashBody)
                .foregroundStyle(Theme.textSecondary)
            TextField("Where to?", text: $search.query)
                .font(.dashBody)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($fieldFocused)
                .accessibilityIdentifier("maps.search")
                .onSubmit { Task { await search.submit() } }
            if search.isSearching {
                ProgressView()
            }
            DictationButton(text: $search.query, identifier: "maps.search.dictate") { _ in
                Task { await search.submit() }
            }
            if !search.query.isEmpty {
                Button {
                    search.clear()
                    fieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.minTouch, height: Theme.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 16)
        .frame(minHeight: Theme.minTouch + 4)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { fieldFocused = true }
        // Never grab the keyboard on its own: only a tap on the field focuses it.
        .onAppear { fieldFocused = false }
        .onChange(of: fieldFocused) { _, focused in
            if focused, let here = location.location?.coordinate { search.focus(on: here) }
        }
    }

    private var favouritesRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved places").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                // Full 60 pt target that overhangs the gaps instead of growing the row.
                EditPlacesButton(identifier: "maps.fav.edit") { editor = PlacesEditorTarget() }
                    .padding(.vertical, -10)
            }
            FavouritesRow(onGo: { item in
                navigation.go(to: item)
            }, onEdit: { id in
                editor = PlacesEditorTarget(placeID: id)
            }, bleed: 14)
        }
        .placesEditor($editor)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if search.results.isEmpty {
                    ForEach(search.completions, id: \.self) { completion in
                        ResultRow(title: completion.title, subtitle: completion.subtitle, symbol: "mappin.circle.fill") {
                            Task {
                                if let item = await search.resolve(completion) { pick(item) }
                            }
                        }
                    }
                } else {
                    ForEach(search.results, id: \.self) { item in
                        ResultRow(title: item.name ?? "Unnamed place",
                                  subtitle: item.addressLine ?? "",
                                  symbol: "mappin.circle.fill") { pick(item) }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .frame(maxHeight: max(Theme.minTouch * 2, min(420, maxHeight - 120)))
    }

    private func pick(_ item: MKMapItem) {
        fieldFocused = false
        onPick(item)
    }
}

struct ResultRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.dashBody).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Theme.minTouch + 8)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("maps.result")
    }
}
