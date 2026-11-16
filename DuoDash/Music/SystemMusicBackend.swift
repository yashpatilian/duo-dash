import MediaPlayer
import MusicKit
import UIKit

/// Plays through the system Music app (MPMusicPlayerController.systemMusicPlayer).
/// Audio runs in the Music app's process, so our voice prompts can duck it without
/// our own audio session ever owning the music.
@MainActor
final class SystemMusicBackend: MusicBackend {
    let isDemo = false
    var onChange: (@MainActor () -> Void)?

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var observers: [NSObjectProtocol] = []
    private let artworkCache = NSCache<NSString, UIImage>()

    init() {
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     Notification.Name.MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(center.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
    }

    // MARK: Access

    func authorizationStatus() -> MusicAccess {
        Self.map(MPMediaLibrary.authorizationStatus())
    }

    func requestAccess() async -> MusicAccess {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        return Self.map(status)
    }

    private static func map(_ status: MPMediaLibraryAuthorizationStatus) -> MusicAccess {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: Library

    func loadLibrary() async -> MusicLibrary {
        await Task.detached(priority: .userInitiated) { Self.buildLibrary() }.value
    }

    nonisolated private static func buildLibrary() -> MusicLibrary {
        var library = MusicLibrary()

        // Recently played albums, newest first (from each song's last-played date).
        let songs = MPMediaQuery.songs().items ?? []
        let played = songs
            .filter { $0.lastPlayedDate != nil }
            .sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
        var seenAlbums = Set<UInt64>()
        for item in played where item.albumPersistentID != 0 {
            guard seenAlbums.insert(item.albumPersistentID).inserted else { continue }
            library.recents.append(MusicEntry(kind: .album, persistentID: item.albumPersistentID,
                                              title: item.albumTitle ?? "Album",
                                              subtitle: item.albumArtist ?? item.artist ?? ""))
            if library.recents.count >= 20 { break }
        }

        let playlists = (MPMediaQuery.playlists().collections as? [MPMediaPlaylist]) ?? []
        library.playlists = playlists
            .filter { $0.count > 0 }
            .prefix(60)
            .map { MusicEntry(kind: .playlist, persistentID: $0.persistentID,
                              title: $0.name ?? "Playlist",
                              subtitle: "\($0.count) songs") }

        let albums = MPMediaQuery.albums().collections ?? []
        library.albums = albums
            .compactMap { collection -> (MPMediaItem, Date)? in
                guard let item = collection.representativeItem else { return nil }
                return (item, item.dateAdded)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(40)
            .map { item, _ in
                MusicEntry(kind: .album, persistentID: item.albumPersistentID,
                           title: item.albumTitle ?? "Album",
                           subtitle: item.albumArtist ?? item.artist ?? "")
            }
        return library
    }

    // MARK: Playlists and albums

    func loadCollection(_ entry: MusicEntry) async throws -> MusicCollection {
        let result = await Task.detached(priority: .userInitiated) { Self.buildCollection(entry) }.value
        guard let result else { throw MusicPlaybackError.notFound }
        return result
    }

    /// Reads every track off the main thread. Only plain values leave this function.
    nonisolated private static func buildCollection(_ entry: MusicEntry) -> MusicCollection? {
        switch entry.kind {
        case .playlist:
            guard let playlist = collectionQuery(for: entry)?.collections?.first as? MPMediaPlaylist else { return nil }
            let owner = playlist.authorDisplayName.flatMap { $0.isEmpty ? nil : $0 } ?? "Playlist"
            return MusicCollection(entry: entry, title: playlist.name ?? entry.title, subtitle: owner,
                                   tracks: tracks(from: playlist.items, isAlbum: false))
        case .album:
            guard let album = collectionQuery(for: entry)?.collections?.first,
                  let first = album.representativeItem ?? album.items.first else { return nil }
            var subtitle = first.albumArtist ?? first.artist ?? entry.subtitle
            if let date = first.releaseDate {
                subtitle += " · \(Calendar.current.component(.year, from: date))"
            }
            return MusicCollection(entry: entry, title: first.albumTitle ?? entry.title, subtitle: subtitle,
                                   tracks: tracks(from: album.items, isAlbum: true))
        case .song, .catalogSong:
            return nil
        }
    }

    nonisolated private static func tracks(from items: [MPMediaItem], isAlbum: Bool) -> [MusicTrack] {
        items.enumerated().map { position, item in
            MusicTrack(position: position, persistentID: item.persistentID,
                       title: item.title ?? "Unknown song",
                       artist: item.artist ?? item.albumArtist ?? "",
                       duration: item.playbackDuration,
                       trackNumber: isAlbum && item.albumTrackNumber > 0 ? item.albumTrackNumber : nil,
                       isCloud: item.isCloudItem)
        }
    }

    nonisolated private static func collectionQuery(for entry: MusicEntry) -> MPMediaQuery? {
        switch entry.kind {
        case .playlist: query(.playlists(), MPMediaPlaylistPropertyPersistentID, entry.persistentID)
        case .album: query(.albums(), MPMediaItemPropertyAlbumPersistentID, entry.persistentID)
        case .song, .catalogSong: nil
        }
    }

    /// The media items of the collection whose rows are on screen, kept so row
    /// artwork doesn't run a library query per row while scrolling.
    private var visibleItems: (id: String, items: [MPMediaItem])?

    private func items(of entry: MusicEntry) -> [MPMediaItem] {
        if let visibleItems, visibleItems.id == entry.id { return visibleItems.items }
        let items = Self.collectionQuery(for: entry)?.collections?.first?.items ?? []
        visibleItems = (entry.id, items)
        return items
    }

    /// The item at a track's position, or the same song elsewhere if the list changed.
    private func item(for track: MusicTrack, in items: [MPMediaItem]) -> MPMediaItem? {
        if track.position < items.count, items[track.position].persistentID == track.persistentID {
            return items[track.position]
        }
        return items.first { $0.persistentID == track.persistentID }
    }

    func artwork(for track: MusicTrack, in collection: MusicEntry, size: CGFloat) -> UIImage? {
        let key = "song:\(track.persistentID)@\(Int(size))" as NSString
        if let cached = artworkCache.object(forKey: key) { return cached }
        guard let item = item(for: track, in: items(of: collection)),
              let image = item.artwork?.image(at: CGSize(width: size, height: size)) else { return nil }
        artworkCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Search

    func search(_ term: String) async -> (results: [MusicEntry], note: String?) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], nil) }

        let local = await Task.detached(priority: .userInitiated) { Self.searchLibrary(trimmed) }.value

        var catalog: [MusicEntry] = []
        var note: String?
        if MusicAuthorization.currentStatus == .authorized {
            do {
                var request = MusicCatalogSearchRequest(term: trimmed, types: [Song.self])
                request.limit = 15
                let response = try await request.response()
                catalog = response.songs.map { song in
                    MusicEntry(kind: .catalogSong, persistentID: 0, storeID: song.id.rawValue,
                               title: song.title, subtitle: song.artistName,
                               artworkURL: song.artwork?.url(width: 120, height: 120))
                }
            } catch {
                note = "Apple Music catalogue search is unavailable (MusicKit must be enabled for this App ID). Showing your library only."
            }
        } else {
            note = "Showing your library only."
        }
        // Library matches first, then catalogue songs not already in the library.
        let localTitles = Set(local.map { "\($0.title)|\($0.subtitle)".lowercased() })
        let extra = catalog.filter { !localTitles.contains("\($0.title)|\($0.subtitle)".lowercased()) }
        return (local + extra, note)
    }

