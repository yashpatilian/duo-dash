import SwiftUI
import UIKit

/// Settings for everything in Duo Dash, laid out like the iOS 26 Settings app: a searchable,
/// grouped list of colourful icons that pushes into each page (with a Liquid Glass back button),
/// or a sidebar and detail side by side when there's room, like Settings on iPad.
/// Every value is saved on the device (UserDefaults, or the Keychain for the Claude API key).
struct SettingsView: View {
    @State private var selection: SettingsSection?
    @State private var wideSelection: SettingsSection = .assistant
    @State private var query = ""

    enum SettingsSection: String, CaseIterable, Identifiable {
        case pro = "Duo Dash Pro", assistant = "AI Assistant", voice = "Voice & Dictation", notifications = "Notifications", navigation = "Navigation", places = "Saved Places",
             dock = "Dock", phone = "Phone & Messages", spotify = "Spotify", car = "Car", dashcam = "Dashcam", home = "Home",
             duoDock = "Duo Dash Mount", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .pro: "star.fill"
            case .assistant: "sparkles"
            case .voice: "waveform"
            case .notifications: "bell.badge.fill"
            case .navigation: "location.fill"
            case .places: "mappin"
            case .dock: "dock.rectangle"
            case .phone: "phone.fill"
            case .spotify: "headphones"
            case .car: "car.fill"
            case .dashcam: "video.fill"
            case .home: "house.fill"
            case .duoDock: "iphone.gen3.radiowaves.left.and.right"
            case .about: "info"
            }
        }
        /// Icon colours in the iOS Settings palette (systemIndigo, systemPink, systemBlue…).
        var tint: [Color] {
            switch self {
            case .pro: ProStyle.gold
            case .assistant: [Color(red: 0.69, green: 0.32, blue: 0.87), Color(red: 0.35, green: 0.34, blue: 0.84)]
            case .voice: [Color(red: 1.0, green: 0.27, blue: 0.42), Color(red: 0.85, green: 0.15, blue: 0.35)]
            case .notifications: [Color(red: 1.0, green: 0.23, blue: 0.19)]
            case .navigation: [Color(red: 0.04, green: 0.52, blue: 1.0)]
            case .places: [Color(red: 1.0, green: 0.27, blue: 0.23)]
            case .dock: [Color(red: 0.56, green: 0.56, blue: 0.58)]
            case .phone: [Color(red: 0.19, green: 0.82, blue: 0.35)]
            case .spotify: [Color(red: 0.12, green: 0.84, blue: 0.38), Color(red: 0.07, green: 0.55, blue: 0.25)]
            case .car: [Color(red: 0.19, green: 0.82, blue: 0.35)]
            case .dashcam: [Color(red: 0.39, green: 0.39, blue: 0.40)]
            case .home: [Color(red: 1.0, green: 0.62, blue: 0.04)]
            case .duoDock: [Color(red: 0.35, green: 0.34, blue: 0.84)]
            case .about: [Color(red: 0.56, green: 0.56, blue: 0.58)]
            }
        }
        /// Words that find this page in search, besides its name.
        var keywords: [String] {
            switch self {
            case .pro: ["pro", "subscription", "purchase", "restore", "theme", "accent", "colour", "color", "wallpaper", "icon", "layout", "trips", "history", "impact"]
            case .assistant: ["claude", "apple intelligence", "api key", "model", "siri", "ai"]
            case .voice: ["whisper", "kokoro", "speech", "microphone", "dictation", "tts"]
            case .notifications: ["announcements", "push", "alerts", "updates", "new version", "news"]
            case .navigation: ["maps", "guidance", "north up", "heading", "directions", "google maps", "waze", "navigate with"]
            case .places: ["favourites", "favorites", "home", "work", "address"]
            case .dock: ["apps", "order", "reorder", "apps on this iphone", "whatsapp", "youtube", "audible"]
            case .phone: ["calls", "messages", "texts", "recents", "contacts"]
            case .spotify: ["music", "sign in", "sign out", "client id", "developer app", "connect"]
            case .car: ["bluetooth", "shortcuts", "obd", "automation"]
            case .dashcam: ["camera", "recording", "loop", "lens", "ultra wide"]
            case .home: ["homekit", "garage", "lights", "arrival"]
            case .duoDock: ["mount", "holder", "buy", "website"]
            case .about: ["version", "welcome", "tour", "screen info"]
            }
        }
        /// The groups of the main list, like the gaps between groups in iOS Settings.
        static let groups: [[SettingsSection]] = [
            [.pro],
            [.assistant, .voice, .notifications],
            [.navigation, .places, .dock],
            [.phone, .spotify, .car, .dashcam, .home],
            [.duoDock],
            [.about],
        ].map { $0.filter(\.isListed) }
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 620 {
                // Wide: the list as a sidebar, the page beside it (Settings on iPad).
                HStack(spacing: 0) {
                    SettingsList(query: $query, highlighted: wideSelection, sidebar: true) { item in
                        withAnimation(.snappy) { wideSelection = item }
                    }
                    .frame(width: min(340, proxy.size.width * 0.38))
                    SettingsPage(section: wideSelection, back: nil)
                        .id(wideSelection)
                        .transition(.opacity)
                }
            } else {
                // Narrow: the list, pushing into each page.
                ZStack {
                    if let selection {
                        SettingsPage(section: selection) { withAnimation(.smooth(duration: 0.32)) { self.selection = nil } }
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    } else {
                        SettingsList(query: $query, highlighted: nil, sidebar: false) { item in
                            withAnimation(.smooth(duration: 0.32)) { selection = item }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
            }
        }
        .background(Theme.background)
        .accessibilityIdentifier("settings")
    }

    @ViewBuilder
    fileprivate static func content(_ item: SettingsSection) -> some View {
        switch item {
        case .pro: ProSettingsSection()
        case .assistant: AssistantSettingsSection()
        case .voice: SpeechSettingsSection()
        case .notifications: NotificationSettingsSection()
        case .navigation: NavigationSettingsSection()
        case .places: PlacesSettingsSection()
        case .dock: DockSettingsSection()
        case .phone: PhoneSettingsSection()
        case .spotify: SpotifySettingsSection()
        case .car: CarSettingsSection()
        case .dashcam: DashcamSettingsPage()
        case .home: SettingsGroup(footer: "Duo Dash never unlocks doors on its own. With automatic opening on, only the garage opens as you arrive.") { HomeArrivalSettingsView().padding(16) }
        case .duoDock: DuoDockSettingsSection()
        case .about: AboutSettingsSection()
        }
    }
}

