import SwiftUI
import MapKit

/// What the places editor should open on.
struct PlacesEditorTarget: Identifiable, Equatable {
    let id = UUID()
    /// Open straight on this place's settings; nil shows the list.
    var placeID: String?
}

extension View {
    /// Presents the saved-places editor while `target` is non-nil.
    func placesEditor(_ target: Binding<PlacesEditorTarget?>) -> some View {
        modifier(PlacesEditorPresenter(target: target))
    }
}

/// Presents the editor for each request. iOS ignores a sheet presented while the
/// previous one is still animating away (a quick Done → Edit), so a request made
/// meanwhile is held and shown once the old sheet has fully gone.
private struct PlacesEditorPresenter: ViewModifier {
    @Binding var target: PlacesEditorTarget?
    @State private var shown: PlacesEditorTarget?
    @State private var lastShownID: UUID?
    /// The sheet is animating away (`shown` is already nil, onDismiss hasn't run).
    @State private var closing = false

    func body(content: Content) -> some View {
        content
            .onChange(of: shown?.id) { old, new in
                if old != nil, new == nil { closing = true }
            }
            .sheet(item: $shown, onDismiss: {
                closing = false
                if let pending = target, pending.id != lastShownID {
                    present(pending)          // asked again while closing
                } else {
                    target = nil
                }
            }) { request in
                PlacesEditorView(startAt: request.placeID)
            }
            .onChange(of: target) { _, request in
                // While a sheet is up (or closing), onDismiss picks the request up.
                if shown == nil, !closing, let request { present(request) }
            }
    }

    private func present(_ request: PlacesEditorTarget) {
        lastShownID = request.id
        shown = request
    }
}

