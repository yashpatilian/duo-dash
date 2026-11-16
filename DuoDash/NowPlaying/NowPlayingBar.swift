import SwiftUI

/// Persistent now-playing strip along the bottom of every screen.
struct NowPlayingBar: View {
    @Environment(NowPlayingModel.self) private var nowPlaying
    @Environment(AppModel.self) private var app
    @Environment(\.dashMetrics) private var metrics

    var body: some View {
        let hasSource = nowPlaying.source != .none
        HStack(spacing: 12) {
            Button {
                app.open(nowPlaying.source.dockItem ?? .music)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(image: nowPlaying.artwork, size: metrics.isCompact ? 44 : 50)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(nowPlaying.title ?? "Not playing")
                            .font(.dashBody)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Image(systemName: nowPlaying.source.symbol)
                            Text(nowPlaying.artist ?? "Tap to choose music")
                        }
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(nowPlaying.title ?? "Not playing")
            .accessibilityValue(nowPlaying.artist ?? "")
            .accessibilityIdentifier("nowplaying.open")

            if hasSource {
                if !metrics.isCompact {
                    DashIconButton(symbol: "backward.fill", label: "Previous", identifier: "nowplaying.previous") {
                        nowPlaying.skipToPrevious()
                    }
                }
                DashIconButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", prominent: true,
                               label: nowPlaying.isPlaying ? "Pause" : "Play", identifier: "nowplaying.playpause") {
                    nowPlaying.togglePlayPause()
                }
                DashIconButton(symbol: "forward.fill", label: "Next", identifier: "nowplaying.next") {
                    nowPlaying.skipToNext()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .animation(.snappy, value: hasSource)
    }
}

/// Album art with a placeholder.
struct ArtworkView: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Theme.surfaceRaised)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}
