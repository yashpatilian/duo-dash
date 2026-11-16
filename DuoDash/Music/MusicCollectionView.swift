import SwiftUI
import UIKit

/// A playlist's or album's page, like Apple Music in CarPlay: big artwork,
/// Play and Shuffle, then every song. Tapping a song plays the list from there.
struct MusicCollectionView: View {
    @Environment(AppleMusicModel.self) private var music
    let entry: MusicEntry
    /// Name of the list this page was opened from ("Playlists").
    let backTitle: String
    let onBack: () -> Void

    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    @State private var artwork: UIImage?
    @State private var width: CGFloat = 600
    @State private var height: CGFloat = 500

    /// Split View, cover screen portrait: stack the header and centre it.
    private var isNarrow: Bool { width < 520 }
    private var collection: MusicCollection? { music.collections[entry.id] }
    /// Long lists get a filter field.
    private var showsFilter: Bool { (collection?.tracks.count ?? 0) > 12 }

    var body: some View {
        VStack(spacing: Theme.gap) {
            topBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { width = $0.width; height = $0.height }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("music.detail")
        .task(id: entry.id) {
            artwork = music.artwork(for: entry, size: 600)
            await music.loadCollection(entry)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.gap) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .bold))
                    if !(isNarrow && showsFilter) {
                        Text(backTitle).font(.dashBody).lineLimit(1)
                    }
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Back to \(backTitle)")
            .accessibilityIdentifier("music.detail.back")

            if showsFilter {
                filterField
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("Find in \(entry.kind == .album ? "album" : "playlist")", text: $filter)
                .font(.dashBody)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($filterFocused)
                .accessibilityIdentifier("music.detail.filter")
            DictationButton(text: $filter, identifier: "music.detail.filter.dictate")
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.minTouch - 12, height: Theme.minTouch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.leading, 14)
        .frame(minHeight: Theme.minTouch)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // The whole capsule is the target, not just the text's line.
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { filterFocused = true }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let collection {
            let rows = filtered(collection.tracks)
            ScrollView {
                LazyVStack(spacing: 6) {
                    if filter.isEmpty {
                        header(collection)
                            .padding(.bottom, 10)
                    } else if rows.isEmpty {
                        Text("No songs match “\(filter)”")
                            .font(.dashBody)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 40)
                    }
                    ForEach(rows) { track in
                        MusicTrackRow(track: track, collection: entry,
                                      showsArtwork: entry.kind != .album,
                                      isPending: music.pendingEntryID == AppleMusicModel.pendingID(for: track, in: entry)) {
                            music.play(track, in: entry)
                        }
                    }
                }
                .padding(.bottom, Theme.gap)
            }
            .scrollDismissesKeyboard(.immediately)
        } else if let error = music.collectionErrors[entry.id] {
            EmptyStateView(symbol: "exclamationmark.triangle.fill", title: "Couldn't open \(entry.title)",
                           message: error, actionTitle: "Back", action: onBack)
        } else {
            ProgressView().controlSize(.large)
        }
    }

    private func filtered(_ tracks: [MusicTrack]) -> [MusicTrack] {
        let term = filter.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return tracks }
        return tracks.filter { $0.title.localizedCaseInsensitiveContains(term) || $0.artist.localizedCaseInsensitiveContains(term) }
    }

    @ViewBuilder
    private func header(_ collection: MusicCollection) -> some View {
        if isNarrow {
            // Compact, so Play and Shuffle are on screen without scrolling even
            // on the cover screen with the now-playing bar showing.
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    ArtworkView(image: artwork, size: min(112, width * 0.3))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                    headerText(collection, alignment: .leading)
                    Spacer(minLength: 0)
                }
                buttons(collection, fill: true)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .center, spacing: 22) {
                ArtworkView(image: artwork, size: max(96, min(210, width * 0.3, height * 0.42)))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 12) {
                    headerText(collection, alignment: .leading)
                    buttons(collection, fill: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }

    private func headerText(_ collection: MusicCollection, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(entry.kind == .album ? "ALBUM" : "PLAYLIST")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            Text(collection.title)
                .font(isNarrow ? .dashTitle : .dashHero)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .accessibilityIdentifier("music.detail.title")
            Text(collection.subtitle)
                .font(.dashBody)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            Text(collection.summary)
                .font(.dashCaption)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("music.detail.summary")
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    private func buttons(_ collection: MusicCollection, fill: Bool) -> some View {
        let pending = music.pendingEntryID == entry.id
        return HStack(spacing: 12) {
            Button { music.playCollection(entry) } label: {
                bigLabel("Play", symbol: "play.fill", busy: pending, fill: fill)
                    .foregroundStyle(Theme.onAccent)
                    .glassEffect(.regular.tint(Theme.accent).interactive(), in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("music.detail.play")

            Button { music.playCollection(entry, shuffle: true) } label: {
                bigLabel("Shuffle", symbol: "shuffle", busy: false, fill: fill)
                    .foregroundStyle(Theme.accent)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("music.detail.shuffle")
        }
        .disabled(collection.tracks.isEmpty)
    }

    private func bigLabel(_ title: String, symbol: String, busy: Bool, fill: Bool) -> some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().tint(Theme.onAccent)
            } else {
                Image(systemName: symbol).font(.system(size: 19, weight: .bold))
            }
            Text(title).font(.dashBody).lineLimit(1)
        }
        .padding(.horizontal, 24)
        .frame(minWidth: 140, maxWidth: fill ? .infinity : nil, minHeight: Theme.minTouch)
        .contentShape(Capsule())
    }
}

/// One song on a playlist/album page.
private struct MusicTrackRow: View {
    @Environment(AppleMusicModel.self) private var music
    let track: MusicTrack
    let collection: MusicEntry
    let showsArtwork: Bool
    let isPending: Bool
    let onPlay: () -> Void
    @State private var image: UIImage?

    private var isCurrent: Bool {
        guard let now = music.track else { return false }
        return now.title == track.title && now.artist == track.artist
    }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.dashBody)
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.textPrimary)
                        .lineLimit(1)
                    if !track.artist.isEmpty {
                        Text(track.artist)
                            .font(.dashCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if track.isCloud {
                    Image(systemName: "icloud")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("In iCloud")
                }
                Text(MusicFormat.duration(track.duration))
                    .font(.dashCaption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .frame(minHeight: Theme.minTouch + 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(track.title)
        .accessibilityValue([track.artist, MusicFormat.duration(track.duration)].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("music.song.\(track.position)")
        .task(id: track.persistentID) {
            if showsArtwork { image = music.artwork(for: track, in: collection, size: 96) }
        }
    }

    @ViewBuilder
    private var leading: some View {
        ZStack {
            if showsArtwork {
                ArtworkView(image: image, size: 46)
            } else {
                Text("\(track.trackNumber ?? track.position + 1)")
                    .font(.dashBody.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(isCurrent ? 0 : 1)
            }
            if isPending {
                if showsArtwork { RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.5)) }
                ProgressView()
            } else if isCurrent {
                if showsArtwork { RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.45)) }
                Image(systemName: music.track?.isPlaying == true ? "waveform" : "pause.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(showsArtwork ? Theme.textPrimary : Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: music.track?.isPlaying == true)
            }
        }
        .frame(width: 46, height: 46)
    }
}