    nonisolated private static func searchLibrary(_ term: String) -> [MusicEntry] {
        var results: [MusicEntry] = []
        var seen = Set<UInt64>()
        for property in [MPMediaItemPropertyTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle] {
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: term, forProperty: property,
                                                              comparisonType: .contains))
            for item in query.items ?? [] where seen.insert(item.persistentID).inserted {
                results.append(MusicEntry(kind: .song, persistentID: item.persistentID,
                                          title: item.title ?? "Song",
                                          subtitle: [item.artist, item.albumTitle].compactMap { $0 }.joined(separator: " · ")))
                if results.count >= 25 { return results }
            }
        }
        return results
    }

    // MARK: Artwork

    func artwork(for entry: MusicEntry, size: CGFloat) -> UIImage? {
        let key = "\(entry.id)@\(Int(size))" as NSString
        if let cached = artworkCache.object(forKey: key) { return cached }
        guard let item = representativeItem(for: entry),
              let image = item.artwork?.image(at: CGSize(width: size, height: size)) else { return nil }
        artworkCache.setObject(image, forKey: key)
        return image
    }

    private func representativeItem(for entry: MusicEntry) -> MPMediaItem? {
        switch entry.kind {
        case .song:
            return Self.query(.songs(), MPMediaItemPropertyPersistentID, entry.persistentID).items?.first
        case .album:
            return Self.query(.songs(), MPMediaItemPropertyAlbumPersistentID, entry.persistentID).items?.first
        case .playlist:
            return Self.query(.playlists(), MPMediaPlaylistPropertyPersistentID, entry.persistentID)
                .collections?.first?.representativeItem
        case .catalogSong:
            return nil
        }
    }

    nonisolated private static func query(_ query: MPMediaQuery, _ property: String, _ id: UInt64) -> MPMediaQuery {
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: property))
        return query
    }

    // MARK: Playback

    func play(_ entry: MusicEntry, queue: [MusicEntry]?, shuffle: Bool) async throws {
        switch entry.kind {
        case .song:
            let songIDs = (queue ?? [entry]).filter { $0.kind == .song }.map(\.persistentID)
            let items = songIDs.compactMap { Self.query(.songs(), MPMediaItemPropertyPersistentID, $0).items?.first }
            guard let start = items.first(where: { $0.persistentID == entry.persistentID }) else {
                throw MusicPlaybackError.notFound
            }
            player.setQueue(with: MPMediaItemCollection(items: items))
            player.nowPlayingItem = start
        case .album, .playlist:
            try await playCollection(entry, startingAt: nil, shuffle: shuffle)
            return
        case .catalogSong:
            guard let storeID = entry.storeID else { throw MusicPlaybackError.notFound }
            let ids = (queue ?? [entry]).compactMap(\.storeID)
            let descriptor = MPMusicPlayerStoreQueueDescriptor(storeIDs: ids.isEmpty ? [storeID] : ids)
            descriptor.startItemID = storeID
            player.setQueue(with: descriptor)
        }
        player.shuffleMode = shuffle ? .songs : .off
        try await start(failure: entry.kind == .catalogSong
            ? "Couldn't stream that song. An Apple Music subscription and a data connection are needed."
            : "Couldn't start playback. If the song is in iCloud, check your data connection.")
    }

    func playCollection(_ entry: MusicEntry, startingAt track: MusicTrack?, shuffle: Bool) async throws {
        // Fresh items: the library may have changed since the page loaded.
        visibleItems = nil
        let items = items(of: entry)
        guard !items.isEmpty else { throw MusicPlaybackError.notFound }
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: items))
        var startItem: MPMediaItem?
        if let track {
            guard let found = item(for: track, in: items) else {
                throw MusicPlaybackError.unavailable("“\(track.title)” is no longer in this list.")
            }
            startItem = found
            descriptor.startItem = found
        }
        // Set the mode before the queue so turning shuffle off doesn't reorder
        // the new queue away from its start item.
        player.shuffleMode = shuffle ? .songs : .off
        player.setQueue(with: descriptor)
        if let startItem { player.nowPlayingItem = startItem }
        let name = track.map { "“\($0.title)”" } ?? "“\(entry.title)”"
        try await start(failure: startItem?.isCloudItem == true
            ? "Couldn't play \(name). It's in iCloud: check your data connection."
            : "Couldn't play \(name). It may no longer be available in Apple Music.")
    }

    private func start(failure: String) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                player.prepareToPlay { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            throw MusicPlaybackError.unavailable(failure)
        }
        player.play()
        onChange?()
    }

    func togglePlayPause() {
        if player.playbackState == .playing {
            player.pause()
        } else {
            player.play()
        }
        onChange?()
    }

    func skipToNext() {
        player.skipToNextItem()
        onChange?()
    }

    /// Like CarPlay: restart the song if we're more than a few seconds in.
    func skipToPrevious() {
        if currentTime > 3 {
            player.skipToBeginning()
        } else {
            player.skipToPreviousItem()
        }
        onChange?()
    }

    func setShuffle(_ on: Bool) {
        player.shuffleMode = on ? .songs : .off
        onChange?()
    }

    func setRepeat(_ setting: RepeatSetting) {
        switch setting {
        case .off: player.repeatMode = .none
        case .all: player.repeatMode = .all
        case .one: player.repeatMode = .one
        }
        onChange?()
    }

    // MARK: State

    var currentTime: TimeInterval {
        let time = player.currentPlaybackTime
        return time.isFinite && time >= 0 ? time : 0
    }

    var snapshot: PlayerSnapshot {
        var snapshot = PlayerSnapshot()
        snapshot.shuffle = player.shuffleMode != .off
        switch player.repeatMode {
        case .one: snapshot.repeatSetting = .one
        case .all: snapshot.repeatSetting = .all
        default: snapshot.repeatSetting = .off
        }
        guard let item = player.nowPlayingItem else { return snapshot }
        let state = player.playbackState
        let key = "now:\(item.persistentID)" as NSString
        var artwork = artworkCache.object(forKey: key)
        if artwork == nil, let image = item.artwork?.image(at: CGSize(width: 600, height: 600)) {
            artworkCache.setObject(image, forKey: key)
            artwork = image
        }
        snapshot.track = TrackInfo(title: item.title ?? "Unknown song",
                                   artist: item.artist ?? "",
                                   album: item.albumTitle ?? "",
                                   artwork: artwork,
                                   isPlaying: state == .playing || state == .seekingForward || state == .seekingBackward,
                                   duration: item.playbackDuration)
        return snapshot
    }
}
