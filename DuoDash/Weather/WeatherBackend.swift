import Foundation

/// Where WeatherModel gets forecasts from.
protocol WeatherBackend: Sendable {
    var isDemo: Bool { get }
    func forecast(at location: GeoPoint) async throws -> WeatherForecast
}

enum WeatherError: LocalizedError, Equatable {
    case badResponse(Int)
    case malformed
    /// Recently failed for this area; waiting before trying again.
    case unavailable

    var errorDescription: String? {
        switch self {
        case .badResponse(let status): "Weather service error (\(status))."
        case .malformed: "Weather data couldn't be read."
        case .unavailable: "Weather unavailable right now."
        }
    }
}

/// Open-Meteo's free forecast API (no key; CC BY 4.0, so the UI must show
/// `WeatherModel.attribution`). Always asks for Celsius; the UI converts.
struct OpenMeteoBackend: WeatherBackend {
    let isDemo = false
    var session: URLSession = .shared
    var baseURL = URL(string: "https://api.open-meteo.com/v1/forecast")!

    func request(for location: GeoPoint) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", location.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,apparent_temperature,relative_humidity_2m,dew_point_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,uv_index,visibility,pressure_msl,precipitation"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max,sunrise,sunset,uv_index_max"),
            URLQueryItem(name: "forecast_days", value: "10"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        return request
    }

    func forecast(at location: GeoPoint) async throws -> WeatherForecast {
        let (data, response) = try await session.data(for: request(for: location))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WeatherError.badResponse(http.statusCode)
        }
        return try Self.decode(data, location: location, fetchedAt: .now)
    }

    // MARK: Decoding

    private struct Payload: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int?
            let apparent_temperature: Double?
            let relative_humidity_2m: Int?
            let dew_point_2m: Double?
            let wind_speed_10m: Double?
            let wind_gusts_10m: Double?
            let wind_direction_10m: Double?
            let uv_index: Double?
            let visibility: Double?
            let pressure_msl: Double?
            let precipitation: Double?
        }
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
            let weather_code: [Int?]
            let precipitation_probability: [Int?]?
            let is_day: [Int?]?
        }
        struct Daily: Decodable {
            let time: [Double]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let weather_code: [Int?]?
            let precipitation_probability_max: [Int?]?
            let sunrise: [Double?]?
            let sunset: [Double?]?
            let uv_index_max: [Double?]?
        }
        let current: Current
        let hourly: Hourly?
        let daily: Daily?
    }

    static func decode(_ data: Data, location: GeoPoint, fetchedAt: Date) throws -> WeatherForecast {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw WeatherError.malformed
        }
        var hours: [HourlyForecast] = []
        if let h = payload.hourly {
            for (i, time) in h.time.enumerated() {
                guard i < h.temperature_2m.count, i < h.weather_code.count,
                      let temp = h.temperature_2m[i], let code = h.weather_code[i] else { continue }
                let precip = h.precipitation_probability.flatMap { i < $0.count ? $0[i] : nil }
                let isDay = h.is_day.flatMap { i < $0.count ? $0[i] : nil }.map { $0 != 0 } ?? true
                hours.append(HourlyForecast(time: Date(timeIntervalSince1970: time), temperatureC: temp,
                                            code: code, precipitationProbability: precip, isDay: isDay))
            }
        }
        // With timezone=auto the first daily entry is "today" where the place is.
        let high = payload.daily?.temperature_2m_max.first ?? nil
        let low = payload.daily?.temperature_2m_min.first ?? nil
        var days: [DailyForecast] = []
        if let d = payload.daily {
            func at<T>(_ array: [T?]?, _ i: Int) -> T? { array.flatMap { i < $0.count ? $0[i] : nil } }
            for (i, time) in d.time.enumerated() {
                guard let hi = at(d.temperature_2m_max, i), let lo = at(d.temperature_2m_min, i) else { continue }
                days.append(DailyForecast(date: Date(timeIntervalSince1970: time), code: at(d.weather_code, i) ?? 2,
                                          highC: hi, lowC: lo,
                                          precipitationProbability: at(d.precipitation_probability_max, i),
                                          sunrise: at(d.sunrise, i).map { Date(timeIntervalSince1970: $0) },
                                          sunset: at(d.sunset, i).map { Date(timeIntervalSince1970: $0) },
                                          uvIndexMax: at(d.uv_index_max, i)))
            }
        }
        let c = payload.current
        let details = WeatherDetails(apparentC: c.apparent_temperature, humidity: c.relative_humidity_2m,
                                     dewPointC: c.dew_point_2m, windKmh: c.wind_speed_10m,
                                     windGustKmh: c.wind_gusts_10m, windDirection: c.wind_direction_10m,
                                     uvIndex: c.uv_index, visibilityM: c.visibility,
                                     pressureHPa: c.pressure_msl, precipitationMM: c.precipitation)
        return WeatherForecast(location: location, fetchedAt: fetchedAt,
                               temperatureC: payload.current.temperature_2m,
                               code: payload.current.weather_code,
                               isDay: (payload.current.is_day ?? 1) != 0,
                               hourly: hours, todayHighC: high, todayLowC: low,
                               daily: days, details: details)
    }
}
