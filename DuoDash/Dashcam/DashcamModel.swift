import AVFoundation
import CoreLocation
import Observation
import Photos
import UIKit

/// The dashcam: loop recording in 60 s segments, keeping the last N minutes,
/// with "Save clip" moving the previous and current segment somewhere the loop
/// never deletes.
///
/// The model decides when segments start and end; the recorder (real camera or
/// demo) only opens and closes files. Everything that can go wrong ends in a
/// `state` or `message` the screen shows.
@MainActor
@Observable
final class DashcamModel {
    /// Below this much free space it won't start, and stops if already recording.
    static let minimumFreeBytes: Int64 = 2_000_000_000
    static let lowDiskText = "Less than 2 GB free. Free up space to record."
    static let heatPausedText = "Phone too hot: recording paused until it cools"
    static let heatReducedText = "Phone is hot: recording at 720p"

    private(set) var state: DashcamState = .idle {
        didSet { if state != oldValue { updateImpactMonitoring() } }
    }
    /// When the current run of recording began (for the REC timer).
    private(set) var recordingStartedAt: Date?
    private(set) var quality: DashcamQuality = .hd1080
    /// Shown while the phone is hot (720p or paused).
    private(set) var heatWarning: String?
    private(set) var savedClips: [DashcamClip] = []
    private(set) var loopBytes: Int64 = 0
    private(set) var savedBytes: Int64 = 0
    private(set) var isSaving = false
    /// A one-off message for the screen: clip saved, storage low, Photos result.
    var message: String?
    /// Shown over every screen after impact detection (Duo Dash Pro) saved a clip.
    var impactBanner: String?

    /// False while this edition needs Pro for the dashcam and the user doesn't have it
    /// (`ProGate.dashcamAvailable`): it never records then. Set by the app.
    var accessAllowed = true {
        didSet {
            guard accessAllowed != oldValue else { return }
            if !accessAllowed { stop() }
        }
    }

    let settings: DashcamSettings
    let isDemo: Bool

    @ObservationIgnored let recorder: DashcamRecorder
    @ObservationIgnored let storage: DashcamStorage
    /// Injectable for tests.
    @ObservationIgnored var freeSpace: () -> Int64
    @ObservationIgnored var thermalState: () -> ProcessInfo.ThermalState
    @ObservationIgnored var photoSaver: ([URL]) async throws -> Void
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored let segmentDuration: Duration
    /// Duo Dash Pro: saves a clip when the phone feels a crash-like jolt while recording.
    @ObservationIgnored private let impactMonitor: ImpactMonitor?

