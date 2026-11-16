import SwiftUI
import UIKit

/// Round contact photo, or initials on a grey circle (CarPlay style).
struct ContactAvatar: View {
    var name: String
    var thumbnail: Data?
    var size: CGFloat = 80

    var body: some View {
        Group {
            if let thumbnail, let image = UIImage(data: thumbnail) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.56), Color(white: 0.40)], startPoint: .top, endPoint: .bottom)
                    if initials.isEmpty {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.42, weight: .semibold))
                    } else {
                        Text(initials)
                            .font(.system(size: size * 0.38, weight: .semibold))
                            .minimumScaleFactor(0.5)
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
            .filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

/// Big tab buttons along the top of Phone and Messages, like Music's.
struct DashTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    var title: (Tab) -> String
    var symbol: (Tab) -> String
    var identifier: (Tab) -> String

    @State private var width: CGFloat = 1000

    var body: some View {
        // Text labels when they fit (about 130 pt a tab), icons only on narrow windows.
        bar(iconOnly: width < CGFloat(tabs.count) * 136)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch, maxHeight: Theme.minTouch)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func bar(iconOnly: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(tabs) { tab in
                let selected = selection == tab
                Button {
                    withAnimation(.snappy) { selection = tab }
                } label: {
                    Label(title(tab), systemImage: symbol(tab))
                        .labelStyle(DashLabelStyle(iconOnly: iconOnly))
                        .font(.dashCaption)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, iconOnly ? 10 : 18)
                        .frame(maxWidth: iconOnly ? .infinity : nil, minHeight: Theme.minTouch - 8)
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .glassEffect(selected ? .regular : .identity, in: Capsule())
                        .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(title(tab))
                .accessibilityIdentifier(identifier(tab))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if !iconOnly { Spacer(minLength: 0) }
        }
    }
}

/// One favourite: big round avatar, name below.
struct FavouriteTile: View {
    let favourite: FavouriteContact
    var avatarSize: CGFloat = 92
    var badge: String? = nil
    var identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ContactAvatar(name: favourite.name, thumbnail: favourite.thumbnail, size: avatarSize)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge {
                            Image(systemName: badge)
                                .font(.system(size: avatarSize * 0.16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: avatarSize * 0.32, height: avatarSize * 0.32)
                                .background(Theme.positive, in: Circle())
                                .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                        }
                    }
                Text(firstName)
                    .font(avatarSize >= 110 ? .dashBody : .dashCaption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: avatarSize + 24)
            }
            .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(favourite.name)
        .accessibilityValue(favourite.numberLabel)
        .accessibilityIdentifier(identifier)
    }

    private var firstName: String {
        favourite.name.split(separator: " ").first.map(String.init) ?? favourite.name
    }
}

/// Grid of favourites with an add tile at the end, and an edit list for
/// reordering and removing.
struct FavouritesGrid: View {
    @Environment(ContactsStore.self) private var contacts
    @Environment(\.dashMetrics) private var metrics
    var idPrefix: String
    var badge: String
    var emptyMessage: String
    var recentKind: RecentEntry.Kind
    let onTap: (FavouriteContact) -> Void
    var onRecent: (RecentEntry) -> Void = { _ in }

    @State private var editing = false

    var body: some View {
        if contacts.favourites.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    EmptyStateView(symbol: "star.fill", title: "No favourites yet",
                                   message: emptyMessage + " Duo Dash keeps its own list: iOS doesn't let apps read the Phone app's Favourites.")
                    DashPillButton(title: "Add Favourite", symbol: "plus", identifier: "\(idPrefix).add") { addFavourite() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        } else if editing {
            editList
        } else {
            grid
        }
    }

