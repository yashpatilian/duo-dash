import AVFoundation
import UIKit

/// A stand-in camera for the Simulator (which has none) and tests. It writes tiny
/// placeholder segment files, so the loop, budget and save-clip logic run on
/// real files. Events arrive on a later main-actor turn, like the real one.
@MainActor
final class DemoDashcamRecorder: DashcamRecorder {
    let isDemo = true
    var onEvent: (@MainActor (DashcamRecorderEvent) -> Void)?
    var captureSession: AVCaptureSession? { nil }

    // Knobs for tests.
    var hasCamera = true
    var permission: DashcamPermission = .authorized
    var grantsAccess = true
    var grantsMicrophone = true
    var failsToStart = false
    /// Size of each placeholder file.
    var bytesPerSegment = 1_024

    private(set) var isSessionRunning = false
    private(set) var quality: DashcamQuality?
    private(set) var audio = false
    private(set) var currentFile: URL?
    private(set) var recordedFiles: [URL] = []
    private(set) var infos: [URL: DashcamSegmentInfo] = [:]
    private(set) var sessionStarts = 0

    private var observers: [NSObjectProtocol] = []

    /// With `observesLifecycle`, leaving the app pauses the "camera" like iOS does.
    init(observesLifecycle: Bool = false) {
        guard observesLifecycle else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.simulateInterruption("Paused: Duo Dash isn't on screen") }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.simulateInterruptionEnded() }
        })
    }

    func cameraPermission() -> DashcamPermission { permission }

    func requestCameraAccess() async -> Bool {
        permission = grantsAccess ? .authorized : .denied
        return grantsAccess
    }

    func requestMicrophoneAccess() async -> Bool { grantsMicrophone }

    func startSession(quality: DashcamQuality, audio: Bool) async throws {
        guard hasCamera else { throw DashcamError.noCamera }
        if failsToStart { throw DashcamError.configurationFailed("demo failure") }
        self.quality = quality
        self.audio = audio
        if !isSessionRunning { sessionStarts += 1 }
        isSessionRunning = true
    }

    func stopSession() {
        stopRecording()
        isSessionRunning = false
    }

    func record(to url: URL, info: DashcamSegmentInfo) {
        guard isSessionRunning else {
            deliver(.failed(DashcamError.notRunning.localizedDescription))
            return
        }
        closeCurrent()
        let header = "DUODASH-DEMO \(quality?.title ?? "") \(info.iso6709 ?? "no-location")\n"
        var data = Data(header.utf8)
        if data.count < bytesPerSegment { data.append(Data(count: bytesPerSegment - data.count)) }
        try? data.write(to: url)
        currentFile = url
        infos[url] = info
        recordedFiles.append(url)
    }

    func stopRecording() {
        closeCurrent()
    }

    /// iOS pausing the camera, e.g. the screen locking.
    func simulateInterruption(_ reason: String = "Camera paused by iOS") {
        closeCurrent()
        deliver(.interrupted(reason))
    }

    func simulateInterruptionEnded() {
        deliver(.interruptionEnded)
    }

    func simulateFailure(_ reason: String) {
        closeCurrent()
        isSessionRunning = false
        deliver(.failed(reason))
    }

    private func closeCurrent() {
        guard let url = currentFile else { return }
        currentFile = nil
        deliver(.segmentFinished(url, usable: true))
    }

    private func deliver(_ event: DashcamRecorderEvent) {
        Task { @MainActor [weak self] in self?.onEvent?(event) }
    }
}
