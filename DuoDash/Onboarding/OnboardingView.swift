import SwiftUI
import UIKit

/// The first-launch welcome tour, full screen over the dashboard. Size-driven like the rest of
/// the app: wide windows put the illustration beside the text (split on the fold when the
/// iPhone Duo is half open), narrow ones stack them.
struct OnboardingView: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(AppleMusicModel.self) private var music
    @Environment(LocationManager.self) private var location
    @Environment(ContactsStore.self) private var contacts
    @Environment(SpotifyModel.self) private var spotify
    @Namespace private var glass

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.size
            // iPad: lay out at a phone-like size and scale up, as the dashboard does.
            let scale = DashMetrics.displayScale(for: window)
            let size = CGSize(width: window.width / scale, height: window.height / scale)
            let fold = scale == 1 ? FoldGeometry.foldFrame(in: proxy) : nil
            let layout = OnboardingLayout(size: size, fold: fold, insets: proxy.safeAreaInsets)
            ZStack {
                page(model.step, layout: layout)
                    .id(model.step)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: window.width, height: window.height, alignment: .topLeading)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding")
        .onAppear {
            let location = location, contacts = contacts
            model.needsPermissions = {
                OnboardingPermission.allCases.contains { $0.state(location: location, contacts: contacts) == .notDetermined }
            }
        }
    }

    private func go(_ change: () -> Void) {
        withAnimation(.snappy(duration: 0.35)) { change() }
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ step: OnboardingStep, layout: OnboardingLayout) -> some View {
        switch step {
        case .welcome:
            OnboardingPage(id: step.id, layout: layout, glass: glass, showsBack: false,
                           title: "Welcome to Duo Dash",
                           message: "Maps, music, calls and messages on big, glanceable buttons, made for the dashboard of your car.\n\n\(Edition.safetyNotice)",
                           question: Edition.current.isCommercial ? "Have you used your phone on a car's screen before?" : "Have you used CarPlay before?") {
                FittedArt { MiniDashboard().frame(width: 340, height: 240) }
            } actions: {
                OnboardingButtonRow {
                    OnboardingButton(title: "Yes", symbol: "checkmark", id: "onboarding.carplay.yes", glass: glass) {
                        go { model.answerUsedCarPlay(true) }
                    }
                    OnboardingButton(title: "No", symbol: "sparkles", id: "onboarding.carplay.no", glass: glass, glassID: "secondary") {
                        go { model.answerUsedCarPlay(false) }
                    }
                }
            }

        case .music:
            OnboardingPage(id: step.id, layout: layout, glass: glass,
                           title: "Which music do you use?",
                           message: "Duo Dash controls the Music and Spotify apps, so your music keeps playing in the background.") {
                FittedArt(design: CGSize(width: 300, height: 140)) { MusicChoiceArt() }
            } actions: {
                GlassEffectContainer(spacing: 10) {
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            musicButton(.appleMusic, "Apple Music", "music.note")
                            musicButton(.spotify, "Spotify", "headphones")
                        }
                        GridRow {
                            musicButton(.both, "Both", "music.note.list")
                            musicButton(.neither, "Neither", "xmark")
                        }
                    }
                }
            }

        case .spotifyIntro where model.spotifyClientBundled:
            // This build ships a Spotify client ID: one sign-in, no developer app.
            OnboardingPage(id: step.id, layout: layout, glass: glass,
                           title: "Connect Spotify",
                           message: spotify.mode == .signInOnce
                            ? "Sign in to Spotify once and Duo Dash stays connected from then on. Spotify opens for a moment to approve. Needs Spotify Premium and the Spotify app."
                            : "Duo Dash controls the Spotify app on this phone: Spotify opens for a moment to connect. Needs Spotify Premium and the Spotify app.",
                           question: "Connect now?") {
                FittedArt(design: CGSize(width: 330, height: 150)) { SpotifyIntroArt(bundled: true) }
            } actions: {
                OnboardingButtonRow {
                    OnboardingButton(title: "Connect", symbol: "arrow.right", prominent: true, id: "onboarding.spotify.now", glass: glass) {
                        spotify.connect()
                        go { model.chooseSpotifySetup(now: true) }
                    }
                    OnboardingButton(title: "Later", id: "onboarding.spotify.later", glass: glass, glassID: "secondary") {
                        go { model.chooseSpotifySetup(now: false) }
                    }
                }
            }

        case .spotifyIntro:
            OnboardingPage(id: step.id, layout: layout, glass: glass,
                           title: "Spotify needs a one-time setup",
                           message: "Spotify only lets Duo Dash connect through a free developer app that you make yourself. It takes about 10 minutes on a computer, and needs Spotify Premium.",
                           question: "Set it up now?") {
                FittedArt(design: CGSize(width: 330, height: 150)) { SpotifyIntroArt() }
            } actions: {
                OnboardingButtonRow {
                    OnboardingButton(title: "Now", symbol: "arrow.right", prominent: true, id: "onboarding.spotify.now", glass: glass) {
                        go { model.chooseSpotifySetup(now: true) }
                    }
                    OnboardingButton(title: "Later", id: "onboarding.spotify.later", glass: glass, glassID: "secondary") {
                        go { model.chooseSpotifySetup(now: false) }
                    }
                }
            }

        case .spotify(let n):
            let info = SpotifyWalkthrough.steps[max(0, min(n, SpotifyWalkthrough.steps.count) - 1)]
            OnboardingPage(id: step.id, layout: layout, glass: glass,
                           stepNumber: n, stepCount: OnboardingStep.spotifyStepCount,
                           title: info.title, message: info.message) {
                FittedArt(design: CGSize(width: 340, height: 250)) { SpotifyStepArt(step: n, bundleID: SpotifyWalkthrough.bundleID) }
            } actions: {
                continueButton
            }

        case .spotifyFinish:
            OnboardingPage(id: step.id, layout: layout, glass: glass, artShare: 0.17,
                           title: "Last step: on your Mac",
                           message: "In the Duo Dash folder, run this with your Client ID, or give the ID to the agent installing Duo Dash for you. Then tap Spotify in the dock and Connect.") {
                FittedArt(design: CGSize(width: 220, height: 230)) { GuideQRCard() }
            } extra: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("scripts/setup.sh --spotify-client-id <your-client-id> --install")
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("onboarding.spotify.command")
                    Link(destination: SpotifyGuide.url) {
                        Label("Full guide: SPOTIFY_SETUP.md", systemImage: "link")
                            .font(.callout.weight(.semibold))
                            .frame(minHeight: Theme.minTouch, alignment: .leading)
                    }
                    .accessibilityIdentifier("onboarding.spotify.guide")
                    HStack(spacing: 12) {
                        Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Video walkthrough").font(.headline)
                            Text("Coming soon").font(.subheadline).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(minHeight: Theme.minTouch)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("onboarding.spotify.video")
                }
            } actions: {
                continueButton
            }

        case .tour(let page):
            tourPage(page, step: step, layout: layout)

        case .whatsNew:
            OnboardingPage(id: step.id, layout: layout, glass: glass,
                           title: Edition.current.isCommercial ? "What Duo Dash adds" : "What's new compared with CarPlay",
                           message: "Everything you know is here, plus an assistant that plans stops for you, a dashcam, live car data and the weather where you're going.") {
                FittedArt(design: CGSize(width: 350, height: 246)) { WhatsNewArt() }
            } actions: {
                continueButton
            }

        case .permissions:
            OnboardingPermissionsPage(layout: layout, glass: glass) { go { model.advance() } }

        case .promo:
            DuoDockPromoSheet(layout: layout) {
                UIApplication.shared.open(DockStore.url)
                go { model.finish() }
            } notNow: {
                go { model.finish() }
            }
        }
    }

    @ViewBuilder
    private func tourPage(_ page: OnboardingTourPage, step: OnboardingStep, layout: OnboardingLayout) -> some View {
        switch page {
        case .dock:
            OnboardingPage(id: step.id, layout: layout, glass: glass, title: "The dock",
                           message: "Your apps run down the right side (along the bottom on narrow screens): scroll for more, press and hold an icon to reorder, and the bottom button switches between the Dashboard and all apps.") {
                FittedArt(design: CGSize(width: 300, height: 330)) { DockTourArt().frame(height: 330) }
            } actions: { continueButton }
        case .maps:
            OnboardingPage(id: step.id, layout: layout, glass: glass, title: "Maps and the assistant",
                           message: "Tap the sparkle and just say where you're going, like “take me to Sam's, stop for petrol on the way”.") {
                FittedArt(design: CGSize(width: 340, height: 240)) { AssistantTourArt().frame(width: 340, height: 240) }
            } actions: { continueButton }
        case .phone:
            OnboardingPage(id: step.id, layout: layout, glass: glass, title: "Phone and Messages",
                           message: "Add your favourite people from Contacts, then call or text them with one tap.") {
                FittedArt(design: CGSize(width: 340, height: 200)) { FavouritesTourArt() }
            } actions: { continueButton }
        case .settings:
            OnboardingPage(id: step.id, layout: layout, glass: glass, title: "Settings",
                           message: "Choose the assistant, voice, saved places and dock order in Settings, and replay this tour from About.") {
                FittedArt(design: CGSize(width: 300, height: 250)) { SettingsTourArt() }
            } actions: { continueButton }
        }
    }

    private var continueButton: some View {
        OnboardingButton(title: "Continue", symbol: "arrow.right", prominent: true, id: "onboarding.next", glass: glass) {
            go { model.advance() }
        }
    }

    private func musicButton(_ choice: OnboardingMusicChoice, _ title: String, _ symbol: String) -> some View {
        OnboardingButton(title: title, symbol: symbol, prominent: model.music == choice,
                         id: "onboarding.music.\(choice.rawValue)", glass: glass, glassID: "music.\(choice.rawValue)") {
            if choice.usesAppleMusic {
                // Only asks for Media & Apple Music access; the library loads when Music opens.
                Task { await music.requestAccess() }
            }
            go { model.chooseMusic(choice) }
        }
    }
}

