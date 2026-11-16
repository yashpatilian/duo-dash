import UIKit
import MapKit
import Observation

/// Today's events for the dashboard, any month's events for the Calendar screen
/// (fetched a month at a time and cached), and a map item for each event so
/// "Go" can start a route.
@MainActor
@Observable
final class CalendarModel {
    private(set) var access: CalendarAccess
    /// Events in the next ~24 hours that haven't ended. All-day events only when
    /// there is nothing else.
    private(set) var upcoming: [CalendarEvent] = []
    /// Everything today and tomorrow (all-day included), for the Calendar screen.
    private(set) var todayAndTomorrow: [CalendarEvent] = []
    /// Events being looked up on the map right now (by id), for spinners.
    private(set) var resolving: Set<String> = []
    /// Events whose location couldn't be found on the map.
    private(set) var unresolvable: Set<String> = []
    private(set) var lastRefresh: Date?
    /// Events for each loaded month (keyed by midnight on the 1st), covering the
    /// month plus a week either side so a month grid's padding days have dots too.
    private(set) var monthEvents: [Date: [CalendarEvent]] = [:]
    /// Bumped whenever cached months are re-read, so views can follow changes.
    private(set) var revision = 0

    let isDemo: Bool

    @ObservationIgnored private let backend: CalendarBackend
    @ObservationIgnored private let geocoder: PlaceGeocoder
    /// Looked-up free-text locations, including misses, so nothing is geocoded twice.
    @ObservationIgnored private var geocodeCache: [String: MKMapItem?] = [:]
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Injectable clock for tests.
    @ObservationIgnored var now: () -> Date = { .now }
    /// Where the user is, to bias place searches. Set by whoever owns location.
    @ObservationIgnored var searchCenter: CLLocationCoordinate2D?
    /// The calendar (first weekday, time zone) months and days are worked out in.
    @ObservationIgnored var calendarSystem: Calendar = .autoupdatingCurrent
    /// Loaded months, least recently used first.
    @ObservationIgnored private var monthUse: [Date] = []
    /// How many months stay cached.
    @ObservationIgnored var maxCachedMonths = 6
    @ObservationIgnored private var lastAccess: CalendarAccess?