// MARK: - The main list

/// The searchable, grouped list of settings pages, with the Duo Dash card on top.
private struct SettingsList: View {
    @Binding var query: String
    /// The open page in the sidebar layout (drawn selected, like iPad Settings).
    let highlighted: SettingsView.SettingsSection?
    /// The iPad-style sidebar: no values or chevrons, just icons and names.
    let sidebar: Bool
    let open: (SettingsView.SettingsSection) -> Void

    private var groups: [[SettingsView.SettingsSection]] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsView.SettingsSection.groups }
        let hits = SettingsView.SettingsSection.allCases.filter { item in
            item.isListed && (item.rawValue.lowercased().contains(q) || item.keywords.contains { $0.contains(q) })
        }
        return hits.isEmpty ? [] : [hits]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings").font(.system(size: 34, weight: .bold)).padding(.horizontal, 6).padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                SettingsSearchField(text: $query)
                if query.isEmpty { AppCard(compact: sidebar) { open(.about) } }
                if groups.isEmpty {
                    Text("No results for \u{201C}\(query)\u{201D}")
                        .font(.dashBody).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    SettingsGroup {
                        ForEach(Array(group.enumerated()), id: \.element) { index, item in
                            if index > 0 { RowDivider(inset: 66) }
                            SectionRow(item: item, selected: item == highlighted, sidebar: sidebar) { open(item) }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .scrollIndicators(.hidden)
    }
}

/// A row of the main list: icon, name, a short value and a chevron.
private struct SectionRow: View {
    let item: SettingsView.SettingsSection
    let selected: Bool
    var sidebar = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SettingsIcon(symbol: item.symbol, colors: item.tint)
                Text(item.rawValue).font(.dashBody.weight(.regular))
                    .foregroundStyle(selected ? .white : Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if !sidebar {
                    SectionValue(item: item).foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: Theme.minTouch + 2)
            .background(selected ? Theme.accent : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowPressStyle())
        .accessibilityIdentifier("settings.section.\(item)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The current value shown on the right of a main-list row, like "Off" or "On" in iOS Settings.
private struct SectionValue: View {
    let item: SettingsView.SettingsSection
    @Environment(AssistantSettings.self) private var assistant
    @Environment(NavigationModel.self) private var navigation
    @Environment(FavouritesStore.self) private var favourites
    @Environment(ProStore.self) private var pro

    var body: some View {
        Group {
            switch item {
            case .pro: Text(pro.isPro ? "Active" : "")
            case .dashcam where !ProGate.dashcamAvailable(edition: .current, isPro: pro.isPro): ProBadge()
            case .assistant: Text(assistant.provider.title)
            case .navigation: Text(navigation.voiceEnabled ? "Voice on" : "Voice off")
            case .places: Text("\(favourites.places.count)")
            default: EmptyView()
            }
        }
        .font(.dashBody.weight(.regular))
        .lineLimit(1)
    }
}

/// The Duo Dash card at the top of the list, where iOS Settings shows the Apple Account.
private struct AppCard: View {
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.15, green: 0.55, blue: 1.0), Color(red: 0.35, green: 0.25, blue: 0.9)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "rectangle.split.2x1.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Duo Dash").font(.system(size: 22, weight: .semibold))
                    Text(compact ? "Version \(AppVersion.text)" : "Version \(AppVersion.text) · Welcome tour, screen info")
                        .font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white.opacity(0.3))
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("settings.appCard")
    }
}

