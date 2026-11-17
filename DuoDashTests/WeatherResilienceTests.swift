import XCTest
@testable import DuoDash

/// "Weather unavailable" must not come back: fallback service, retries, the saved forecast,
/// and keeping what's on screen when a refresh fails.
@MainActor
final class WeatherResilienceTests: XCTestCase {
    private let testPlace = GeoPoint(latitude: 51.5072, longitude: -0.1276)
    private let morning = Date(timeIntervalSince1970: 1_790_000_000)

    /// A backend that fails a set number of times, then returns the demo forecast.
    private final class Flaky: WeatherBackend, @unchecked Sendable {
        let isDemo = false
        var failuresLeft: Int
        var calls = 0
        let error: Error
        init(failures: Int, error: Error = URLError(.timedOut)) { failuresLeft = failures; self.error = error }
        func forecast(at location: GeoPoint) async throws -> WeatherForecast {
            calls += 1
            if failuresLeft > 0 { failuresLeft -= 1; throw error }
            var f = try await DemoWeatherBackend().forecast(at: location)
            f.attribution = "test"
            return f
        }
    }

    func testRetriesThenFallsBackToTheSecondService() async throws {
        let primary = Flaky(failures: 99), secondary = Flaky(failures: 1)
        let backend = ResilientWeatherBackend(backends: [primary, secondary], attempts: 2, retryDelay: .zero)
        let forecast = try await backend.forecast(at: testPlace)
        XCTAssertEqual(primary.calls, 2, "the first service gets a retry")
        XCTAssertEqual(secondary.calls, 2, "the second service recovers on its retry")
        XCTAssertEqual(forecast.attribution, "test")
    }

    func testUnreadableResponseSkipsStraightToTheNextService() async throws {
        let primary = Flaky(failures: 99, error: WeatherError.malformed), secondary = Flaky(failures: 0)
        _ = try await ResilientWeatherBackend(backends: [primary, secondary], attempts: 3, retryDelay: .zero).forecast(at: testPlace)
        XCTAssertEqual(primary.calls, 1)
    }

    func testAFailedRefreshKeepsTheForecastOnScreen() async {
        let backend = DemoWeatherBackend(referenceDate: morning)
        let model = WeatherModel(backend: backend, unit: .celsius)
        var clock = morning
        model.now = { clock }
        let ok1 = await model.updateCurrent(at: testPlace.coordinate)
        XCTAssertTrue(ok1)
        backend.failing = true
        clock = morning.addingTimeInterval(3600)
        let ok2 = await model.updateCurrent(at: testPlace.coordinate)
        XCTAssertFalse(ok2)
        XCTAssertNotNil(model.current, "the old forecast stays")
        XCTAssertNil(model.errorMessage, "no error while there's something to show")
        XCTAssertEqual(model.staleText?.hasPrefix("Updated "), true)
    }

    func testSavedForecastShowsOnLaunchAndIsUsedWithoutALocationFix() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("weather-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = WeatherModel(backend: Flaky(failures: 0), unit: .celsius, savedURL: url)
        let ok3 = await first.updateCurrent(at: testPlace.coordinate)
        XCTAssertTrue(ok3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Next launch, offline and with no fix yet: the saved forecast is there straight away.
        let offline = Flaky(failures: 99)
        let second = WeatherModel(backend: offline, unit: .celsius, savedURL: url)
        XCTAssertEqual(second.current?.location, testPlace)
        let ok4 = await second.updateCurrent(at: nil)
        XCTAssertFalse(ok4)
        XCTAssertEqual(offline.calls, 1, "it retried at the last known place")
        XCTAssertNotNil(second.current)
        XCTAssertNil(second.errorMessage)
    }

    func testMETNorwayDecodes() throws {
        let json = """
        {"properties":{"timeseries":[
          {"time":"2026-11-17T09:00:00Z","data":{"instant":{"details":{"air_temperature":17.4,"wind_speed":5.0,
            "wind_from_direction":200,"relative_humidity":61.2,"air_pressure_at_sea_level":1012.3}},
            "next_1_hours":{"summary":{"symbol_code":"lightrainshowers_day"},"details":{"precipitation_amount":0.4}}}},
          {"time":"2026-11-17T10:00:00Z","data":{"instant":{"details":{"air_temperature":19.0}},
            "next_1_hours":{"summary":{"symbol_code":"partlycloudy_day"}}}},
          {"time":"2026-11-18T12:00:00Z","data":{"instant":{"details":{"air_temperature":24.0}},
            "next_6_hours":{"summary":{"symbol_code":"clearsky_day"}}}}
        ]}}
        """
        let f = try METNorwayBackend.decode(Data(json.utf8), location: testPlace, fetchedAt: morning,
                                            timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(f.temperatureC, 17.4)
        XCTAssertEqual(f.code, 80)
        XCTAssertEqual(f.hourly.count, 2)
        XCTAssertEqual(f.daily.count, 2)
        XCTAssertEqual(f.todayHighC, 19.0)
        XCTAssertEqual(f.details.windKmh ?? 0, 18, accuracy: 0.01)
        XCTAssertEqual(f.details.humidity, 61)
        XCTAssertEqual(f.attribution, "Weather: MET Norway")
        XCTAssertThrowsError(try METNorwayBackend.decode(Data("{}".utf8), location: testPlace, fetchedAt: morning))
    }

    func testMETNorwaySymbols() {
        XCTAssertEqual(METNorwayBackend.wmoCode("clearsky_night"), 0)
        XCTAssertEqual(METNorwayBackend.wmoCode("fair_day"), 1)
        XCTAssertEqual(METNorwayBackend.wmoCode("cloudy"), 3)
        XCTAssertEqual(METNorwayBackend.wmoCode("fog"), 45)
        XCTAssertEqual(METNorwayBackend.wmoCode("heavyrain"), 65)
        XCTAssertEqual(METNorwayBackend.wmoCode("rainshowersandthunder_day"), 95)
        XCTAssertEqual(METNorwayBackend.wmoCode("lightsnow"), 71)
        XCTAssertEqual(METNorwayBackend.wmoCode("sleetshowers_polartwilight"), 67)
    }

    func testTheLiveAppUsesBothServices() {
        let backend = ResilientWeatherBackend()
        XCTAssertTrue(backend.backends.first is OpenMeteoBackend)
        XCTAssertTrue(backend.backends.last is METNorwayBackend)
    }
}