    /// The Simulator's calendar is empty; `-DemoCalendar` forces the demo on a device.
    static var usesDemo: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("-DemoCalendar")
        #endif
    }

    init(backend: CalendarBackend? = nil, geocoder: PlaceGeocoder? = nil) {
        let arguments = ProcessInfo.processInfo.arguments
        let backend = backend ?? (Self.usesDemo
            ? DemoCalendarBackend(access: arguments.contains("-DemoCalendarDenied") ? .denied : .granted,
                                  includesMonth: true)
            : EventKitCalendarBackend())
        self.backend = backend
        self.geocoder = geocoder ?? (backend.isDemo ? DemoPlaceGeocoder() : MapKitPlaceGeocoder())
        isDemo = backend.isDemo
        access = backend.access()
        backend.onChange = { [weak self] in self?.calendarDidChange() }
        refresh()
    }

    /// The event "Next up" shows: one in progress that started in the last 15
    /// minutes (you may be running late), else the next to start, else whatever
    /// `upcoming` has first (an all-day event).
    var nextEvent: CalendarEvent? {
        let current = now()
        let timed = upcoming.filter { !$0.isAllDay }
        if let justStarted = timed.first(where: {
            $0.isInProgress(at: current) && current.timeIntervalSince($0.start) <= 15 * 60
        }) {
            return justStarted
        }
        return timed.first(where: { $0.start > current }) ?? upcoming.first
    }

    /// Events after `nextEvent` in the upcoming list.
    var laterEvents: [CalendarEvent] {
        guard let next = nextEvent else { return upcoming }
        return upcoming.filter { $0.id != next.id && $0.start >= next.start && !$0.isAllDay }
    }

    // MARK: Permission

    func requestAccess() async {
        access = await backend.requestAccess()
        refresh()
    }

    /// For the Denied / Add Events Only states.
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Loading

    /// Re-reads events. Cheap (EventKit is local), so call it freely.
    func refresh() {
        access = backend.access()
        if access != lastAccess {
            lastAccess = access
            reloadCachedMonths()
        }
        let current = now()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: current)
        let windowEnd = max(current.addingTimeInterval(24 * 3600),
                            calendar.date(byAdding: .day, value: 2, to: dayStart) ?? current)
        let all = access.isGranted ? backend.events(from: dayStart, to: windowEnd) : []
        let tomorrowEnd = calendar.date(byAdding: .day, value: 2, to: dayStart) ?? windowEnd
        todayAndTomorrow = all.filter { $0.start < tomorrowEnd && $0.end > dayStart }
        upcoming = Self.upcoming(from: all, now: current)
        lastRefresh = current
    }

    /// The calendar database changed (EKEventStoreChanged): re-read everything.
    func calendarDidChange() {
        reloadCachedMonths()
        refresh()
    }

    // MARK: Any date range (Calendar screen)

    /// Makes sure the month containing `date` is loaded (from cache if it is).
    func loadMonth(containing date: Date) {
        let key = MonthGrid.startOfMonth(for: date, calendar: calendarSystem)
        if monthEvents[key] == nil {
            monthEvents[key] = fetchMonth(key)
        }
        touch(key)
    }

    /// Loads every month `start..<end` touches.
    func load(from start: Date, to end: Date) {
        var month = MonthGrid.startOfMonth(for: start, calendar: calendarSystem)
        var keys: [Date] = []
        while month < end {
            keys.append(month)
            guard let next = calendarSystem.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        keys.forEach(loadMonth(containing:))
    }

    /// Cached events overlapping `day`, all-day first. Call `loadMonth` first.
    func events(on day: Date) -> [CalendarEvent] {
        CalendarDayGroup.events(cachedEvents(near: day), on: day, calendar: calendarSystem)
    }

    /// Cached events overlapping `start..<end`, sorted by start, each once.
    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        var seen = Set<String>()
        return monthEvents.values.joined()
            .filter { $0.end > start && $0.start < end && seen.insert($0.id).inserted }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// The next `days` days with events, grouped by day, from now. Loads what it needs first.
    func upcomingDays(_ days: Int = 14) -> [CalendarDayGroup] {
        let current = now()
        let today = calendarSystem.startOfDay(for: current)
        let end = calendarSystem.date(byAdding: .day, value: days, to: today) ?? today
        return CalendarDayGroup.upcoming(events(from: today, to: end), now: current, days: days,
                                         calendar: calendarSystem)
    }

    /// The month whose cache covers `day`: its own month, else a neighbour's padding.
    private func cachedEvents(near day: Date) -> [CalendarEvent] {
        let key = MonthGrid.startOfMonth(for: day, calendar: calendarSystem)
        if let events = monthEvents[key] { return events }
        for offset in [-1, 1] {
            if let neighbour = calendarSystem.date(byAdding: .month, value: offset, to: key),
               let events = monthEvents[neighbour],
               MonthGrid.fetchRange(forMonth: neighbour, calendar: calendarSystem).contains(day) {
                return events
            }
        }
        return []
    }

    private func fetchMonth(_ month: Date) -> [CalendarEvent] {
        guard backend.access().isGranted else { return [] }
        let range = MonthGrid.fetchRange(forMonth: month, calendar: calendarSystem)
        return backend.events(from: range.start, to: range.end)
    }

    private func touch(_ key: Date) {
        monthUse.removeAll { $0 == key }
        monthUse.append(key)
        while monthUse.count > maxCachedMonths {
            monthEvents[monthUse.removeFirst()] = nil
        }
    }

    private func reloadCachedMonths() {
        for key in monthEvents.keys {
            monthEvents[key] = fetchMonth(key)
        }
        revision += 1
    }

    /// Keeps `nextEvent` moving along while the dashboard is up. Safe to call repeatedly.
    func startAutoRefresh(every interval: Duration = .seconds(60)) {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Events that haven't ended and start within `window`; all-day ones only if
    /// there are no timed ones.
    static func upcoming(from events: [CalendarEvent], now: Date,
                         window: TimeInterval = 24 * 3600) -> [CalendarEvent] {
        let limit = now.addingTimeInterval(window)
        let live = events
            .filter { $0.end > now && $0.start < limit }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        let timed = live.filter { !$0.isAllDay }
        return timed.isEmpty ? live : timed
    }

    // MARK: Destinations

    /// A map item for the event's place: its Maps-picked coordinate if it has one,
    /// else the typed location looked up on the map (cached, misses too).
    func destination(for event: CalendarEvent) async -> MKMapItem? {
        switch event.place {
        case .none:
            return nil
        case .coordinate(let point, let name):
            let item = MKMapItem(location: point.location, address: nil)
            item.name = name
            return item
        case .address(let text):
            let key = text.lowercased()
            if let cached = geocodeCache[key] {
                if cached == nil { unresolvable.insert(event.id) }
                return cached.map { Self.named($0, event: event) }
            }
            resolving.insert(event.id)
            let found = await geocoder.mapItem(for: text.replacingOccurrences(of: "\n", with: ", "),
                                               near: searchCenter)
            resolving.remove(event.id)
            geocodeCache[key] = .some(found)
            if found == nil { unresolvable.insert(event.id) } else { unresolvable.remove(event.id) }
            return found.map { Self.named($0, event: event) }
        }
    }

    private static func named(_ item: MKMapItem, event: CalendarEvent) -> MKMapItem {
        if item.name?.isEmpty ?? true { item.name = event.placeName ?? event.title }
        return item
    }
}
