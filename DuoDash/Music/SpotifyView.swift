import SwiftUI
import UIKit

private let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.33)

/// CarPlay-style Spotify screen, in the same style as Music: big tab buttons,
/// short lists, and the shared Apple Music-style player. Before it can do any
/// of that it walks through Spotify's states: not installed, connect,
/// connecting, and reconnect after a drop.
struct SpotifyView: View {
    @Environment(SpotifyModel.self) private var spotify
    @Environment(\.dashMetrics) private var metrics
    @Environment(\.openURL) private var openURL
    @State private var tab: SpotifyTab = .recents
    /// The playlist/album pages open on each list tab, like a navigation stack per tab.
    @State private var paths: [SpotifyTab: [SpotifyItem]] = [:]

    enum SpotifyTab: String, CaseIterable, Identifiable {
        case nowPlaying = "Now Playing", recents = "Recents", playlists = "Playlists"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .nowPlaying: "waveform"
            case .recents: "clock.fill"
            case .playlists: "music.note.list"
            }
        }
    }

    var body: some View {
        Group {
            switch spotify.status {
            case .notConfigured:
                SpotifyStateView(symbol: "key.fill", title: "Spotify isn't set up",
                                 message: "This build has no Spotify client ID. Add SPOTIFY_CLIENT_ID to Config/Secrets.xcconfig and build again.",
                                 identifier: "spotify.notconfigured")
            case .notInstalled:
                SpotifyStateView(symbol: "arrow.down.app.fill", title: "Spotify isn't installed",
                                 message: "Duo Dash controls the Spotify app, so it needs to be on this phone and signed in.",
                                 actionTitle: "Get Spotify", actionIdentifier: "spotify.appstore",
                                 identifier: "spotify.notinstalled") {
                    openURL(spotify.appStoreURL)
                }
            case .notConnected:
                SpotifyStateView(symbol: "headphones", title: "Connect Spotify",
                                 message: "Spotify opens for a moment to approve, then you're straight back here.",
                                 actionTitle: "Connect", actionIdentifier: "spotify.connect",
                                 identifier: "spotify.notconnected") {
                    spotify.connect()
                }
            case .connecting:
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large)
                    Text("Connecting to Spotify…").font(.dashTitle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("spotify.connecting")
            case .disconnected(let reason):
                SpotifyStateView(symbol: "bolt.horizontal.circle.fill", title: "Spotify isn't connected",
                                 message: reason, actionTitle: "Reconnect", actionIdentifier: "spotify.reconnect",
                                 identifier: "spotify.disconnected") {
                    spotify.connect()
                }
            case .connected:
                connected
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let message = spotify.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.dashCaption)
                    .padding(14)
                    .glassEffect(.regular.tint(Theme.warning.opacity(0.4)), in: Capsule())
                    .padding(12)
                    .onTapGesture { spotify.errorMessage = nil }
                    .accessibilityIdentifier("spotify.error")
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(6))
                        if spotify.errorMessage == message { spotify.errorMessage = nil }
                    }
            }
        }
    }

    // MARK: Connected

    private var showsPlayer: Bool { tab == .nowPlaying && spotify.track != nil }

    private var connected: some View {
        VStack(spacing: Theme.gap) {
            tabBar
            ZStack {
                ForEach([SpotifyTab.recents, .playlists]) { item in
                    browser(item)
                        .opacity(item == tab ? 1 : 0)
                        .allowsHitTesting(item == tab)
                        .accessibilityHidden(item != tab)
                }
                if tab == .nowPlaying {
                    PlayerView(source: spotify, idPrefix: "spotify",
                               emptyMessage: "Pick something from Recents or Playlists.", extraReserve: 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 6)
        .padding(.horizontal, tab == .nowPlaying ? 6 : 0)
        .background {
            if showsPlayer {
                ArtworkBackdrop(image: spotify.track?.artwork)
                    .padding([.horizontal, .bottom], -Theme.gap)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: tab)
        .onChange(of: spotify.pendingItemID) { old, new in
            // When a tapped item starts, jump to Now Playing (like CarPlay).
            if old != nil, new == nil, spotify.errorMessage == nil {
                withAnimation(.snappy) { tab = .nowPlaying }
            }
        }
    }

    /// Same as Music: labelled tabs on wide windows, icon-only tabs sharing the
    /// width on compact ones (cover screen, Split View).
    private var tabBar: some View {
        HStack(spacing: metrics.isCompact ? 4 : 8) {
            ForEach(SpotifyTab.allCases) { item in
                tabButton(item).frame(maxWidth: metrics.isCompact ? .infinity : nil)
            }
            if !metrics.isCompact {
                Spacer(minLength: 0)
                if spotify.isDemo && !LaunchOptions.isCapture {
                    Text("Demo Spotify")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: Theme.minTouch)
    }

    private func tabButton(_ item: SpotifyTab) -> some View {
        let selected = tab == item
        return Button {
            withAnimation(.snappy) {
                // Tapping the tab you're on goes back to its list, like CarPlay.
                if tab == item, paths[item]?.isEmpty == false {
                    paths[item] = []
                } else {
                    tab = item
                }
            }
        } label: {
            Label(item.rawValue, systemImage: item.symbol)
                .labelStyle(DashLabelStyle(iconOnly: metrics.isCompact))
                .font(.dashCaption)
                .lineLimit(1)
                .padding(.horizontal, metrics.isCompact ? 12 : 18)
                .frame(minHeight: Theme.minTouch - 8)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .glassEffect(selected ? .regular : .identity, in: Capsule())
                .frame(maxWidth: metrics.isCompact ? .infinity : nil, minHeight: Theme.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(item.rawValue)
        .accessibilityIdentifier("spotify.tab.\(item)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Lists and pages

    /// A list tab, with any opened playlist/album page on top. The list stays
    /// underneath (hidden), so Back returns to the same scroll position.
    private func browser(_ item: SpotifyTab) -> some View {
        let path = paths[item] ?? []
        return ZStack {
            Group {
                if item == .recents {
                    recentsList(in: item)
                } else {
                    playlistsList(in: item)
                }
            }
            .opacity(path.isEmpty ? 1 : 0)
            .allowsHitTesting(path.isEmpty)
            .accessibilityHidden(!path.isEmpty)

            if let open = path.last {
                SpotifyPageView(item: open,
                                backTitle: path.count > 1 ? path[path.count - 2].title : item.rawValue,
                                onOpen: { child in push(child, on: item) },
                                onBack: { withAnimation(.snappy) { _ = paths[item]?.popLast() } })
                    .id(open.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private func push(_ child: SpotifyItem, on item: SpotifyTab) {
        withAnimation(.snappy) { paths[item, default: []].append(child) }
    }

    @ViewBuilder
    private func recentsList(in item: SpotifyTab) -> some View {
        if let state = libraryState(isEmpty: spotify.recents.isEmpty, empty: "Nothing played recently") {
            state
        } else {
            ScrollView {
                SpotifyItemGrid(items: spotify.recents, idPrefix: "spotify.row") { push($0, on: item) }
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func playlistsList(in item: SpotifyTab) -> some View {
        if let state = libraryState(isEmpty: spotify.shelves.isEmpty, empty: "No playlists") {
            state
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.gap) {
                    ForEach(Array(spotify.shelves.enumerated()), id: \.element.id) { shelfIndex, shelf in
                        Text(shelf.section.title)
                            .font(.dashTitle)
                            .padding(.horizontal, 6)
                            .padding(.top, shelfIndex == 0 ? 4 : 14)
                            .accessibilityAddTraits(.isHeader)
                        SpotifyItemGrid(items: shelf.items, idPrefix: "spotify.shelf\(shelfIndex).row") { push($0, on: item) }
                    }
                }
            }
        }
    }

    /// Loading, error or empty states for the list tabs; nil when there's a list to show.
    private func libraryState(isEmpty: Bool, empty: String) -> AnyView? {
        guard isEmpty else { return nil }
        if spotify.isLoadingLibrary || !spotify.hasLoadedLibrary && spotify.libraryError == nil {
            return AnyView(ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        if let error = spotify.libraryError {
            return AnyView(EmptyStateView(symbol: "exclamationmark.triangle.fill", title: "Couldn't load Spotify",
                                          message: error, actionTitle: "Try Again") {
                Task { await spotify.loadLibrary() }
            })
        }
        return AnyView(EmptyStateView(symbol: "music.note", title: empty))
    }
}

/// Rows in an adaptive grid: one column on narrow windows, two or more when wide.
private struct SpotifyItemGrid: View {
    @Environment(SpotifyModel.self) private var spotify
    let items: [SpotifyItem]
    let idPrefix: String
    let onOpen: (SpotifyItem) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.gap)], spacing: Theme.gap) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                SpotifyItemRow(item: item, identifier: "\(idPrefix).\(index)",
                               isPending: spotify.pendingItemID == item.id) {
                    // Playlists and albums open their page; songs play straight away.
                    if item.opensAsPage { onOpen(item) } else { spotify.play(item) }
                }
            }
        }
    }
}

/// A playlist/album page: back, title, Play, then its songs (or sub-items).
private struct SpotifyPageView: View {
    @Environment(SpotifyModel.self) private var spotify
    let item: SpotifyItem
    let backTitle: String
    let onOpen: (SpotifyItem) -> Void
    let onBack: () -> Void
    @State private var cover: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Label(backTitle, systemImage: "chevron.left")
                        .font(.dashBody)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .frame(minHeight: Theme.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .glassEffect(.regular.interactive(), in: Capsule())
                .accessibilityIdentifier("spotify.back")
                Spacer(minLength: 0)
            }

            HStack(spacing: 14) {
                ArtworkView(image: cover, size: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.dashTitle).lineLimit(2).minimumScaleFactor(0.8)
                        .accessibilityIdentifier("spotify.page.title")
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if item.isPlayable {
                    DashIconButton(symbol: "play.fill", prominent: true, tint: spotifyGreen,
                                   label: "Play \(item.title)", identifier: "spotify.page.play") {
                        spotify.play(item)
                    }
                    .overlay {
                        if spotify.pendingItemID == item.id { ProgressView().tint(.white) }
                    }
                }
            }
            .padding(.horizontal, 6)

            Group {
                if let items = spotify.children[item.id] {
                    if items.isEmpty {
                        EmptyStateView(symbol: "music.note", title: "Nothing in here")
                    } else {
                        ScrollView {
                            SpotifyItemGrid(items: items, idPrefix: "spotify.song", onOpen: onOpen)
                        }
                    }
                } else if let error = spotify.childErrors[item.id] {
                    EmptyStateView(symbol: "exclamationmark.triangle.fill", title: "Couldn't open it",
                                   message: error, actionTitle: "Try Again") {
                        Task { await spotify.loadChildren(of: item) }
                    }
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .task(id: item.id) {
            await spotify.loadChildren(of: item)
            cover = await spotify.image(for: item, size: 144)
        }
    }
}

private struct SpotifyItemRow: View {
    @Environment(SpotifyModel.self) private var spotify
    let item: SpotifyItem
    let identifier: String
    let isPending: Bool
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 14) {
                    ZStack {
                        ArtworkView(image: image, size: 52)
                        if isPending {
                            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.5)).frame(width: 52, height: 52)
                            ProgressView()
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.dashBody).lineLimit(1)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if item.opensAsPage {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                            .padding(.trailing, 4)
                    }
                }
                .padding(.leading, 8)
                .frame(minHeight: Theme.minTouch + 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)")
            .accessibilityIdentifier(identifier)

            if item.opensAsPage && item.isPlayable {
                // Play the whole playlist without opening it.
                Button { spotify.play(item) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: Theme.minTouch, height: Theme.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Play \(item.title)")
                .accessibilityIdentifier("\(identifier).play")
            }
        }
        .padding(.trailing, 4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: item.id) { image = await spotify.image(for: item, size: 120) }
    }
}

/// Big centred message with one large action, for the not-connected states.
private struct SpotifyStateView: View {
    let symbol: String
    let title: String
    var message = ""
    var actionTitle: String? = nil
    var actionIdentifier: String? = nil
    let identifier: String
    var action: (() -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content.frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var content: some View {
        VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(spotifyGreen)
                Text(title)
                    .font(.dashTitle)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("\(identifier).title")
                if !message.isEmpty {
                    Text(message)
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                        .accessibilityIdentifier("\(identifier).message")
                }
                if let actionTitle, let action {
                    DashPillButton(title: actionTitle, tint: spotifyGreen, identifier: actionIdentifier, action: action)
                        .padding(.top, 6)
                }
            }
            .padding(24)
    }
}
