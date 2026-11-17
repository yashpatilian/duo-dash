import Foundation
import Network
import Observation
import UIKit
import WhisperKit

/// Where speech models live: Application Support/Speech (excluded from iCloud backup).
struct SpeechModelLocations {
    let root: URL
    var whisperBase: URL { root.appending(component: "whisper") }
    var kokoroDirectory: URL { root.appending(component: "kokoro") }
    /// URLSession resume data for a paused Kokoro download.
    var kokoroResumeData: URL { root.appending(component: "kokoro-download.resume") }

    static var standard: SpeechModelLocations {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SpeechModelLocations(root: support.appending(component: "Speech"))
    }

    func prepare() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func bytes(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Downloads, prepares and deletes the on-device speech models, keeping
/// `settings.whisperState` / `kokoroState` current. Downloads are cancellable and resume
/// where they stopped (WhisperKit keeps `.incomplete` files; Kokoro keeps URLSession
/// resume data). In `.appleOnly` / `.demo` mode nothing is ever downloaded or loaded.
@MainActor
@Observable
final class SpeechModelStore {
    let settings: SpeechSettings
    @ObservationIgnored let locations: SpeechModelLocations
    @ObservationIgnored let whisperRuntime: WhisperRuntime
    @ObservationIgnored let kokoroRuntime: KokoroRuntime

    /// On mobile data / Low Data Mode: the UI asks before downloading.
    private(set) var isExpensiveNetwork = false
    private(set) var isOffline = false
    /// Bumped after downloads/deletes so storage figures refresh.
    private(set) var storageRevision = 0

    @ObservationIgnored private var whisperTask: Task<Void, Never>?
    @ObservationIgnored private var kokoroTask: Task<Void, Never>?
    @ObservationIgnored private var kokoroDownload: ResumableDownload?
    /// Bumped on every new download or delete. A task whose generation is stale (the user
    /// deleted or restarted meanwhile) changes nothing when it finishes.
    @ObservationIgnored private var whisperGeneration = 0
    @ObservationIgnored private var kokoroGeneration = 0
    /// Whisper is being loaded into memory (don't unload it from under the load).
    @ObservationIgnored private var whisperLoading = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var memoryObserver: NSObjectProtocol?

    private static let kokoroPausedKey = "speech.kokoroPausedFraction"

    init(settings: SpeechSettings, locations: SpeechModelLocations = .standard) {
        self.settings = settings
        self.locations = locations
        whisperRuntime = WhisperRuntime(downloadBase: locations.whisperBase)
        kokoroRuntime = KokoroRuntime(directory: locations.kokoroDirectory)
        guard settings.mode == .full else { return }
        locations.prepare()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in
                self?.isExpensiveNetwork = expensive
                self?.isOffline = offline
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "speech.path"))
        // Whisper is big; give the memory back if iOS asks. It reloads on the next dictation.
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Unloading mid-load would cancel it and look like a failure; let it finish.
                    guard let self, !self.whisperLoading else { return }
                    self.whisperRuntime.unload()
                }
            }
    }

    var whisperVariant: WhisperModelCatalog.Variant {
        WhisperModelCatalog.variant(id: settings.whisperVariantID)
            ?? WhisperModelCatalog.preferred(supported: WhisperKit.recommendedModels().supported)
    }

    /// Reads what's on disk and starts preparing/warming installed models.
    func refresh() {
        guard settings.mode == .full else {
            settings.whisperState = .notDownloaded
            settings.kokoroState = .notDownloaded
            return
        }
        if !settings.whisperState.isBusy {
            if whisperRuntime.isInstalled(settings.whisperVariantID) {
                if settings.whisperPrepared {
                    settings.whisperState = .ready
                } else {
                    prepareWhisper()
                }
            } else if FileManager.default.fileExists(atPath: whisperRuntime.folder(for: whisperVariant.id).path) {
                settings.whisperState = .paused(min(0.99, Double(whisperBytes) / Double(whisperVariant.downloadBytes)))
            } else {
                settings.whisperState = .notDownloaded
            }
        }
        if !settings.kokoroState.isBusy {
            if kokoroRuntime.isInstalled {
                settings.kokoroState = .ready
                if settings.voice == .natural { kokoroRuntime.warmUp() }
            } else if FileManager.default.fileExists(atPath: locations.kokoroResumeData.path) {
                settings.kokoroState = .paused(UserDefaults.standard.double(forKey: Self.kokoroPausedKey))
            } else {
                settings.kokoroState = .notDownloaded
            }
        }
    }

    // MARK: - Whisper

    func downloadWhisper() {
        guard settings.mode == .full, whisperTask == nil else { return }
        let variant = whisperVariant
        settings.whisperVariantID = variant.id
        settings.whisperPrepared = false
        settings.whisperState = .downloading(currentFraction(settings.whisperState))
        let base = locations.whisperBase
        let settings = settings
        whisperGeneration += 1
        let generation = whisperGeneration
        whisperTask = Task { [weak self] in
            do {
                _ = try await WhisperKit.download(variant: variant.id, downloadBase: base,
                                                  from: WhisperRuntime.repo) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [settings] in
                        guard case .downloading = settings.whisperState else { return }
                        settings.whisperState = .downloading(fraction)
                    }
                }
                guard let self, generation == self.whisperGeneration else { return }
                self.whisperTask = nil
                self.storageRevision += 1
                self.prepareWhisper()
            } catch {
                guard let self, generation == self.whisperGeneration else { return }
                self.whisperTask = nil
                self.storageRevision += 1
                if Task.isCancelled || error is CancellationError {
                    self.settings.whisperState = .paused(self.currentFraction(self.settings.whisperState))
                } else {
                    self.settings.whisperState = .failed("Download failed. Check the connection and try again.")
                }
            }
        }
    }

    /// First load after a download: CoreML compiles the model for this chip (can take a
    /// minute) and the tokenizer is fetched. Apple dictation is used meanwhile.
    func prepareWhisper() {
        guard settings.mode == .full else { return }
        let variant = settings.whisperVariantID
        settings.whisperState = .preparing
        let generation = whisperGeneration
        whisperLoading = true
        whisperTask = Task { [weak self] in
            guard let self else { return }
            defer { self.whisperLoading = false }
            do {
                _ = try await self.whisperRuntime.load(variant: variant, prewarm: true)
                guard generation == self.whisperGeneration else { return }
                self.settings.whisperPrepared = true
                self.settings.whisperState = .ready
            } catch is CancellationError {
                // Interrupted, not failed: try again shortly (unless it was deleted meanwhile).
                guard generation == self.whisperGeneration else { return }
                self.whisperTask = nil
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, generation == self.whisperGeneration, self.whisperTask == nil else { return }
                    self.prepareWhisper()
                }
                return
            } catch {
                guard generation == self.whisperGeneration else { return }
                self.settings.whisperState = .failed("Whisper couldn't load on this device.")
            }
            guard generation == self.whisperGeneration else { return }
            self.whisperTask = nil
            self.storageRevision += 1
        }
    }

    func cancelWhisper() {
        whisperTask?.cancel()
    }

    func deleteWhisper() {
        whisperGeneration += 1
        whisperTask?.cancel()
        whisperTask = nil
        whisperRuntime.unload()
        try? FileManager.default.removeItem(at: locations.whisperBase)
        settings.whisperPrepared = false
        settings.whisperState = .notDownloaded
        storageRevision += 1
    }

    var whisperBytes: Int64 { SpeechModelLocations.bytes(at: locations.whisperBase) }

    // MARK: - Kokoro

    func downloadKokoro() {
        guard settings.mode == .full, kokoroTask == nil else { return }
        settings.kokoroState = .downloading(currentFraction(settings.kokoroState))
        let locations = locations
        let resume = try? Data(contentsOf: locations.kokoroResumeData)
        let settings = settings
        let download = ResumableDownload()
        kokoroDownload = download
        kokoroGeneration += 1
        let generation = kokoroGeneration
        kokoroTask = Task { [weak self] in
            do {
                let file = try await download.run(url: NaturalVoice.modelURL, resumeData: resume) { fraction in
                    Task { @MainActor [settings] in
                        guard case .downloading = settings.kokoroState else { return }
                        settings.kokoroState = .downloading(fraction)
                    }
                }
                guard let current = self, generation == current.kokoroGeneration else {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                try? FileManager.default.removeItem(at: locations.kokoroResumeData)
                current.settings.kokoroState = .preparing
                // Unpack next to the final folder, then swap in, so a half-unpacked model is never used.
                let staging = locations.root.appending(component: "kokoro-staging")
                try await Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: staging)
                    try TarGzExtractor.extract(file, to: staging)
                    try? FileManager.default.removeItem(at: file)
                }.value
                // Deleted while unpacking: throw the unpacked copy away instead of installing it.
                guard let self, generation == self.kokoroGeneration else {
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
                try? FileManager.default.removeItem(at: locations.kokoroDirectory)
                try FileManager.default.moveItem(at: staging, to: locations.kokoroDirectory)
                self.kokoroTask = nil
                self.kokoroDownload = nil
                self.storageRevision += 1
                self.settings.kokoroState = self.kokoroRuntime.isInstalled ? .ready : .failed("The voice download was incomplete.")
                if self.settings.kokoroState == .ready { self.kokoroRuntime.warmUp() }
            } catch let failure as ResumableDownload.Stopped {
                guard let self, generation == self.kokoroGeneration else { return }
                if let data = failure.resumeData {
                    try? data.write(to: locations.kokoroResumeData)
                    UserDefaults.standard.set(self.currentFraction(self.settings.kokoroState), forKey: Self.kokoroPausedKey)
                }
                self.kokoroTask = nil
                self.kokoroDownload = nil
                self.settings.kokoroState = failure.cancelled
                    ? .paused(self.currentFraction(self.settings.kokoroState))
                    : .failed("Download failed. Check the connection and try again.")
            } catch {
                guard let self, generation == self.kokoroGeneration else { return }
                self.kokoroTask = nil
                self.kokoroDownload = nil
                self.settings.kokoroState = .failed("Couldn't unpack the voice model.")
            }
        }
    }

    func cancelKokoro() {
        kokoroDownload?.cancel()
    }

    func deleteKokoro() {
        kokoroGeneration += 1
        kokoroDownload?.cancel()
        kokoroTask = nil
        kokoroDownload = nil
        kokoroRuntime.unload()
        try? FileManager.default.removeItem(at: locations.kokoroDirectory)
        try? FileManager.default.removeItem(at: locations.kokoroResumeData)
        settings.kokoroState = .notDownloaded
        storageRevision += 1
    }

    var kokoroBytes: Int64 { SpeechModelLocations.bytes(at: locations.kokoroDirectory) }

    private func currentFraction(_ state: SpeechModelState) -> Double {
        switch state {
        case .downloading(let fraction), .paused(let fraction): fraction
        default: 0
        }
    }
}

/// A single-file download with progress that can be paused and resumed (URLSession resume data).
final class ResumableDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Stopped: Error {
        let cancelled: Bool
        let resumeData: Data?
    }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: (@Sendable (Double) -> Void)?
    private var cancelled = false
    private let lock = NSLock()

    func run(url: URL, resumeData: Data?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        self.progress = progress
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel { _ in }   // resume data arrives via didCompleteWithError
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : NaturalVoice.modelDownloadBytes
        progress?(min(1, Double(totalBytesWritten) / Double(expected)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            complete(.failure(Stopped(cancelled: false, resumeData: nil)))
            return
        }
        // The temporary file is deleted when this returns: move it somewhere we own.
        let kept = FileManager.default.temporaryDirectory.appending(component: "kokoro-\(UUID().uuidString).tar.gz")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            complete(.success(kept))
        } catch {
            complete(.failure(Stopped(cancelled: false, resumeData: nil)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        complete(.failure(Stopped(cancelled: wasCancelled, resumeData: resume)))
    }
}
