import Foundation

/// Fixed, offline weather for the Simulator, `-DemoWeather` and tests: 18° and
/// partly cloudy now, light rain (70%) from three to five hours out.
final class DemoWeatherBackend: WeatherBackend, @unchecked Sendable {
    let isDemo = true
    /// Fixed clock for tests; nil means "now".
    let referenceDate: Date?
    /// Make the next fetches fail (for error-path tests).
    var failing = false

    private let lock = NSLock()
    private var _fetchCount = 0
    var fetchCount: Int { lock.withLock { _fetchCount } }

    init(referenceDate: Date? = nil) {
        self.referenceDate = referenceDate
    }

    func forecast(at location: GeoPoint) async throws -> WeatherForecast {
        lock.withLock { _fetchCount += 1 }
        if lock.withLock({ failing }) { throw WeatherError.badResponse(503) }
        return Self.sample(at: location, now: referenceDate ?? .now)
    }

    static func sample(at location: GeoPoint, now: Date) -> WeatherForecast {
        let calendar = Calendar.current
        let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var hours: [HourlyForecast] = []
        for offset in 0..<48 {
            let time = hourStart.addingTimeInterval(Double(offset) * 3600)
            let localHour = calendar.component(.hour, from: time)
            let isDay = (7..<19).contains(localHour)
            let rainy = (3...5).contains(offset)
            // Warmest mid-afternoon, coolest before dawn: 12°…21°.
            let temp = 16.5 + 4.5 * sin((Double(localHour) - 9) / 24 * 2 * .pi)
            hours.append(HourlyForecast(time: time, temperatureC: (temp * 10).rounded() / 10,
                                        code: rainy ? 61 : (isDay ? 2 : 1),
                                        precipitationProbability: rainy ? 70 : 10,
                                        isDay: isDay))
        }
        // `-DemoWeatherSky clear|cloudy|rain|storm|snow|fog|night` picks the current sky (screenshots).
        let sky = UserDefaults.standard.string(forKey: "DemoWeatherSky") ?? ""
        let (code, isDay, temp): (Int, Bool, Double) = switch sky {
        case "clear": (0, true, 24)
        case "cloudy": (3, true, 16)
        case "rain": (63, true, 13)
        case "storm": (95, true, 19)
        case "snow": (73, true, -2)
        case "fog": (45, true, 9)
        case "night": (0, false, 11)
        default: (2, true, 18)
        }
        let codes = [2, 61, 3, 0, 1, 80, 63, 2, 0, 3]
        let highs = [21.0, 17, 19, 24, 25, 20, 16, 18, 22, 21]
        let lows = [12.0, 11, 10, 13, 15, 12, 9, 10, 12, 13]
        let startOfDay = calendar.startOfDay(for: now)
        var days: [DailyForecast] = []
        for i in 0..<10 {
            let date = calendar.date(byAdding: .day, value: i, to: startOfDay) ?? startOfDay
            days.append(DailyForecast(date: date, code: i == 0 ? code : codes[i],
                                      highC: highs[i], lowC: lows[i],
                                      precipitationProbability: [10, 80, 30, 0, 5, 60, 90, 20, 0, 25][i],
                                      sunrise: date.addingTimeInterval(6.5 * 3600),
                                      sunset: date.addingTimeInterval(19.75 * 3600),
                                      uvIndexMax: [8, 3, 5, 10, 11, 6, 2, 7, 10, 6][i]))
        }
        let details = WeatherDetails(apparentC: temp - 1, humidity: 64, dewPointC: 9, windKmh: 17, windGustKmh: 31,
                                     windDirection: 225, uvIndex: isDay ? 6 : 0, visibilityM: 24_000,
                                     pressureHPa: 1016, precipitationMM: 0.4)
        return WeatherForecast(location: location, fetchedAt: now, temperatureC: temp, code: code, isDay: isDay,
                               hourly: hours, todayHighC: 21, todayLowC: 12, daily: days, details: details)
    }
}
