import XCTest
import SwiftUI
@testable import DuoDash

@MainActor
final class CalendarViewTests: XCTestCase {
    /// Gregorian in the device's time zone, so model code using it and these dates agree.
    private func gregorian(firstWeekday: Int = 1) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")
        cal.timeZone = .current
        cal.firstWeekday = firstWeekday
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                      cal: Calendar? = nil) -> Date {
        (cal ?? gregorian()).date(from: DateComponents(year: year, month: month, day: day,
                                                       hour: hour, minute: minute))!
    }

    private func event(_ id: String, _ start: Date, minutes: Double, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: start, end: start.addingTimeInterval(minutes * 60), isAllDay: allDay)
    }

    // MARK: Month grid

    func testMonthGridSundayFirst() {
        let cal = gregorian(firstWeekday: 1)
        // 1 November 2026 is a Sunday: no leading padding, 30 days -> 5 weeks.
        let grid = MonthGrid.make(for: date(2026, 11, 17), calendar: cal)
        XCTAssertEqual(grid.month, date(2026, 11, 1))
        XCTAssertEqual(grid.days.count, 35)
        XCTAssertEqual(grid.weeks, 5)
        XCTAssertEqual(grid.days.first, date(2026, 11, 1))
        XCTAssertEqual(grid.days.last, date(2026, 12, 5), "Trailing padding fills the last week")
        XCTAssertFalse(grid.contains(grid.days.last!, calendar: cal))
        XCTAssertEqual(MonthGrid.weekdaySymbols(calendar: cal, short: false).first, "Sun")
    }

    func testMonthGridMondayFirstPadsFromPreviousMonth() {
        let cal = gregorian(firstWeekday: 2)
        let grid = MonthGrid.make(for: date(2026, 11, 17), calendar: cal)
        XCTAssertEqual(grid.days.count, 42, "Six leading padding days push November into a sixth week")
        XCTAssertEqual(grid.days.first, date(2026, 10, 26))
        XCTAssertEqual(cal.component(.weekday, from: grid.days.first!), 2, "Every row starts on Monday")
        XCTAssertEqual(grid.days.filter { grid.contains($0, calendar: cal) }.count, 30)
        XCTAssertEqual(grid.days.last, date(2026, 12, 6))
        XCTAssertEqual(MonthGrid.weekdaySymbols(calendar: cal, short: false),
                       ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        XCTAssertEqual(MonthGrid.weekdaySymbols(calendar: cal, short: true).count, 7)
    }

    func testMonthGridFourWeekFebruary() {
        // 1 February 2026 is a Sunday and it has 28 days: exactly four rows.
        let grid = MonthGrid.make(for: date(2026, 2, 10), calendar: gregorian(firstWeekday: 1))
        XCTAssertEqual(grid.weeks, 4)
        XCTAssertEqual(grid.days.last, date(2026, 2, 28))
        // Consecutive days throughout.
        for (a, b) in zip(grid.days, grid.days.dropFirst()) {
            XCTAssertEqual(gregorian().dateComponents([.day], from: a, to: b).day, 1)
        }
    }

    func testFetchRangeCoversPaddingDays() {
        for first in 1...7 {
            let cal = gregorian(firstWeekday: first)
            let range = MonthGrid.fetchRange(forMonth: date(2026, 11, 9), calendar: cal)
            XCTAssertEqual(range.start, date(2026, 10, 25))
            XCTAssertEqual(range.end, date(2026, 12, 8))
            let grid = MonthGrid.make(for: date(2026, 11, 9), calendar: cal)
            XCTAssertTrue(grid.days.allSatisfy(range.contains), "first weekday \(first)")
        }
    }

    // MARK: Day timeline

    func testTimelineLaysOutOverlapsSideBySide() {
        let cal = gregorian()
        let day = date(2026, 11, 17)
        let at: (Int, Int) -> Date = { self.date(2026, 11, 17, $0, $1) }
        let events = [
            event("A", at(9, 0), minutes: 60),
            event("B", at(9, 30), minutes: 60),
            event("C", at(10, 30), minutes: 30),         // touches B's end: new cluster
            event("G", at(16, 0), minutes: 120),
            event("H", at(16, 15), minutes: 30),
            event("I", at(17, 0), minutes: 30),          // reuses H's column
            event("Short", at(14, 0), minutes: 5),
            event("Next", at(14, 10), minutes: 30),      // within Short's 30-minute block
            event("Overnight", date(2026, 11, 16, 22), minutes: 180),
            event("Holiday", day, minutes: 1440, allDay: true),
            event("Tomorrow", date(2026, 11, 18, 9), minutes: 60),
        ]
        let slots = Dictionary(uniqueKeysWithValues: TimelineSlot.layout(events, on: day, calendar: cal).map { ($0.id, $0) })

        XCTAssertNil(slots["Holiday"], "All-day events go in the all-day row")
        XCTAssertNil(slots["Tomorrow"])
        XCTAssertEqual(slots["A"]?.column, 0)
        XCTAssertEqual(slots["B"]?.column, 1)
        XCTAssertEqual(slots["A"]?.columns, 2)
        XCTAssertEqual(slots["B"]?.columns, 2)
        XCTAssertEqual(slots["C"]?.columns, 1)
        XCTAssertEqual(slots["C"]?.column, 0)
        XCTAssertEqual(slots["G"]?.column, 0)
        XCTAssertEqual(slots["H"]?.column, 1)
        XCTAssertEqual(slots["I"]?.column, 1)
        XCTAssertEqual(slots["I"]?.columns, 2)
        XCTAssertEqual(slots["Short"]?.columns, 2, "Short events still get a readable block")
        XCTAssertEqual(slots["Next"]?.column, 1)
        XCTAssertEqual(slots["Overnight"]?.startMinute, 0, "Clipped to midnight")
        XCTAssertEqual(slots["Overnight"]?.endMinute, 60)
        XCTAssertEqual(slots["A"]?.startMinute, 9 * 60)
        XCTAssertEqual(slots["A"]?.endMinute, 10 * 60)
    }

    // MARK: Upcoming grouping

    func testUpcomingGroupsByDaySkippingEmptyAndEnded() {
        let cal = gregorian()
        let now = date(2026, 11, 17, 12)
        let events = [
            event("ended", date(2026, 11, 17, 9), minutes: 60),
            event("later", date(2026, 11, 17, 15), minutes: 60),
            event("allday", date(2026, 11, 17), minutes: 1440, allDay: true),
            event("trip", date(2026, 11, 20), minutes: 3 * 1440, allDay: true),
            event("far", date(2026, 12, 5, 9), minutes: 60),
        ]
        let groups = CalendarDayGroup.upcoming(events, now: now, days: 14, calendar: cal)
        XCTAssertEqual(groups.map(\.day), [date(2026, 11, 17), date(2026, 11, 20), date(2026, 11, 21), date(2026, 11, 22)])
        XCTAssertEqual(groups[0].events.map(\.id), ["allday", "later"], "All-day first, ended events gone")
        XCTAssertEqual(groups[1].events.map(\.id), ["trip"], "Multi-day events show on each day")
        XCTAssertEqual(groups[3].events.map(\.id), ["trip"])
        XCTAssertFalse(groups.contains { $0.events.contains { $0.id == "far" } }, "Beyond 14 days")
    }

    func testTimeLabelsForMultiDayEvents() {
        let cal = gregorian()
        let start = date(2026, 11, 17, 20)
        let conference = event("c", start, minutes: 48 * 60)    // 17th 8 PM to 19th 8 PM
        XCTAssertEqual(conference.timeLabels(on: date(2026, 11, 17), calendar: cal).bottom, "Continues")
        XCTAssertEqual(conference.timeLabels(on: date(2026, 11, 18), calendar: cal).top, "All day")
        XCTAssertEqual(conference.timeLabels(on: date(2026, 11, 19), calendar: cal).top, "Ends")
        XCTAssertTrue(conference.spansMultipleDays(calendar: cal))
        let oneDay = event("d", date(2026, 11, 17), minutes: 1440, allDay: true)
        XCTAssertFalse(oneDay.spansMultipleDays(calendar: cal), "Ending at the next midnight is still one day")
        XCTAssertEqual(oneDay.timeLabels(on: date(2026, 11, 17), calendar: cal).top, "All day")
    }

    // MARK: Model: range fetching and caching

    func testMonthsAreFetchedOnceAndCached() {
        let now = date(2026, 11, 17, 9, 2)
        let backend = DemoCalendarBackend(now: now, includesMonth: true)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        model.calendarSystem = gregorian()
        model.now = { now }
        let baseline = backend.fetchCount

        model.loadMonth(containing: date(2026, 11, 3))
        XCTAssertEqual(backend.fetchCount, baseline + 1)
        model.loadMonth(containing: date(2026, 11, 28))
        XCTAssertEqual(backend.fetchCount, baseline + 1, "Same month comes from the cache")

        // Mondays have Weekly planning; the 5th starts the two-day conference.
        let monday = model.events(on: date(2026, 11, 16))
        XCTAssertTrue(monday.contains { $0.title == "Weekly planning" })
        XCTAssertTrue(model.events(on: date(2026, 11, 6)).contains { $0.title == "Design conference" })
        XCTAssertEqual(model.events(on: date(2026, 11, 6)).first?.isAllDay, true, "All-day events first")

        // Padding days come from the neighbouring month's cache.
        XCTAssertTrue(model.events(on: date(2026, 12, 4)).contains { $0.title == "Team standup" })
        XCTAssertTrue(model.events(on: date(2027, 1, 4)).isEmpty, "Not loaded yet")

        model.load(from: date(2026, 11, 17), to: date(2026, 12, 1))
        XCTAssertEqual(backend.fetchCount, baseline + 1, "Fully inside November")
        model.load(from: date(2026, 11, 17), to: date(2026, 12, 2))
        XCTAssertEqual(backend.fetchCount, baseline + 2, "Spills into December")
        XCTAssertEqual(model.monthEvents.count, 2)
    }

    func testOldMonthsAreEvicted() {
        let now = date(2026, 11, 17, 9)
        let backend = DemoCalendarBackend(now: now, includesMonth: true)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        model.calendarSystem = gregorian()
        model.maxCachedMonths = 2
        model.loadMonth(containing: date(2026, 10, 1))
        model.loadMonth(containing: date(2026, 11, 1))
        model.loadMonth(containing: date(2026, 10, 1))   // touch October again
        model.loadMonth(containing: date(2026, 12, 1))
        XCTAssertEqual(Set(model.monthEvents.keys), [date(2026, 10, 1), date(2026, 12, 1)],
                       "The least recently used month goes")
    }

    func testStoreChangeReloadsCachedMonths() {
        let now = date(2026, 11, 17, 9)
        let backend = DemoCalendarBackend(now: now, includesMonth: true)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        model.calendarSystem = gregorian()
        model.now = { now }
        model.loadMonth(containing: now)
        let revision = model.revision
        let target = date(2026, 11, 25)
        XCTAssertFalse(model.events(on: target).contains { $0.id == "new" })

        backend.demoEvents.append(event("new", date(2026, 11, 25, 11), minutes: 30))
        XCTAssertFalse(model.events(on: target).contains { $0.id == "new" }, "Cached until told otherwise")
        backend.onChange?()   // what EKEventStoreChanged triggers
        XCTAssertTrue(model.events(on: target).contains { $0.id == "new" })
        XCTAssertGreaterThan(model.revision, revision)
    }

    func testNoAccessMeansNoMonthEventsUntilGranted() async {
        let now = date(2026, 11, 17, 9)
        let backend = DemoCalendarBackend(now: now, access: .notDetermined, includesMonth: true)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        model.calendarSystem = gregorian()
        model.now = { now }
        model.loadMonth(containing: now)
        XCTAssertTrue(model.events(on: date(2026, 11, 16)).isEmpty)
        await model.requestAccess()
        XCTAssertFalse(model.events(on: date(2026, 11, 16)).isEmpty, "Granting reloads the cached months")
    }

    func testModelUpcomingDays() {
        let now = date(2026, 11, 17, 9, 2)
        let backend = DemoCalendarBackend(now: now, includesMonth: true)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        model.calendarSystem = gregorian()
        model.now = { now }
        model.refresh()
        let today = date(2026, 11, 17)
        model.load(from: today, to: date(2026, 12, 1))
        let groups = model.upcomingDays(14)
        XCTAssertEqual(groups.first?.day, today)
        XCTAssertTrue(groups.first?.events.contains { $0.title == "Design review" } ?? false)
        XCTAssertLessThanOrEqual(groups.count, 14)
        XCTAssertTrue(groups.allSatisfy { !$0.events.isEmpty })
        XCTAssertTrue(groups.contains { $0.events.contains { $0.title == "Tahoe trip" } })
        // Existing API still behaves.
        XCTAssertEqual(model.nextEvent?.title, "Design review")
    }

    // MARK: Demo data and detail card

    func testDemoMonthLooksReal() {
        let now = date(2026, 11, 17, 9)
        let events = DemoCalendarBackend.sampleMonths(around: now)
        XCTAssertGreaterThan(events.count, 100)
        XCTAssertGreaterThanOrEqual(Set(events.map(\.calendarTitle)).count, 5)
        XCTAssertTrue(events.contains { $0.isAllDay && $0.spansMultipleDays() })
        XCTAssertTrue(events.contains { $0.place.isNavigable })
        XCTAssertTrue(events.contains { $0.notes != nil })
        XCTAssertTrue(events.contains { $0.url != nil })
        XCTAssertFalse(events.contains { !$0.isAllDay && Calendar.current.isDate($0.start, inSameDayAs: now) },
                       "Today's timed events are the curated demo day")
        XCTAssertEqual(Set(events.map(\.id)).count, events.count, "Unique ids")
    }

    func testDetailCardText() {
        let cal = gregorian()
        let timed = event("t", date(2026, 11, 17, 10), minutes: 60)
        let text = EventDetailCard.timeDescription(timed, calendar: cal)
        XCTAssertTrue(text.0.contains("17"))
        XCTAssertTrue(text.1?.contains("–") ?? false)
        let trip = event("trip", date(2026, 11, 20), minutes: 3 * 1440, allDay: true)
        XCTAssertEqual(EventDetailCard.timeDescription(trip, calendar: cal).1, "All day")
        XCTAssertTrue(EventDetailCard.timeDescription(trip, calendar: cal).0.contains("22"), "Shows the last day")
        let url = EventDetailCard.calendarURL(for: timed)
        XCTAssertEqual(url?.scheme, "calshow")
        XCTAssertEqual(url?.absoluteString, "calshow:\(Int(timed.start.timeIntervalSinceReferenceDate))")
    }

    /// Renders the detail card and a month grid with another day selected, at the
    /// inner-screen and cover-screen widths. PNGs land in the temp directory for a look.
    func testDetailCardAndGridRender() throws {
        let now = Date.now
        let backend = DemoCalendarBackend(now: now, includesMonth: true)
        let model = CalendarModel(backend: backend, geocoder: DemoPlaceGeocoder())
        model.loadMonth(containing: now)
        let event = try XCTUnwrap(backend.demoEvents.first { $0.title == "Weekly planning" })
        let selected = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now))!
        let sizes = [CGSize(width: 840, height: 520), CGSize(width: 450, height: 480)]
        for size in sizes {
            let views: [(String, AnyView)] = [
                ("detail", AnyView(EventDetailCard(event: event, onClose: {}, onNavigate: { _ in }))),
                ("grid", AnyView(MonthGridView(grid: MonthGrid.make(for: now), selectedDay: selected,
                                               rowHeight: nil, onTap: { _ in }))),
            ]
            for (name, view) in views {
                let renderer = ImageRenderer(content: view
                    .frame(width: size.width, height: size.height)
                    .background(Color.black)
                    .environment(model)
                    .environment(\.colorScheme, .dark))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage, name)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("calendar-\(name)-\(Int(size.width)).png")
                try image.pngData()?.write(to: url)
                print("Rendered \(url.path)")
            }
        }
    }

    func testViewModePersistsByRawValue() {
        XCTAssertEqual(CalendarViewMode.storageKey, "calendar.view")
        XCTAssertEqual(CalendarViewMode(rawValue: "upcoming"), .upcoming)
        XCTAssertEqual(CalendarViewMode.allCases.map(\.title), ["Day", "Month", "Upcoming"])
    }
}
