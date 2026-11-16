import SwiftUI
import MapKit

/// Dashboard card: the next calendar event with a one-tap "Go", plus current weather.
/// Picks its layout from the space it gets (about 220×120 up to 420×300 pt).
struct NextUpCard: View {
    @Environment(CalendarModel.self) private var calendar
    @Environment(\.scenePhase) private var scenePhase
    /// Starts a route to the event's place.
    let onNavigate: (MKMapItem) -> Void
    /// Opens the full Calendar screen when the event text is tapped. Optional.
    var onOpenCalendar: (() -> Void)? = nil

    var body: some View {
        Card(padding: 14) {
            ViewThatFits(in: .vertical) {
                large
                medium
                compactRow(showsWeather: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nextup.card")
        .weatherFollowsLocation()
        .task { calendar.startAutoRefresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { calendar.refresh() }
        }
    }

    // MARK: Layouts

    /// Header with weather, big title, time, place, Go and the weather credit.
    private var large: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let event = calendar.nextEvent {
                opensCalendar {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.dashTitle).lineLimit(2).minimumScaleFactor(0.8)
                        EventTimeText(event: event).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                        placeLine(event)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 4)
                if let later = calendar.laterEvents.first {
                    HStack(spacing: 6) {
                        Text("Then").foregroundStyle(Theme.textSecondary)
                        Text(later.start, format: .dateTime.hour().minute()).monospacedDigit()
                        Text(later.title)
                    }
                    .font(.dashCaption)
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    EventGoButton(event: event, style: .pill, onNavigate: onNavigate)
                    Spacer(minLength: 0)
                    WeatherAttribution()
                }
            } else {
                Spacer(minLength: 0)
                emptyOrPermission(roomy: true)
                Spacer(minLength: 0)
                HStack { Spacer(); WeatherAttribution() }
            }
        }
    }

    /// Weather row on top, then the compact event row.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            compactRow(showsWeather: false)
            HStack { Spacer(minLength: 0); WeatherAttribution() }
        }
    }

    /// One row: time / title / place, and a round Go button.
    @ViewBuilder
    private func compactRow(showsWeather: Bool) -> some View {
        if let event = calendar.nextEvent {
            HStack(spacing: 10) {
                opensCalendar {
                    VStack(alignment: .leading, spacing: 1) {
                        ViewThatFits(in: .horizontal) {
                            if showsWeather {
                                HStack(spacing: 6) {
                                    timeLine(event)
                                    Spacer(minLength: 0)
                                    WeatherChip(showsText: false)
                                }
                            }
                            timeLine(event)
                        }
                        Text(event.title).font(.dashBody).lineLimit(1).minimumScaleFactor(0.75)
                        placeLine(event)
                    }
                    .frame(maxWidth: .infinity, minHeight: Theme.minTouch, alignment: .leading)
                }
                EventGoButton(event: event, style: .round, onNavigate: onNavigate)
            }
        } else {
            emptyOrPermission(roomy: false)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Next up", systemImage: "calendar")
                .font(.dashCaption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            WeatherChip()
        }
    }

    /// The event's text opens the Calendar screen when there is one (a big target).
    @ViewBuilder
    private func opensCalendar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let onOpenCalendar {
            Button(action: onOpenCalendar) {
                content().contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("nextup.open")
        } else {
            content()
        }
    }

    private func timeLine(_ event: CalendarEvent) -> some View {
        EventTimeText(event: event, short: true)
            .font(.dashCaption)
            .foregroundStyle(Theme.accent)
    }

    @ViewBuilder
    private func placeLine(_ event: CalendarEvent) -> some View {
        if calendar.unresolvable.contains(event.id) {
            Label("Location not found", systemImage: "mappin.slash")
                .font(.dashCaption).foregroundStyle(Theme.warning).lineLimit(1)
        } else if let place = event.placeName {
            Text(place).font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    // MARK: Empty / permission

    @ViewBuilder
    private func emptyOrPermission(roomy: Bool) -> some View {
        let access = calendar.access
        if !access.isGranted {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(access.title).font(.dashBody).lineLimit(roomy ? 2 : 1).minimumScaleFactor(0.75)
                    if roomy {
                        Text(access.message).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                            .lineLimit(3).minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
                if let action = access.actionTitle {
                    if roomy {
                        DashPillButton(title: action, identifier: "nextup.permission") { fix(access) }
                    } else {
                        DashIconButton(symbol: access.canRequest ? "calendar.badge.checkmark" : "gearshape.fill",
                                       prominent: true, label: action, identifier: "nextup.permission") {
                            fix(access)
                        }
                    }
                }
            }
            .accessibilityIdentifier("nextup.access")
        } else {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.positive)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nothing else today").font(.dashBody).lineLimit(1).minimumScaleFactor(0.75)
                    if !roomy { WeatherChip() }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Theme.minTouch)
            .accessibilityIdentifier("nextup.empty")
        }
    }

    private func fix(_ access: CalendarAccess) {
        if access.canRequest {
            Task { await calendar.requestAccess() }
        } else {
            calendar.openSettings()
        }
    }
}

/// "10:40 AM · in 40 min", "Now · until 11:40 AM", "All day". Ticks every minute.
struct EventTimeText: View {
    let event: CalendarEvent
    /// Where there's little room: an event in progress just says "Now".
    var short = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.describe(event, now: context.date, short: short))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .monospacedDigit()
        }
    }

    static func describe(_ event: CalendarEvent, now: Date, short: Bool = false) -> String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        if event.isInProgress(at: now) {
            return short ? "Now" : "Now · until \(event.end.formatted(date: .omitted, time: .shortened))"
        }
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "\(start) · now" }
        if minutes < 60 { return "\(start) · in \(minutes) min" }
        if minutes < 12 * 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(start) · in \(h) h" : "\(start) · in \(h) h \(m) min"
        }
        return Calendar.current.isDate(event.start, inSameDayAs: now) ? start : "Tomorrow \(start)"
    }
}

/// "Go" for an event: resolves its place (geocoding if needed) and hands the
/// map item on. Disabled when the event has no drivable place.
struct EventGoButton: View {
    enum Style { case pill, round }

    @Environment(CalendarModel.self) private var calendar
    let event: CalendarEvent
    var style: Style = .round
    let onNavigate: (MKMapItem) -> Void

    var body: some View {
        let navigable = event.place.isNavigable && !calendar.unresolvable.contains(event.id)
        Group {
            if calendar.resolving.contains(event.id) {
                ProgressView()
                    .controlSize(.regular)
                    .frame(width: Theme.minTouch, height: Theme.minTouch)
            } else {
                switch style {
                case .pill:
                    DashPillButton(title: "Go", symbol: "car.fill", identifier: "event.go.\(event.id)", action: go)
                case .round:
                    DashIconButton(symbol: "car.fill", prominent: true, label: "Go to \(event.title)",
                                   identifier: "event.go.\(event.id)", action: go)
                }
            }
        }
        .disabled(!navigable)
        .opacity(navigable ? 1 : 0.35)
    }

    private func go() {
        Task {
            if let item = await calendar.destination(for: event) { onNavigate(item) }
        }
    }
}
