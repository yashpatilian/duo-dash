import SwiftUI
import UIKit

/// Settings for everything in Duo Dash. Every value here is saved on the device
/// (UserDefaults, or the Keychain for the Claude API key) and survives relaunches.
struct SettingsView: View {
    @Environment(\.dashMetrics) private var metrics
    @State private var section: SettingsSection = .assistant

    enum SettingsSection: String, CaseIterable, Identifiable {
        case assistant = "AI Assistant", voice = "Voice & Dictation", navigation = "Navigation", places = "Saved Places",
             dock = "Dock", phone = "Phone & Messages", car = "Car", dashcam = "Dashcam", home = "Home",
             duoDock = "Duo Dock", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .assistant: "sparkles"
            case .voice: "waveform"
            case .navigation: "location.north.fill"
            case .places: "mappin.and.ellipse"
            case .dock: "square.grid.2x2.fill"
            case .phone: "phone.fill"
            case .car: "car.fill"
            case .dashcam: "video.fill"
            case .home: "house.fill"
            case .duoDock: "rectangle.split.2x1.fill"
            case .about: "info.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .assistant: Color(red: 0.55, green: 0.36, blue: 0.96)
            case .voice: Color(red: 0.98, green: 0.30, blue: 0.45)
            case .navigation: Theme.accent
            case .places: Theme.danger
            case .dock: Color(white: 0.45)
            case .phone: Theme.positive
            case .car: Theme.warning
            case .dashcam: Theme.danger
            case .home: Color(red: 0.98, green: 0.6, blue: 0.15)
            case .duoDock: Theme.accent
            case .about: Color(white: 0.45)
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 620 {
                // Wide: section list on the left, detail on the right (like Settings on iPad).
                HStack(spacing: Theme.gap) {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(SettingsSection.allCases) { item in sectionRow(item, selected: item == section) }
                        }
                    }
                    .frame(width: min(300, proxy.size.width * 0.36))
                    detail(section)
                }
            } else {
                // Narrow: one scrolling page with every section.
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(SettingsSection.allCases) { item in
                            SettingsHeader(item)
                            sectionContent(item)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .accessibilityIdentifier("settings")
    }

    private func sectionRow(_ item: SettingsSection, selected: Bool) -> some View {
        Button { withAnimation(.snappy) { section = item } } label: {
            HStack(spacing: 14) {
                SettingsIcon(symbol: item.symbol, tint: item.tint)
                Text(item.rawValue).font(.dashBody).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Theme.minTouch + 4)
            .background(selected ? Theme.surfaceRaised : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("settings.section.\(item)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func detail(_ item: SettingsSection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsHeader(item)
                sectionContent(item)
            }
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.immediately)
        .id(item)
    }

    @ViewBuilder
    private func sectionContent(_ item: SettingsSection) -> some View {
        switch item {
        case .assistant: AssistantSettingsSection()
        case .voice: SpeechSettingsSection()
        case .navigation: NavigationSettingsSection()
        case .places: PlacesSettingsSection()
        case .dock: DockSettingsSection()
        case .phone: PhoneSettingsSection()
        case .car: CarSettingsSection()
        case .dashcam: SettingsGroup(footer: "The rear camera records the road while Duo Dash is on screen. iOS stops the camera when the phone locks or another app is in front.") { DashcamSettingsPanel().padding(16) }
        case .home: SettingsGroup(footer: "Duo Dash never unlocks doors on its own. With automatic opening on, only the garage opens as you arrive.") { HomeArrivalSettingsView().padding(16) }
        case .duoDock: DuoDockSettingsSection()
        case .about: AboutSettingsSection()
        }
    }
}

// MARK: - Building blocks

private struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct SettingsHeader: View {
    let section: SettingsView.SettingsSection
    init(_ section: SettingsView.SettingsSection) { self.section = section }

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: section.symbol, tint: section.tint)
            Text(section.rawValue).font(.dashTitle)
        }
        .padding(.top, 4)
    }
}

