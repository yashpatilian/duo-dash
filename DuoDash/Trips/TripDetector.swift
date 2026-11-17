import CoreLocation
import Foundation

/// One GPS fix as trip recording sees it.
struct TripFix: Equatable, Sendable {
    var time: Date
    var latitude: Double
    var longitude: Double
    /// Metres per second; nil when the GPS doesn't know (then it's worked out from the last fix).
    var speed: Double?
    var accuracy: Double = 10

    init(time: Date, latitude: Double, longitude: Double, speed: Double? = nil, accuracy: Double = 10) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.accuracy = accuracy
    }

    init(_ location: CLLocation) {
        self.init(time: location.timestamp, latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  speed: location.speed >= 0 ? location.speed : nil, accuracy: location.horizontalAccuracy)
    }

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

/// A point on a saved trip's route.
struct TripPoint: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// A finished drive, as saved in Application Support/Trips/<id>.json.
struct Trip: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var distanceMeters: Double
    /// Metres per second.
    var maxSpeed: Double
    var averageSpeed: Double
    /// At most `TripDetector.maxRoutePoints` points, first and last always kept.
    var route: [TripPoint]
    var startName: String?
    var endName: String?

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var title: String {
        switch (startName, endName) {
        case let (start?, end?) where start != end: "\(start) to \(end)"
        case let (start?, _): start
        case let (nil, end?): end
        default: "Drive"
        }
    }
}

/// Decides when a drive starts and ends, from GPS fixes. Pure (no timers, no CoreLocation
/// managers), so the tests drive it with synthetic fixes.
///
/// - A drive starts once the car has moved faster than 15 km/h for 30 s; it begins at the
///   first of those fixes.
/// - It ends after 5 minutes stopped (no fix faster than walking pace; `tick` covers the
///   silence when a parked phone sends no fixes), or when the app was in the background for
///   more than 10 minutes, or when fixes stop for more than 10 minutes. It ends at the last
///   moment the car was moving.
struct TripDetector: Sendable {
    static let startSpeed = 15 / 3.6
    static let startDuration: TimeInterval = 30
    /// Slower than this counts as stopped (about walking pace).
    static let movingSpeed = 5 / 3.6
    static let stopDuration: TimeInterval = 5 * 60
    static let backgroundLimit: TimeInterval = 10 * 60
    static let maxRoutePoints = 300
    /// Fixes worse than this are ignored.
    static let maxAccuracy: Double = 100
    /// Shorter "drives" (a car park shuffle) aren't kept.
    static let minimumDistance: Double = 300

    enum Phase: Equatable, Sendable {
        case idle
        /// Moving fast since `since`, not yet for 30 s.
        case starting(since: Date)
        case driving
    }

    private(set) var phase: Phase = .idle
    private var lastFix: TripFix?
    /// Fixes since the drive (or its 30 s run-up) began.
    private var fixes: [TripFix] = []
    private var distance: Double = 0
    private var maxSpeed: Double = 0
    private var lastMovingAt: Date?
    private var backgroundSince: Date?

    var isDriving: Bool { phase == .driving }

    /// Feeds one fix. Returns a trip when this fix ends one (a long gap since the last fix).
    mutating func ingest(_ fix: TripFix) -> Trip? {
        guard fix.accuracy >= 0, fix.accuracy <= Self.maxAccuracy else { return nil }
        if let last = lastFix, fix.time <= last.time { return nil }
        var finished: Trip?
        // Fixes stopped for a long time (phone off, app closed): the old drive is over.
        if let last = lastFix, fix.time.timeIntervalSince(last.time) > Self.backgroundLimit {
            finished = finish()
            reset()
        }
        let speed = Self.speed(of: fix, after: lastFix)

        switch phase {
        case .idle:
            if speed > Self.startSpeed {
                phase = .starting(since: fix.time)
                fixes = [fix]
                distance = 0
                maxSpeed = speed
                lastMovingAt = fix.time
            }
        case .starting(let since):
            if speed > Self.startSpeed {
                append(fix, speed: speed)
                if fix.time.timeIntervalSince(since) >= Self.startDuration { phase = .driving }
            } else {
                phase = .idle
                fixes = []
            }
        case .driving:
            append(fix, speed: speed)
            if let moving = lastMovingAt, fix.time.timeIntervalSince(moving) >= Self.stopDuration {
                finished = finish()
                reset()
            }
        }
        lastFix = fix
        return finished
    }

    /// Called every so often with the time: a parked phone sends no fixes, so this is what ends
    /// a drive after 5 minutes stopped.
    mutating func tick(now: Date) -> Trip? {
        guard phase == .driving, let moving = lastMovingAt,
              now.timeIntervalSince(moving) >= Self.stopDuration else { return nil }
        let trip = finish()
        reset()
        return trip
    }

    mutating func enteredBackground(at time: Date) {
        backgroundSince = time
    }

    /// Back in front: if the app was away for more than 10 minutes, the drive ended back then.
    mutating func becameActive(at time: Date) -> Trip? {
        defer { backgroundSince = nil }
        guard let since = backgroundSince, time.timeIntervalSince(since) > Self.backgroundLimit else { return nil }
        guard phase != .idle else { return nil }
        let trip = finish()
        reset()
        return trip
    }

    private mutating func append(_ fix: TripFix, speed: Double) {
        if let previous = fixes.last {
            distance += fix.location.distance(from: previous.location)
        }
        fixes.append(fix)
        maxSpeed = max(maxSpeed, speed)
        if speed >= Self.movingSpeed { lastMovingAt = fix.time }
    }

    private mutating func reset() {
        phase = .idle
        fixes = []
        distance = 0
        maxSpeed = 0
        lastMovingAt = nil
        lastFix = nil
    }

    /// The drive so far as a trip, or nil if it never really started or was too short.
    private func finish() -> Trip? {
        guard phase == .driving, let first = fixes.first else { return nil }
        let end = lastMovingAt ?? fixes.last?.time ?? first.time
        // Drop the parked tail after the car stopped.
        let driven = fixes.filter { $0.time <= end }
        let duration = end.timeIntervalSince(first.time)
        guard duration > 0, distance >= Self.minimumDistance else { return nil }
        let pathDistance = zip(driven, driven.dropFirst()).reduce(0.0) { $0 + $1.1.location.distance(from: $1.0.location) }
        return Trip(id: UUID(), startedAt: first.time, endedAt: end, distanceMeters: pathDistance,
                    maxSpeed: maxSpeed, averageSpeed: pathDistance / duration,
                    route: Self.downsample(driven.map { TripPoint(latitude: $0.latitude, longitude: $0.longitude) }),
                    startName: nil, endName: nil)
    }

    /// GPS speed, or distance over time from the previous fix when the GPS gives none.
    static func speed(of fix: TripFix, after previous: TripFix?) -> Double {
        if let speed = fix.speed, speed >= 0 { return speed }
        guard let previous else { return 0 }
        let seconds = fix.time.timeIntervalSince(previous.time)
        guard seconds > 0 else { return 0 }
        return fix.location.distance(from: previous.location) / seconds
    }

    /// Evenly spaced points, at most `limit`, always keeping the first and last.
    static func downsample<T>(_ points: [T], limit: Int = maxRoutePoints) -> [T] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
    }
}
