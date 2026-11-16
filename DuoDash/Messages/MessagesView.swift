import SwiftUI
import MessageUI

/// CarPlay-style Messages: pick a person, dictate or tap a quick reply, then
/// Apple's compose sheet opens pre-filled (iOS requires the user to tap Send).
struct MessagesView: View {
    @Environment(ContactsStore.self) private var contacts
    @AppStorage("messages.tab") private var tab: MessagesTab = .favourites
    @State private var recipient: Recipient?

    enum MessagesTab: String, CaseIterable, Identifiable {
        case favourites, recents, new
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .favourites: "star.fill"
            case .recents: "clock.fill"
            case .new: "square.and.pencil"
            }
        }
    }

    var body: some View {
        Group {
            if let recipient {
                ComposeView(recipient: recipient) {
                    withAnimation(.snappy) { self.recipient = nil }
                }
                .id(recipient.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: Theme.gap) {
                    DashTabBar(tabs: MessagesTab.allCases, selection: $tab,
                               title: \.title, symbol: \.symbol, identifier: { "messages.tab.\($0.rawValue)" })
                    Group {
                        switch tab {
                        case .favourites:
                            FavouritesGrid(idPrefix: "messages", badge: "message.fill",
                                           emptyMessage: "Add the people you text most.") { open($0.recipient) }
                        case .recents:
                            DashRecentsList(kind: .message, idPrefix: "messages") { open($0.recipient) }
                        case .new:
                            NewMessageView { open($0) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, 6)
            }
        }
        .overlay(alignment: .bottom) { ContactsNoticeBanner() }
        .onChange(of: contacts.pendingCompose, initial: true) { _, pending in
            // Opened from elsewhere (e.g. the Home favourites strip).
            guard let pending else { return }
            contacts.pendingCompose = nil
            open(pending)
        }
    }

    private func open(_ person: Recipient) {
        var person = person
        if person.thumbnail == nil { person.thumbnail = contacts.thumbnail(for: person) }
        withAnimation(.snappy) { recipient = person }
    }
}

/// Start a message to someone not on the favourites list.
struct NewMessageView: View {
    let onChoose: (Recipient) -> Void
    @State private var number = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DashPillButton(title: "Choose from Contacts", symbol: "person.crop.circle.badge.plus",
                               identifier: "messages.new.pick") {
                    ContactPicker.present { picked in
                        onChoose(Recipient(name: picked.name, number: picked.number.number,
                                           contactID: picked.contactID, thumbnail: picked.thumbnail))
                    }
                }
                Text("or enter a number").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    TextField("Phone number", text: $number)
                        .font(.dashBody)
                        .keyboardType(.phonePad)
                        .padding(.leading, 18)
                        .accessibilityIdentifier("messages.new.number")
                    DictationButton(text: $number, identifier: "messages.new.dictate")
                }
                .frame(minHeight: Theme.minTouch)
                .background(Theme.surface, in: Capsule())
                .frame(maxWidth: 480)
                DashPillButton(title: "Next", symbol: "arrow.right", identifier: "messages.new.next") {
                    onChoose(Recipient(name: "", number: number.trimmingCharacters(in: .whitespaces)))
                }
                .disabled(PhoneNumber.digits(number).isEmpty)
                .opacity(PhoneNumber.digits(number).isEmpty ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.immediately)
    }
}

/// Big text field with the voice button, quick replies, and Send.
struct ComposeView: View {
    @Environment(ContactsStore.self) private var contacts
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dashMetrics) private var metrics
    let recipient: Recipient
    let onClose: () -> Void

    @State private var text = ""
    @State private var unavailable = false
    @FocusState private var focused: Bool

    static let quickReplies = ["On my way", "Running late", "Here", "Call you soon"]

    var body: some View {
        VStack(spacing: Theme.gap) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    field
                    replies
                    if unavailable {
                        Label("This device can't send text messages (the Simulator, or no SIM / iMessage). Nothing was sent.",
                              systemImage: "exclamationmark.bubble.fill")
                            .font(.dashCaption)
                            .foregroundStyle(Theme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityIdentifier("messages.compose.unavailable")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.top, 6)
    }

    private var header: some View {
        HStack(spacing: 12) {
            DashIconButton(symbol: "chevron.left", label: "Back", identifier: "messages.compose.back") { onClose() }
            ContactAvatar(name: recipient.name, thumbnail: recipient.thumbnail, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipient.displayName).font(.dashBody).lineLimit(1)
                if !recipient.name.isEmpty {
                    Text(recipient.number).font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            sendButton
        }
    }

    private var field: some View {
        HStack(alignment: .top, spacing: 4) {
            TextField("Message", text: $text, axis: .vertical)
                .font(.system(size: 24, weight: .medium))
                .lineLimit(metrics.isCompact ? 2...4 : 3...6)
                .focused($focused)
                .padding(.leading, 18)
                .padding(.vertical, 16)
                .accessibilityIdentifier("messages.compose.field")
            DictationButton(text: $text, identifier: "messages.compose.dictate")
                .padding(.top, 4)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.minTouch, height: Theme.minTouch)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel("Clear message")
                .accessibilityIdentifier("messages.compose.clear")
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    /// "On my way, ETA 5:42" while a route is active.
    private var etaReply: String? {
        guard navigation.isGuiding, let eta = navigation.eta else { return nil }
        return "On my way, ETA \(eta.formatted(date: .omitted, time: .shortened))"
    }

    private var replies: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.gap)], spacing: Theme.gap) {
            if let etaReply {
                replyButton(etaReply, symbol: "car.fill", id: "messages.quick.eta")
            }
            ForEach(Array(Self.quickReplies.enumerated()), id: \.offset) { index, reply in
                replyButton(reply, symbol: nil, id: "messages.quick.\(index)")
            }
        }
    }

    private func replyButton(_ reply: String, symbol: String?, id: String) -> some View {
        Button {
            text = reply
            focused = false
        } label: {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(reply).lineLimit(1).minimumScaleFactor(0.75)
            }
            .font(.dashBody)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
            .background(Theme.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(reply)
        .accessibilityIdentifier(id)
    }

    private var sendButton: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button { send() } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .background(empty ? Theme.surfaceRaised : Theme.accent, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(empty)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("messages.compose.send")
    }

    private func send() {
        focused = false
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let person = recipient
        let shown = MessageComposer.present(to: person.number, body: body) { result in
            if result == .sent {
                contacts.logRecent(.message, to: person)
                text = ""
                onClose()
            } else if result == .failed {
                contacts.notice = "The message wasn't sent."
            }
        }
        unavailable = !shown
    }
}
