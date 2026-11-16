import XCTest
import SwiftUI
import EventKit
import MapKit
@testable import DuoDash

/// Serves canned Open-Meteo responses so the weather tests never touch the network.
final class OpenMeteoStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenMeteoStubProtocol.self]
        return URLSession(configuration: config)
    }
}

@MainActor
final class CalendarWeatherTests: XCTestCase {
    private let cupertino = GeoPoint(latitude: 37.3230, longitude: -122.0322)
    /// A fixed mid-morning, so demo events all land on the same day.
    private var morning: Date {
        Calendar.current.date(bySettingHour: 9, minute: 2, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
    }

    override func tearDown() {
        OpenMeteoStubProtocol.handler = nil
        OpenMeteoStubProtocol.requests = []
        super.tearDown()
    }

    // MARK: WMO codes

    func testWMOCodeMapping() {
        XCTAssertEqual(WeatherCondition(code: 0).text, "Clear")
        XCTAssertEqual(WeatherCondition(code: 0, isDay: true).symbol, "sun.max.fill")
        XCTAssertEqual(WeatherCondition(code: 0, isDay: false).symbol, "moon.stars.fill")
        XCTAssertEqual(WeatherCondition(code: 2, isDay: false).symbol, "cloud.moon.fill")
        XCTAssertEqual(WeatherCondition(code: 3).text, "Cloudy")
        XCTAssertEqual(WeatherCondition(code: 45).symbol, "cloud.fog.fill")
        XCTAssertEqual(WeatherCondition(code: 48).text, "Fog")
        XCTAssertEqual(WeatherCondition(code: 61).text, "Light rain")
        XCTAssertEqual(WeatherCondition(code: 61).symbol, "cloud.rain.fill")
        XCTAssertEqual(WeatherCondition(code: 65).symbol, "cloud.heavyrain.fill")
        XCTAssertEqual(WeatherCondition(code: 66).text, "Freezing rain")
        XCTAssertEqual(WeatherCondition(code: 73).text, "Snow")
        XCTAssertEqual(WeatherCondition(code: 80, isDay: false).symbol, "cloud.moon.rain.fill")
        XCTAssertEqual(WeatherCondition(code: 95).symbol, "cloud.bolt.rain.fill")
        XCTAssertEqual(WeatherCondition(code: 99).text, "Storm with hail")
        XCTAssertEqual(WeatherCondition(code: 1234).text, "—", "Unknown codes still render")
        XCTAssertFalse(WeatherCondition(code: 3).isWet)
        XCTAssertTrue(WeatherCondition(code: 53).isWet)
    }

    func testEveryDocumentedCodeHasRealSymbolAndText() {
        let codes = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99]
        for code in codes {
            for isDay in [true, false] {
                let condition = WeatherCondition(code: code, isDay: isDay)
                XCTAssertNotEqual(condition.text, "—", "code \(code)")
                XCTAssertNotNil(UIImage(systemName: condition.symbol), "\(condition.symbol) for code \(code)")
            }
        }
    }

    // MARK: Units

    func testUnitFollowsMeasurementSystem() {
        XCTAssertEqual(TemperatureUnit.forLocale(Locale(identifier: "en_US")), .fahrenheit)
        XCTAssertEqual(TemperatureUnit.forLocale(Locale(identifier: "en_AU")), .celsius)
        XCTAssertEqual(TemperatureUnit.forLocale(Locale(identifier: "de_DE")), .celsius)
        XCTAssertEqual(TemperatureUnit.forLocale(Locale(identifier: "en_GB")), .celsius)
    }

