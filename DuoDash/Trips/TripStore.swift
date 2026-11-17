import CoreLocation
import Foundation
import MapKit
import Observation

/// Duo Dash Pro → Trip history. Records each drive from the app's location feed and keeps it
/// on the device, as one JSON file per trip in Application Support/Trips (at most 200; the
/// oldest go first). Recording runs only with Pro and "Record trips" on, so nobody without
/// Pro has a location history stored.
@MainActor
@Observable
final class TripStore {
    static let maxTrips = 200

    /// Newest first.
    private(set) var trips: [Trip] = []
    /// A drive is being recorded right now.
    private(set) var isDriving = false

    /// "Record trips" in Settings → Duo Dash Pro. On by default (only matters with Pro).
    var isRecordingEnabled: Bool {
        didSet {
            defaults.set(isRecordingEnabled, forKey: Keys.recording)
            if !isRecordingEnabled { discardCurrent() }
        }
    }

    /// Mirrors `ProStore.isPro` (set by the app). Not saved.
    var isProActive = false {
        didSet { if !isProActive { discardCurrent() } }
    }

    /// The trip list is open (drawn over the app by RootView).
    var isBrowsing = false

    var isRecordingActive: Bool { isProActive && isRecordingEnabled }

    enum Keys {
        static let recording = "trips.recording"
    }

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var detector = TripDetector()
    /// Turns a place into a short name ("Richmond"); nil when it can't. Injectable for tests.
    @ObservationIgnored var placeName: (CLLocation) async -> String? = TripStore.reverseGeocode
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored private var ticker: Task<Void, Never>?

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Trips", directoryHint: .isDirectory)
    }

    init(directory: URL = TripStore.defaultDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        isRecordingEnabled = defaults.object(forKey: Keys.recording) as? Bool ?? true
        reload()
    }

    // MARK: Recording

    /// From the LocationManager listener.
    func ingest(_ location: CLLocation) {
        guard isRecordingActive else { return }
        let finished = detector.ingest(TripFix(location))
        isDriving = detector.isDriving
        if let finished { record(finished) }
        if detector.phase != .idle { startTicker() }
    }

    /// Checks for "stopped for 5 minutes" while no fixes come in (a parked phone sends none).
    func tick() {
        guard let finished = detector.tick(now: now()) else { return }
        isDriving = detector.isDriving
        record(finished)
    }

    func enteredBackground() { detector.enteredBackground(at: now()) }

    func becameActive() {
        if let finished = detector.becameActive(at: now()) { record(finished) }
        isDriving = detector.isDriving
    }

    private func discardCurrent() {
        detector = TripDetector()
        isDriving = false
        ticker?.cancel()
        ticker = nil
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.tick()
                if self.detector.phase == .idle { self.ticker = nil; return }
            }
        }
    }

    /// Saves a finished trip, then names its ends when the geocoder answers.
    func record(_ trip: Trip) {
        save(trip)
        guard let first = trip.route.first, let last = trip.route.last else { return }
        Task { [weak self] in
            guard let self else { return }
            let start = await self.placeName(CLLocation(latitude: first.latitude, longitude: first.longitude))
            let end = await self.placeName(CLLocation(latitude: last.latitude, longitude: last.longitude))
            guard start != nil || end != nil, var named = self.trips.first(where: { $0.id == trip.id }) else { return }
            named.startName = start
            named.endName = end
            self.save(named)
        }
    }

    // MARK: Files

    private func url(for id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func save(_ trip: Trip) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(trip) else { return }
        try? data.write(to: url(for: trip.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        trips.removeAll { $0.id == trip.id }
        trips.append(trip)
        trips.sort { $0.startedAt > $1.startedAt }
        while trips.count > Self.maxTrips, let oldest = trips.last {
            try? FileManager.default.removeItem(at: url(for: oldest.id))
            trips.removeLast()
        }
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        trips = files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Trip.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
        // Files from before the cap was lowered, or copied in: keep the newest 200.
        for old in trips.dropFirst(Self.maxTrips) { try? FileManager.default.removeItem(at: url(for: old.id)) }
        trips = Array(trips.prefix(Self.maxTrips))
    }

    func delete(_ trip: Trip) {
        try? FileManager.default.removeItem(at: url(for: trip.id))
        trips.removeAll { $0.id == trip.id }
    }

    func deleteAll() {
        for trip in trips { try? FileManager.default.removeItem(at: url(for: trip.id)) }
        trips = []
    }

    // MARK: Place names

    /// Suburb or street via MapKit's reverse geocoder (iOS 26), nil offline.
    static func reverseGeocode(_ location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        guard let item = try? await request.mapItems.first else { return nil }
        return item.addressRepresentations?.cityName ?? item.address?.shortAddress ?? item.name
    }

    // MARK: Totals

    var totalDistance: Double { trips.reduce(0) { $0 + $1.distanceMeters } }
}