    /// The file being written now.
    @ObservationIgnored private(set) var currentSegment: URL?
    @ObservationIgnored private var currentInfo: DashcamSegmentInfo?
    @ObservationIgnored private var currentTrack: [DashcamTrackSample] = []
    @ObservationIgnored private(set) var lastLocation: CLLocation?
    /// Segment file names the loop must not delete (being saved).
    @ObservationIgnored private(set) var protected: Set<String> = []
    @ObservationIgnored private var recentlyFinished: [String] = []
    @ObservationIgnored private var finishWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var rotationTask: Task<Void, Never>?
    /// The user wants it recording (survives interruptions and heat pauses).
    @ObservationIgnored private(set) var wantsRecording = false
    @ObservationIgnored private var pausedForHeat = false
    @ObservationIgnored private var recordsAudioNow = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The Simulator has no camera; `-DemoDashcam` asks for the demo on a device.
    static var usesDemo: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("-DemoDashcam")
        #endif
    }

    init(settings: DashcamSettings,
         recorder: DashcamRecorder? = nil,
         storage: DashcamStorage? = nil,
         freeSpace: (() -> Int64)? = nil,
         thermalState: (() -> ProcessInfo.ThermalState)? = nil,
         photoSaver: (([URL]) async throws -> Void)? = nil,
         segmentDuration: Duration = .seconds(60),
         observesLifecycle: Bool = true) {
        let recorder = recorder ?? (Self.usesDemo
            ? DemoDashcamRecorder(observesLifecycle: observesLifecycle)
            : AVDashcamRecorder())
        let storage = storage ?? DashcamStorage()
        self.settings = settings
        self.recorder = recorder
        self.storage = storage
        self.isDemo = recorder.isDemo
        self.segmentDuration = segmentDuration
        self.freeSpace = freeSpace ?? { [base = storage.base] in DashcamStorage.freeSpace(at: base) }
        self.thermalState = thermalState ?? { ProcessInfo.processInfo.thermalState }
        self.photoSaver = photoSaver ?? (recorder.isDemo ? { _ in } : DashcamPhotos.save)
        self.impactMonitor = observesLifecycle ? ImpactMonitor() : nil
        recorder.onEvent = { [weak self] event in self?.handle(event) }
        impactMonitor?.onImpact = { [weak self] in
            guard let self else { return }
            Task { await self.handleImpact() }
        }
        storage.prune(keeping: segmentLimit, protected: [])
        reloadClips()

        if observesLifecycle {
            observers.append(NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.handleThermalState(self.thermalState()) }
                }
            })
        }
    }

    // MARK: Derived

    var captureSession: AVCaptureSession? { recorder.captureSession }

    /// Finished loop segments to keep: the loop length in segments.
    var segmentLimit: Int {
        let seconds = Double(segmentDuration.components.seconds)
        guard seconds > 0 else { return 1 }
        return max(1, Int((Double(settings.effectiveLoopMinutes) * 60 / seconds).rounded(.up)))
    }

    var loopDescription: String { "Last \(settings.effectiveLoopMinutes) min" }

    var storageDescription: String {
        let loop = DashcamClip.size(loopBytes)
        let saved = DashcamClip.size(savedBytes)
        return "Loop \(loop) · Saved \(saved)"
    }

    // MARK: Start / stop

    /// Start recording if "Auto-start when Duo Dash opens" is on.
    func startIfAutoStart() async {
        guard settings.autoStart else { return }
        await start()
    }

    func start() async {
        guard accessAllowed else { return }
        switch state {
        case .starting, .recording: return
        default: break
        }
        wantsRecording = true
        pausedForHeat = false
        message = nil
        await begin()
    }

    func stop() {
        wantsRecording = false
        pausedForHeat = false
        rotationTask?.cancel()
        closeSidecar()
        recorder.stopSession()
        state = .idle
        recordingStartedAt = nil
    }

    /// The start/stop button.
    func toggle() {
        switch state {
        case .recording, .starting: stop()
        case .interrupted where wantsRecording: stop()
        default: Task { await start() }
        }
    }

    private func begin() async {
        state = .starting
        guard hasRoom() else { refuseLowDisk(); return }

        switch recorder.cameraPermission() {
        case .authorized: break
        case .denied:
            wantsRecording = false
            state = .permissionDenied
            return
        case .notDetermined:
            guard await recorder.requestCameraAccess() else {
                wantsRecording = false
                state = .permissionDenied
                return
            }
        }
        guard recorder.hasCamera else {
            wantsRecording = false
            state = .unavailable(DashcamError.noCamera.localizedDescription)
            return
        }

        let action = DashcamThermalAction(thermalState())
        applyHeatWarning(action)
        if action == .paused {
            pausedForHeat = true
            state = .interrupted(Self.heatPausedText)
            return
        }

        var audio = settings.recordsAudio
        if audio { audio = await recorder.requestMicrophoneAccess() }
        recordsAudioNow = audio
        quality = action.quality
        do {
            try await recorder.startSession(quality: quality, audio: audio)
        } catch {
            wantsRecording = false
            state = .unavailable(error.localizedDescription)
            return
        }
        guard wantsRecording, !pausedForHeat else {
            if !wantsRecording { recorder.stopSession(); state = .idle }
            return
        }
        beginSegment()
        state = .recording
        recordingStartedAt = now()
        scheduleRotation()
    }

    /// Picks recording back up after an interruption or a heat pause.
    private func resume() {
        guard wantsRecording, !pausedForHeat else { return }
        switch state {
        case .starting, .recording: return
        default: Task { await begin() }
        }
    }

    private func hasRoom() -> Bool { freeSpace() >= Self.minimumFreeBytes }

    private func refuseLowDisk() {
        wantsRecording = false
        rotationTask?.cancel()
        closeSidecar()
        recorder.stopSession()
        recordingStartedAt = nil
        state = .unavailable(Self.lowDiskText)
        message = Self.lowDiskText
    }

    // MARK: Segments

    private func beginSegment() {
        let start = now()
        let url = storage.newSegmentURL(at: start)
        let info = DashcamSegmentInfo(startedAt: start, location: lastLocation)
        currentSegment = url
        currentInfo = info
        currentTrack = lastLocation.map { [DashcamTrackSample($0)] } ?? []
        recorder.record(to: url, info: info)
    }

    /// Writes the current segment's sidecar and forgets it (the file itself is
    /// closed by the recorder).
    private func closeSidecar() {
        guard let url = currentSegment, let info = currentInfo else { return }
        storage.writeSidecar(DashcamSidecar(segment: url.lastPathComponent, startedAt: info.startedAt,
                                            endedAt: now(), quality: quality.title, track: currentTrack),
                             for: url)
        currentSegment = nil
        currentInfo = nil
        currentTrack = []
    }

    /// Ends the current segment and starts the next. Runs every `segmentDuration`.
    func rotateSegment() {
        guard state == .recording, currentSegment != nil else { return }
        guard hasRoom() else { refuseLowDisk(); return }
        closeSidecar()
        beginSegment()
        scheduleRotation()
    }

    private func scheduleRotation() {
        rotationTask?.cancel()
        let duration = segmentDuration
        rotationTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.rotateSegment()
        }
    }

    /// Deletes loop segments beyond the budget, oldest first.
    func pruneLoop() {
        var keep = protected
        if let currentSegment { keep.insert(currentSegment.lastPathComponent) }
        storage.prune(keeping: segmentLimit, protected: keep)
        refreshUsage()
    }

    // MARK: Location

    /// Feed from the app's LocationManager. The sidecar keeps at most one fix a second.
    func ingest(_ location: CLLocation) {
        lastLocation = location
        guard currentSegment != nil else { return }
        if let last = currentTrack.last, location.timestamp.timeIntervalSince(last.time) < 1 { return }
        currentTrack.append(DashcamTrackSample(location))
    }

    // MARK: Recorder events

    func handle(_ event: DashcamRecorderEvent) {
        switch event {
        case .segmentFinished(let url, let usable):
            let name = url.lastPathComponent
            if currentSegment?.lastPathComponent == name { closeSidecar() }
            if !usable && !protected.contains(name) { storage.removeSegment(url) }
            markFinished(name)
            pruneLoop()
        case .interrupted(let reason):
            guard wantsRecording, !pausedForHeat else { return }
            rotationTask?.cancel()
            closeSidecar()
            state = .interrupted(reason)
        case .interruptionEnded:
            guard case .interrupted = state else { return }
            resume()
        case .failed(let reason):
            rotationTask?.cancel()
            closeSidecar()
            wantsRecording = false
            recordingStartedAt = nil
            recorder.stopSession()
            state = .unavailable(reason)
        }
    }

    private func markFinished(_ name: String) {
        recentlyFinished.append(name)
        if recentlyFinished.count > 20 { recentlyFinished.removeFirst(recentlyFinished.count - 20) }
        for waiter in finishWaiters.removeValue(forKey: name) ?? [] { waiter.resume() }
    }

    /// Waits until the recorder has closed `name` (or 10 s, as a safety net).
    private func waitUntilFinished(_ name: String) async {
        guard !recentlyFinished.contains(name) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            for waiter in self?.finishWaiters.removeValue(forKey: name) ?? [] { waiter.resume() }
        }
        await withCheckedContinuation { finishWaiters[name, default: []].append($0) }
    }

    // MARK: Heat

    /// `.serious` drops to 720p; `.critical` pauses until it cools; cooler goes back to 1080p.
    func handleThermalState(_ thermal: ProcessInfo.ThermalState) async {
        let action = DashcamThermalAction(thermal)
        applyHeatWarning(action)
        switch action {
        case .paused:
            guard wantsRecording, !pausedForHeat else { return }
            pausedForHeat = true
            rotationTask?.cancel()
            closeSidecar()
            recorder.stopSession()
            state = .interrupted(Self.heatPausedText)
        case .normal, .reduced:
            if pausedForHeat {
                pausedForHeat = false
                if wantsRecording { await begin() }
                return
            }
            guard state == .recording, action.quality != quality else { return }
            await changeQuality(action.quality)
        }
    }

    private func applyHeatWarning(_ action: DashcamThermalAction) {
        switch action {
        case .normal: heatWarning = nil
        case .reduced: heatWarning = Self.heatReducedText
        case .paused: heatWarning = Self.heatPausedText
        }
    }

    private func changeQuality(_ newQuality: DashcamQuality) async {
        rotationTask?.cancel()
        closeSidecar()
        recorder.stopRecording()
        quality = newQuality
        state = .starting
        do {
            try await recorder.startSession(quality: newQuality, audio: recordsAudioNow)
        } catch {
            handle(.failed(error.localizedDescription))
            return
        }
        guard wantsRecording, state == .starting else { return }
        beginSegment()
        state = .recording
        scheduleRotation()
    }

    // MARK: Impact detection (Duo Dash Pro)

    /// Runs the motion sensors only while recording with impact detection on (and Pro).
    /// Call after the setting or Pro status changes; state changes call it themselves.
    func updateImpactMonitoring() {
        guard let impactMonitor else { return }
        if state == .recording && settings.impactDetectionActive {
            impactMonitor.start(sensitivity: settings.impactSensitivity)
        } else {
            impactMonitor.stop()
        }
    }

    static let impactSavedText = "Impact detected: clip saved"

    /// An impact: keep the last two minutes (Save clip's path) and say so on every screen.
    @discardableResult
    func handleImpact() async -> DashcamClip? {
        guard settings.impactDetectionActive, state == .recording else { return nil }
        let clip = await saveClip(reason: "Impact")
        if clip != nil { impactBanner = Self.impactSavedText }
        return clip
    }

    // MARK: Saved clips

    /// Keeps the previous and current segment: the current one is closed (a new
    /// one starts straight away) and both move to `Saved/<timestamp>/`, out of
    /// the loop's reach. Also for a future crash / hard-brake trigger.
    @discardableResult
    func saveClip(reason: String = "Manual") async -> DashcamClip? {
        guard !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        let createdAt = now()

        var names: [String]
        if state == .recording, let current = currentSegment {
            let currentName = current.lastPathComponent
            let previous = storage.loopSegments().map(\.lastPathComponent)
                .filter { $0 < currentName && !protected.contains($0) }.last
            names = [previous, currentName].compactMap { $0 }
            protected.formUnion(names)
            rotateSegment()
            await waitUntilFinished(currentName)
        } else {
            let current = currentSegment?.lastPathComponent
            names = Array(storage.loopSegments().map(\.lastPathComponent)
                .filter { $0 != current && !protected.contains($0) }.suffix(2))
            protected.formUnion(names)
        }
        defer {
            protected.subtract(names)
            pruneLoop()
        }
        guard !names.isEmpty else {
            message = "Nothing recorded yet."
            return nil
        }

        let urls = names.map { storage.loopDirectory.appending(path: $0, directoryHint: .notDirectory) }
        let manifest = DashcamClipManifest(title: Self.defaultTitle(for: createdAt), createdAt: createdAt, reason: reason,
                                           latitude: lastLocation?.coordinate.latitude,
                                           longitude: lastLocation?.coordinate.longitude)
        do {
            guard let clip = try storage.saveClip(segments: urls, manifest: manifest) else {
                message = "Nothing recorded yet."
                return nil
            }
            reloadClips()
            message = "Clip saved"
            return clip
        } catch {
            message = "Couldn't save the clip: \(error.localizedDescription)"
            reloadClips()
            return nil
        }
    }

    static func defaultTitle(for date: Date) -> String {
        "Clip \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    func delete(_ clip: DashcamClip) {
        do {
            try storage.deleteClip(clip)
        } catch {
            message = "Couldn't delete the clip: \(error.localizedDescription)"
        }
        reloadClips()
    }

    /// Renames a clip, e.g. to a reverse-geocoded place name.
    func rename(_ clip: DashcamClip, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? storage.renameClip(clip, to: trimmed)
        reloadClips()
    }

    func saveToPhotos(_ clip: DashcamClip) async {
        do {
            try await photoSaver(clip.segments)
            message = isDemo ? "Demo: not saved to Photos" : "Saved to Photos"
        } catch {
            message = error.localizedDescription
        }
    }

    func reloadClips() {
        savedClips = storage.savedClips()
        refreshUsage()
    }

    private func refreshUsage() {
        let usage = storage.usage()
        loopBytes = usage.loop
        savedBytes = usage.saved
    }
}

/// Saves videos to the photo library with add-only access.
enum DashcamPhotos {
    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? { "Allow Duo Dash to add to Photos in Settings." }
    }

    static func save(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.denied }
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
        }
    }
}
