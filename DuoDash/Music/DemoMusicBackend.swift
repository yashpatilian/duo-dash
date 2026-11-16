import UIKit

/// A silent, deterministic stand-in for the Music app. Used in the Simulator
/// (which has no Music app) and in UI tests, so every screen and control can be
/// exercised end to end. Time advances with a timer while "playing".
@MainActor
final class DemoMusicBackend: MusicBackend {
    let isDemo = true
    var onChange: (@MainActor () -> Void)?

    private struct Song { let id: UInt64; let title: String; let artist: String; let album: String; let duration: TimeInterval; let trackNumber: Int }
    private struct Collection { let title: String; let subtitle: String; let songs: [UInt64] }

    private let songs: [Song]
    private let songsByID: [UInt64: Song]
    private let collections: [MusicEntry.Kind: [UInt64: Collection]]
    private var library = MusicLibrary()
    /// Song IDs in play order, and the position of the current one. Internal so
    /// unit tests can check the queue.
    private(set) var queue: [UInt64] = []
    private(set) var index = 0
    private var isPlaying = false
    private var elapsed: TimeInterval = 0
    private var startedAt: Date?
    private var shuffle = false
    private var repeatSetting: RepeatSetting = .off
    private var access: MusicAccess = .notDetermined
    private var timer: Timer?

    /// The long playlist (300 songs) that proves the song list scrolls smoothly.
    static let favouritesID: UInt64 = 200

