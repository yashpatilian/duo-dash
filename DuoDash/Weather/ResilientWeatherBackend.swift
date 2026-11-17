import Foundation

/// Tries each backend in turn, each with a retry, so one slow or failing service never leaves
/// the app without weather. Order: Open-Meteo (full forecast), then MET Norway (global, keyless).
struct ResilientWeatherBackend: WeatherBackend {
    let isDemo = false
    var backends: [WeatherBackend]
    /// Attempts per backend before moving on to the next one.
    var attempts = 2
    /// Pause between attempts on the same backend.
    var retryDelay: Duration = .seconds(1.5)

    init(backends: [WeatherBackend] = [OpenMeteoBackend(), METNorwayBackend()], attempts: Int = 2,
         retryDelay: Duration = .seconds(1.5)) {
        self.backends = backends
        self.attempts = attempts
        self.retryDelay = retryDelay
    }

    func forecast(at location: GeoPoint) async throws -> WeatherForecast {
        var lastError: Error = WeatherError.unavailable
        for backend in backends {
            for attempt in 0..<max(1, attempts) {
                try Task.checkCancellation()
                do {
                    return try await backend.forecast(at: location)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    // A response the decoder can't read won't change on a retry: try the next service.
                    if case WeatherError.malformed = error { break }
                    if attempt + 1 < attempts { try? await Task.sleep(for: retryDelay) }
                }
            }
        }
        throw lastError
    }
}

/// MET Norway's Locationforecast 2.0 "compact" (free, global, no key; needs an identifying
/// User-Agent; data CC BY 4.0, credited as "Weather: MET Norway" in the UI).
/// Used as the fallback: no sunrise/sunset or rain chance, everything else is filled in.
struct METNorwayBackend: WeatherBackend {
    let isDemo = false
    var session: URLSession = .shared
    var baseURL = URL(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact")!
    var timeZone: TimeZone = .current

    func request(for location: GeoPoint) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", location.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", location.longitude)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        request.setValue("DuoDash/1.0 github.com/yashpatilian/duo-dash", forHTTPHeaderField: "User-Agent")
        return request
    }

    func forecast(at location: GeoPoint) async throws -> WeatherForecast {
        let (data, response) = try await session.data(for: request(for: location))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WeatherError.badResponse(http.statusCode)
        }
        return try Self.decode(data, location: location, fetchedAt: .now, timeZone: timeZone)
    }

    // MARK: Decoding

    private struct Payload: Decodable {
        struct Properties: Decodable { let timeseries: [Entry] }
        struct Entry: Decodable {
            let time: String
            let data: EntryData
        }
        struct EntryData: Decodable {
            let instant: Instant
            let next_1_hours: Period?
            let next_6_hours: Period?
            let next_12_hours: Period?
        }
        struct Instant: Decodable { let details: Details }
        struct Details: Decodable {
            let air_temperature: Double?
            let wind_speed: Double?
            let wind_from_direction: Double?
            let relative_humidity: Double?
            let air_pressure_at_sea_level: Double?
            let dew_point_temperature: Double?
        }
        struct Period: Decodable {
            struct Summary: Decodable { let symbol_code: String }
            struct PeriodDetails: Decodable { let precipitation_amount: Double? }
            let summary: Summary?
            let details: PeriodDetails?
        }
        let properties: Properties
    }

    static func decode(_ data: Data, location: GeoPoint, fetchedAt: Date, timeZone: TimeZone = .current) throws -> WeatherForecast {
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch { throw WeatherError.malformed }
        let iso = ISO8601DateFormatter()
        let entries: [(Date, Payload.EntryData)] = payload.properties.timeseries.compactMap { e in
            iso.date(from: e.time).map { ($0, e.data) }
        }
        guard let first = entries.first, let temperature = first.1.instant.details.air_temperature else {
            throw WeatherError.malformed
        }
        func symbol(_ d: Payload.EntryData) -> String? {
            (d.next_1_hours ?? d.next_6_hours ?? d.next_12_hours)?.summary?.symbol_code
        }

        var hours: [HourlyForecast] = []
        for (time, d) in entries {
            guard d.next_1_hours != nil, let t = d.instant.details.air_temperature, let s = symbol(d) else { continue }
            hours.append(HourlyForecast(time: time, temperatureC: t, code: wmoCode(s), precipitationProbability: nil,
                                        isDay: !s.hasSuffix("_night")))
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.0) }
        let days: [DailyForecast] = byDay.keys.sorted().prefix(10).compactMap { day in
            let items = byDay[day]!
            let temps = items.compactMap { $0.1.instant.details.air_temperature }
            guard let hi = temps.max(), let lo = temps.min() else { return nil }
            // The day's weather: the symbol nearest midday.
            let noon = day.addingTimeInterval(12 * 3600)
            let mid = items.filter { symbol($0.1) != nil }.min { abs($0.0.timeIntervalSince(noon)) < abs($1.0.timeIntervalSince(noon)) }
            return DailyForecast(date: day, code: mid.flatMap { symbol($0.1) }.map(wmoCode) ?? 2, highC: hi, lowC: lo,
                                 precipitationProbability: nil, sunrise: nil, sunset: nil, uvIndexMax: nil)
        }

        let d = first.1.instant.details
        let s = symbol(first.1) ?? "cloudy"
        let details = WeatherDetails(apparentC: nil, humidity: d.relative_humidity.map { Int($0.rounded()) },
                                     dewPointC: d.dew_point_temperature, windKmh: d.wind_speed.map { $0 * 3.6 },
                                     windGustKmh: nil, windDirection: d.wind_from_direction, uvIndex: nil,
                                     visibilityM: nil, pressureHPa: d.air_pressure_at_sea_level,
                                     precipitationMM: first.1.next_1_hours?.details?.precipitation_amount)
        let today = days.first { calendar.isDate($0.date, inSameDayAs: first.0) }
        return WeatherForecast(location: location, fetchedAt: fetchedAt, temperatureC: temperature,
                               code: wmoCode(s), isDay: !s.hasSuffix("_night"), hourly: hours,
                               todayHighC: today?.highC, todayLowC: today?.lowC, daily: days, details: details,
                               attribution: "Weather: MET Norway")
    }

    /// MET Norway symbol code ("lightrainshowers_day") to the WMO weather code the UI uses.
    static func wmoCode(_ symbol: String) -> Int {
        var s = symbol
        for suffix in ["_day", "_night", "_polartwilight"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        let light = s.hasPrefix("light"), heavy = s.hasPrefix("heavy"), showers = s.contains("showers")
        if s.contains("thunder") { return 95 }
        if s.contains("snow") { return showers ? (heavy ? 86 : 85) : (light ? 71 : heavy ? 75 : 73) }
        if s.contains("sleet") { return light ? 66 : 67 }
        if s.contains("rain") { return showers ? (light ? 80 : heavy ? 82 : 81) : (light ? 61 : heavy ? 65 : 63) }
        switch s {
        case "clearsky": return 0
        case "fair": return 1
        case "partlycloudy": return 2
        case "fog": return 45
        default: return 3
        }
    }
}
