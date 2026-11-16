import SwiftUI
import MapKit

/// Full-screen Calendar, modelled on Apple's Calendar app for a car screen:
/// Day (hour timeline), Month (grid plus the selected day's events) and Upcoming
/// (the next 14 days as a list). Glass controls float over black content.
struct CalendarScreen: View {
    @Environment(CalendarModel.self) private var calendar
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CalendarViewMode.storageKey) private var mode: CalendarViewMode = .month
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var detail: CalendarEvent?
    /// Which way the last day/month change went, for the slide.
    @State private var forward = true
    /// Starts a route to an event's place.
    let onNavigate: (MKMapItem) -> Void

    private var cal: Calendar { calendar.calendarSystem }

    var body: some View {
        VStack(spacing: Theme.gap) {
            CalendarToolbar(mode: $mode, title: title,
                            showsStepper: calendar.access.isGranted && mode != .upcoming,
                            isShowingToday: isShowingToday,
                            onPrevious: { step(-1) }, onNext: { step(1) }, onToday: goToToday)
            if calendar.access.isGranted {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                permission
            }
        }
        .background(DashBackground())
        .overlay {
            if let detail {
                EventDetailCard(event: detail,
                                onClose: { withAnimation(.snappy) { self.detail = nil } },
                                onNavigate: { item in self.detail = nil; onNavigate(item) })
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .accessibilityIdentifier("calendar.screen")
        .task { calendar.refresh(); calendar.startAutoRefresh() }
        .task(id: monthKey) { calendar.loadMonth(containing: selectedDay) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { calendar.refresh() }
        }
    }

    private var monthKey: Date { MonthGrid.startOfMonth(for: selectedDay, calendar: cal) }

    @ViewBuilder
    private var content: some View {
        let select: (CalendarEvent) -> Void = { event in withAnimation(.snappy) { detail = event } }
        ZStack {
            switch mode {
            case .month:
                CalendarMonthLayout(month: monthKey, selectedDay: $selectedDay,
                                    onOpenDay: { day in
                                        selectedDay = day
                                        withAnimation(.snappy) { mode = .day }
                                    },
                                    onSelect: select, onNavigate: onNavigate, onSwipe: step)
            case .day:
                CalendarDayView(day: selectedDay, onSelect: select, onNavigate: onNavigate, onSwipe: step)
                    .id(selectedDay)
                    .transition(.push(from: forward ? .trailing : .leading))
            case .upcoming:
                CalendarUpcomingView(onSelect: select, onNavigate: onNavigate)
            }
        }
        .clipped()
    }

    private var title: String {
        switch mode {
        case .month:
            selectedDay.formatted(.dateTime.month(.wide).year())
        case .day:
            selectedDay.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        case .upcoming:
            "Next 14 days"
        }
    }

    private var isShowingToday: Bool {
        switch mode {
        case .month, .day: cal.isDateInToday(selectedDay)
        case .upcoming: true
        }
    }

    /// Back or forward one month (Month) or one day (Day).
    private func step(_ direction: Int) {
        forward = direction > 0
        withAnimation(.snappy) {
            if mode == .day {
                selectedDay = cal.date(byAdding: .day, value: direction, to: selectedDay) ?? selectedDay
            } else {
                let month = cal.date(byAdding: .month, value: direction, to: monthKey) ?? monthKey
                // Like iOS: today if it's in that month, else the 1st.
                selectedDay = cal.isDate(month, equalTo: .now, toGranularity: .month)
                    ? cal.startOfDay(for: .now) : month
            }
        }
    }

    private func goToToday() {
        let today = cal.startOfDay(for: .now)
        forward = today >= selectedDay
        withAnimation(.snappy) { selectedDay = today }
    }

    struct DaySection {
        let title: String
        let events: [CalendarEvent]
    }

    /// Today (events not yet ended) and Tomorrow; all-day events first in each.
    static func sections(_ events: [CalendarEvent], now: Date) -> [DaySection] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
        let dayAfter = cal.date(byAdding: .day, value: 2, to: today) ?? tomorrow
        let todays = events.filter { $0.start < tomorrow && $0.end > now }
        let tomorrows = events.filter { $0.start >= tomorrow && $0.start < dayAfter }
        return [DaySection(title: "Today", events: CalendarDayGroup.ordered(todays)),
                DaySection(title: "Tomorrow", events: CalendarDayGroup.ordered(tomorrows))]
    }

    // MARK: Permission

    private var permission: some View {
        let access = calendar.access
        return EmptyStateView(symbol: "calendar.badge.exclamationmark", title: access.title,
                              message: access.message, actionTitle: access.actionTitle) {
            if access.canRequest {
                Task { await calendar.requestAccess() }
            } else {
                calendar.openSettings()
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("calendar.permission")
    }
}

/// One event: time column on the left, colour bar, title and place, and "Go".
/// Tapping the text opens the event's details when `onSelect` is set.
struct CalendarEventRow: View {
    @Environment(CalendarModel.self) private var calendar
    let event: CalendarEvent
    var isNext = false
    let onNavigate: (MKMapItem) -> Void
    /// The day the row is listed under, so multi-day events read "Ends 10 AM" and the like.
    var day: Date? = nil
    var onSelect: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let onSelect {
                Button(action: onSelect) { info.contentShape(Rectangle()) }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("calendar.open.\(event.id)")
            } else {
                info
            }
            if event.place.isNavigable {
                EventGoButton(event: event, style: .round, onNavigate: onNavigate)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: Theme.minTouch + 20)
        .background(isNext ? Theme.surfaceRaised : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.row.\(event.id)")
    }

    private var info: some View {
        let labels = event.timeLabels(on: day ?? event.start, calendar: calendar.calendarSystem)
        return HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(labels.top).font(.dashBody)
                if let bottom = labels.bottom {
                    Text(bottom).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 92, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(event.color)
                .frame(width: 4)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.dashBody).lineLimit(2)
                if calendar.unresolvable.contains(event.id) {
                    Label("Location not found", systemImage: "mappin.slash")
                        .font(.dashCaption).foregroundStyle(Theme.warning).lineLimit(1)
                } else if let place = event.placeName {
                    Text(place).font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                if isNext, !event.isAllDay {
                    EventTimeText(event: event).font(.dashCaption).foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Theme.minTouch)
    }
}
