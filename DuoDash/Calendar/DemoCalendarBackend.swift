import Foundation
import MapKit

/// A deterministic day near Cupertino, relative to "now", optionally with a
/// realistic few months around it. Used in the Simulator (whose calendar is
/// empty), with `-DemoCalendar` on a device, and in tests.
@MainActor
final class DemoCalendarBackend: CalendarBackend {
    let isDemo = true
    var onChange: (@MainActor () -> Void)?

    var currentAccess: CalendarAccess
    /// What the system prompt answers when asked.
    var grantsOnRequest: Bool
    private(set) var requestCount = 0
    /// How many times `events(from:to:)` was called (to test caching).
    private(set) var fetchCount = 0
    var demoEvents: [CalendarEvent]

    /// Coordinates used by the demo events (and the demo geocoder).
    static let applePark = GeoPoint(latitude: 37.33270, longitude: -122.00530)
    static let cafe = GeoPoint(latitude: 37.32290, longitude: -122.03220)
    static let gym = GeoPoint(latitude: 37.32360, longitude: -122.01510)
    static let market = GeoPoint(latitude: 37.33660, longitude: -122.01450)
    static let park = GeoPoint(latitude: 37.32470, longitude: -122.04460)
    static let library = GeoPoint(latitude: 37.31790, longitude: -122.02920)

    /// - Parameter includesMonth: add `sampleMonths` (the app does; tests that
    ///   count today's events use the single day).
    init(now: Date = .now, access: CalendarAccess = .granted, grantsOnRequest: Bool = true,
         includesMonth: Bool = false) {
        currentAccess = access
        self.grantsOnRequest = grantsOnRequest
        demoEvents = Self.sampleDay(now: now) + (includesMonth ? Self.sampleMonths(around: now) : [])
    }

    func access() -> CalendarAccess { currentAccess }

    func requestAccess() async -> CalendarAccess {
        requestCount += 1
        if currentAccess == .notDetermined {
            currentAccess = grantsOnRequest ? .granted : .denied
        }
        return currentAccess
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        fetchCount += 1
        guard currentAccess == .granted else { return [] }
        return demoEvents
            .filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
    }

    /// Three timed events plus an all-day one (which "Next up" should skip).
    static func sampleDay(now: Date) -> [CalendarEvent] {
        // Round to 5 minutes so the times look like real appointments.
        let base = Date(timeIntervalSinceReferenceDate:
            (now.timeIntervalSinceReferenceDate / 300).rounded(.up) * 300)
        let dayStart = Calendar.current.startOfDay(for: now)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        return [
            CalendarEvent(id: "demo.birthday", title: "Sam's birthday",
                          start: dayStart, end: dayStart.addingTimeInterval(86_400), isAllDay: true,
                          calendarTitle: "Birthdays", colorRGB: [0.75, 0.35, 0.95]),
            CalendarEvent(id: "demo.design", title: "Design review", start: at(40), end: at(100),
                          location: "Apple Park Visitor Center\n10600 N Tantau Ave, Cupertino, CA 95014",
                          structuredTitle: "Apple Park Visitor Center", structuredCoordinate: applePark,
                          calendarTitle: "Work", colorRGB: [0.04, 0.52, 1.0]),
            CalendarEvent(id: "demo.lunch", title: "Lunch with Sam", start: at(150), end: at(210),
                          location: "Coffee & Kitchen\n20686 Stevens Creek Blvd, Cupertino, CA 95014",
                          structuredTitle: "Coffee & Kitchen", structuredCoordinate: cafe,
                          calendarTitle: "Home", colorRGB: [0.19, 0.82, 0.35]),
            // Free text only: exercises the geocoding path.
            CalendarEvent(id: "demo.gym", title: "Gym", start: at(300), end: at(360),
                          location: "Cupertino Fitness, 19900 Stevens Creek Blvd",
                          calendarTitle: "Home", colorRGB: [1.0, 0.62, 0.04]),
        ]
    }
}

extension DemoCalendarBackend {
    enum DemoCalendar {
        static let work = ("Work", [0.04, 0.52, 1.0])
        static let home = ("Home", [0.19, 0.82, 0.35])
        static let family = ("Family", [1.0, 0.80, 0.0])
        static let fitness = ("Fitness", [1.0, 0.62, 0.04])
        static let birthdays = ("Birthdays", [0.75, 0.35, 0.95])
        static let travel = ("Travel", [1.0, 0.27, 0.42])
    }