/// A rounded group of rows, like an inset-grouped list.
private struct SettingsGroup<Content: View>: View {
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) { content }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
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
                Text(title).font(.dashBody)
                if let subtitle {
                    Text(subtitle).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Theme.minTouch + 6)
    }
}

private struct RowDivider: View {
    var body: some View { Theme.separator.frame(height: 1).padding(.leading, 16) }
}

/// A big segmented choice (car-sized, unlike the system segmented control).
private struct BigSegments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var identifier: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, title in
                Button { withAnimation(.snappy) { selection = value } } label: {
                    Text(title)
                        .font(.dashCaption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(selection == value ? Theme.onAccent : Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(selection == value ? Theme.accent : Theme.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("\(identifier).\(value)")
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(8)
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
                    Toggle("", isOn: $settings.speaksReplies).labelsHidden().tint(Theme.accent)
                        .accessibilityIdentifier("settings.speaksReplies")
                }
            }

            Text("Claude").font(.dashBody).foregroundStyle(Theme.textSecondary).padding(.top, 4)
            SettingsGroup(footer: "The key is stored in this iPhone's Keychain and is only sent to Anthropic. When Claude is selected, what you ask, your approximate location, your route and any contact you name are sent to Anthropic to answer; Claude can also search the web (e.g. for reviews).") {
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
                    Text("Thinking effort").font(.dashBody).padding(.horizontal, 16).padding(.top, 12)
                    BigSegments(options: AssistantSettings.effortOptions.map { ($0, $0.capitalized) },
                                selection: $settings.claudeEffort, identifier: "settings.effort")
                }
                RowDivider()
                HStack(spacing: 10) {
                    Text("Model").font(.dashBody)
                    TextField("claude-opus-5-5", text: $settings.claudeModel)
                        .font(.dashBody.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.claudeModel")
                    DictationButton(text: $settings.claudeModel, identifier: "settings.claudeModel.dictate")
                }
                .padding(.leading, 16)
                .frame(minHeight: Theme.minTouch + 6)
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
                    Toggle("", isOn: $navigation.voiceEnabled).labelsHidden().tint(Theme.accent)
                        .accessibilityIdentifier("settings.voiceGuidance")
                }
            }
            SettingsGroup(footer: "How the map turns while you're just looking around. During guidance it always follows your heading.") {
                BigSegments(options: [(MapOrientation.headingUp, "Heading up"), (MapOrientation.northUp, "North up")],
                            selection: $orientation, identifier: "settings.mapOrientation")
            }
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
        SettingsGroup(footer: "To reorder the apps, press and hold an icon in the dock, then drag it. The dock scrolls when there are more apps than fit.") {
            SettingsRow(title: "Reset app order") {
                DashPillButton(title: "Reset", prominent: false, identifier: "settings.dock.reset") {
                    withAnimation(.snappy) { app.resetDockOrder() }
                }
            }
        }
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
        SettingsGroup(footer: "Duo Dash works in any mount; Duo Dock is made for it.") {
            VStack(alignment: .leading, spacing: 14) {
                FittedArt(maxScale: 1.3) { DuoDockIllustration() }
                    .frame(height: 210)
                    .accessibilityIdentifier("settings.dock.illustration")
                Text(DuoDockCopy.headline).font(.dashTitle)
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
                    Label("Visit the website", systemImage: "arrow.up.forward")
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
        SettingsGroup(footer: Edition.notAffiliatedNotice) {
            SettingsRow(title: "Version", subtitle: version) { EmptyView() }
            RowDivider()
            Button { onboarding.restart() } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show the welcome tour").font(.dashBody).foregroundStyle(Theme.accent)
                        Text("Music setup, a short tour and permissions").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: Theme.minTouch + 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("onboarding.showAgain")
            RowDivider()
            SettingsRow(title: "Screen info", subtitle: "Real screen, window, safe-area and hinge numbers") {
                DashPillButton(title: "Show", prominent: false, identifier: "settings.screenInfo") {
                    app.showScreenInfo = true
                }
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
