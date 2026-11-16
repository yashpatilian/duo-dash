import Foundation
import CoreLocation
import Observation

/// Current weather where you are, and the forecast at a destination for when you
/// arrive. Forecasts are cached per ~2 km for 15 minutes and concurrent requests
/// for the same area share one fetch, so the API is never hammered.
@MainActor
@Observable
final class WeatherModel {
    /// Open-Meteo's data is CC BY 4.0: this line must be visible wherever weather is shown.
    static let attribution = "Weather: Open-Meteo.com"
    static let attributionURL = URL(string: "https://open-meteo.com/")!

    /// Weather where the user is (or the demo place).
    private(set) var current: WeatherForecast?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    let isDemo: Bool
    var unit: TemperatureUnit

    @ObservationIgnored private let backend: WeatherBackend
    @ObservationIgnored private var cache: [WeatherForecast] = []
    @ObservationIgnored private var inFlight: [GridKey: Task<WeatherForecast, Error>] = [:]
    /// Areas that just failed, so a flaky connection doesn't trigger a retry storm.
    @ObservationIgnored private var failures: [GridKey: Date] = [:]
    @ObservationIgnored var now: () -> Date = { .now }

    /// Reuse a forecast fetched within this distance…
    @ObservationIgnored var cacheRadius: CLLocationDistance = 2_000
    /// …and this age.
    @ObservationIgnored var cacheLifetime: TimeInterval = 15 * 60
    /// Wait this long before retrying an area that failed.
    @ObservationIgnored var failureBackoff: TimeInterval = 2 * 60

    /// Where the demo pretends you are when there's no location fix (Cupertino).
    static let demoLocation = GeoPoint(latitude: 37.3230, longitude: -122.0322)

    /// The Simulator gets fixed weather; `-DemoWeather` forces it on a device.
    static var usesDemo: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("-DemoWeather")
        #endif
    }

    init(backend: WeatherBackend? = nil, unit: TemperatureUnit = .current) {
        let backend = backend ?? (Self.usesDemo ? DemoWeatherBackend() : OpenMeteoBackend())
        self.backend = backend
        self.unit = unit
        isDemo = backend.isDemo
    }

    // MARK: Formatting

    func format(_ celsius: Double) -> String { unit.format(celsius: celsius) }

    // MARK: Current location

    /// Updates `current` for where the user is. Cached, so call it on every location change.
    /// With no fix, the demo uses Cupertino and the real backend waits.
    func updateCurrent(at coordinate: CLLocationCoordinate2D?) async {
        let point = coordinate.map(GeoPoint.init) ?? (isDemo ? Self.demoLocation : nil)
        guard let point else { return }
        if current == nil { isLoading = true }
        defer { isLoading = false }
        do {
            current = try await forecast(at: point)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Weather unavailable."
        }
    }

    // MARK: Destination

    /// Weather at a place at a time (e.g. the ETA), using the nearest hourly slot.
    /// `time` nil or within 30 minutes means current conditions. Nil if it can't be fetched.
    func weather(at coordinate: CLLocationCoordinate2D, time: Date?) async -> DestinationWeather? {
        guard let forecast = try? await forecast(at: GeoPoint(coordinate)) else { return nil }
        return DestinationWeather(forecast: forecast, time: time, now: now())
    }

    // MARK: Cache

    /// A cached forecast within `cacheRadius` and `cacheLifetime`, else one fetch
    /// (shared with any concurrent callers for the same area).
    func forecast(at point: GeoPoint) async throws -> WeatherForecast {
        let time = now()
        if let hit = cachedForecast(near: point, at: time) { return hit }
        let key = GridKey(point)
        if let failedAt = failures[key], time.timeIntervalSince(failedAt) < failureBackoff {
            throw WeatherError.unavailable
        }
        if let pending = inFlight[key] { return try await pending.value }

        let backend = backend
        let task = Task { try await backend.forecast(at: point) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            var forecast = try await task.value
            forecast.fetchedAt = time
            store(forecast)
            failures[key] = nil
            return forecast
        } catch {
            failures[key] = time
            throw error
        }
    }

    func cachedForecast(near point: GeoPoint, at time: Date) -> WeatherForecast? {
        cache
            .filter { time.timeIntervalSince($0.fetchedAt) < cacheLifetime && $0.location.distance(to: point) <= cacheRadius }
            .min { $0.location.distance(to: point) < $1.location.distance(to: point) }
    }

    private func store(_ forecast: WeatherForecast) {
        let time = now()
        cache.removeAll { time.timeIntervalSince($0.fetchedAt) >= cacheLifetime
            || $0.location.distance(to: forecast.location) <= cacheRadius / 2 }
        cache.append(forecast)
        if cache.count > 20 { cache.removeFirst(cache.count - 20) }
    }

    /// ~2 km grid cell, for sharing in-flight fetches and failure backoff.
    private struct GridKey: Hashable {
        let lat: Int
        let lon: Int
        init(_ point: GeoPoint) {
            lat = Int((point.latitude / 0.02).rounded())
            lon = Int((point.longitude / 0.02).rounded())
        }
    }
}