    func testUnitConversion() {
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(fromCelsius: 0), 32)
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(fromCelsius: 100), 212)
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(fromCelsius: -40), -40)
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(fromCelsius: 21), 70)  // 69.8
        XCTAssertEqual(TemperatureUnit.celsius.value(fromCelsius: 21.6), 22)
        XCTAssertEqual(TemperatureUnit.celsius.value(fromCelsius: -0.4), 0)
        XCTAssertEqual(TemperatureUnit.celsius.format(celsius: 18.2), "18°")
        XCTAssertEqual(TemperatureUnit.fahrenheit.format(celsius: 18.2), "65°")
        XCTAssertEqual(WeatherModel(backend: DemoWeatherBackend(), unit: .fahrenheit).format(30), "86°")
    }

    // MARK: Nearest hour / destination weather

    private func hours(from start: Date, count: Int, rainAt: Set<Int> = []) -> [HourlyForecast] {
        (0..<count).map { i in
            HourlyForecast(time: start.addingTimeInterval(Double(i) * 3600), temperatureC: 10 + Double(i),
                           code: rainAt.contains(i) ? 63 : 1, precipitationProbability: rainAt.contains(i) ? 80 : 5,
                           isDay: true)
        }
    }

    func testNearestHourForETA() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let list = hours(from: start, count: 6)
        XCTAssertEqual(WeatherForecast.nearestHour(to: start.addingTimeInterval(3600 + 20 * 60), in: list)?.time,
                       start.addingTimeInterval(3600), "1:20 rounds to 1:00")
        XCTAssertEqual(WeatherForecast.nearestHour(to: start.addingTimeInterval(3600 + 40 * 60), in: list)?.time,
                       start.addingTimeInterval(7200), "1:40 rounds to 2:00")
        XCTAssertEqual(WeatherForecast.nearestHour(to: start.addingTimeInterval(-10 * 60), in: list)?.time, start)
        XCTAssertNil(WeatherForecast.nearestHour(to: start.addingTimeInterval(20 * 3600), in: list),
                     "Outside the forecast")
        XCTAssertNil(WeatherForecast.nearestHour(to: start, in: []))
    }

    func testDestinationWeatherUsesCurrentNowAndHourlyLater() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = WeatherForecast(location: cupertino, fetchedAt: now, temperatureC: 17, code: 2, isDay: true,
                                       hourly: hours(from: now, count: 6, rainAt: [3]),
                                       todayHighC: 20, todayLowC: 9)
        let rightNow = try XCTUnwrap(DestinationWeather(forecast: forecast, time: nil, now: now))
        XCTAssertEqual(rightNow.temperatureC, 17)
        XCTAssertEqual(rightNow.condition.text, "Partly cloudy")
        XCTAssertFalse(rightNow.isRainLikely)

        let soon = try XCTUnwrap(DestinationWeather(forecast: forecast, time: now.addingTimeInterval(10 * 60), now: now))
        XCTAssertEqual(soon.temperatureC, 17, "Arriving within 30 minutes uses current conditions")

        let later = try XCTUnwrap(DestinationWeather(forecast: forecast, time: now.addingTimeInterval(3 * 3600 + 900), now: now))
        XCTAssertEqual(later.temperatureC, 13)
        XCTAssertEqual(later.condition.text, "Rain")
        XCTAssertTrue(later.isRainLikely)
        XCTAssertEqual(DestinationWeatherBadge.spoken(later, format: TemperatureUnit.celsius.format),
                       "At arrival: Rain, 13°, rain likely")

        XCTAssertNil(DestinationWeather(forecast: forecast, time: now.addingTimeInterval(30 * 3600), now: now))
    }

    func testRainLikelyThreshold() {
        let c = WeatherCondition(code: 61)
        XCTAssertTrue(DestinationWeather(time: .now, temperatureC: 1, condition: c, precipitationProbability: 50).isRainLikely)
        XCTAssertFalse(DestinationWeather(time: .now, temperatureC: 1, condition: c, precipitationProbability: 49).isRainLikely)
        XCTAssertFalse(DestinationWeather(time: .now, temperatureC: 1, condition: c, precipitationProbability: nil).isRainLikely)
    }

    // MARK: Open-Meteo

    private let sampleJSON = """
    {"latitude":37.32,"longitude":-122.03,"utc_offset_seconds":-28800,"timezone":"America/Los_Angeles",
     "current":{"time":1800000000,"interval":900,"temperature_2m":14.3,"weather_code":61,"is_day":0},
     "hourly":{"time":[1800000000,1800003600,1800007200],
               "temperature_2m":[14.3,13.1,null],
               "weather_code":[61,63,3],
               "precipitation_probability":[55,80,10],
               "is_day":[0,0,1]},
     "daily":{"time":[1799971200,1800057600],"temperature_2m_max":[19.5,21.0],"temperature_2m_min":[8.25,9.0]}}
    """

    func testOpenMeteoRequestAndDecoding() async throws {
        OpenMeteoStubProtocol.handler = { [sampleJSON] _ in (200, Data(sampleJSON.utf8)) }
        let backend = OpenMeteoBackend(session: OpenMeteoStubProtocol.session())
        let forecast = try await backend.forecast(at: cupertino)

        let url = try XCTUnwrap(OpenMeteoStubProtocol.requests.first?.url)
        XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertEqual(url.path, "/v1/forecast")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["timezone"], "auto")
        XCTAssertEqual(items["latitude"], "37.3230")
        XCTAssertEqual(items["longitude"], "-122.0322")
        XCTAssertTrue(items["current"]?.contains("weather_code") ?? false)
        XCTAssertTrue(items["current"]?.contains("is_day") ?? false)
        XCTAssertTrue(items["hourly"]?.contains("precipitation_probability") ?? false)
        XCTAssertTrue(items["daily"]?.hasPrefix("temperature_2m_max,temperature_2m_min") ?? false)
        XCTAssertEqual(items["forecast_days"], "10")
        XCTAssertNil(items["apikey"], "Open-Meteo needs no key")

        XCTAssertEqual(forecast.temperatureC, 14.3)
        XCTAssertEqual(forecast.code, 61)
        XCTAssertFalse(forecast.isDay)
        XCTAssertEqual(forecast.condition.text, "Light rain")
        XCTAssertEqual(forecast.hourly.count, 2, "Hours with missing values are skipped")
        XCTAssertEqual(forecast.hourly[1].precipitationProbability, 80)
        XCTAssertEqual(forecast.hourly[1].time, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(forecast.todayHighC, 19.5)
        XCTAssertEqual(forecast.todayLowC, 8.25)
    }

    func testOpenMeteoErrors() async {
        OpenMeteoStubProtocol.handler = { _ in (429, Data()) }
        let backend = OpenMeteoBackend(session: OpenMeteoStubProtocol.session())
        do {
            _ = try await backend.forecast(at: cupertino)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? WeatherError, .badResponse(429))
        }
        XCTAssertThrowsError(try OpenMeteoBackend.decode(Data("{}".utf8), location: cupertino, fetchedAt: .now)) {
            XCTAssertEqual($0 as? WeatherError, .malformed)
        }
    }

    // MARK: Weather model cache

    func testWeatherCacheByDistanceAndAge() async throws {
        let backend = DemoWeatherBackend(referenceDate: morning)
        let model = WeatherModel(backend: backend, unit: .celsius)
        var clock = morning
        model.now = { clock }

        _ = try await model.forecast(at: cupertino)
        _ = try await model.forecast(at: cupertino)
        XCTAssertEqual(backend.fetchCount, 1)

        // ~1 km away: same forecast.
        _ = try await model.forecast(at: GeoPoint(latitude: cupertino.latitude + 0.009, longitude: cupertino.longitude))
        XCTAssertEqual(backend.fetchCount, 1)

        // ~5 km away: a new fetch.
        _ = try await model.forecast(at: GeoPoint(latitude: cupertino.latitude + 0.045, longitude: cupertino.longitude))
        XCTAssertEqual(backend.fetchCount, 2)

        // 16 minutes later: stale, fetched again.
        clock = morning.addingTimeInterval(16 * 60)
        _ = try await model.forecast(at: cupertino)
        XCTAssertEqual(backend.fetchCount, 3)
    }

    func testConcurrentRequestsShareOneFetch() async throws {
        let backend = DemoWeatherBackend(referenceDate: morning)
        let model = WeatherModel(backend: backend, unit: .celsius)
        model.now = { [morning] in morning }
        async let a = model.forecast(at: cupertino)
        async let b = model.forecast(at: cupertino)
        async let c = model.weather(at: cupertino.coordinate, time: nil)
        _ = try await (a, b)
        _ = await c
        XCTAssertEqual(backend.fetchCount, 1)
    }

    func testFailureBacksOff() async {
        let backend = DemoWeatherBackend(referenceDate: morning)
        backend.failing = true
        let model = WeatherModel(backend: backend, unit: .celsius)
        var clock = morning
        model.now = { clock }

        await model.updateCurrent(at: cupertino.coordinate)
        XCTAssertNil(model.current)
        XCTAssertNotNil(model.errorMessage)
        await model.updateCurrent(at: cupertino.coordinate)
        XCTAssertEqual(backend.fetchCount, 1, "No retry straight after a failure")

        backend.failing = false
        clock = morning.addingTimeInterval(3 * 60)
        await model.updateCurrent(at: cupertino.coordinate)
        XCTAssertEqual(backend.fetchCount, 2)
        XCTAssertNotNil(model.current)
        XCTAssertNil(model.errorMessage)
    }

    func testDemoWeatherBackend() async throws {
        let model = WeatherModel(backend: DemoWeatherBackend(referenceDate: morning), unit: .celsius)
        model.now = { [morning] in morning }
        XCTAssertTrue(model.isDemo)
        await model.updateCurrent(at: nil)
        let current = try XCTUnwrap(model.current, "Demo works without a location fix")
        XCTAssertEqual(current.temperatureC, 18)
        XCTAssertEqual(current.condition.text, "Partly cloudy")
        XCTAssertEqual(current.todayHighC, 21)
        XCTAssertEqual(current.todayLowC, 12)
        XCTAssertEqual(current.hourly.count, 48)
        XCTAssertEqual(current.nextHours(6, from: morning).count, 6)

        let arrivalValue = await model.weather(at: cupertino.coordinate, time: morning.addingTimeInterval(4 * 3600))
        let arrival = try XCTUnwrap(arrivalValue)
        XCTAssertTrue(arrival.isRainLikely, "Demo rains three to five hours out")
        XCTAssertEqual(arrival.condition.text, "Light rain")
        let soonValue = await model.weather(at: cupertino.coordinate, time: morning.addingTimeInterval(3600))
        let soon = try XCTUnwrap(soonValue)
        XCTAssertFalse(soon.isRainLikely)
        XCTAssertEqual(WeatherModel.attribution, "Weather: Open-Meteo.com")
    }

    func testRealWeatherWaitsForLocation() async {
        OpenMeteoStubProtocol.handler = { _ in XCTFail("No fetch without a location"); return (500, Data()) }
        let model = WeatherModel(backend: OpenMeteoBackend(session: OpenMeteoStubProtocol.session()), unit: .celsius)
        await model.updateCurrent(at: nil)
        XCTAssertNil(model.current)
        XCTAssertTrue(OpenMeteoStubProtocol.requests.isEmpty)
    }

    // MARK: Calendar: events and next up

    private func event(_ id: String, start: TimeInterval, length: TimeInterval = 3600, allDay: Bool = false,
                       location: String? = nil, geo: GeoPoint? = nil, from base: Date) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: base.addingTimeInterval(start),
                      end: base.addingTimeInterval(start + length), isAllDay: allDay,
                      location: location, structuredCoordinate: geo)
    }

    func testDemoCalendarDay() {
        let backend = DemoCalendarBackend(now: morning)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        model.now = { [morning] in morning }
        model.refresh()

        XCTAssertTrue(model.isDemo)
        XCTAssertEqual(model.access, .granted)
        XCTAssertEqual(model.upcoming.map(\.title), ["Design review", "Lunch with Sam", "Gym"],
                       "All-day events are skipped when there are timed ones")
        XCTAssertEqual(model.nextEvent?.title, "Design review")
        XCTAssertEqual(model.laterEvents.map(\.title), ["Lunch with Sam", "Gym"])
        XCTAssertTrue(model.todayAndTomorrow.contains { $0.isAllDay }, "The Calendar screen still lists all-day events")
        XCTAssertEqual(model.nextEvent?.placeName, "Apple Park Visitor Center")
        for e in model.upcoming {
            XCTAssertGreaterThan(e.start, morning, "Demo times are relative to now")
            XCTAssertLessThan(e.start, morning.addingTimeInterval(6 * 3600))
        }
    }

    func testUpcomingSkipsAllDayUnlessNothingElse() {
        let now = morning
        let allDay = event("Holiday", start: -9 * 3600, length: 86_400, allDay: true, from: now)
        let ended = event("Standup", start: -2 * 3600, length: 900, from: now)
        let soon = event("Dentist", start: 1800, from: now)
        let farOff = event("Flight", start: 30 * 3600, from: now)

        XCTAssertEqual(CalendarModel.upcoming(from: [allDay, ended, soon, farOff], now: now).map(\.id), ["Dentist"])
        XCTAssertEqual(CalendarModel.upcoming(from: [allDay, ended], now: now).map(\.id), ["Holiday"])
        XCTAssertEqual(CalendarModel.upcoming(from: [ended], now: now).map(\.id), [])
    }

    func testNextEventPrefersJustStartedThenNextToStart() {
        let backend = DemoCalendarBackend(now: morning)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        var clock = morning
        model.now = { clock }
        backend.demoEvents = [
            event("Running", start: -40 * 60, length: 2 * 3600, from: morning),
            event("Started", start: -5 * 60, length: 3600, from: morning),
            event("Later", start: 3600, from: morning),
        ]
        model.refresh()
        XCTAssertEqual(model.nextEvent?.id, "Started", "Just started: you might be on your way")

        clock = morning.addingTimeInterval(20 * 60)
        model.refresh()
        XCTAssertEqual(model.nextEvent?.id, "Later", "Events that started a while ago give way to the next one")
    }

    func testEventTimeText() {
        let now = morning
        let start = now.addingTimeInterval(40 * 60)
        let e = CalendarEvent(id: "a", title: "A", start: start, end: start.addingTimeInterval(3600))
        let clock = start.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(EventTimeText.describe(e, now: now), "\(clock) · in 40 min")
        XCTAssertEqual(EventTimeText.describe(e, now: now.addingTimeInterval(-100 * 60)), "\(clock) · in 2 h 20 min")
        XCTAssertEqual(EventTimeText.describe(e, now: start.addingTimeInterval(60), short: true), "Now")
        XCTAssertTrue(EventTimeText.describe(e, now: start.addingTimeInterval(60)).hasPrefix("Now · until "))
        var allDay = e
        allDay.isAllDay = true
        XCTAssertEqual(EventTimeText.describe(allDay, now: now), "All day")
    }

    // MARK: Calendar: destinations

    func testStructuredLocationBeatsText() {
        let geo = GeoPoint(latitude: 37.3349, longitude: -122.0090)
        var e = CalendarEvent(id: "x", title: "Meeting", start: morning, end: morning.addingTimeInterval(3600),
                              location: "Somewhere else entirely, Sydney", structuredTitle: "Apple Park",
                              structuredCoordinate: geo)
        XCTAssertEqual(e.place, .coordinate(geo, name: "Apple Park"))

        e.structuredCoordinate = nil
        e.structuredTitle = nil
        XCTAssertEqual(e.place, .address("Somewhere else entirely, Sydney"))
        XCTAssertEqual(e.placeName, "Somewhere else entirely, Sydney")

        e.location = "https://zoom.us/j/123"
        XCTAssertEqual(e.place, .none)
        e.location = "Zoom"
        XCTAssertEqual(e.place, .none)
        e.location = "   "
        XCTAssertEqual(e.place, .none)
        XCTAssertNil(e.placeName)
        XCTAssertFalse(e.place.isNavigable)
    }

    func testDestinationFromStructuredGeoSkipsGeocoding() async throws {
        let geocoder = DemoPlaceGeocoder()
        let model = CalendarModel(backend: DemoCalendarBackend(now: morning), geocoder: geocoder)
        let geo = GeoPoint(latitude: 37.3349, longitude: -122.0090)
        let e = CalendarEvent(id: "x", title: "Meeting", start: morning, end: morning.addingTimeInterval(3600),
                              location: "Cupertino Fitness", structuredTitle: "Apple Park",
                              structuredCoordinate: geo)
        let itemValue = await model.destination(for: e)
        let item = try XCTUnwrap(itemValue)
        XCTAssertEqual(item.name, "Apple Park")
        XCTAssertEqual(item.location.coordinate.latitude, geo.latitude, accuracy: 1e-9)
        XCTAssertEqual(item.location.coordinate.longitude, geo.longitude, accuracy: 1e-9)
        XCTAssertTrue(geocoder.lookups.isEmpty, "A Maps-picked place never needs geocoding")
    }

    func testDestinationGeocodesTextOnceAndCaches() async throws {
        let geocoder = DemoPlaceGeocoder()
        let model = CalendarModel(backend: DemoCalendarBackend(now: morning), geocoder: geocoder)
        let gym = CalendarEvent(id: "gym", title: "Gym", start: morning, end: morning.addingTimeInterval(3600),
                                location: "Cupertino Fitness, 19900 Stevens Creek Blvd")
        let firstValue = await model.destination(for: gym)
        let first = try XCTUnwrap(firstValue)
        let secondValue = await model.destination(for: gym)
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(first.location.coordinate.latitude, DemoCalendarBackend.gym.latitude, accuracy: 1e-9)
        XCTAssertEqual(second.location.coordinate.longitude, DemoCalendarBackend.gym.longitude, accuracy: 1e-9)
        XCTAssertEqual(geocoder.lookups.count, 1, "Second lookup comes from the cache")
        XCTAssertFalse(model.unresolvable.contains("gym"))

        let nowhere = CalendarEvent(id: "nowhere", title: "?", start: morning, end: morning.addingTimeInterval(60),
                                    location: "Narnia")
        let miss = await model.destination(for: nowhere)
        XCTAssertNil(miss)
        let missAgain = await model.destination(for: nowhere)
        XCTAssertNil(missAgain)
        XCTAssertEqual(geocoder.lookups.count, 2, "Misses are cached too")
        XCTAssertTrue(model.unresolvable.contains("nowhere"))
        XCTAssertTrue(model.resolving.isEmpty)

        let online = CalendarEvent(id: "o", title: "Call", start: morning, end: morning, location: "Teams")
        let none = await model.destination(for: online)
        XCTAssertNil(none)
        XCTAssertEqual(geocoder.lookups.count, 2)
    }

    // MARK: Calendar: permission

    func testPermissionStateText() {
        XCTAssertEqual(CalendarAccess.notDetermined.actionTitle, "Allow Calendar")
        XCTAssertTrue(CalendarAccess.notDetermined.canRequest)
        XCTAssertEqual(CalendarAccess.denied.title, "Calendar access is off")
        XCTAssertTrue(CalendarAccess.denied.message.contains("Settings"))
        XCTAssertEqual(CalendarAccess.denied.actionTitle, "Open Settings")
        XCTAssertFalse(CalendarAccess.denied.canRequest)
        XCTAssertTrue(CalendarAccess.writeOnly.message.contains("Full Access"))
        XCTAssertEqual(CalendarAccess.writeOnly.actionTitle, "Open Settings")
        XCTAssertNil(CalendarAccess.restricted.actionTitle)
        XCTAssertNil(CalendarAccess.granted.actionTitle)
        XCTAssertEqual(CalendarAccess.granted.message, "")
        for state in [CalendarAccess.notDetermined, .denied, .restricted, .writeOnly] {
            XCTAssertFalse(state.isGranted)
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.message.isEmpty)
        }
    }

    func testEventKitStatusMapping() {
        XCTAssertEqual(EventKitCalendarBackend.map(.fullAccess), .granted)
        XCTAssertEqual(EventKitCalendarBackend.map(.writeOnly), .writeOnly)
        XCTAssertEqual(EventKitCalendarBackend.map(.denied), .denied)
        XCTAssertEqual(EventKitCalendarBackend.map(.restricted), .restricted)
        XCTAssertEqual(EventKitCalendarBackend.map(.notDetermined), .notDetermined)
    }

    func testRequestingAccessLoadsEvents() async {
        let backend = DemoCalendarBackend(now: morning, access: .notDetermined)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        model.now = { [morning] in morning }
        model.refresh()
        XCTAssertEqual(model.access, .notDetermined)
        XCTAssertTrue(model.upcoming.isEmpty)
        XCTAssertNil(model.nextEvent)

        await model.requestAccess()
        XCTAssertEqual(backend.requestCount, 1)
        XCTAssertEqual(model.access, .granted)
        XCTAssertEqual(model.nextEvent?.title, "Design review")
    }

    func testDeniedShowsNoEvents() async {
        let backend = DemoCalendarBackend(now: morning, access: .notDetermined, grantsOnRequest: false)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        model.now = { [morning] in morning }
        await model.requestAccess()
        XCTAssertEqual(model.access, .denied)
        XCTAssertTrue(model.upcoming.isEmpty)
        XCTAssertTrue(model.todayAndTomorrow.isEmpty)
    }

    func testBackendChangeRefreshes() {
        let backend = DemoCalendarBackend(now: morning)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        model.now = { [morning] in morning }
        model.refresh()
        backend.demoEvents.append(event("Coffee", start: 10 * 60, length: 600, from: morning))
        backend.onChange?()
        XCTAssertEqual(model.nextEvent?.title, "Coffee")
    }

    func testCalendarScreenSections() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: morning)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let events = [
            CalendarEvent(id: "done", title: "Done", start: morning.addingTimeInterval(-7200), end: morning.addingTimeInterval(-3600)),
            CalendarEvent(id: "b", title: "B", start: morning.addingTimeInterval(3600), end: morning.addingTimeInterval(7200)),
            CalendarEvent(id: "allday", title: "All", start: today, end: tomorrow, isAllDay: true),
            CalendarEvent(id: "t", title: "T", start: tomorrow.addingTimeInterval(9 * 3600), end: tomorrow.addingTimeInterval(10 * 3600)),
        ]
        let sections = CalendarScreen.sections(events, now: morning)
        XCTAssertEqual(sections.map(\.title), ["Today", "Tomorrow"])
        XCTAssertEqual(sections[0].events.map(\.id), ["allday", "b"], "All-day first; finished events hidden")
        XCTAssertEqual(sections[1].events.map(\.id), ["t"])
    }

    // MARK: Layout smoke test

    /// Renders the card at its smallest and largest sizes and the screen (all demo
    /// data) to check they lay out. PNGs land in the temp directory for a look.
    func testViewsRenderAtDashboardSizes() async throws {
        let calendar = CalendarModel(backend: DemoCalendarBackend(), geocoder: DemoPlaceGeocoder())
        let weather = WeatherModel(backend: DemoWeatherBackend(), unit: .celsius)
        await weather.updateCurrent(at: nil)
        let location = LocationManager()
        let sizes = [CGSize(width: 220, height: 120), CGSize(width: 300, height: 180), CGSize(width: 420, height: 300)]
        var views: [(String, AnyView, CGSize)] = sizes.map { size in
            ("nextup-\(Int(size.width))x\(Int(size.height))", AnyView(NextUpCard(onNavigate: { _ in })), size)
        }
        // ImageRenderer can't draw a ScrollView, so render the screen's pieces directly.
        let rows = VStack(spacing: Theme.gap) {
            WeatherHeader()
            ForEach(calendar.todayAndTomorrow) { event in
                CalendarEventRow(event: event, isNext: event.id == calendar.nextEvent?.id, onNavigate: { _ in })
            }
            Spacer(minLength: 0)
        }
        views.append(("screen", AnyView(rows.padding(Theme.gap)), CGSize(width: 800, height: 600)))
        views.append(("screen-narrow", AnyView(rows.padding(Theme.gap)), CGSize(width: 380, height: 700)))
        views.append(("badge", AnyView(DestinationWeatherBadge(coordinate: cupertino.coordinate,
                                                               eta: .now.addingTimeInterval(4 * 3600))),
                      CGSize(width: 220, height: 40)))
        for (name, view, size) in views {
            let renderer = ImageRenderer(content: view
                .frame(width: size.width, height: size.height)
                .background(Color.black)
                .environment(calendar)
                .environment(weather)
                .environment(location)
                .environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, name)
            XCTAssertEqual(image.size, size, name)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("calweather-\(name).png")
            try image.pngData()?.write(to: url)
        }
    }
}