/// Saved places: add, reorder, delete; tap one to rename it, pick its emoji and set its location.
struct PlacesEditorView: View {
    @Environment(FavouritesStore.self) private var favourites
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String]
    @State private var editMode: EditMode = .inactive

    init(startAt: String? = nil) {
        _path = State(initialValue: startAt.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(favourites.places) { place in
                        row(place)
                    }
                    .onMove { favourites.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        for index in offsets { favourites.delete(favourites.places[index].id) }
                    }
                } footer: {
                    Text(editMode.isEditing ? "Drag ≡ to reorder. Tap ⊖ to delete."
                                            : "Tap a place to rename it, pick an emoji or set its address.")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Section {
                    Button {
                        let place = favourites.add(name: "New place")
                        editMode = .inactive
                        path.append(place.id)
                    } label: {
                        Label("Add place", systemImage: "plus.circle.fill")
                            .font(.dashBody)
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: Theme.minTouch, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.surface)
                    .accessibilityIdentifier("places.add")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.editMode, $editMode)
            .navigationTitle("Saved places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    toolbarText(editMode.isEditing ? "Finish" : "Reorder", identifier: "places.reorder") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    toolbarText("Done", bold: true, identifier: "places.done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { id in
                PlaceDetailView(placeID: id) { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(Theme.background)
    }

    private func row(_ place: Favourite) -> some View {
        Button {
            path.append(place.id)
        } label: {
            HStack(spacing: 16) {
                PlaceIcon(place: place, size: 26, dimmed: !place.isSet)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.dashBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let location = place.location {
                        Text(location.address ?? location.name)
                            .font(.dashCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("Not set")
                        }
                        .font(.dashCaption)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !editMode.isEditing {
                    Image(systemName: "chevron.right").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(minHeight: Theme.minTouch + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .accessibilityIdentifier("places.row.\(Favourite.slug(place.name))")
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { favourites.delete(place.id) }
        }
    }

    private func toolbarText(_ title: String, bold: Bool = false, identifier: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(bold ? .dashBody : .system(size: 19, weight: .regular))
                .padding(.horizontal, 8)
                .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Car-trip emoji offered in the picker, with spoken names for voice input.
enum PlaceEmoji {
    static let palette: [(emoji: String, words: [String])] = [
        ("🏠", ["home", "house"]), ("🏡", ["garden", "cottage"]), ("🏢", ["office", "building", "work"]),
        ("💼", ["briefcase", "job"]), ("🎓", ["uni", "university", "graduation"]), ("🏫", ["school"]),
        ("🏥", ["hospital", "doctor"]), ("🏋️", ["gym", "weights", "fitness"]), ("⛽️", ["fuel", "petrol", "gas"]),
        ("🔌", ["charger", "charging", "plug"]), ("🅿️", ["parking", "car park"]), ("🛒", ["shopping", "groceries", "supermarket"]),
        ("☕️", ["coffee", "cafe"]), ("🍔", ["burger", "food"]), ("🍕", ["pizza"]), ("🍽️", ["restaurant", "dinner"]),
        ("🍺", ["pub", "beer", "bar"]), ("⚽️", ["football", "soccer", "sport"]), ("🏖️", ["beach"]),
        ("⛰️", ["mountain", "hike"]), ("🏕️", ["camping", "camp"]), ("✈️", ["airport", "plane", "flight"]),
        ("🚉", ["station", "train"]), ("🚗", ["car"]), ("🐶", ["dog", "vet", "pet"]), ("👪", ["family"]),
        ("👵", ["grandma", "nana", "gran"]), ("❤️", ["heart", "love", "partner"]), ("⭐️", ["star", "favourite"]),
        ("⛪️", ["church"]), ("🏦", ["bank"]), ("🎵", ["music", "concert"]),
    ]

    /// Finds an emoji for spoken text ("coffee" → ☕️), or the text itself if it already is one.
    static func match(spoken text: String) -> String? {
        if let emoji = Favourite.validatedEmoji(text) { return emoji }
        let lowered = text.lowercased()
        for entry in palette where entry.words.contains(where: { lowered.contains($0) }) {
            return entry.emoji
        }
        return nil
    }
}

/// One place's settings: name, icon, location, delete.
struct PlaceDetailView: View {
    let placeID: String
    /// Closes the whole editor.
    var onDone: () -> Void = {}

    @Environment(FavouritesStore.self) private var favourites
    @Environment(LocationManager.self) private var location
    @Environment(\.dismiss) private var dismiss

    @State private var nameDraft = ""
    @State private var emojiDraft = ""
    @State private var spokenEmoji = ""
    @State private var emojiError: String?
    @State private var search = SearchModel()
    @State private var locating = false
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool
    @FocusState private var searchFocused: Bool

    private var place: Favourite? { favourites.place(id: placeID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Theme.background)
        // Own header with car-sized Back / Done: the system bar squeezes its items
        // into the camera column on the cover screen.
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            nameDraft = place?.name ?? ""
            if let here = location.location?.coordinate { search.focus(on: here) }
        }
        .confirmationDialog("Delete \(place?.name ?? "this place")?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                favourites.delete(placeID)
                dismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            DashIconButton(symbol: "chevron.left", label: "Back", identifier: "places.back") { dismiss() }
            Text(place?.name ?? "Place")
                .font(.dashTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            DashPillButton(title: "Done", identifier: "places.done", action: onDone)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var content: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 760
            ScrollView {
                if let place {
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(spacing: 20) { nameSection(place); iconSection(place) }
                            VStack(spacing: 20) { locationSection(place); deleteButton(place) }
                        }
                        .padding(20)
                    } else {
                        VStack(spacing: 20) {
                            nameSection(place)
                            iconSection(place)
                            locationSection(place)
                            deleteButton(place)
                        }
                        .padding(16)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Name

    private func nameSection(_ place: Favourite) -> some View {
        section("Name") {
            HStack(spacing: 8) {
                TextField("Name", text: $nameDraft)
                    .font(.dashBody)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .accessibilityIdentifier("place.name")
                    .onSubmit { commitName() }
                    .onChange(of: nameDraft) { _, _ in commitName() }
                DictationButton(text: $nameDraft, identifier: "place.name.dictate") { _ in commitName() }
            }
            .padding(.leading, 16)
            .frame(minHeight: Theme.minTouch + 4)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture { nameFocused = true }
            if nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("A place needs a name.").font(.dashCaption).foregroundStyle(Theme.warning)
            }
        }
    }

    private func commitName() {
        favourites.rename(placeID, to: nameDraft)
    }

    // MARK: Icon

    private func iconSection(_ place: Favourite) -> some View {
        section("Icon") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.minTouch, maximum: 84), spacing: 8)], spacing: 8) {
                // The place's own symbol (Home / Work / Uni) or the default pin.
                iconChoice(selected: place.emoji == nil, label: "Symbol", identifier: "place.icon.symbol") {
                    Image(systemName: place.displaySymbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                } action: {
                    favourites.clearEmoji(placeID)
                    emojiError = nil
                }
                ForEach(PlaceEmoji.palette, id: \.emoji) { entry in
                    iconChoice(selected: place.emoji == entry.emoji, label: entry.words.first ?? entry.emoji,
                               identifier: "place.icon.\(entry.words.first ?? "emoji")") {
                        GreyEmoji(emoji: entry.emoji, size: 26)
                    } action: {
                        favourites.setEmoji(placeID, to: entry.emoji)
                        emojiDraft = ""
                        emojiError = nil
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Other").font(.dashBody).foregroundStyle(Theme.textSecondary)
                EmojiTextField(text: $emojiDraft, placeholder: "Type any emoji")
                    .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                    .accessibilityIdentifier("place.emoji")
                    .onChange(of: emojiDraft) { _, text in applyTypedEmoji(text) }
                DictationButton(text: $spokenEmoji, identifier: "place.emoji.dictate") { spoken in
                    spokenEmoji = ""
                    if let emoji = PlaceEmoji.match(spoken: spoken) {
                        emojiDraft = emoji
                    } else {
                        emojiError = "No emoji for “\(spoken)”. Try a word like coffee, gym or beach."
                    }
                }
            }
            .padding(.leading, 16)
            .frame(minHeight: Theme.minTouch + 4)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let emojiError {
                Label(emojiError, systemImage: "exclamationmark.triangle.fill")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.warning)
                    .accessibilityIdentifier("place.emoji.error")
            }
        }
    }

    private func applyTypedEmoji(_ text: String) {
        guard !text.isEmpty else { emojiError = nil; return }
        if favourites.setEmoji(placeID, to: text) {
            emojiError = nil
        } else {
            emojiError = "Use just one emoji."
        }
    }

    private func iconChoice<Icon: View>(selected: Bool, label: String, identifier: String,
                                        @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon()
                .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 3)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: Location

    private func locationSection(_ place: Favourite) -> some View {
        section("Location") {
            HStack(spacing: 14) {
                Image(systemName: place.isSet ? "mappin.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.location?.name ?? "Not set yet").font(.dashBody).lineLimit(1)
                    Text(place.location?.address ?? (place.isSet ? "Saved location" : "Search below or use where you are now"))
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if place.isSet {
                    DashIconButton(symbol: "xmark", label: "Remove location", identifier: "place.location.clear") {
                        favourites.clearLocation(placeID)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minHeight: Theme.minTouch + 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("place.location")

            DashPillButton(title: locating ? "Finding you…" : "Use current location", symbol: "location.fill",
                           prominent: false, identifier: "place.useCurrent") {
                Task { await useCurrentLocation() }
            }
            .disabled(location.location == nil || locating)
            .opacity(location.location == nil ? 0.5 : 1)

            searchField
            if !search.query.isEmpty { results }
            if let message = search.errorMessage, !search.query.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.dashBody).foregroundStyle(Theme.textSecondary)
            TextField(place?.isSet == true ? "Search to replace the address" : "Search for an address",
                      text: $search.query)
                .font(.dashBody)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .accessibilityIdentifier("place.search")
                .onSubmit { Task { await search.submit() } }
            if search.isSearching { ProgressView() }
            DictationButton(text: $search.query, identifier: "place.search.dictate") { _ in
                Task { await search.submit() }
            }
            if !search.query.isEmpty {
                Button {
                    search.clear()
                    searchFocused = false
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
        .onTapGesture { searchFocused = true }
    }

    private var results: some View {
        LazyVStack(spacing: 6) {
            if search.results.isEmpty {
                ForEach(search.completions, id: \.self) { completion in
                    ResultRow(title: completion.title, subtitle: completion.subtitle, symbol: "mappin.circle.fill") {
                        Task { if let item = await search.resolve(completion) { choose(item) } }
                    }
                }
            } else {
                ForEach(search.results, id: \.self) { item in
                    ResultRow(title: item.name ?? "Unnamed place", subtitle: item.addressLine ?? "",
                              symbol: "mappin.circle.fill") { choose(item) }
                }
            }
        }
    }

    private func choose(_ item: MKMapItem) {
        favourites.setLocation(placeID, item: item)
        adoptNameIfDefault(item.name)
        search.clear()
        searchFocused = false
    }

    private func useCurrentLocation() async {
        guard let here = location.location else { return }
        locating = true
        defer { locating = false }
        var name = "Current location"
        var address: String?
        if let request = MKReverseGeocodingRequest(location: here),
           let item = try? await request.mapItems.first {
            address = item.addressLine
            name = item.address?.shortAddress ?? item.name ?? name
        }
        favourites.setLocation(placeID, coordinate: here.coordinate, name: name, address: address)
    }

    /// A brand-new place takes the name of the first location picked for it.
    private func adoptNameIfDefault(_ name: String?) {
        guard let name, !name.isEmpty, place?.name == "New place" else { return }
        nameDraft = name
        favourites.rename(placeID, to: name)
    }

    // MARK: Delete

    private func deleteButton(_ place: Favourite) -> some View {
        DashPillButton(title: "Delete \(place.name)", symbol: "trash", tint: Theme.danger, identifier: "place.delete") {
            confirmDelete = true
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Layout

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A text field that opens on the emoji keyboard.
struct EmojiTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeUIView(context: Context) -> EmojiKeyboardTextField {
        let field = EmojiKeyboardTextField()
        field.font = .systemFont(ofSize: 26)
        field.textColor = .white
        field.tintColor = UIColor(Theme.accent)
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(Theme.textSecondary),
                         .font: UIFont.systemFont(ofSize: 19, weight: .semibold)])
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: EmojiKeyboardTextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text { field.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}

final class EmojiKeyboardTextField: UITextField {
    override var textInputContextIdentifier: String? { "" }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}
