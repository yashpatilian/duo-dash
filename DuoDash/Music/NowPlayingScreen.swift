import SwiftUI
import UIKit

/// What the full player shows and drives. Apple Music and Spotify both provide it.
@MainActor
protocol PlayerSource: AnyObject {
    var track: TrackInfo? { get }
    var snapshot: PlayerSnapshot { get }
    var currentTime: TimeInterval { get }
    func togglePlayPause()
    func skipToNext()
    func skipToPrevious()
    func toggleShuffle()
    func cycleRepeat()
}

extension AppleMusicModel: PlayerSource {}

/// The Apple Music player.
struct MusicNowPlayingView: View {
    @Environment(AppleMusicModel.self) private var music

    var body: some View {
        PlayerView(source: music, idPrefix: "music",
                   emptyMessage: "Pick something from Recents, Playlists or Albums.")
    }
}

/// Full-screen player in the style of Apple Music: big artwork over a blurred,
/// artwork-coloured backdrop, left-aligned title, a thin scrubber, and the
/// transport floating in a Liquid Glass capsule.
struct PlayerView: View {
    let source: any PlayerSource
    /// Accessibility identifiers are "<prefix>.np.title" and so on.
    var idPrefix = "music"
    var emptyMessage = ""
    /// Extra height kept free in the stacked layout (Spotify keeps the mini bar
    /// below it); the art may then shrink below its usual 100 pt minimum.
    var extraReserve: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            if let track = source.track {
                if w >= h * 1.1 {
                    // Side by side: art on the left, everything else beside it.
                    let art = max(120, min(h - 48, w * 0.42, 440))
                    let column = min(w - art - 72, 460)
                    HStack(spacing: 32) {
                        Artwork(image: track.artwork, isPlaying: track.isPlaying)
                            .frame(width: art, height: art)
                        VStack(alignment: .leading, spacing: 18) {
                            TrackText(track: track, large: column >= 320, idPrefix: idPrefix)
                            ScrubberView(source: source, duration: track.duration)
                            TransportCapsule(source: source, idPrefix: idPrefix, isPlaying: track.isPlaying, width: column)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(width: column)
                    }
                    .padding(.horizontal, 20)
                    .frame(width: w, height: h)
                } else {
                    // Stacked: the art takes whatever height the controls leave.
                    let controls: CGFloat = w - 48 >= 360 ? 88 : 160
                    let art = max(extraReserve > 0 ? 60 : 100, min(w - 56, h - controls - 170 - extraReserve, 420))
                    VStack(alignment: .leading, spacing: 16) {
                        Artwork(image: track.artwork, isPlaying: track.isPlaying)
                            .frame(width: art, height: art)
                            .frame(maxWidth: .infinity)
                        TrackText(track: track, large: false, idPrefix: idPrefix)
                        ScrubberView(source: source, duration: track.duration)
                        TransportCapsule(source: source, idPrefix: idPrefix, isPlaying: track.isPlaying, width: w - 48)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 24)
                    .frame(width: w, height: h)
                }
            } else {
                EmptyStateView(symbol: "waveform", title: "Nothing playing", message: emptyMessage)
                    .frame(width: w, height: h)
            }
        }
    }
}

/// The blurred artwork wash behind the whole Music screen while the player shows.
struct ArtworkBackdrop: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80, opaque: true)
                    .saturation(1.5)
                    .scaleEffect(1.3)
                    .opacity(0.9)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            }
            // Keeps white text readable on light covers.
            LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: image.map(ObjectIdentifier.init))
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// Cover art with a soft shadow; eases back a little while paused, like Apple Music.
private struct Artwork: View {
    let image: UIImage?
    let isPlaying: Bool

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let shape = RoundedRectangle(cornerRadius: max(8, side * 0.035), style: .continuous)
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Theme.surfaceRaised
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.36, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(0.08), lineWidth: 1) }
                .shadow(color: .black.opacity(isPlaying ? 0.5 : 0.3), radius: isPlaying ? 30 : 16, y: isPlaying ? 18 : 8)
                .scaleEffect(isPlaying ? 1 : 0.84)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .animation(.spring(response: 0.45, dampingFraction: 0.72), value: isPlaying)
        }
        .accessibilityHidden(true)
    }
}

