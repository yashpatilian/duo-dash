import Foundation

/// Which Calendar view is showing. Persisted, so the screen comes back the way it was left.
enum CalendarViewMode: String, CaseIterable, Identifiable {
    case day, month, upcoming

    static let storageKey = "calendar.view"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .month: "Month"
        case .upcoming: "Upcoming"
        }
    }

    var symbol: String {
        switch self {
        case .day: "calendar.day.timeline.left"
        case .month: "calendar"
        case .upcoming: "list.bullet"
        }
    }
}

/// The days an iOS-style month grid shows: whole weeks starting on the user's
/// first weekday, with the previous and next month's days filling the first and last rows.
struct MonthGrid: Equatable {
    /// Midnight on the 1st of the month.
    let month: Date
    /// Every cell, row by row (a multiple of 7).
    let days: [Date]

    var weeks: Int { days.count / 7 }

    static func make(for date: Date, calendar: Calendar = .current) -> MonthGrid {
        let month = startOfMonth(for: date, calendar: calendar)
        let dayCount = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let weekday = calendar.component(.weekday, from: month)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let cells = Int((Double(leading + dayCount) / 7).rounded(.up)) * 7
        let first = calendar.date(byAdding: .day, value: -leading, to: month) ?? month
        let days = (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
        return MonthGrid(month: month, days: days)
    }

    func contains(_ day: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(day, equalTo: month, toGranularity: .month)
    }

    /// The fetch window for this month: a week either side covers the padding days.
    static func fetchRange(forMonth date: Date, calendar: Calendar = .current) -> DateInterval {
        let month = startOfMonth(for: date, calendar: calendar)
        let next = calendar.date(byAdding: .month, value: 1, to: month) ?? month.addingTimeInterval(31 * 86_400)
        let start = calendar.date(byAdding: .day, value: -7, to: month) ?? month
        let end = calendar.date(byAdding: .day, value: 7, to: next) ?? next
        return DateInterval(start: start, end: end)
    }

    static func startOfMonth(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Weekday column titles in grid order ("M", "T", … or "Mon", "Tue", …).
    static func weekdaySymbols(calendar: Calendar = .current, short: Bool) -> [String] {
        let symbols = short ? calendar.veryShortStandaloneWeekdaySymbols : calendar.shortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }
}

/// Where a timed event sits in the Day view: minutes from midnight, and which of
/// `columns` side-by-side columns it takes (overlapping events share the width).
struct TimelineSlot: Identifiable, Equatable {
    let event: CalendarEvent
    let startMinute: Double
    let endMinute: Double
    var column: Int
    var columns: Int

    var id: String { event.id }

    /// Lays out `day`'s timed events. Overlapping events (transitively) form a
    /// cluster whose events split the width; each takes the first free column.
    /// Very short events count as `minimumMinutes` long so their blocks don't collide.
    static func layout(_ events: [CalendarEvent], on day: Date, calendar: Calendar = .current,
                       minimumMinutes: Double = 30) -> [TimelineSlot] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let dayLength = dayEnd.timeIntervalSince(dayStart) / 60
        let timed = events
            .filter { !$0.isAllDay && $0.end > dayStart && $0.start < dayEnd }
            .map { event -> TimelineSlot in
                let start = max(0, event.start.timeIntervalSince(dayStart) / 60)
                let end = min(dayLength, max(start, event.end.timeIntervalSince(dayStart) / 60))
                return TimelineSlot(event: event, startMinute: start, endMinute: end, column: 0, columns: 1)
            }
            .sorted { ($0.startMinute, -$0.endMinute, $0.event.title) < ($1.startMinute, -$1.endMinute, $1.event.title) }

        var result: [TimelineSlot] = []
        var cluster: [TimelineSlot] = []
        var columnEnds: [Double] = []
        var clusterEnd = -Double.infinity

        func closeCluster() {
            let count = max(1, columnEnds.count)
            result += cluster.map { var slot = $0; slot.columns = count; return slot }
            cluster = []
            columnEnds = []
            clusterEnd = -.infinity
        }

        for var slot in timed {
            let visualEnd = max(slot.endMinute, slot.startMinute + minimumMinutes)
            if slot.startMinute >= clusterEnd { closeCluster() }
            if let free = columnEnds.firstIndex(where: { $0 <= slot.startMinute }) {
                slot.column = free
                columnEnds[free] = visualEnd
            } else {
                slot.column = columnEnds.count
                columnEnds.append(visualEnd)
            }
            cluster.append(slot)
            clusterEnd = max(clusterEnd, visualEnd)
        }
        closeCluster()
        return result
    }
}

/// One day of events, for the Upcoming list and the selected day's list.
struct CalendarDayGroup: Identifiable, Equatable {
    let day: Date
    let events: [CalendarEvent]
    var id: Date { day }

    /// All-day first, then by start time.
    static func ordered(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
    }

    /// Events overlapping `day` (midnight to midnight), all-day first.
    static func events(_ events: [CalendarEvent], on day: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return ordered(events.filter { $0.end > start && $0.start < end })
    }

    /// iOS's list view: the next `days` days that have something on, grouped by
    /// day. Multi-day events show on every day they cover; events that have
    /// already ended are left out.
    static func upcoming(_ events: [CalendarEvent], now: Date, days: Int = 14,
                         calendar: Calendar = .current) -> [CalendarDayGroup] {
        let live = events.filter { $0.end > now }
        let today = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let list = Self.events(live, on: day, calendar: calendar)
            return list.isEmpty ? nil : CalendarDayGroup(day: day, events: list)
        }
    }
}

extension CalendarEvent {
    /// Starts and ends on different days (an all-day event ending at the next midnight doesn't count).
    func spansMultipleDays(calendar: Calendar = .current) -> Bool {
        let lastMoment = end > start ? end.addingTimeInterval(-1) : end
        return !calendar.isDate(start, inSameDayAs: lastMoment)
    }

    /// How the event's time reads on a given day: "All day", or start and end
    /// times, with "Ends"/"Starts" for the first and last day of a multi-day event.
    func timeLabels(on day: Date, calendar: Calendar = .current) -> (top: String, bottom: String?) {
        if isAllDay { return ("All day", nil) }
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let startsToday = start >= dayStart
        let endsToday = end <= dayEnd
        let time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        switch (startsToday, endsToday) {
        case (true, true): return (time(start), time(end))
        case (true, false): return (time(start), "Continues")
        case (false, true): return ("Ends", time(end))
        case (false, false): return ("All day", nil)
        }
    }
}
