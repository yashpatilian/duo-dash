import UIKit

/// Permission state for the music library.
enum MusicAccess: Equatable {
    case notDetermined, denied, restricted, authorized
}

/// One thing that can be played: a song, album, playlist or catalogue song.
struct MusicEntry: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case song, album, playlist, catalogSong }

    let kind: Kind
    let persistentID: UInt64
    var storeID: String? = nil
    let title: String
    let subtitle: String
    var artworkURL: URL? = nil

    var id: String { "\(kind.rawValue):\(storeID ?? String(persistentID))" }
}

/// One song inside a playlist or album, at its position in that list. The
/// position is the identity, because a playlist can hold the same song twice.
struct MusicTrack: Identifiable, Hashable, Sendable {
    let position: Int
    let persistentID: UInt64
    let title: String
    let artist: String
    let duration: TimeInterval
    /// Album track number, when known (album pages show it instead of artwork).
    var trackNumber: Int? = nil
    /// Stored in iCloud / Apple Music rather than on the phone.
    var isCloud = false

    var id: Int { position }
}

/// The contents of a playlist or album, for its detail page.
struct MusicCollection: Sendable {
    let entry: MusicEntry
    var title: String
    /// Owner (playlists) or artist and year (albums).
    var subtitle: String
    var tracks: [MusicTrack]

    var totalDuration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }

    /// "300 songs, 18 hr 4 min".
    var summary: String {
        let count = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        let total = totalDuration
        return total > 0 ? "\(count), \(MusicFormat.totalDuration(total))" : count
    }
}

enum MusicFormat {
    /// "3:07", or "1:02:03" for very long tracks.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "42 min", "1 hr 5 min".
    static func totalDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(rest) min"
    }
}

/// Play order for a collection, as positions into its track list.
enum MusicQueue {
    /// In order: every track, starting at `start` (earlier tracks stay before it,
    /// so Previous works like Apple Music). Shuffled: `start` (if any) plays first,
    /// then the rest in random order.
    static func order<G: RandomNumberGenerator>(count: Int, start: Int?, shuffle: Bool,
                                                using rng: inout G) -> (order: [Int], index: Int) {
        guard count > 0 else { return ([], 0) }
        let start = start.map { min(max($0, 0), count - 1) }
        guard shuffle else { return (Array(0..<count), start ?? 0) }
        var rest = Array(0..<count)
        if let start { rest.remove(at: start) }
        rest.shuffle(using: &rng)
        return ((start.map { [$0] } ?? []) + rest, 0)
    }

    static func order(count: Int, start: Int?, shuffle: Bool) -> (order: [Int], index: Int) {
        var rng = SystemRandomNumberGenerator()
        return order(count: count, start: start, shuffle: shuffle, using: &rng)
    }
}

struct MusicLibrary: Sendable {
    var recents: [MusicEntry] = []
    var playlists: [MusicEntry] = []
    var albums: [MusicEntry] = []

    var isEmpty: Bool { recents.isEmpty && playlists.isEmpty && albums.isEmpty }
}

enum RepeatSetting: String, Sendable {
    case off, all, one

    var next: RepeatSetting {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

struct PlayerSnapshot: Equatable {
    var track: TrackInfo?
    var shuffle = false
    var repeatSetting: RepeatSetting = .off
}

enum MusicPlaybackError: LocalizedError {
    case notFound
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "That item is no longer in your library."
        case .unavailable(let reason): reason
        }
    }
}

/// What the Music screen needs from a player. `SystemMusicBackend` drives the
/// Music app; `DemoMusicBackend` is used in the Simulator and UI tests.
@MainActor
protocol MusicBackend: AnyObject {
    var isDemo: Bool { get }
    var onChange: (@MainActor () -> Void)? { get set }
    var snapshot: PlayerSnapshot { get }
    var currentTime: TimeInterval { get }

    func authorizationStatus() -> MusicAccess
    func requestAccess() async -> MusicAccess
    func loadLibrary() async -> MusicLibrary
    func search(_ term: String) async -> (results: [MusicEntry], note: String?)
    func artwork(for entry: MusicEntry, size: CGFloat) -> UIImage?

    /// Every track of a playlist or album, in order.
    func loadCollection(_ entry: MusicEntry) async throws -> MusicCollection
    func artwork(for track: MusicTrack, in collection: MusicEntry, size: CGFloat) -> UIImage?

    func play(_ entry: MusicEntry, queue: [MusicEntry]?, shuffle: Bool) async throws
    /// Queues the whole playlist/album and starts at `track` (nil: the first
    /// track, or a random one when shuffling).
    func playCollection(_ entry: MusicEntry, startingAt track: MusicTrack?, shuffle: Bool) async throws
    func togglePlayPause()
    func skipToNext()
    func skipToPrevious()
    func setShuffle(_ on: Bool)
    func setRepeat(_ setting: RepeatSetting)
}
