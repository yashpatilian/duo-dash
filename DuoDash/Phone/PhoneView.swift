import SwiftUI
import UIKit

/// CarPlay-style Phone: Favourites, Recents, Contacts and Keypad.
/// Calls go through `tel://`, so iOS shows its own confirm prompt.
struct PhoneView: View {
    @Environment(ContactsStore.self) private var contacts
    @AppStorage("phone.tab") private var tab: PhoneTab = .favourites

    enum PhoneTab: String, CaseIterable, Identifiable {
        case favourites, recents, contacts, keypad
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .favourites: "star.fill"
            case .recents: "clock.fill"
            case .contacts: "person.crop.circle.fill"
            case .keypad: "circle.grid.3x3.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: Theme.gap) {
            DashTabBar(tabs: PhoneTab.allCases, selection: $tab,
                       title: \.title, symbol: \.symbol, identifier: { "phone.tab.\($0.rawValue)" })
            Group {
                switch tab {
                case .favourites:
                    FavouritesGrid(idPrefix: "phone", badge: "phone.fill",
                                   emptyMessage: "Add the people you call most.") { contacts.call($0.recipient) }
                case .recents:
                    DashRecentsList(kind: .call, idPrefix: "phone") { contacts.call($0.recipient) }
                case .contacts:
                    PhoneContactsList()
                case .keypad:
                    KeypadView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 6)
        .overlay(alignment: .bottom) { ContactsNoticeBanner() }
        .task { await contacts.refreshFavouritesFromContacts() }
    }
}

/// Searchable address book. Contacts permission is asked for only when this
/// tab first opens.
struct PhoneContactsList: View {
    @Environment(ContactsStore.self) private var contacts
    @State private var query = ""
    /// A contact with several numbers waiting for the user to pick one.
    @State private var choosing: Choice?

    struct Choice: Identifiable {
        var person: DirectoryContact
        var favourite: Bool
        var id: String { person.id + (favourite ? "-fav" : "-call") }
    }

    var body: some View {
        VStack(spacing: Theme.gap) {
            switch contacts.access {
            case .denied:
                EmptyStateView(symbol: "lock.fill", title: "Contacts access is off",
                               message: "Turn on Contacts for Duo Dash in Settings to search everyone. Favourites still work without it: add people with the + tile.",
                               actionTitle: "Open Settings") { openSettings() }
            case .notDetermined:
                EmptyStateView(symbol: "person.crop.circle", title: "Search your contacts",
                               message: "Duo Dash needs Contacts access to list everyone.",
                               actionTitle: "Allow Access") { Task { await contacts.prepareDirectory() } }
            case .authorized, .limited:
                searchField
                if contacts.access == .limited {
                    Button { openSettings() } label: {
                        Label("Showing only the contacts you shared with Duo Dash", systemImage: "person.2.badge.key.fill")
                            .font(.dashCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                list
            }
        }
        .padding(.top, 6)
        .task { await contacts.prepareDirectory() }
        .confirmationDialog(choosing.map { ($0.favourite ? "Favourite " : "Call ") + $0.person.name } ?? "",
                            isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                            titleVisibility: .visible, presenting: choosing) { choice in
            ForEach(choice.person.numbers) { number in
                Button("\(number.label)  \(number.number)") { use(number, of: choice.person, favourite: choice.favourite) }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary).padding(.leading, 14)
            TextField("Search contacts", text: $query)
                .font(.dashBody)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .accessibilityIdentifier("phone.contacts.search")
            DictationButton(text: $query, identifier: "phone.contacts.dictate")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.minTouch, height: Theme.minTouch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(minHeight: Theme.minTouch)
        .background(Theme.surface, in: Capsule())
    }

    @ViewBuilder
    private var list: some View {
        let results = contacts.search(query)
        if contacts.isLoadingDirectory && contacts.directory.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            EmptyStateView(symbol: "person.fill.questionmark",
                           title: query.isEmpty ? "No contacts with phone numbers" : "No matches")
        } else {
            ScrollView {
                LazyVStack(spacing: Theme.gap) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, person in
                        HStack(spacing: Theme.gap) {
                            ListRow(title: person.name.isEmpty ? (person.numbers.first?.number ?? "") : person.name,
                                    subtitle: person.numbers.count == 1
                                        ? "\(person.numbers[0].label) \(person.numbers[0].number)"
                                        : "\(person.numbers.count) numbers",
                                    identifier: "phone.contact.\(index)") {
                                ContactAvatar(name: person.name, thumbnail: person.thumbnail, size: 44)
                            } action: {
                                call(person)
                            }
                            favouriteButton(person)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func favouriteButton(_ person: DirectoryContact) -> some View {
        let isFav = person.numbers.contains { contacts.isFavourite(contactID: person.id, number: $0.number) }
        return Button {
            guard !isFav else { return }
            choose(person, favourite: true)
        } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isFav ? Theme.warning : Theme.textSecondary)
                .frame(width: Theme.minTouch, height: Theme.minTouch + 8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(isFav ? "\(person.name) is a favourite" : "Add \(person.name) to favourites")
    }

    private func call(_ person: DirectoryContact) { choose(person, favourite: false) }

    /// One number: act straight away. Several: ask which.
    private func choose(_ person: DirectoryContact, favourite: Bool) {
        switch NumberChoice.resolve(person.numbers) {
        case .none:
            contacts.notice = "\(person.name) has no phone number."
        case .single(let number):
            use(number, of: person, favourite: favourite)
        case .multiple:
            choosing = Choice(person: person, favourite: favourite)
        }
    }

    private func use(_ number: LabeledNumber, of person: DirectoryContact, favourite: Bool) {
        if favourite {
            contacts.addFavourite(name: person.name, number: number, contactID: person.id, thumbnail: person.thumbnail)
        } else {
            contacts.call(Recipient(name: person.name, number: number.number, contactID: person.id, thumbnail: person.thumbnail))
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