/// The search field above the list, a Liquid Glass capsule like iOS 26.
private struct SettingsSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("Search", text: $text)
                .font(.dashBody.weight(.regular))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.search)
                .accessibilityIdentifier("settings.search")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

// MARK: - A page

/// One settings page: a Liquid Glass back button (when pushed), the title, then its groups.
private struct SettingsPage: View {
    let section: SettingsView.SettingsSection
    /// nil in the sidebar layout, where there's nothing to go back to.
    let back: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let back {
                    HStack {
                        Button(action: back) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 52, height: 52)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings.back")
                        Spacer()
                    }
                }
                HStack(spacing: 14) {
                    SettingsIcon(symbol: section.symbol, colors: section.tint, size: 44)
                    Text(section.rawValue).font(.system(size: 30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                SettingsView.content(section)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .scrollIndicators(.hidden)
    }
}

// MARK: - Building blocks

/// Shared measurements for the Settings look.
enum SettingsStyle {
    /// iOS 26 inset-grouped corner radius.
    static let corner: CGFloat = 26
}

enum AppVersion {
    static var text: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// The rounded-square icon: a white symbol on a colour with the faint top light iOS icons have.
private struct SettingsIcon: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(LinearGradient(colors: colors.count > 1 ? colors : [colors[0].opacity(0.88), colors[0]],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// Rows highlight grey while pressed, like a list cell (no shrinking).
private struct SettingsRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Color.white.opacity(configuration.isPressed ? 0.08 : 0))
    }
}

/// A rounded group of rows, like an inset-grouped list.
private struct SettingsGroup<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header).font(.dashCaption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 18)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.dashCaption.weight(.regular))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 18)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dashBody.weight(.regular))
                if let subtitle {
                    Text(subtitle).font(.dashCaption.weight(.regular)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(minHeight: Theme.minTouch + 2)
    }
}

private struct RowDivider: View {
    var inset: CGFloat = 18
    var body: some View { Theme.separator.frame(height: 0.5).padding(.leading, inset) }
}

/// A segmented choice: the iOS 26 capsule control, car-sized.
private struct BigSegments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var identifier: String
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button { withAnimation(.snappy) { selection = value } } label: {
                    Text(title)
                        .font(.dashCaption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background {
                            if selection == value {
                                Capsule().fill(Color(white: 0.39))
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifier).\(value)")
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color(white: 0.46, opacity: 0.24), in: Capsule())
        .padding(12)
    }
}