    init() {
        // 26 albums of 9 to 15 songs (about 310 songs), every title unique.
        let artists = ["Coastal Lights", "The Overpass", "Nova Rae", "Harbour Line", "Low Tide",
                       "Ivy Lane", "The Long Weekend", "Sol & Sable", "Kestrel", "Atlas Grey",
                       "Wren Hollow", "June Avenue", "Parallel Coast"]
        let albumTitles = ["Open Water", "Afterglow", "Signals", "Long Way Home", "Coastline", "Satellite",
                           "Paper Planes", "Weather Systems", "Slow Burn", "Daybreak", "Low Light", "Northbound",
                           "Carousel", "Static Fields", "Lantern", "Harbour Songs", "Blue Hour", "Tidal",
                           "Rearview", "Golden State", "Small Hours", "Overpass", "Kite String", "Saltwater",
                           "Far Shore", "Lighthouse"]
        let firstWords = ["Open", "Night", "Golden", "Neon", "Silver", "Paper", "Velvet", "Northern",
                          "Electric", "Quiet", "Wild", "Crystal", "Summer", "Distant", "Blue", "Fading",
                          "Hollow", "Bright", "Southern", "Echo", "Ocean", "Static", "Amber", "Lunar"]
        let secondWords = ["Road", "Lights", "Hour", "Signal", "Tide", "Highway", "Hearts", "Skyline",
                           "Rain", "Horizon", "Fever", "Waves", "Avenue", "Dreams"]

        var songs: [Song] = []
        var albums: [UInt64: Collection] = [:]
        var albumEntries: [MusicEntry] = []
        var k = 0
        for (i, albumTitle) in albumTitles.enumerated() {
            let artist = artists[i % artists.count]
            let count = 9 + (i * 5) % 7
            var ids: [UInt64] = []
            for n in 1...count {
                let a = k % firstWords.count, q = k / firstWords.count
                let title = "\(firstWords[a]) \(secondWords[(q + a) % secondWords.count])"
                let id = UInt64(1000 + k)
                songs.append(Song(id: id, title: title, artist: artist, album: albumTitle,
                                  duration: 150 + Double((k * 37) % 140), trackNumber: n))
                ids.append(id)
                k += 1
            }
            let albumID = UInt64(100 + i)
            albums[albumID] = Collection(title: albumTitle, subtitle: "\(artist) · \(2016 + i % 9)", songs: ids)
            albumEntries.append(MusicEntry(kind: .album, persistentID: albumID, title: albumTitle, subtitle: artist))
        }
        self.songs = songs
        self.songsByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })

        let all = songs.map(\.id)
        // A stable scramble of the library, so the long playlist mixes artists.
        let favourites = (0..<min(300, all.count)).map { all[($0 * 7) % all.count] }
        let playlists: [UInt64: Collection] = [
            Self.favouritesID: Collection(title: "Favourite Songs", subtitle: "Demo library", songs: favourites),
            201: Collection(title: "Road Trip", subtitle: "Demo library", songs: all.filter { $0 % 3 == 0 }.prefix(40).map { $0 }),
            202: Collection(title: "Night Drive", subtitle: "Demo library", songs: all.filter { $0 % 7 == 2 }.prefix(25).map { $0 }),
            203: Collection(title: "Morning Commute", subtitle: "Demo library", songs: Array(all.prefix(12))),
        ]
        collections = [.album: albums, .playlist: playlists]

        library.playlists = [Self.favouritesID, 201, 202, 203].map { id in
            MusicEntry(kind: .playlist, persistentID: id, title: playlists[id]!.title,
                       subtitle: "\(playlists[id]!.songs.count) songs")
        }
        library.albums = albumEntries
        // Recents: a few albums (open their page) and a couple of songs (play directly).
        library.recents = Array(albumEntries.prefix(3)) + songs.suffix(2).map {
            MusicEntry(kind: .song, persistentID: $0.id, title: $0.title, subtitle: $0.artist)
        }

        if LaunchOptions.isUITesting { access = .authorized }
    }

    func authorizationStatus() -> MusicAccess { access }

    func requestAccess() async -> MusicAccess {
        try? await Task.sleep(for: .milliseconds(150))
        access = .authorized
        return access
    }

    func loadLibrary() async -> MusicLibrary {
        try? await Task.sleep(for: .milliseconds(200))
        return library
    }

    func search(_ term: String) async -> (results: [MusicEntry], note: String?) {
        try? await Task.sleep(for: .milliseconds(150))
        let t = term.lowercased()
        let hits = songs.filter { $0.title.lowercased().contains(t) || $0.artist.lowercased().contains(t) }
        return (hits.prefix(25).map { MusicEntry(kind: .song, persistentID: $0.id, title: $0.title, subtitle: $0.artist) },
                "Demo library (Simulator)")
    }

    func artwork(for entry: MusicEntry, size: CGFloat) -> UIImage? {
        Self.makeArtwork(seed: entry.persistentID, size: size)
    }

    func loadCollection(_ entry: MusicEntry) async throws -> MusicCollection {
        try await Task.sleep(for: .milliseconds(120))
        guard let collection = collections[entry.kind]?[entry.persistentID] else { throw MusicPlaybackError.notFound }
        let tracks = collection.songs.enumerated().compactMap { position, id -> MusicTrack? in
            guard let song = songsByID[id] else { return nil }
            return MusicTrack(position: position, persistentID: id, title: song.title, artist: song.artist,
                              duration: song.duration, trackNumber: entry.kind == .album ? song.trackNumber : nil,
                              isCloud: id % 11 == 0)
        }
        return MusicCollection(entry: entry, title: collection.title, subtitle: collection.subtitle, tracks: tracks)
    }

    func artwork(for track: MusicTrack, in collection: MusicEntry, size: CGFloat) -> UIImage? {
        Self.makeArtwork(seed: track.persistentID, size: size)
    }

    func play(_ entry: MusicEntry, queue entries: [MusicEntry]?, shuffle: Bool) async throws {
        switch entry.kind {
        case .song, .catalogSong:
            try await Task.sleep(for: .milliseconds(120))
            let ids = (entries ?? [entry]).map(\.persistentID)
            queue = ids
            index = ids.firstIndex(of: entry.persistentID) ?? 0
            self.shuffle = shuffle
            elapsed = 0
            setPlaying(true)
        case .album, .playlist:
            try await playCollection(entry, startingAt: nil, shuffle: shuffle)
        }
    }

    func playCollection(_ entry: MusicEntry, startingAt track: MusicTrack?, shuffle: Bool) async throws {
        try await Task.sleep(for: .milliseconds(120))
        guard let ids = collections[entry.kind]?[entry.persistentID]?.songs, !ids.isEmpty else {
            throw MusicPlaybackError.notFound
        }
        var start: Int?
        if let track {
            // The position is the identity; fall back to the song if the list changed.
            if track.position < ids.count, ids[track.position] == track.persistentID {
                start = track.position
            } else if let found = ids.firstIndex(of: track.persistentID) {
                start = found
            } else {
                throw MusicPlaybackError.unavailable("“\(track.title)” is no longer in this list.")
            }
        }
        let plan = MusicQueue.order(count: ids.count, start: start, shuffle: shuffle)
        queue = plan.order.map { ids[$0] }
        index = plan.index
        self.shuffle = shuffle
        elapsed = 0
        setPlaying(true)
    }

    func togglePlayPause() {
        guard !queue.isEmpty else { return }
        setPlaying(!isPlaying)
    }

    func skipToNext() {
        guard !queue.isEmpty else { return }
        if repeatSetting == .one {
            elapsed = 0
        } else if index + 1 < queue.count {
            index += 1
            elapsed = 0
        } else if repeatSetting == .all {
            index = 0
            elapsed = 0
        } else {
            elapsed = 0
            setPlaying(false)
            return
        }
        if isPlaying { startedAt = Date() }
        onChange?()
    }

    func skipToPrevious() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 || index == 0 {
            elapsed = 0
        } else {
            index -= 1
            elapsed = 0
        }
        if isPlaying { startedAt = Date() }
        onChange?()
    }

    func setShuffle(_ on: Bool) { shuffle = on; onChange?() }
    func setRepeat(_ setting: RepeatSetting) { repeatSetting = setting; onChange?() }

    var currentTime: TimeInterval {
        guard let startedAt, isPlaying else { return elapsed }
        return elapsed + Date().timeIntervalSince(startedAt)
    }

    var snapshot: PlayerSnapshot {
        var snapshot = PlayerSnapshot(track: nil, shuffle: shuffle, repeatSetting: repeatSetting)
        guard index < queue.count, let song = songsByID[queue[index]] else { return snapshot }
        snapshot.track = TrackInfo(title: song.title, artist: song.artist, album: song.album,
                                   artwork: Self.makeArtwork(seed: song.id, size: 600),
                                   isPlaying: isPlaying, duration: song.duration)
        return snapshot
    }

    private func setPlaying(_ playing: Bool) {
        if playing {
            startedAt = Date()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } else {
            elapsed = currentTime
            startedAt = nil
            timer?.invalidate()
            timer = nil
        }
        isPlaying = playing
        onChange?()
    }

    private func tick() {
        guard index < queue.count, let song = songsByID[queue[index]] else { return }
        if currentTime >= song.duration { skipToNext() }
    }

    private static var artworkCache: [String: UIImage] = [:]

    static func makeArtwork(seed: UInt64, size: CGFloat) -> UIImage {
        let key = "\(seed)@\(Int(size))"
        if let cached = artworkCache[key] { return cached }
        let hue = CGFloat((seed * 47) % 360) / 360
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { context in
            let colors = [UIColor(hue: hue, saturation: 0.65, brightness: 0.85, alpha: 1).cgColor,
                          UIColor(hue: fmod(hue + 0.15, 1), saturation: 0.8, brightness: 0.35, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.38, weight: .bold)
            if let note = UIImage(systemName: "music.note", withConfiguration: config)?
                .withTintColor(.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal) {
                note.draw(at: CGPoint(x: (size - note.size.width) / 2, y: (size - note.size.height) / 2))
            }
        }
        artworkCache[key] = image
        return image
    }
}
