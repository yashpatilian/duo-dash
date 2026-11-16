import Foundation
import CoreLocation
import Observation

/// Where the dashcam stands. Every failure ends in a state the screen can show.
enum DashcamState: Equatable, Sendable {
    case idle
    case starting
    case recording
    /// iOS (or the heat) paused the camera; recording resumes on its own when it can.
    case interrupted(String)
    /// It can't record right now (no camera, storage nearly full, capture failed).
    case unavailable(String)
    /// Camera access was refused: the user has to allow it in Settings.
    case permissionDenied

    var isRecording: Bool { self == .recording }

    /// Short status text for the screen and the chip.
    var summary: String {
        switch self {
        case .idle: "Off"
        case .starting: "Starting…"
        case .recording: "Recording"
        case .interrupted(let reason): reason
        case .unavailable(let reason): reason
        case .permissionDenied: "Camera access is off"
        }
    }
}

/// Recording resolution. Always 30 fps.
enum DashcamQuality: String, Equatable, Sendable {
    case hd1080
    case hd720

    var title: String { self == .hd1080 ? "1080p" : "720p" }
}

/// What the heat allows.
enum DashcamThermalAction: Equatable, Sendable {
    case normal
    /// `.serious`: drop to 720p and warn.
    case reduced
    /// `.critical`: stop recording until the phone cools down.
    case paused

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .critical: self = .paused
        case .serious: self = .reduced
        default: self = .normal
        }
    }

    var quality: DashcamQuality { self == .normal ? .hd1080 : .hd720 }
}

/// Camera permission as the recorder sees it.
enum DashcamPermission: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
}

/// Errors from the recorder, with text that can go straight on screen.
enum DashcamError: LocalizedError, Equatable, Sendable {
    case noCamera
    case configurationFailed(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .noCamera: "This device has no rear camera."
        case .configurationFailed(let reason): "The camera couldn't start: \(reason)"
        case .notRunning: "The camera isn't running."
        }
    }
}

/// Which rear camera records. Ultra Wide sees both lanes and the kerb, so it's the default.
enum DashcamLens: String, CaseIterable, Sendable {
    case ultraWide, wide

    var title: String { self == .ultraWide ? "Ultra Wide 0.5×" : "Wide 1×" }

    /// Stored choice, read by the capture engine (UserDefaults.standard in the app).
    static func stored(in defaults: UserDefaults = .standard) -> DashcamLens {
        defaults.string(forKey: DashcamSettings.Keys.lens).flatMap(DashcamLens.init(rawValue:)) ?? .ultraWide
    }
}

/// Dashcam preferences, kept in UserDefaults like the rest of the app.
@MainActor
@Observable
final class DashcamSettings {
    static let loopOptions = [2, 5, 10, 20, 30]
    static let defaultLoopMinutes = 10

    /// How many minutes of driving the loop keeps.
    var loopMinutes: Int {
        didSet {
            if !Self.loopOptions.contains(loopMinutes) { loopMinutes = Self.defaultLoopMinutes }
            defaults.set(loopMinutes, forKey: Keys.loop)
        }
    }

    /// Record sound from the microphone too. Off by default (privacy).
    var recordsAudio: Bool {
        didSet { defaults.set(recordsAudio, forKey: Keys.audio) }
    }

    /// Start recording when Duo Dash opens.
    var autoStart: Bool {
        didSet { defaults.set(autoStart, forKey: Keys.autoStart) }
    }

    /// Rear camera to record with (Ultra Wide by default; Wide if the phone has no ultra-wide).
    var lens: DashcamLens {
        didSet { defaults.set(lens.rawValue, forKey: Keys.lens) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    enum Keys {
        static let loop = "dashcam.loopMinutes"
        static let audio = "dashcam.recordsAudio"
        static let autoStart = "dashcam.autoStart"
        static let lens = "dashcam.lens"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loop = defaults.integer(forKey: Keys.loop)
        loopMinutes = Self.loopOptions.contains(loop) ? loop : Self.defaultLoopMinutes
        recordsAudio = defaults.bool(forKey: Keys.audio)
        autoStart = defaults.bool(forKey: Keys.autoStart)
        lens = DashcamLens.stored(in: defaults)
    }
}

/// What the recorder stamps on a new segment file.
struct DashcamSegmentInfo: Equatable, Sendable {
    var startedAt: Date
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?

    init(startedAt: Date, location: CLLocation?) {
        self.startedAt = startedAt
        if let location, CLLocationCoordinate2DIsValid(location.coordinate) {
            latitude = location.coordinate.latitude
            longitude = location.coordinate.longitude
            altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
        }
    }

    /// ISO 6709 location as QuickTime expects it, e.g. `+37.3317-122.0302+012.500/`.
    var iso6709: String? {
        guard let latitude, let longitude else { return nil }
        return Self.iso6709(latitude: latitude, longitude: longitude, altitude: altitude)
    }

    static func iso6709(latitude: Double, longitude: Double, altitude: Double?) -> String {
        var text = String(format: "%+08.4f%+09.4f", latitude, longitude)
        if let altitude { text += String(format: "%+.3f", altitude) }
        return text + "/"
    }

    /// ISO 8601 creation date for `quickTimeMetadataCreationDate`.
    var creationDate: String { startedAt.formatted(.iso8601) }
}

/// One GPS fix in a segment's sidecar track.
struct DashcamTrackSample: Codable, Equatable, Sendable {
    var time: Date
    var latitude: Double
    var longitude: Double
    /// Metres per second; nil when unknown.
    var speed: Double?
    var course: Double?
    var altitude: Double?
    var accuracy: Double

    init(time: Date, latitude: Double, longitude: Double, speed: Double? = nil,
         course: Double? = nil, altitude: Double? = nil, accuracy: Double = 5) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.course = course
        self.altitude = altitude
        self.accuracy = accuracy
    }

    init(_ location: CLLocation) {
        self.init(time: location.timestamp,
                  latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  speed: location.speed >= 0 ? location.speed : nil,
                  course: location.course >= 0 ? location.course : nil,
                  altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                  accuracy: location.horizontalAccuracy)
    }
}

/// The sidecar JSON written next to every segment (`<segment>.json`).
struct DashcamSidecar: Codable, Equatable, Sendable {
    var segment: String
    var startedAt: Date
    var endedAt: Date
    var quality: String
    var track: [DashcamTrackSample]
}

/// A saved clip: a folder under `Dashcam/Saved/` holding its segments, their
/// sidecars and `clip.json`. The loop never touches it.
struct DashcamClip: Identifiable, Equatable, Sendable {
    /// The folder name (a timestamp).
    let id: String
    let folder: URL
    let createdAt: Date
    /// "Saved clip", or a place name once one is known.
    var title: String
    /// Video files, oldest first.
    var segments: [URL]
    var bytes: Int64

    /// "0 KB", "48.2 MB" (never "Zero KB").
    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    var subtitle: String {
        let size = Self.size(bytes)
        let count = segments.count == 1 ? "1 segment" : "\(segments.count) segments"
        return "\(createdAt.formatted(date: .abbreviated, time: .shortened)) · \(count) · \(size)"
    }
}

/// `clip.json` inside a saved clip folder.
struct DashcamClipManifest: Codable, Equatable, Sendable {
    var title: String
    var createdAt: Date
    var reason: String
    var latitude: Double?
    var longitude: Double?
}