// MARK: - Sections

private struct AssistantSettingsSection: View {
    @Environment(AssistantSettings.self) private var settings
    @State private var keyDraft = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(footer: providerFooter) {
                BigSegments(options: AssistantProvider.allCases.map { ($0, $0.title) },
                            selection: $settings.provider, identifier: "settings.provider")
                RowDivider()
                SettingsRow(title: "Status", subtitle: status.text) {
                    Image(systemName: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(status.ok ? Theme.positive : Theme.warning)
                }
                RowDivider()
                SettingsRow(title: "Speak replies", subtitle: "Read the assistant's answers aloud (music ducks).") {
                    Toggle("", isOn: $settings.speaksReplies).labelsHidden().tint(Theme.positive)
                        .accessibilityIdentifier("settings.speaksReplies")
                }
            }

            SettingsGroup(header: "CLAUDE", footer: "The key is stored in this iPhone's Keychain and is only sent to Anthropic. When Claude is selected, what you ask, your approximate location, your route and any contact you name are sent to Anthropic to answer; Claude can also search the web (e.g. for reviews).") {
                if settings.hasClaudeKey {
                    SettingsRow(title: "API key", subtitle: "Saved in the Keychain") {
                        DashPillButton(title: "Remove", prominent: false, identifier: "settings.claudeKey.remove") {
                            settings.clearClaudeKey()
                            testResult = nil
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(Theme.textSecondary)
                        SecureField("Paste your Claude API key", text: $keyDraft)
                            .font(.dashBody)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("settings.claudeKey")
                        DashPillButton(title: "Save", identifier: "settings.claudeKey.save") {
                            let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !key.isEmpty else { return }
                            settings.setClaudeKey(key)
                            keyDraft = ""
                            testResult = nil
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: Theme.minTouch + 10)
                }
                RowDivider()
                SettingsRow(title: "Test connection", subtitle: testResult) {
                    if testing {
                        ProgressView()
                    } else {
                        DashPillButton(title: "Test", prominent: false, identifier: "settings.claudeKey.test") {
                            Task { await test() }
                        }
                        .disabled(!settings.hasClaudeKey)
                    }
                }
                RowDivider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thinking effort").font(.dashBody.weight(.regular)).padding(.horizontal, 18).padding(.top, 12)
                    BigSegments(options: AssistantSettings.effortOptions.map { ($0, $0.capitalized) },
                                selection: $settings.claudeEffort, identifier: "settings.effort")
                }
                RowDivider()
                HStack(spacing: 10) {
                    Text("Model").font(.dashBody.weight(.regular))
                    TextField("claude-opus-5-5", text: $settings.claudeModel)
                        .font(.dashBody.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.claudeModel")
                    DictationButton(text: $settings.claudeModel, identifier: "settings.claudeModel.dictate")
                }
                .padding(.leading, 18)
                .frame(minHeight: Theme.minTouch + 2)
            }
        }
    }

    private var providerFooter: String {
        settings.provider == .appleIntelligence
            ? "Apple Intelligence runs on the iPhone: private, free, works without a key. It can't read reviews."
            : "Claude runs in the cloud with your API key: stronger answers and live web search (reviews, opening hours). Uses mobile data."
    }

    private var status: (ok: Bool, text: String) {
        switch settings.provider {
        case .appleIntelligence:
            if let reason = AppleIntelligenceBrain.unavailableReason { return (false, reason) }
            return (true, "Ready on this iPhone")
        case .claude:
            if !settings.hasClaudeKey { return (false, "Add your API key below. Until then the basic voice commands still work.") }
            if testOK, let testResult { return (true, testResult) }
            return (true, "Key saved")
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        switch await settings.testClaudeKey() {
        case .success(let message):
            testOK = true
            testResult = message.isEmpty ? "Connected" : message
        case .failure(let error):
            testOK = false
            testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct NavigationSettingsSection: View {
    @Environment(NavigationModel.self) private var navigation
    @AppStorage(MapOrientation.storageKey) private var orientation: MapOrientation = .headingUp

    var body: some View {
        @Bindable var navigation = navigation
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(footer: "Spoken turn-by-turn directions. Music is ducked while a prompt plays. You can also toggle this from the speaker button while navigating.") {
                SettingsRow(title: "Voice guidance") {
                    Toggle("", isOn: $navigation.voiceEnabled).labelsHidden().tint(Theme.positive)
                        .accessibilityIdentifier("settings.voiceGuidance")
                }
            }
            SettingsGroup(footer: "How the map turns while you're just looking around. During guidance it always follows your heading.") {
                BigSegments(options: [(MapOrientation.headingUp, "Heading up"), (MapOrientation.northUp, "North up")],
                            selection: $orientation, identifier: "settings.mapOrientation")
            }
            NavigateWithGroup(handoff: navigation.handoff)
        }
    }
}

private struct PlacesSettingsSection: View {
    @Environment(FavouritesStore.self) private var favourites
    @State private var editor: PlacesEditorTarget?

    var body: some View {
        SettingsGroup(footer: "Your one-tap destinations on Home and in Maps. Add, rename, give them an emoji, set their address, and reorder them.") {
            SettingsRow(title: "Saved places", subtitle: summary) {
                DashPillButton(title: "Edit", identifier: "settings.places.edit") {
                    editor = PlacesEditorTarget(placeID: nil)
                }
            }
        }
        .placesEditor($editor)
    }

    private var summary: String {
        let set = favourites.places.filter { $0.location != nil }.count
        return "\(favourites.places.count) places, \(set) with an address"
    }
}

private struct DockSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(footer: "To reorder the apps, press and hold an icon in the dock, then drag it. The dock scrolls when there are more apps than fit.") {
                SettingsRow(title: "Reset app order") {
                    DashPillButton(title: "Reset", prominent: false, identifier: "settings.dock.reset") {
                        withAnimation(.snappy) { app.resetDockOrder() }
                    }
                }
            }
            ExternalAppsGroup()
        }
    }
}

/// Settings → Navigation → "Navigate with": Duo Dash's own guidance, or Google Maps / Waze once installed.
private struct NavigateWithGroup: View {
    @Bindable var handoff: NavigationHandoff

