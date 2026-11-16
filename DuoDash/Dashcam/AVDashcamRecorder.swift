import AVFoundation

/// The rear wide camera through AVFoundation: 1080p30 (720p when hot), HEVC when
/// the hardware has it, one `AVCaptureMovieFileOutput` file per loop segment.
@MainActor
final class AVDashcamRecorder: DashcamRecorder {
    let isDemo = false
    var onEvent: (@MainActor (DashcamRecorderEvent) -> Void)?

    private let engine = DashcamCaptureEngine()

    init() {
        engine.onEvent = { [weak self] event in
            Task { @MainActor in self?.onEvent?(event) }
        }
    }

    var captureSession: AVCaptureSession? { engine.session }

    var hasCamera: Bool { DashcamCaptureEngine.rearCamera() != nil }

    func cameraPermission() -> DashcamPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func startSession(quality: DashcamQuality, audio: Bool) async throws {
        try await engine.start(quality: quality, audio: audio)
    }

    func stopSession() { engine.stop() }

    func record(to url: URL, info: DashcamSegmentInfo) { engine.record(to: url, info: info) }

    func stopRecording() { engine.stopRecording() }
}

/// Owns the capture session and does all its work on one serial queue, as
/// AVFoundation wants. Events go out through `onEvent` from any thread.
final class DashcamCaptureEngine: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onEvent: (@Sendable (DashcamRecorderEvent) -> Void)?

    private let queue = DispatchQueue(label: "duodash.dashcam.session", qos: .userInitiated)
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    /// The file to open as soon as the current one has closed (rotation).
    private var pending: (url: URL, info: DashcamSegmentInfo)?
    private var shouldRun = false
    private var observers: [NSObjectProtocol] = []

    /// The chosen rear camera; falls back to the wide camera on phones without an ultra-wide.
    static func rearCamera(lens: DashcamLens = .stored()) -> AVCaptureDevice? {
        if lens == .ultraWide, let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            return ultraWide
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    override init() {
        super.init()
        observeSession()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Session

    func start(quality: DashcamQuality, audio: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configure(quality: quality, audio: audio)
                    self.shouldRun = true
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.shouldRun = false
            self.pending = nil
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure(quality: DashcamQuality, audio: Bool) throws {
        session.beginConfiguration()
        // Lens changed in Settings since the last start: swap the camera input.
        if let current = videoInput, let wanted = Self.rearCamera(), current.device.uniqueID != wanted.uniqueID {
            session.removeInput(current)
            videoInput = nil
        }
        var device = videoInput?.device
        if videoInput == nil {
            guard let camera = Self.rearCamera() else {
                session.commitConfiguration()
                throw DashcamError.noCamera
            }
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input) else { throw DashcamError.configurationFailed("camera input") }
                session.addInput(input)
                videoInput = input
                device = camera
                rotation = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
            } catch {
                session.commitConfiguration()
                throw (error as? DashcamError) ?? DashcamError.configurationFailed(error.localizedDescription)
            }
        }

        let preset: AVCaptureSession.Preset = quality == .hd1080 ? .hd1920x1080 : .hd1280x720
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        if audio, audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        } else if !audio, let input = audioInput {
            session.removeInput(input)
            audioInput = nil
        }

        if !session.outputs.contains(movieOutput) {
            guard session.canAddOutput(movieOutput) else {
                session.commitConfiguration()
                throw DashcamError.configurationFailed("movie output")
            }
            session.addOutput(movieOutput)
        }
        if let connection = movieOutput.connection(with: .video) {
            if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .standard
            }
        }
        session.commitConfiguration()

        // 30 fps; the preset may have picked a format that runs faster.
        if let device, (try? device.lockForConfiguration()) != nil {
            let thirty = CMTime(value: 1, timescale: 30)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                device.activeVideoMinFrameDuration = thirty
                device.activeVideoMaxFrameDuration = thirty
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: Recording

    func record(to url: URL, info: DashcamSegmentInfo) {
        queue.async {
            if self.movieOutput.isRecording {
                self.pending = (url, info)
                self.movieOutput.stopRecording()
            } else {
                self.begin(url: url, info: info)
            }
        }
    }

    func stopRecording() {
        queue.async {
            self.pending = nil
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        }
    }

    /// On `queue`.
    private func begin(url: URL, info: DashcamSegmentInfo) {
        guard session.isRunning, movieOutput.connection(with: .video) != nil else {
            onEvent?(.segmentFinished(url, usable: false))
            return
        }
        movieOutput.metadata = Self.metadata(for: info)
        if let connection = movieOutput.connection(with: .video), let rotation {
            let angle = rotation.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        var usable = true
        if let error {
            // Interruptions and full disks still leave a playable file.
            usable = (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
        }
        onEvent?(.segmentFinished(url, usable: usable))
        queue.async {
            guard let next = self.pending else { return }
            self.pending = nil
            self.begin(url: next.url, info: next.info)
        }
    }

    static func metadata(for info: DashcamSegmentInfo) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let location = info.iso6709 {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = location as NSString
            item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
            items.append(item)
        }
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = info.creationDate as NSString
        items.append(date)
        let software = AVMutableMetadataItem()
        software.identifier = .quickTimeMetadataSoftware
        software.value = "Duo Dash" as NSString
        items.append(software)
        return items
    }

    // MARK: Interruptions and errors

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            self?.onEvent?(.interrupted(Self.describeInterruption(raw)))
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            self?.onEvent?(.interruptionEnded)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.handleRuntimeError(code: error?.code, message: error?.localizedDescription)
        })
    }

    private func handleRuntimeError(code: AVError.Code?, message: String?) {
        guard code == .mediaServicesWereReset else {
            onEvent?(.failed(message ?? "The camera stopped unexpectedly."))
            return
        }
        // The media server restarted: start the session again and carry on.
        onEvent?(.interrupted("Camera restarting…"))
        queue.async {
            guard self.shouldRun else { return }
            self.session.startRunning()
            self.onEvent?(self.session.isRunning ? .interruptionEnded : .failed(message ?? "The camera couldn't restart."))
        }
    }

    static func describeInterruption(_ raw: Int?) -> String {
        guard let raw, let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return "Camera paused by iOS"
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "Paused: Duo Dash isn't on screen"
        case .videoDeviceInUseByAnotherClient: return "Another app is using the camera"
        case .audioDeviceInUseByAnotherClient: return "Another app is using the microphone"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "Camera is off in Split View"
        case .videoDeviceNotAvailableDueToSystemPressure: return "Phone too hot: camera paused"
        default: return "Camera paused by iOS"
        }
    }
}
