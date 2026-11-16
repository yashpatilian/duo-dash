import AVFoundation

/// What a recorder tells the model. Delivered on the main actor.
enum DashcamRecorderEvent: Equatable, Sendable {
    /// A segment file was closed (rotation, stop, interruption or error).
    /// `usable` is false when nothing playable was written.
    case segmentFinished(URL, usable: Bool)
    /// iOS paused the camera (background, lock, another app, Split View, heat).
    case interrupted(String)
    case interruptionEnded
    /// Capture failed and couldn't recover on its own.
    case failed(String)
}

/// The camera side of the dashcam. `DashcamModel` decides when segments start
/// and end; the recorder only opens and closes files.
///
/// - `AVDashcamRecorder`: the rear camera through AVFoundation.
/// - `DemoDashcamRecorder`: the Simulator and tests; writes tiny placeholder files.
@MainActor
protocol DashcamRecorder: AnyObject {
    var isDemo: Bool { get }
    var onEvent: (@MainActor (DashcamRecorderEvent) -> Void)? { get set }

    /// The live session for the preview (nil for the demo).
    var captureSession: AVCaptureSession? { get }

    /// There is a usable rear camera.
    var hasCamera: Bool { get }

    func cameraPermission() -> DashcamPermission
    func requestCameraAccess() async -> Bool
    /// Asks for the microphone; false leaves recording video-only.
    func requestMicrophoneAccess() async -> Bool

    /// Configures and starts the session (no recording yet). Calling it again
    /// with different settings reconfigures the running session.
    func startSession(quality: DashcamQuality, audio: Bool) async throws
    /// Stops the session; closes any open file first.
    func stopSession()

    /// Starts writing `url`. If a file is open it is closed first (and reported
    /// with `.segmentFinished`) and the new one starts straight after.
    func record(to url: URL, info: DashcamSegmentInfo)
    /// Closes the open file, if any.
    func stopRecording()
}
