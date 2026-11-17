import Foundation

/// A WMO weather interpretation code (what Open-Meteo returns) as an SF Symbol and a few words.
struct WeatherCondition: Hashable, Sendable {
    let code: Int
    let symbol: String
    let text: String

    init(code: Int, isDay: Bool = true) {
        self.code = code
        let (day, night, text) = Self.table(code)
        symbol = isDay ? day : night
        self.text = text
    }

    /// Rain, drizzle, showers, storms, snow and the like.
    var isWet: Bool { code >= 51 }

    private static func table(_ code: Int) -> (day: String, night: String, text: String) {
        switch code {
        case 0: ("sun.max.fill", "moon.stars.fill", "Clear")
        case 1: ("sun.max.fill", "moon.fill", "Mostly clear")
        case 2: ("cloud.sun.fill", "cloud.moon.fill", "Partly cloudy")
        case 3: ("cloud.fill", "cloud.fill", "Cloudy")
        case 45, 48: ("cloud.fog.fill", "cloud.fog.fill", "Fog")
        case 51: ("cloud.drizzle.fill", "cloud.drizzle.fill", "Light drizzle")
        case 53: ("cloud.drizzle.fill", "cloud.drizzle.fill", "Drizzle")
        case 55: ("cloud.drizzle.fill", "cloud.drizzle.fill", "Heavy drizzle")
        case 56, 57: ("cloud.sleet.fill", "cloud.sleet.fill", "Freezing drizzle")
        case 61: ("cloud.rain.fill", "cloud.rain.fill", "Light rain")
        case 63: ("cloud.rain.fill", "cloud.rain.fill", "Rain")
        case 65: ("cloud.heavyrain.fill", "cloud.heavyrain.fill", "Heavy rain")
        case 66, 67: ("cloud.sleet.fill", "cloud.sleet.fill", "Freezing rain")
        case 71: ("cloud.snow.fill", "cloud.snow.fill", "Light snow")
        case 73: ("cloud.snow.fill", "cloud.snow.fill", "Snow")
        case 75: ("snowflake", "snowflake", "Heavy snow")
        case 77: ("cloud.snow.fill", "cloud.snow.fill", "Snow grains")
        case 80: ("cloud.sun.rain.fill", "cloud.moon.rain.fill", "Light showers")
        case 81: ("cloud.rain.fill", "cloud.rain.fill", "Showers")
        case 82: ("cloud.heavyrain.fill", "cloud.heavyrain.fill", "Heavy showers")
        case 85, 86: ("cloud.snow.fill", "cloud.snow.fill", "Snow showers")
        case 95: ("cloud.bolt.rain.fill", "cloud.bolt.rain.fill", "Thunderstorm")
        case 96, 99: ("cloud.bolt.rain.fill", "cloud.bolt.rain.fill", "Storm with hail")
        default: ("cloud.fill", "cloud.fill", "—")
        }
    }
}

/// °C or °F, from the region's measurement system (US → °F).
enum TemperatureUnit: String, Sendable, CaseIterable {
    case celsius
    case fahrenheit

    static var current: TemperatureUnit { forLocale(.current) }

    static func forLocale(_ locale: Locale) -> TemperatureUnit {
        locale.measurementSystem == .us ? .fahrenheit : .celsius
    }

    var symbol: String { self == .celsius ? "°C" : "°F" }

    /// Whole degrees in this unit, from Celsius.
    func value(fromCelsius celsius: Double) -> Int {
        let converted = self == .celsius ? celsius : celsius * 9 / 5 + 32
        return Int(converted.rounded())
    }

    /// "21°" (the unit is implied by the region, like the Weather app).
    func format(celsius: Double) -> String { "\(value(fromCelsius: celsius))°" }
}

/// One hour of forecast. Temperatures are always stored in Celsius.
struct HourlyForecast: Hashable, Sendable, Codable {
    var time: Date
    var temperatureC: Double
    var code: Int
    var precipitationProbability: Int?
    var isDay: Bool

    var condition: WeatherCondition { WeatherCondition(code: code, isDay: isDay) }
}

/// One day of the 10-day forecast. Temperatures in Celsius.
struct DailyForecast: Hashable, Sendable, Codable {
    var date: Date
    var code: Int
    var highC: Double
    var lowC: Double
    var precipitationProbability: Int?
    var sunrise: Date?
    var sunset: Date?
    var uvIndexMax: Double?

    var condition: WeatherCondition { WeatherCondition(code: code, isDay: true) }
}

/// The detail tiles (feels like, humidity, wind, UV…), all optional: the service may omit any.
struct WeatherDetails: Hashable, Sendable, Codable {
    var apparentC: Double?
    var humidity: Int?
    var dewPointC: Double?
    var windKmh: Double?
    var windGustKmh: Double?
    var windDirection: Double?
    var uvIndex: Double?
    var visibilityM: Double?
    var pressureHPa: Double?
    var precipitationMM: Double?
}

/// A forecast for one place, as fetched.
struct WeatherForecast: Hashable, Sendable, Codable {
    var location: GeoPoint
    var fetchedAt: Date
    var temperatureC: Double
    var code: Int
    var isDay: Bool
    var hourly: [HourlyForecast]
    var todayHighC: Double?
    var todayLowC: Double?
    /// Today first, up to 10 days.
    var daily: [DailyForecast] = []
    var details = WeatherDetails()
    /// The credit line for the service this came from (CC BY 4.0). nil means Open-Meteo.
    var attribution: String?

    var condition: WeatherCondition { WeatherCondition(code: code, isDay: isDay) }

    /// The hourly slot nearest `date`, if the forecast covers it (within 90 minutes).
    func hour(nearest date: Date) -> HourlyForecast? {
        Self.nearestHour(to: date, in: hourly)
    }

    static func nearestHour(to date: Date, in hours: [HourlyForecast],
                            tolerance: TimeInterval = 90 * 60) -> HourlyForecast? {
        guard let best = hours.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }),
              abs(best.time.timeIntervalSince(date)) <= tolerance else { return nil }
        return best
    }

    /// The next `count` hours starting with the current one.
    func nextHours(_ count: Int, from now: Date) -> [HourlyForecast] {
        let start = now.addingTimeInterval(-30 * 60)
        return Array(hourly.filter { $0.time >= start }.prefix(count))
    }
}

/// Weather at a place and time, e.g. at the destination on arrival.
struct DestinationWeather: Hashable, Sendable {
    var time: Date
    var temperatureC: Double
    var condition: WeatherCondition
    var precipitationProbability: Int?

    /// "Rain likely" threshold.
    var isRainLikely: Bool { (precipitationProbability ?? 0) >= 50 }

    /// Picks the right slot from a forecast: "now" uses current conditions (plus the
    /// current hour's rain chance); a later time uses the nearest hourly slot.
    init?(forecast: WeatherForecast, time: Date?, now: Date) {
        let target = time ?? now
        let nearest = forecast.hour(nearest: target)
        if time == nil || abs(target.timeIntervalSince(now)) < 30 * 60 {
            self.time = now
            temperatureC = forecast.temperatureC
            condition = forecast.condition
            precipitationProbability = nearest?.precipitationProbability
            return
        }
        guard let nearest else { return nil }
        self.time = nearest.time
        temperatureC = nearest.temperatureC
        condition = nearest.condition
        precipitationProbability = nearest.precipitationProbability
    }

    init(time: Date, temperatureC: Double, condition: WeatherCondition, precipitationProbability: Int?) {
        self.time = time
        self.temperatureC = temperatureC
        self.condition = condition
        self.precipitationProbability = precipitationProbability
    }
}