// MARK: - Layout

struct OnboardingLayout {
    let size: CGSize
    /// The iPhone Duo's fold while half open, in this view's coordinates.
    var fold: CGRect? = nil
    var insets = EdgeInsets()

    /// Illustration beside the text.
    var wide: Bool { size.width > size.height && size.width >= 560 }
    var compact: Bool { min(size.width, size.height) < 520 }
    var padding: CGFloat { compact ? 16 : 28 }

    /// A vertical fold to split the two columns on (wide windows).
    var verticalFold: CGRect? {
        guard wide, let fold, fold.height > fold.width, fold.minX > 220, size.width - fold.maxX > 260 else { return nil }
        return fold
    }

    /// A horizontal fold to split art (above) and text (below) on (tall windows).
    var horizontalFold: CGRect? {
        guard !wide, let fold, fold.width > fold.height, fold.minY > 180, size.height - fold.maxY > 260 else { return nil }
        return fold
    }
}

// MARK: - Building blocks

/// One page: back button, illustration, big title, one or two sentences, the answers.
struct OnboardingPage<Art: View, Extra: View, Actions: View>: View {
    let id: String
    let layout: OnboardingLayout
    let glass: Namespace.ID
    var showsBack = true
    var stepNumber: Int? = nil
    var stepCount = 0
    /// Share of a tall window's height for the illustration (smaller on text-heavy pages).
    var artShare: CGFloat? = nil
    let title: String
    var message = ""
    var question: String? = nil
    @ViewBuilder var art: Art
    @ViewBuilder var extra: Extra
    @ViewBuilder var actions: Actions
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        let p = layout.padding
        Group {
            if layout.wide {
                let fold = layout.verticalFold
                let textWidth = fold.map { layout.size.width - $0.maxX - 2 * p } ?? min(460, layout.size.width * 0.5)
                HStack(spacing: fold.map { $0.width + 2 * p } ?? p * 1.5) {
                    VStack(spacing: 0) {
                        topBar
                        art.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 8)
                    }
                    .frame(width: fold.map { $0.minX - 2 * p })
                    VStack(alignment: .leading, spacing: 16) {
                        textColumn
                        actions
                    }
                    .frame(width: textWidth)
                }
            } else if let fold = layout.horizontalFold {
                VStack(spacing: 0) {
                    VStack(spacing: 0) { topBar; art.frame(maxWidth: .infinity, maxHeight: .infinity) }
                        .frame(height: fold.minY - 2 * p)
                    Spacer().frame(height: fold.height + 2 * p)
                    VStack(alignment: .leading, spacing: 14) { textColumn; actions }
                        .frame(maxHeight: .infinity)
                }
            } else {
                VStack(spacing: layout.compact ? 10 : 16) {
                    topBar
                    art.frame(maxWidth: .infinity)
                        .frame(height: layout.size.height * (artShare ?? (layout.compact ? 0.38 : 0.40)))
                    textColumn.frame(maxHeight: .infinity, alignment: .top)
                    actions
                }
            }
        }
        .padding(.horizontal, p)
        .padding(.top, max(p * 0.75, layout.insets.top))
        .padding(.bottom, max(p, layout.insets.bottom))
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private var topBar: some View {
        HStack {
            if showsBack && model.canGoBack {
                Button { withAnimation(.snappy(duration: 0.35)) { model.back() } } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.bold))
                        .frame(width: Theme.minTouch, height: Theme.minTouch)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("onboarding.back")
            } else {
                Label("Duo Dash", systemImage: "steeringwheel")
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(height: Theme.minTouch)
            }
            Spacer(minLength: 0)
            if model.path.last != .promo {
                Button("Skip") { withAnimation(.snappy(duration: 0.35)) { model.skip() } }
                    .font(.headline)
                    .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                    .buttonStyle(.glass)
                    .accessibilityHint("Skips the rest of the welcome tour")
                    .accessibilityIdentifier("onboarding.skip")
            }
        }
    }

    private var textColumn: some View {
        ViewThatFits(in: .vertical) {
            text
            ScrollView { text }.scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: layout.compact ? 8 : 12) {
            if let stepNumber {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(stepNumber)")
                        .font(.system(size: layout.compact ? 52 : 64, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("onboarding.stepNumber")
                    Text("of \(stepCount)").font(.title3.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                }
            }
            Text(title)
                .font(layout.compact ? .title.weight(.bold) : .largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                // Each page is identified by its title (SwiftUI can fold a lone container away).
                .accessibilityIdentifier("onboarding.page.\(id)")
            if !message.isEmpty {
                Text(message)
                    .font(layout.compact ? .body : .title3)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            extra
            if let question {
                Text(question)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension OnboardingPage where Extra == EmptyView {
    init(id: String, layout: OnboardingLayout, glass: Namespace.ID, showsBack: Bool = true,
         stepNumber: Int? = nil, stepCount: Int = 0, title: String, message: String = "", question: String? = nil,
         @ViewBuilder art: () -> Art, @ViewBuilder actions: () -> Actions) {
        self.init(id: id, layout: layout, glass: glass, showsBack: showsBack, stepNumber: stepNumber,
                  stepCount: stepCount, title: title, message: message, question: question,
                  art: art, extra: { EmptyView() }, actions: actions)
    }
}

/// Side-by-side answers in one glass container, so they blend and morph together.
struct OnboardingButtonRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) { content }
        }
    }
}

/// A full-width Liquid Glass button, at least 60 pt tall.
struct OnboardingButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    let id: String
    let glass: Namespace.ID
    /// Buttons sharing an ID morph into each other between pages.
    var glassID = "primary"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
            .contentShape(Capsule())
        }
        .buttonStyle(OnboardingGlassStyle(prominent: prominent))
        .glassEffectID(glassID, in: glass)
        .accessibilityIdentifier(id)
    }
}