private struct TrackText: View {
    let track: TrackInfo
    let large: Bool
    let idPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title)
                .font(.system(size: large ? 30 : 24, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier("\(idPrefix).np.title")
            Text(track.artist)
                .font(.system(size: large ? 22 : 19, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
            if !track.album.isEmpty {
                Text(track.album)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Thin white bar with elapsed / remaining time underneath.
private struct ScrubberView: View {
    let source: any PlayerSource
    let duration: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let elapsed = min(source.currentTime, max(duration, 0))
            let fraction = duration > 0 ? elapsed / duration : 0
            VStack(spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(.white.opacity(0.92))
                            .frame(width: max(6, proxy.size.width * fraction))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text(Self.format(elapsed))
                    Spacer()
                    Text("-" + Self.format(max(duration - elapsed, 0)))
                }
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Track position")
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The transport in one floating Liquid Glass capsule. Narrow windows move
/// shuffle and repeat into a second, smaller capsule.
private struct TransportCapsule: View {
    let source: any PlayerSource
    let idPrefix: String
    let isPlaying: Bool
    let width: CGFloat

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            if width >= 360 {
                HStack(spacing: 0) {
                    shuffle
                    Spacer(minLength: 0)
                    transport
                    Spacer(minLength: 0)
                    repeatButton
                }
                .padding(.horizontal, 8)
                .frame(width: min(width, 440), height: 88)
                .glassEffect(.regular.interactive(), in: Capsule())
            } else {
                VStack(spacing: 12) {
                    transport
                        .padding(.horizontal, 8)
                        .frame(height: 84)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    HStack(spacing: 8) { shuffle; repeatButton }
                        .padding(.horizontal, 6)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 4) {
            GlyphButton(symbol: "backward.fill", size: 30, label: "Previous", identifier: "\(idPrefix).np.previous") {
                source.skipToPrevious()
            }
            GlyphButton(symbol: isPlaying ? "pause.fill" : "play.fill", size: 44,
                        label: isPlaying ? "Pause" : "Play", identifier: "\(idPrefix).np.playpause") {
                source.togglePlayPause()
            }
            .contentTransition(.symbolEffect(.replace))
            GlyphButton(symbol: "forward.fill", size: 30, label: "Next", identifier: "\(idPrefix).np.next") {
                source.skipToNext()
            }
        }
    }

    private var shuffle: some View {
        GlyphButton(symbol: "shuffle", size: 19, isOn: source.snapshot.shuffle,
                    label: "Shuffle", identifier: "\(idPrefix).np.shuffle") { source.toggleShuffle() }
    }

    private var repeatButton: some View {
        GlyphButton(symbol: source.snapshot.repeatSetting.symbol, size: 19,
                    isOn: source.snapshot.repeatSetting != .off,
                    label: "Repeat", identifier: "\(idPrefix).np.repeat") { source.cycleRepeat() }
    }
}

/// A plain white glyph with a full-size touch target. "On" toggles get a soft
/// white disc behind them, as in Apple Music.
struct GlyphButton: View {
    let symbol: String
    let size: CGFloat
    var isOn: Bool? = nil
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(isOn == false ? 0.72 : 1))
                .frame(width: max(Theme.minTouch, size * 1.7), height: max(Theme.minTouch, size * 1.7))
                .background {
                    if isOn == true {
                        Circle().fill(.white.opacity(0.22)).padding(8)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isOn == true ? .isSelected : [])
    }
}

/// Previous / play-pause / next as white glyphs in one Liquid Glass capsule, the same
/// controls as the full player. Used by the mini bar and the Home media card.
struct GlassTransport: View {
    let isPlaying: Bool
    var showsPrevious = true
    var scale: CGFloat = 1
    var idPrefix: String
    let previous: () -> Void
    let playPause: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if showsPrevious {
                GlyphButton(symbol: "backward.fill", size: 22 * scale, label: "Previous",
                            identifier: "\(idPrefix).previous", action: previous)
            }
            GlyphButton(symbol: isPlaying ? "pause.fill" : "play.fill", size: 28 * scale,
                        label: isPlaying ? "Pause" : "Play", identifier: "\(idPrefix).playpause", action: playPause)
                .contentTransition(.symbolEffect(.replace))
            GlyphButton(symbol: "forward.fill", size: 22 * scale, label: "Next",
                        identifier: "\(idPrefix).next", action: next)
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}
