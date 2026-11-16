import SwiftUI
import Observation

/// Where audio is coming from.
enum AudioSource: String {
    case none, appleMusic, spotify

    var displayName: String {
        switch self {
        case .none: "No audio"
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        }
    }

    var symbol: String {
        switch self {
        case .none: "speaker.slash.fill"
        case .appleMusic: "music.note"
        case .spotify: "headphones"
        }
    }

    var dockItem: DockItem? {
        switch self {
        case .none: nil
        case .appleMusic: .music
        case .spotify: .spotify
        }
    }
}

/// Playback controls a source provides. Apple Music and (later) Spotify implement it.
@MainActor
protocol NowPlayingController: AnyObject {
    func togglePlayPause()
    func skipToNext()
    func skipToPrevious()
}

/// What a source reports about its current track.
struct TrackInfo: Equatable {
    var title: String
    var artist: String
    var album: String = ""
    var artwork: UIImage?
    var isPlaying: Bool
    var duration: TimeInterval = 0
}

/// One shared now-playing state for whichever source is active.
/// Read by the now-playing bar, the Home card and the Music screen.
///
/// Arbitration: the source that most recently *started playing* becomes active.
/// A source that pauses stays active (so Play resumes it) until another starts.
@MainActor
@Observable
final class NowPlayingModel {
    private(set) var source: AudioSource = .none
    private(set) var track: TrackInfo?

    @ObservationIgnored private var controllers: [AudioSource: NowPlayingController] = [:]
    @ObservationIgnored private var latest: [AudioSource: TrackInfo] = [:]

    var title: String? { track?.title }
    var artist: String? { track?.artist }
    var artwork: UIImage? { track?.artwork }
    var isPlaying: Bool { track?.isPlaying ?? false }
    var hasTrack: Bool { track != nil }

    func register(_ source: AudioSource, controller: NowPlayingController) {
        controllers[source] = controller
    }

    /// A source reports its state. `nil` means it has nothing loaded.
    func update(_ source: AudioSource, track newTrack: TrackInfo?) {
        latest[source] = newTrack
        let startedPlaying = newTrack?.isPlaying == true
        if source == self.source {
            if let newTrack {
                track = newTrack
            } else {
                // Active source went empty: fall back to any other source that has a track.
                if let other = latest.first(where: { $0.key != source }) {
                    self.source = other.key
                    track = other.value
                } else {
                    self.source = .none
                    track = nil
                }
            }
        } else if startedPlaying || self.source == .none, let newTrack {
            self.source = source
            track = newTrack
        }
    }

    func togglePlayPause() { controllers[source]?.togglePlayPause() }
    func skipToNext() { controllers[source]?.skipToNext() }
    func skipToPrevious() { controllers[source]?.skipToPrevious() }
}