/// `.glass` / `.glassProminent` with a full-width label (the system styles size to content).
private struct OnboardingGlassStyle: PrimitiveButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        }
    }
}

// MARK: - Permissions page

struct OnboardingPermissionsPage: View {
    let layout: OnboardingLayout
    let glass: Namespace.ID
    let onContinue: () -> Void
    @Environment(LocationManager.self) private var location
    @Environment(ContactsStore.self) private var contacts
    /// The ones still undecided when the page opened (decided ones are skipped).
    @State private var asking: [OnboardingPermission] = []
    @State private var refresh = 0

    var body: some View {
        OnboardingPage(id: "permissions", layout: layout, glass: glass, artShare: 0.16,
                       title: "A few permissions",
                       message: "Allow what you'd like to use. You can change these later in the iPhone's Settings.") {
            FittedArt(design: CGSize(width: 300, height: 150)) {
                HStack(spacing: 16) {
                    ForEach(OnboardingPermission.allCases) { permission in
                        Image(systemName: permission.symbol)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 76, height: 76)
                            .background(permission.tint.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        } extra: {
            VStack(spacing: 8) {
                ForEach(asking) { row($0) }
            }
            .padding(.top, 4)
        } actions: {
            OnboardingButton(title: "Continue", symbol: "arrow.right", prominent: true, id: "onboarding.next", glass: glass,
                             action: onContinue)
        }
        .onAppear {
            asking = OnboardingPermission.allCases.filter { $0.state(location: location, contacts: contacts) == .notDetermined }
        }
    }

    private func row(_ permission: OnboardingPermission) -> some View {
        let state = permission.state(location: location, contacts: contacts)
        return HStack(spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(permission.tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.headline)
                Text(permission.detail).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch state {
            case .notDetermined:
                Button("Allow") {
                    Task {
                        await permission.request(location: location, contacts: contacts)
                        refresh += 1
                    }
                }
                .font(.headline)
                .frame(minWidth: 70, minHeight: 44)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
                .accessibilityIdentifier("onboarding.permission.\(permission.rawValue)")
            case .allowed:
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.positive)
                    .accessibilityLabel("Allowed")
            case .denied:
                Text("Off").font(.headline).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Theme.minTouch + 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .id("\(permission.rawValue).\(refresh)")
    }
}

// MARK: - Spotify walkthrough text (docs/SPOTIFY_SETUP.md, steps 1 to 5)

enum SpotifyWalkthrough {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "your app's bundle ID" }

    static let steps: [(title: String, message: String)] = [
        ("Open the developer dashboard",
         "On a computer, go to developer.spotify.com/dashboard and log in with the Spotify account you use on this phone. Accept the Developer Terms if asked."),
        ("Create an app",
         "Click Create app. Name it Duo Dash, describe it as Personal car dashboard, and leave Website blank."),
        ("Add the Redirect URI",
         "Under Redirect URI, type duodash://spotify-callback exactly, then click Add."),
        ("Choose the SDKs and save",
         "Under Which API/SDKs are you planning to use, tick iOS and Web API. Tick the terms checkbox and click Save."),
        ("Add the iOS bundle ID",
         "Open the new app's Settings, then Edit, and add \(bundleID) under iOS app bundles. Check the Redirect URI and click Save."),
        ("Allow your account",
         "In Settings, then User Management, add your name and your Spotify account's email, so development mode lets you connect."),
        ("Copy the Client ID",
         "In Settings, then Basic Information, copy the 32-character Client ID. You don't need the Client secret: never share it."),
    ]
}
