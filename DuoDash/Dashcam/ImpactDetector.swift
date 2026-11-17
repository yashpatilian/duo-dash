import CoreMotion
import Foundation
import Observation

/// How hard a jolt has to be before the dashcam saves a clip (Duo Dash Pro).
enum ImpactSensitivity: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// User acceleration (gravity removed) that counts as an impact, in g. Potholes and speed
    /// bumps in a mount stay well under 2 g; a collision is far above it.
    var thresholdG: Double {
        switch self {
        case .low: 3.5
        case .medium: 2.5
        case .high: 1.8
        }
    }
}

/// Decides when the phone felt an impact, from user-acceleration samples (in g). Pure, so the
/// tests can feed it samples without CoreMotion.
struct ImpactDetector: Sendable {
    var sensitivity: ImpactSensitivity
    /// After an impact, further jolts within this time are the same event (the car rocking,
    /// the phone rattling in the mount) and don't save another clip.
    var debounce: TimeInterval = 30
    private(set) var lastImpact: Date?

    init(sensitivity: ImpactSensitivity, debounce: TimeInterval = 30) {
        self.sensitivity = sensitivity
        self.debounce = debounce
    }

    static func magnitude(x: Double, y: Double, z: Double) -> Double { (x * x + y * y + z * z).squareRoot() }

    /// Returns true when this sample is a new impact.
    mutating func ingest(x: Double, y: Double, z: Double, at time: Date) -> Bool {
        let g = Self.magnitude(x: x, y: y, z: z)
        guard g.isFinite, g >= sensitivity.thresholdG else { return false }
        if let lastImpact, time.timeIntervalSince(lastImpact) < debounce { return false }
        lastImpact = time
        return true
    }

    mutating func reset() { lastImpact = nil }
}

/// Watches the motion sensors while the dashcam records and impact detection is on (Pro).
/// Device motion needs no permission prompt (unlike motion activity or the pedometer).
@MainActor
final class ImpactMonitor {
    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "duodash.impact"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var detector = ImpactDetector(sensitivity: .medium)
    private(set) var isRunning = false
    /// Called on the main actor for each new impact.
    var onImpact: (@MainActor () -> Void)?

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    func start(sensitivity: ImpactSensitivity) {
        detector.sensitivity = sensitivity
        guard !isRunning, motion.isDeviceMotionAvailable else { return }
        isRunning = true
        motion.deviceMotionUpdateInterval = 1.0 / 50
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            guard let a = data?.userAcceleration else { return }
            let x = a.x, y = a.y, z = a.z
            Task { @MainActor [weak self] in self?.handle(x: x, y: y, z: z) }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        motion.stopDeviceMotionUpdates()
    }

    private func handle(x: Double, y: Double, z: Double) {
        guard isRunning, detector.ingest(x: x, y: y, z: z, at: .now) else { return }
        onImpact?()
    }
}
