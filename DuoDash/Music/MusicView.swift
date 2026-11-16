import SwiftUI
import UIKit

/// CarPlay-style Apple Music screen: big tab buttons, short lists, big now playing.
struct MusicView: View {
    @Environment(AppleMusicModel.self) private var music
    @Environment(AppModel.self) private var app
    @Environment(\.dashMetrics) private var metrics
    @State private var tab: MusicTab = .recents
    @State private var query = ""
    /// The playlist/album page open on each library tab (like a navigation stack per tab).
    @State private var openCollection: [MusicTab: MusicEntry] = [:]
    /// Library tabs stay alive once visited, so their scroll positions survive.
    @State private var visitedTabs: Set<MusicTab> = []

    enum MusicTab: String, CaseIterable, Identifiable {
        case nowPlaying = "Now Playing", recents = "Recents", playlists = "Playlists", albums = "Albums", search = "Search"
        var id: String { rawValue }
        static let libraryTabs: [MusicTab] = [.recents, .playlists, .albums]
        var symbol: String {
            switch self {
            case .nowPlaying: "waveform"
            case .recents: "clock.fill"
            case .playlists: "music.note.list"
            case .albums: "square.stack.fill"
            case .search: "magnifyingglass"
            }
        }
    }

    var body: some View {
        VStack(spacing: Theme.gap) {
            tabBar
            Group {
                switch music.access {
                case .notDetermined:
                    EmptyStateView(symbol: "music.note", title: "Connect Apple Music",
                                   message: "Allow access to play your library and playlists.",
                                   actionTitle: "Allow Access") {
                        Task { await music.prepare() }
                    }
                case .denied, .restricted:
                    EmptyStateView(symbol: "lock.fill", title: "Apple Music access is off",
                                   message: "Turn on Media & Apple Music for Duo Dash in Settings.",
                                   actionTitle: "Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                case .authorized:
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 6)
        .padding(.horizontal, tab == .nowPlaying ? 6 : 0)
        .background {
            // Apple Music style: the cover, blurred, washes the whole player.
            if tab == .nowPlaying, music.track != nil {
                ArtworkBackdrop(image: music.track?.artwork)
                    // Bleed out over the shell's margins to the screen edges.
                    .padding([.horizontal, .bottom], -Theme.gap)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: tab)
        .onChange(of: tab == .nowPlaying && music.track != nil, initial: true) { _, open in
            app.isPlayerOpen = open
        }
        .task { await music.prepare() }
        .onChange(of: music.pendingEntryID) { old, new in
            // When a tapped item finishes loading, jump to Now Playing (like CarPlay).
            if old != nil, new == nil, music.track != nil, music.errorMessage == nil {
                withAnimation(.snappy) { tab = .nowPlaying }
            }
        }
        .overlay(alignment: .bottom) {
            if let message = music.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.dashCaption)
                    .padding(14)
                    .glassEffect(.regular.tint(Theme.warning.opacity(0.4)), in: Capsule())
                    .padding(12)
                    .onTapGesture { music.errorMessage = nil }
                    .accessibilityIdentifier("music.error")
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(6))
                        if music.errorMessage == message { music.errorMessage = nil }
                    }
            }
        }
    }

