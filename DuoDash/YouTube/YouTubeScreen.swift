import SwiftUI
import WebKit

/// YouTube inside Duo Dash, for passengers: the mobile site for browsing and search, and the
/// official embedded player for the video. Wide windows (the unfolded Duo in landscape, the cover
/// screen on its side) put the video on one half and the results on the other, split on the fold
/// when the phone is half open; tall windows (portrait, cover screen, Split View) stack them.
struct YouTubeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = YouTubeModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let wide = Self.isWide(size)
            let split = Self.halves(width: size.width, fold: wide ? FoldGeometry.foldFrame(in: proxy) : nil)
            let layout = wide ? AnyLayout(HStackLayout(spacing: split.gap)) : AnyLayout(VStackLayout(spacing: Theme.gap))
            layout {
                if wide {
                    widePlayerPane.frame(width: split.video)
                } else if model.videoID != nil {
                    stackedPlayer(size: size)
                }
                browserPane(wide: wide)
                    .frame(width: wide ? split.browser : nil)
            }
            .animation(.snappy(duration: 0.3), value: model.videoID)
            .overlay(alignment: .bottom) {
                if model.showsSafetyNotice { safetyBanner.padding(12).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .animation(.snappy, value: model.showsSafetyNotice)
        }
        .onAppear { model.loadHomeIfNeeded() }
        // Never play on, unseen, behind another screen or in the background (YouTube's terms):
        // picture in picture is the one way to keep watching.
        .onChange(of: app.selected) { _, selected in
            if selected != .youtube { model.pauseAll() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.pauseAll() }
            if phase == .active { model.refreshAppInstalled() }
        }
    }

    /// Side by side when the window is wider than tall and has room for two useful halves.
    static func isWide(_ size: CGSize) -> Bool { size.width > size.height && size.width >= 560 }

    /// Video / browser widths: halves, with the gap exactly on the fold when the Duo is half open.
    static func halves(width: CGFloat, fold: CGRect?) -> (video: CGFloat, browser: CGFloat, gap: CGFloat) {
        if let fold, fold.height > fold.width, fold.minX > 200, width - fold.maxX > 200 {
            return (fold.minX, width - fold.maxX, max(Theme.gap, fold.width))
        }
        let half = max(0, (width - Theme.gap) / 2)
        return (half, half, Theme.gap)
    }

    // MARK: Player

    private var widePlayerPane: some View {
        VStack(spacing: Theme.gap) {
            if model.videoID != nil {
                Spacer(minLength: 0)
                video
                    .aspectRatio(16 / 9, contentMode: .fit)
                HStack(spacing: 10) {
                    if model.isYouTubeAppInstalled { openInAppButton }
                    Spacer(minLength: 0)
                    closeVideoButton
                }
                Spacer(minLength: 0)
            } else {
                placeholder
            }
        }
    }

    private func stackedPlayer(size: CGSize) -> some View {
        // Small windows keep most of the height for the results.
        let height = min(size.width * 9 / 16, size.height * 0.42)
        return video.frame(width: height * 16 / 9, height: height).frame(maxWidth: .infinity)
    }

    private var video: some View {
        YouTubeWebView(webView: model.player)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay {
                if model.embedError != nil { embedErrorCard }
            }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.2, blue: 0.2))
            Text("Pick a video").font(.dashTitle)
            Text("Search or browse beside this. Videos play here, so you can keep looking.")
                .font(.dashCaption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.isYouTubeAppInstalled { openInAppButton }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("youtube.placeholder")
    }

    private var embedErrorCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text("This video can't play in Duo Dash's player.")
                .font(.dashBody)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { errorActions }
                VStack(spacing: 10) { errorActions }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .accessibilityIdentifier("youtube.embedError")
    }

    @ViewBuilder
    private var errorActions: some View {
        DashPillButton(title: "Play on YouTube's site", symbol: "safari", prominent: false,
                       identifier: "youtube.playOnSite") { model.playOnMobileSite() }
        if model.isYouTubeAppInstalled { openInAppButton }
    }

    private var openInAppButton: some View {
        DashPillButton(title: "Open in YouTube app", symbol: "arrow.up.forward.app", prominent: false,
                       identifier: "youtube.openApp") { model.openInYouTubeApp() }
    }

    private var closeVideoButton: some View {
        DashIconButton(symbol: "xmark", label: "Close video", identifier: "youtube.closeVideo") {
            model.closeVideo()
        }
    }

    // MARK: Browser

    private func browserPane(wide: Bool) -> some View {
        VStack(spacing: Theme.gap) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    searchField.frame(minWidth: 280)
                    controls(wide: wide)
                }
                VStack(spacing: Theme.gap) {
                    searchField
                    controls(wide: wide)
                }
            }
            YouTubeWebView(webView: model.browser)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .overlay(alignment: .top) {
                    if model.isLoading {
                        ProgressView().progressViewStyle(.linear).tint(Color(red: 1.0, green: 0.2, blue: 0.2))
                            .padding(.horizontal, Theme.corner)
                    }
                }
        }
    }

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.dashBody)
                .foregroundStyle(Theme.textSecondary)
            TextField("Search YouTube", text: $model.query)
                .font(.dashBody)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .accessibilityIdentifier("youtube.search")
                .onSubmit { model.search() }
            DictationButton(text: $model.query, identifier: "youtube.search.dictate") { _ in model.search() }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
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
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
    }

    /// Big Liquid Glass buttons: back, forward, reload, YouTube home; on stacked layouts also the
    /// video's own buttons (the wide layout shows those under the video).
    private func controls(wide: Bool) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 6) {
                DashIconButton(symbol: "chevron.backward", label: "Back", identifier: "youtube.back") { model.back() }
                    .disabled(!model.canGoBack)
                    .opacity(model.canGoBack ? 1 : 0.45)
                DashIconButton(symbol: "chevron.forward", label: "Forward", identifier: "youtube.forward") { model.forward() }
                    .disabled(!model.canGoForward)
                    .opacity(model.canGoForward ? 1 : 0.45)
                DashIconButton(symbol: model.isLoading ? "xmark" : "arrow.clockwise",
                               label: model.isLoading ? "Stop loading" : "Reload", identifier: "youtube.reload") { model.reload() }
                DashIconButton(symbol: "house.fill", label: "YouTube home", identifier: "youtube.home") { model.goHome() }
                if !wide && model.videoID != nil {
                    if model.isYouTubeAppInstalled {
                        DashIconButton(symbol: "arrow.up.forward.app", label: "Open in YouTube app",
                                       identifier: "youtube.openApp") { model.openInYouTubeApp() }
                    }
                    closeVideoButton
                } else if !wide && model.isYouTubeAppInstalled {
                    DashIconButton(symbol: "arrow.up.forward.app", label: "Open YouTube app",
                                   identifier: "youtube.openApp") { model.openInYouTubeApp() }
                }
            }
        }
        .fixedSize()
    }

    // MARK: Passenger notice

    private var safetyBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text(Edition.safetyNotice)
                .font(.dashCaption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("youtube.safety")
            Spacer(minLength: 0)
            Button {
                model.dismissSafetyNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: Theme.minTouch, height: Theme.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("youtube.safety.dismiss")
        }
        .padding(.leading, 16)
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// Shows a web view the model owns, so the page survives layout changes (fold, rotation).
struct YouTubeWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
