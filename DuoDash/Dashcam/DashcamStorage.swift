import Foundation

/// The dashcam's files:
///
///     <base>/Loop/seg-20261116-081500-000001.mov   (+ .json sidecar)
///     <base>/Saved/2026-11-16_08-16-02/            (segments, sidecars, clip.json)
///
/// `base` is `Application Support/Dashcam` in the app and a temp folder in tests.
/// Moves stay on one volume, so they are instant whatever the file size.
final class DashcamStorage {
    let base: URL
    var loopDirectory: URL { base.appending(path: "Loop", directoryHint: .isDirectory) }
    var savedDirectory: URL { base.appending(path: "Saved", directoryHint: .isDirectory) }

    static let videoExtension = "mov"
    static let manifestName = "clip.json"

    private let files = FileManager.default
    private var sequence = 0

    static var defaultBase: URL {
        URL.applicationSupportDirectory.appending(path: "Dashcam", directoryHint: .isDirectory)
    }

    init(base: URL = DashcamStorage.defaultBase) {
        self.base = base
        try? files.createDirectory(at: loopDirectory, withIntermediateDirectories: true)
        try? files.createDirectory(at: savedDirectory, withIntermediateDirectories: true)
        // Footage is large and personal: keep it out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = base
        try? url.setResourceValues(values)
    }

    // MARK: Loop

    /// A new, unique, time-ordered segment file name in the loop folder.
    func newSegmentURL(at date: Date = .now) -> URL {
        sequence += 1
        let stamp = Self.segmentStamp.string(from: date)
        let name = String(format: "seg-%@-%06d.%@", stamp, sequence, Self.videoExtension)
        return loopDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    /// Video files in the loop folder, oldest first.
    func loopSegments() -> [URL] {
        videos(in: loopDirectory)
    }

    /// Deletes the oldest loop segments so at most `keeping` remain, never touching
    /// `protected` ones (file names: the segment being recorded, segments being saved).
    /// Returns what was deleted.
    @discardableResult
    func prune(keeping: Int, protected: Set<String>) -> [URL] {
        let candidates = loopSegments().filter { !protected.contains($0.lastPathComponent) }
        let excess = candidates.count - max(0, keeping)
        guard excess > 0 else { return [] }
        let doomed = Array(candidates.prefix(excess))
        for url in doomed { removeSegment(url) }
        return doomed
    }

    func removeSegment(_ url: URL) {
        try? files.removeItem(at: url)
        try? files.removeItem(at: Self.sidecarURL(for: url))
    }

    static func sidecarURL(for segment: URL) -> URL {
        segment.deletingPathExtension().appendingPathExtension("json")
    }

    func writeSidecar(_ sidecar: DashcamSidecar, for segment: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sidecar) else { return }
        try? data.write(to: Self.sidecarURL(for: segment), options: .atomic)
    }

    func readSidecar(for segment: URL) -> DashcamSidecar? {
        guard let data = try? Data(contentsOf: Self.sidecarURL(for: segment)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DashcamSidecar.self, from: data)
    }

    // MARK: Saved clips

    /// Moves `segments` (and their sidecars) into a new folder under `Saved/`.
    /// Segments that don't exist are skipped; returns nil if none did.
    func saveClip(segments: [URL], manifest: DashcamClipManifest) throws -> DashcamClip? {
        let existing = segments.filter { files.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !existing.isEmpty else { return nil }
        let folder = uniqueFolder(for: manifest.createdAt)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in existing {
            try files.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
            let sidecar = Self.sidecarURL(for: url)
            if files.fileExists(atPath: sidecar.path(percentEncoded: false)) {
                try files.moveItem(at: sidecar, to: folder.appending(path: sidecar.lastPathComponent))
            }
        }
        try writeManifest(manifest, in: folder)
        return clip(in: folder)
    }

    /// Saved clips, newest first.
    func savedClips() -> [DashcamClip] {
        let folders = (try? files.contentsOfDirectory(at: savedDirectory, includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles)) ?? []
        return folders.compactMap(clip(in:)).sorted { $0.createdAt > $1.createdAt }
    }

    func deleteClip(_ clip: DashcamClip) throws {
        try files.removeItem(at: clip.folder)
    }

    func renameClip(_ clip: DashcamClip, to title: String) throws {
        guard var manifest = manifest(in: clip.folder) else { return }
        manifest.title = title
        try writeManifest(manifest, in: clip.folder)
    }

    private func clip(in folder: URL) -> DashcamClip? {
        guard let manifest = manifest(in: folder) else { return nil }
        let videos = videos(in: folder)
        return DashcamClip(id: folder.lastPathComponent, folder: folder, createdAt: manifest.createdAt,
                           title: manifest.title, segments: videos, bytes: size(of: folder))
    }

    private func manifest(in folder: URL) -> DashcamClipManifest? {
        guard let data = try? Data(contentsOf: folder.appending(path: Self.manifestName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DashcamClipManifest.self, from: data)
    }

    private func writeManifest(_ manifest: DashcamClipManifest, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appending(path: Self.manifestName), options: .atomic)
    }

    private func uniqueFolder(for date: Date) -> URL {
        let stamp = Self.clipStamp.string(from: date)
        var folder = savedDirectory.appending(path: stamp, directoryHint: .isDirectory)
        var n = 2
        while files.fileExists(atPath: folder.path(percentEncoded: false)) {
            folder = savedDirectory.appending(path: "\(stamp)-\(n)", directoryHint: .isDirectory)
            n += 1
        }
        return folder
    }

    // MARK: Sizes

    /// Bytes used by the loop folder and by saved clips.
    func usage() -> (loop: Int64, saved: Int64) {
        (size(of: loopDirectory), size(of: savedDirectory))
    }

    /// Free space for "important" data (what iOS would let us use).
    static func freeSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    private func size(of folder: URL) -> Int64 {
        guard let enumerator = files.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private func videos(in folder: URL) -> [URL] {
        let urls = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                    options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.pathExtension == Self.videoExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// UTC, so names always sort in recording order: a daylight-saving change or a drive into
    /// an earlier time zone mustn't make new segments look older (the loop deletes "oldest" first).
    private static let segmentStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let clipStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}