    /// Wide windows: labelled tabs in a scrollable row. Compact windows (cover
    /// screen, Split View): icon-only tabs sharing the width, so every tab is
    /// always on screen.
    @ViewBuilder
    private var tabBar: some View {
        if metrics.isCompact {
            HStack(spacing: 4) {
                ForEach(MusicTab.allCases) { item in
                    tabButton(item).frame(maxWidth: .infinity)
                }
            }
            .frame(height: Theme.minTouch)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MusicTab.allCases) { item in tabButton(item) }
                    if music.isDemo && !LaunchOptions.isCapture {
                        Text("Demo library")
                            .font(.dashCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 2)
            }
            // Clipped so the row can't draw over the dock beside it.
            .frame(height: Theme.minTouch)
            .clipped()
        }
    }

    private func tabButton(_ item: MusicTab) -> some View {
        let selected = tab == item
        return Button {
            withAnimation(.snappy) {
                // Tapping the tab you're on goes back to its list, like CarPlay.
                if tab == item, openCollection[item] != nil {
                    openCollection[item] = nil
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
        .accessibilityIdentifier("music.tab.\(item)")
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            ForEach(MusicTab.libraryTabs) { item in
                if item == tab || visitedTabs.contains(item) {
                    libraryBrowser(item)
                        .opacity(item == tab ? 1 : 0)
                        .allowsHitTesting(item == tab)
                        .accessibilityHidden(item != tab)
                }
            }
            switch tab {
            case .nowPlaying:
                MusicNowPlayingView()
            case .search:
                searchContent
            case .recents, .playlists, .albums:
                EmptyView()
            }
        }
        .onChange(of: tab, initial: true) { _, newTab in
            if MusicTab.libraryTabs.contains(newTab) { visitedTabs.insert(newTab) }
        }
    }

    /// A library list, with the playlist/album page opened from it on top. The
    /// list stays underneath (hidden), so Back returns to the same scroll spot.
    private func libraryBrowser(_ item: MusicTab) -> some View {
        let open = openCollection[item]
        return ZStack {
            Group {
                switch item {
                case .recents: entryList(music.library.recents, empty: "Nothing played recently", in: item)
                case .playlists: entryList(music.library.playlists, empty: "No playlists", in: item)
                default: entryList(music.library.albums, empty: "No albums in your library", in: item)
                }
            }
            .opacity(open == nil ? 1 : 0)
            .allowsHitTesting(open == nil)
            .accessibilityHidden(open != nil)

            if let open {
                MusicCollectionView(entry: open, backTitle: item.rawValue) {
                    withAnimation(.snappy) { openCollection[item] = nil }
                }
                .id(open.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var searchContent: some View {
        VStack(spacing: Theme.gap) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("Songs, artists, albums", text: $query)
                    .font(.dashBody)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("music.search")
                if music.isSearching { ProgressView() }
                DictationButton(text: $query, identifier: "music.search.dictate")
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
            .padding(.leading, 16)
            .frame(minHeight: Theme.minTouch + 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onChange(of: query) { _, newValue in music.search(newValue) }

            if let note = music.searchNote {
                Text(note).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            entryList(music.searchResults,
                      empty: query.isEmpty ? "Search your library" : (music.isSearching ? "Searching…" : "No results"),
                      queueAll: true, padTop: false)
        }
    }

    @ViewBuilder
    private func entryList(_ entries: [MusicEntry], empty: String, in listTab: MusicTab? = nil,
                           queueAll: Bool = false, padTop: Bool = true) -> some View {
        if music.isLoadingLibrary && entries.isEmpty && !queueAll {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            EmptyStateView(symbol: "music.note", title: empty)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.gap)], spacing: Theme.gap) {
                    // Rows in the visible tab are music.row.N; rows in tabs kept alive behind it get
                    // tab-scoped ids, so ids never repeat (UI tests, automation).
                    let owner = listTab ?? .search
                    let idPrefix = owner == tab ? "music" : "music.\(owner)"
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        MusicEntryRow(entry: entry, index: index, idPrefix: idPrefix,
                                      isPending: music.pendingEntryID == entry.id,
                                      isCurrent: false) {
                            if let listTab, entry.kind == .album || entry.kind == .playlist {
                                // Playlists and albums open their page; songs play directly.
                                withAnimation(.snappy) { openCollection[listTab] = entry }
                            } else {
                                music.play(entry, queue: queueAll ? entries.filter { $0.kind == entry.kind } : nil)
                            }
                        } onShuffle: {
                            music.play(entry, shuffle: true)
                        }
                    }
                }
                .padding(.top, padTop ? 4 : 0)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }
}

private struct MusicEntryRow: View {
    @Environment(AppleMusicModel.self) private var music
    let entry: MusicEntry
    let index: Int
    var idPrefix = "music"
    let isPending: Bool
    let isCurrent: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                HStack(spacing: 14) {
                    ZStack {
                        if let url = entry.artworkURL, image == nil {
                            AsyncImage(url: url) { phase in
                                if let loaded = phase.image { loaded.resizable().scaledToFill() } else { ArtworkView(image: nil, size: 52) }
                            }
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            ArtworkView(image: image, size: 52)
                        }
                        if isPending {
                            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.5)).frame(width: 52, height: 52)
                            ProgressView()
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.dashBody).lineLimit(1)
                        Text(entry.subtitle).font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if entry.kind == .album || entry.kind == .playlist {
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
            .accessibilityIdentifier("\(idPrefix).row.\(index)")

            if entry.kind == .album || entry.kind == .playlist {
                Button(action: onShuffle) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: Theme.minTouch, height: Theme.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Shuffle \(entry.title)")
                .accessibilityIdentifier("\(idPrefix).shuffle.\(index)")
            }
        }
        .padding(.trailing, 4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: entry.id) {
            if entry.artworkURL == nil { image = music.artwork(for: entry, size: 120) }
        }
    }
}

/// Title + icon normally; icon only in compact windows.
struct DashLabelStyle: LabelStyle {
    var iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
            if !iconOnly { configuration.title }
        }
        .frame(minWidth: iconOnly ? Theme.minTouch - 32 : nil)
    }
}