    /// A believable routine from the start of last month to the end of next
    /// month: standups, gym, a weekly plan, lunches, weekend plans, birthdays,
    /// bills, a two-day conference and a three-day trip. Timed events skip today,
    /// which `sampleDay` fills.
    static func sampleMonths(around now: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        let thisMonth = MonthGrid.startOfMonth(for: now, calendar: calendar)
        guard let first = calendar.date(byAdding: .month, value: -1, to: thisMonth),
              let last = calendar.date(byAdding: .month, value: 2, to: thisMonth) else { return [] }
        let today = calendar.startOfDay(for: now)
        var events: [CalendarEvent] = []
        var day = first

        func key(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        func timed(_ title: String, _ cal: (String, [Double]), _ hour: Int, _ minute: Int, minutes: Int,
                   location: String? = nil, placeTitle: String? = nil, geo: GeoPoint? = nil,
                   notes: String? = nil, url: URL? = nil) {
            guard !calendar.isDate(day, inSameDayAs: today),
                  let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return }
            let slug = title.lowercased().filter(\.isLetter)
            events.append(CalendarEvent(id: "demo.\(key(day)).\(slug)", title: title, start: start,
                                        end: start.addingTimeInterval(Double(minutes) * 60),
                                        location: location, structuredTitle: placeTitle, structuredCoordinate: geo,
                                        calendarTitle: cal.0, colorRGB: cal.1, notes: notes, url: url))
        }
        func allDay(_ title: String, _ cal: (String, [Double]), days: Int = 1, location: String? = nil,
                    notes: String? = nil) {
            guard let end = calendar.date(byAdding: .day, value: days, to: day) else { return }
            let slug = title.lowercased().filter(\.isLetter)
            events.append(CalendarEvent(id: "demo.\(key(day)).\(slug)", title: title, start: day, end: end,
                                        isAllDay: true, location: location, calendarTitle: cal.0, colorRGB: cal.1,
                                        notes: notes))
        }

        while day < last {
            let weekday = calendar.component(.weekday, from: day)  // 1 = Sunday
            let date = calendar.component(.day, from: day)
            let week = calendar.component(.weekOfYear, from: day)
            switch weekday {
            case 2...6:
                timed("Team standup", DemoCalendar.work, 9, 30, minutes: 15, location: "Zoom",
                      url: URL(string: "https://zoom.us/j/5550100"))
            default:
                break
            }
            switch weekday {
            case 2:
                timed("Weekly planning", DemoCalendar.work, 13, 0, minutes: 60,
                      location: "Apple Park\n1 Apple Park Way, Cupertino, CA 95014",
                      placeTitle: "Apple Park", geo: applePark,
                      notes: "Bring the roadmap. Review last week's launches and pick next week's priorities.")
            case 3, 5:
                timed("Gym", DemoCalendar.fitness, 7, 0, minutes: 60,
                      location: "Cupertino Fitness, 19900 Stevens Creek Blvd", placeTitle: "Cupertino Fitness", geo: gym)
            case 4:
                timed("1:1 with Alex", DemoCalendar.work, 15, 0, minutes: 30, location: "Microsoft Teams")
                if week % 2 == 0 {
                    timed("Book club", DemoCalendar.home, 19, 0, minutes: 90,
                          location: "Cupertino Library\n10800 Torre Ave, Cupertino, CA 95014",
                          placeTitle: "Cupertino Library", geo: library, notes: "This month: Project Hail Mary.")
                }
            case 6:
                timed("Team lunch", DemoCalendar.work, 12, 30, minutes: 60,
                      location: "Coffee & Kitchen\n20686 Stevens Creek Blvd, Cupertino, CA 95014",
                      placeTitle: "Coffee & Kitchen", geo: cafe)
                timed("Design sync", DemoCalendar.work, 12, 45, minutes: 45, location: "Zoom")
            case 7:
                timed("Farmers market", DemoCalendar.home, 9, 0, minutes: 90,
                      location: "Cupertino Village\n10787 N Wolfe Rd, Cupertino, CA 95014",
                      placeTitle: "Cupertino Village", geo: market)
                if week % 2 == 1 {
                    timed("Soccer practice", DemoCalendar.family, 14, 0, minutes: 90,
                          location: "Memorial Park\n21221 Stevens Creek Blvd, Cupertino, CA 95014",
                          placeTitle: "Memorial Park", geo: park, notes: "Bring oranges for half time.")
                }
            case 1:
                timed("Family dinner", DemoCalendar.family, 18, 0, minutes: 120,
                      notes: "Mum's cooking. Bring dessert.")
            default:
                break
            }
            switch date {
            case 1: allDay("Rent due", DemoCalendar.home)
            case 5: allDay("Design conference", DemoCalendar.work, days: 2,
                           location: "Moscone West, San Francisco",
                           notes: "Badge pickup from 8 AM. Keynote in Hall A.")
            case 8: timed("Dentist", DemoCalendar.home, 10, 0, minutes: 60,
                          location: "Cupertino Dental, 10383 S De Anza Blvd")
            case 12: allDay("Alex's birthday", DemoCalendar.birthdays)
            case 15: timed("Car service", DemoCalendar.home, 8, 0, minutes: 90,
                           location: "Stevens Creek Toyota, 4202 Stevens Creek Blvd, San Jose")
            case 20: allDay("Tahoe trip", DemoCalendar.travel, days: 3, location: "South Lake Tahoe, CA",
                            notes: "Cabin check-in after 4 PM. Chains in the boot just in case.")
            case 27: allDay("Mum's birthday", DemoCalendar.birthdays)
            default: break
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return events.sorted { $0.start < $1.start }
    }
}

/// Offline stand-in for MapKit search: knows the demo places, nothing else.
@MainActor
final class DemoPlaceGeocoder: PlaceGeocoder {
    private(set) var lookups: [String] = []
    var places: [String: GeoPoint] = [
        "cupertino fitness": DemoCalendarBackend.gym,
        "apple park": DemoCalendarBackend.applePark,
        "coffee & kitchen": DemoCalendarBackend.cafe,
        "cupertino dental": GeoPoint(latitude: 37.31600, longitude: -122.03230),
        "stevens creek toyota": GeoPoint(latitude: 37.32300, longitude: -121.97200),
    ]

    func mapItem(for query: String, near: CLLocationCoordinate2D?) async -> MKMapItem? {
        lookups.append(query)
        let lower = query.lowercased()
        guard let match = places.first(where: { lower.contains($0.key) }) else { return nil }
        let item = MKMapItem(location: match.value.location, address: nil)
        item.name = query.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
        return item
    }
}