    var body: some View {
        SettingsGroup(header: "NAVIGATE WITH", footer: ExternalNavigationCopy.settingsFooter) {
            ForEach(Array(NavigationApp.allCases.enumerated()), id: \.element) { index, choice in
                if index > 0 { RowDivider() }
                let installed = handoff.isInstalled(choice)
                Button {
                    withAnimation(.snappy) { handoff.preferred = choice }
                } label: {
                    SettingsRow(title: choice == .appleMaps ? "Apple Maps (in Duo Dash)" : choice.title,
                                subtitle: installed ? nil : "Not installed") {
                        if handoff.preferred == choice {
                            Image(systemName: "checkmark").font(.dashBody).foregroundStyle(Theme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsRowPressStyle())
                .disabled(!installed)
                .opacity(installed ? 1 : 0.45)
                .accessibilityIdentifier("settings.navApp.\(choice.rawValue)")
                .accessibilityAddTraits(handoff.preferred == choice ? .isSelected : [])
            }
        }
    }
}

/// Settings → Dock → "Apps on this iPhone": popular apps found on the phone, each with a switch
/// that adds its tile to the dock. Every installed one is always in the app grid.
private struct ExternalAppsGroup: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsGroup(header: "APPS ON THIS IPHONE", footer: footer) {
            if app.installedApps.isEmpty {
                SettingsRow(title: "None found", subtitle: "Google Maps, Waze, WhatsApp, Audible and others appear here once installed.") { EmptyView() }
            }
            ForEach(Array(app.installedApps.enumerated()), id: \.element) { index, external in
                if index > 0 { RowDivider(inset: 74) }
                HStack(spacing: 14) {
                    ExternalAppTile(app: external, size: 42)
                    Text(external.name).font(.dashBody.weight(.regular))
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(get: { app.isInDock(external) },
                                             set: { on in withAnimation(.snappy) { app.setInDock(external, on) } }))
                        .labelsHidden()
                        .tint(Theme.positive)
                        .accessibilityLabel("\(external.name) in the dock")
                        .accessibilityIdentifier("settings.dock.ext.\(external.id)")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .frame(minHeight: Theme.minTouch + 2)
            }
        }
    }

    private var footer: String {
        "Tiles open the app itself. They're drawn by Duo Dash (no logos), and every app here is also in the app grid. Apps you delete disappear from the dock on their own."
    }
}

private struct PhoneSettingsSection: View {
    @Environment(ContactsStore.self) private var contacts
    @State private var confirmClear = false

