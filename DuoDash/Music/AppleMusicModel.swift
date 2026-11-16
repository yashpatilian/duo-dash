import UIKit
import Observation

/// Apple Music state for the UI, and the `.appleMusic` source for NowPlayingModel.
@MainActor
@Observable
final class AppleMusicModel: NowPlayingController {
    private(set) var access: MusicAccess
    private(set) var library = MusicLibrary()
    private(set) var isLoadingLibrary = false
    private(set) var hasLoadedLibrary = false
    private(set) var snapshot = PlayerSnapshot()
    private(set) var searchResults: [MusicEntry] = []
    private(set) var searchNote: String?
    private(set) var isSearching = false
    private(set) var pendingEntryID: String?
    /// Loaded playlist/album pages, by entry id.
    private(set) var collections: [String: MusicCollection] = [:]
    private(set) var collectionErrors: [String: String] = [:]
    var errorMessage: String?

    let isDemo: Bool

    @ObservationIgnored private let backend: MusicBackend
    @ObservationIgnored private let nowPlaying: NowPlayingModel
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var lastQuery = ""

    init(nowPlaying: NowPlayingModel, backend: MusicBackend? = nil) {
        let backend = backend ?? (LaunchOptions.usesDemoMusic ? DemoMusicBackend() : SystemMusicBackend())
        self.backend = backend
        self.nowPlaying = nowPlaying
        self.isDemo = backend.isDemo
        self.access = backend.authorizationStatus()
        nowPlaying.register(.appleMusic, controller: self)
        backend.onChange = { [weak self] in self?.refreshFromPlayer() }
        refreshFromPlayer()
    }

    var track: TrackInfo? { snapshot.track }
    var currentTime: TimeInterval { backend.currentTime }

    // MARK: Access and library

    /// Ask for access if needed, then load the library once.
    func prepare() async {
        if access == .notDetermined {
            access = await backend.requestAccess()
        }
        if access == .authorized, !hasLoadedLibrary, !isLoadingLibrary {
            await reloadLibrary()
        }
    }

    func reloadLibrary() async {
        guard access == .authorized, !isLoadingLibrary else { return }
        isLoadingLibrary = true
        library = await backend.loadLibrary()
        collections = [:]
        collectionErrors = [:]
        isLoadingLibrary = false
        hasLoadedLibrary = true
    }

    func artwork(for entry: MusicEntry, size: CGFloat) -> UIImage? {
        backend.artwork(for: entry, size: size)
    }

    // MARK: Playlists and albums

    /// Loads a playlist's or album's songs once; later visits use the cache.
    func loadCollection(_ entry: MusicEntry) async {
        guard collections[entry.id] == nil else { return }
        collectionErrors[entry.id] = nil
        do {
            collections[entry.id] = try await backend.loadCollection(entry)
        } catch {
            collectionErrors[entry.id] = (error as? LocalizedError)?.errorDescription ?? "Couldn't open “\(entry.title)”."
        }
    }

    func artwork(for track: MusicTrack, in collection: MusicEntry, size: CGFloat) -> UIImage? {
        backend.artwork(for: track, in: collection, size: size)
    }

    /// The id a song row shows its spinner for while it starts.
    static func pendingID(for track: MusicTrack, in collection: MusicEntry) -> String {
        "\(collection.id)#\(track.position)"
    }

    // MARK: Search (debounced)

    func search(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastQuery else { return }
        lastQuery = trimmed
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            searchResults = []
            searchNote = nil
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let result = await backend.search(trimmed)
            guard !Task.isCancelled else { return }
            searchResults = result.results
            searchNote = result.note
            isSearching = false
        }
    }

    // MARK: Playback

    /// Starts an item. Rapid taps cancel the previous request, so the last tap wins.
    func play(_ entry: MusicEntry, queue: [MusicEntry]? = nil, shuffle: Bool = false) {
        start(pendingID: entry.id, title: entry.title) { backend in
            try await backend.play(entry, queue: queue, shuffle: shuffle)
        }
    }

    /// Plays a whole playlist/album from the top (or shuffled).
    func playCollection(_ entry: MusicEntry, shuffle: Bool = false) {
        start(pendingID: entry.id, title: entry.title) { backend in
            try await backend.playCollection(entry, startingAt: nil, shuffle: shuffle)
        }
    }

    /// Plays `track` with the rest of its playlist/album queued around it, in order.
    func play(_ track: MusicTrack, in collection: MusicEntry) {
        start(pendingID: Self.pendingID(for: track, in: collection), title: track.title) { backend in
            try await backend.playCollection(collection, startingAt: track, shuffle: false)
        }
    }

    private func start(pendingID: String, title: String,
                       _ operation: @escaping @MainActor (MusicBackend) async throws -> Void) {
        playTask?.cancel()
        pendingEntryID = pendingID
        errorMessage = nil
        let backend = backend
        playTask = Task {
            do {
                try await operation(backend)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't play “\(title)”."
            }
            if pendingEntryID == pendingID { pendingEntryID = nil }
            refreshFromPlayer()
        }
    }

    func togglePlayPause() { backend.togglePlayPause() }
    func skipToNext() { backend.skipToNext() }
    func skipToPrevious() { backend.skipToPrevious() }
    func toggleShuffle() { backend.setShuffle(!snapshot.shuffle) }
    func cycleRepeat() { backend.setRepeat(snapshot.repeatSetting.next) }

    /// Re-read the player. Also called when the app returns to the foreground,
    /// in case the track was changed from Control Center or the Music app.
    func refreshFromPlayer() {
        let latest = backend.snapshot
        if latest != snapshot { snapshot = latest }
        if access != .authorized, latest.track != nil { access = backend.authorizationStatus() }
        nowPlaying.update(.appleMusic, track: latest.track)
    }
}