    /// Avatars grow to fill the width: up to five across, never smaller than the old fixed size.
    private func layout(width: CGFloat, height: CGFloat) -> (columns: Int, avatar: CGFloat) {
        let count = contacts.favourites.count + 1                      // + the add tile
        let fit = max(3, Int(width / 150))                             // ~150 pt per tile at most density
        let columns = max(3, min(5, min(count, fit)))
        let tile = (width - CGFloat(columns - 1) * 12) / CGFloat(columns)
        let floor: CGFloat = metrics.isCompact ? 80 : 96
        // Short windows (phone landscape): a row of tiles must leave room below for the edit button.
        let byHeight = (height - Theme.minTouch - 40) * 0.62
        return (columns, max(floor, min(150, tile - 28, byHeight)))
    }

    private var grid: some View {
        GeometryReader { proxy in
            let (columns, avatar) = layout(width: proxy.size.width - Theme.minTouch, height: proxy.size.height)
            let recents = Array(contacts.recents(of: recentKind).prefix(proxy.size.height > 560 ? 4 : 2))
            let showsRecents = !recents.isEmpty && proxy.size.height > 380
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 18) {
                        ForEach(Array(contacts.favourites.enumerated()), id: \.element.id) { index, fav in
                            FavouriteTile(favourite: fav, avatarSize: avatar, badge: badge,
                                          identifier: "\(idPrefix).fav.\(index)") { onTap(fav) }
                                .contextMenu {
                                    Button("Remove", systemImage: "star.slash", role: .destructive) {
                                        contacts.removeFavourite(id: fav.id)
                                    }
                                }
                        }
                        addTile(avatar: avatar)
                    }
                    if showsRecents {
                        VStack(alignment: .leading, spacing: Theme.gap) {
                            Text("Recent").font(.dashTitle)
                            ForEach(Array(recents.enumerated()), id: \.element.id) { index, entry in
                                ListRow(title: entry.name.isEmpty ? entry.number : entry.name,
                                        subtitle: entry.date.formatted(.relative(presentation: .named)),
                                        identifier: "\(idPrefix).favrecent.\(index)") {
                                    ContactAvatar(name: entry.name, thumbnail: contacts.thumbnail(for: entry.recipient), size: 44)
                                } action: {
                                    onRecent(entry)
                                }
                            }
                        }
                        .padding(.trailing, Theme.minTouch + 8)          // keep clear of the edit button
                    }
                }
                .padding(.vertical, 12)
                // With little to show, sit in the middle rather than stuck to the top.
                .frame(minHeight: showsRecents ? nil : proxy.size.height - Theme.minTouch, alignment: .center)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            DashIconButton(symbol: "pencil", label: "Edit favourites", identifier: "\(idPrefix).edit") {
                withAnimation(.snappy) { editing = true }
            }
            .padding(4)
        }
    }

    private func addTile(avatar: CGFloat) -> some View {
        Button { addFavourite() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: avatar * 0.36, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: avatar, height: avatar)
                    .background(Theme.surface, in: Circle())
                Text("Add").font(avatar >= 110 ? .dashBody : .dashCaption).foregroundStyle(Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Add favourite")
        .accessibilityIdentifier("\(idPrefix).add")
    }

    private var editList: some View {
        VStack(spacing: Theme.gap) {
            HStack {
                Text("Drag to reorder").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                Spacer()
                DashPillButton(title: "Done", identifier: "\(idPrefix).done") {
                    withAnimation(.snappy) { editing = false }
                }
            }
            List {
                ForEach(contacts.favourites) { fav in
                    HStack(spacing: 14) {
                        ContactAvatar(name: fav.name, thumbnail: fav.thumbnail, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fav.name).font(.dashBody).lineLimit(1)
                            Text("\(fav.numberLabel) \(fav.number)").font(.dashCaption)
                                .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button {
                            withAnimation { contacts.removeFavourite(id: fav.id) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(Theme.danger)
                                .frame(width: Theme.minTouch, height: Theme.minTouch)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(fav.name)")
                    }
                    .frame(minHeight: Theme.minTouch)
                    .listRowBackground(Theme.surface)
                }
                .onMove { contacts.moveFavourites(fromOffsets: $0, toOffset: $1) }
                .onDelete { contacts.removeFavourites(atOffsets: $0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .padding(.top, 6)
    }

    private func addFavourite() {
        ContactPicker.present { picked in
            contacts.addFavourite(name: picked.name, number: picked.number,
                                  contactID: picked.contactID, thumbnail: picked.thumbnail)
        }
    }
}

/// Duo Dash's own recents (calls or messages started here), newest first.
struct DashRecentsList: View {
    @Environment(ContactsStore.self) private var contacts
    var kind: RecentEntry.Kind
    var idPrefix: String
    let onTap: (RecentEntry) -> Void

    var body: some View {
        let items = contacts.recents(of: kind)
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack {
                Text(kind == .call ? "Calls from Duo Dash" : "Messages from Duo Dash")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("\(idPrefix).recents.title")
                Spacer()
                if !items.isEmpty {
                    DashPillButton(title: "Clear", prominent: false, identifier: "\(idPrefix).recents.clear") {
                        withAnimation { contacts.clearRecents(of: kind) }
                    }
                }
            }
            if items.isEmpty {
                EmptyStateView(symbol: "clock.fill", title: "No recents",
                               message: kind == .call
                                   ? "Calls you start from Duo Dash show here. iOS doesn't let apps read the Phone app's call history."
                                   : "Messages you send from Duo Dash show here. iOS doesn't let apps read Messages history.")
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.gap) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                            ListRow(title: entry.name.isEmpty ? entry.number : entry.name,
                                    subtitle: entry.date.formatted(.relative(presentation: .named)),
                                    identifier: "\(idPrefix).recent.\(index)") {
                                ContactAvatar(name: entry.name, thumbnail: contacts.thumbnail(for: entry.recipient), size: 44)
                            } action: {
                                onTap(entry)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }
}

/// Short message at the bottom of a screen that clears itself.
struct ContactsNoticeBanner: View {
    @Environment(ContactsStore.self) private var contacts

    var body: some View {
        if let message = contacts.notice {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.dashCaption)
                .padding(14)
                .background(Theme.surfaceRaised, in: Capsule())
                .padding(12)
                .onTapGesture { contacts.notice = nil }
                .accessibilityIdentifier("contacts.notice")
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(5))
                    if contacts.notice == message { contacts.notice = nil }
                }
        }
    }
}

/// The first few favourites with call and message buttons, for the Home
/// dashboard. Message opens the Messages screen with a compose view.
struct FavouriteContactsStrip: View {
    @Environment(ContactsStore.self) private var contacts
    @Environment(AppModel.self) private var app
    var limit: Int = 4
    var avatarSize: CGFloat = 64

    var body: some View {
        let favs = Array(contacts.favourites.prefix(limit))
        if favs.isEmpty {
            Button { app.open(.phone) } label: {
                Label("Add favourites in Phone", systemImage: "star.fill")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("favstrip.empty")
        } else {
            // As many people as fit side by side (each needs room for two buttons).
            GeometryReader { proxy in
                let fit = max(1, Int((proxy.size.width + 10) / (2 * Theme.minTouch + 14)))
                row(Array(favs.prefix(fit)))
            }
            .frame(height: avatarSize + 6 + 22 + 6 + Theme.minTouch)
        }
    }

    private func row(_ favs: [FavouriteContact]) -> some View {
        HStack(alignment: .top, spacing: 10) {
                ForEach(Array(favs.enumerated()), id: \.element.id) { index, fav in
                    VStack(spacing: 6) {
                        ContactAvatar(name: fav.name, thumbnail: fav.thumbnail, size: avatarSize)
                        Text(fav.name.split(separator: " ").first.map(String.init) ?? fav.name)
                            .font(.dashCaption).lineLimit(1)
                        HStack(spacing: 4) {
                            stripButton("phone.fill", label: "Call \(fav.name)", id: "favstrip.call.\(index)") {
                                contacts.call(fav.recipient)
                            }
                            stripButton("message.fill", label: "Message \(fav.name)", id: "favstrip.message.\(index)") {
                                contacts.pendingCompose = fav.recipient
                                app.open(.messages)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
        }
    }

    private func stripButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .background(Theme.surfaceRaised, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