    var body: some View {
        SettingsGroup(footer: "iOS doesn't let apps read your call history or texts, so Recents only lists calls and messages started from Duo Dash. Favourite contacts are managed on the Phone screen.") {
            SettingsRow(title: "Duo Dash recents", subtitle: "\(contacts.recents.count) entries") {
                DashPillButton(title: "Clear", prominent: false, identifier: "settings.recents.clear") {
                    confirmClear = true
                }
                .disabled(contacts.recents.isEmpty)
            }
        }
        .confirmationDialog("Clear all Duo Dash recents?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Recents", role: .destructive) { contacts.clearRecents() }
        }
    }
}

private struct CarSettingsSection: View {
    var body: some View {
        SettingsGroup(footer: "iOS doesn't let an app open itself when Bluetooth connects, so this uses a Shortcuts automation, which iOS runs for you.") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open Duo Dash when the car connects").font(.dashBody)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.dashCaption.weight(.bold))
                            .frame(width: 26, height: 26)
                            .background(Theme.surfaceRaised, in: Circle())
                        Text(step).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    }
                }
                DashPillButton(title: "Open Shortcuts", symbol: "arrow.up.forward.app", identifier: "settings.car.shortcuts") {
                    if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
    }

    private let steps = [
        "In Shortcuts, tap Automation, then +.",
        "Choose Bluetooth, pick your car and select Is Connected.",
        "Choose Run Immediately.",
        "Add the action Open Duo Dash (optionally pick a screen, e.g. Maps).",
    ]
}

private struct DuoDockSettingsSection: View {
    var body: some View {
        SettingsGroup(footer: "Duo Dash works in any mount; the Duo Dash mount is made for it.") {
            VStack(alignment: .leading, spacing: 14) {
                FittedArt(maxScale: 1.3) { DuoDockIllustration() }
                    .frame(height: 210)
                    .accessibilityIdentifier("settings.dock.illustration")
                Text(DuoDockCopy.headline).font(.dashTitle)
                Text(DuoDockCopy.price).font(.dashCaption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.dock.price")
                Text(DuoDockCopy.about).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.dock.about")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(DuoDockCopy.benefits, id: \.text) { benefit in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: benefit.symbol)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28, height: 28)
                            Text(benefit.text).font(.dashCaption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.dock.benefits")
                Button {
                    UIApplication.shared.open(DockStore.url)
                } label: {
                    Label("Register your interest", systemImage: "arrow.up.forward")
                        .font(.dashBody)
                        .padding(.horizontal, 10)
                        .frame(minHeight: Theme.minTouch)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
                .accessibilityIdentifier("settings.dock.visit")
            }
            .padding(16)
        }
    }
}

private struct AboutSettingsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(OnboardingModel.self) private var onboarding

    var body: some View {
        SettingsGroup(footer: Edition.safetyNotice + "\n\n" + Edition.notAffiliatedNotice) {
            SettingsRow(title: "Version") { Text(AppVersion.text).font(.dashBody.weight(.regular)).foregroundStyle(Theme.textSecondary) }
            RowDivider()
            Button { onboarding.restart() } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show the welcome tour").font(.dashBody.weight(.regular)).foregroundStyle(Theme.accent)
                        Text("Music setup, a short tour and permissions").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: Theme.minTouch + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowPressStyle())
            .accessibilityIdentifier("onboarding.showAgain")
            RowDivider()
            SettingsRow(title: "Screen info", subtitle: "Real screen, window, safe-area and hinge numbers") {
                DashPillButton(title: "Show", prominent: false, identifier: "settings.screenInfo") {
                    app.showScreenInfo = true
                }
            }
        }
    }
}
