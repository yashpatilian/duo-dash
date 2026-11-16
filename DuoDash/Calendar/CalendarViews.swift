import SwiftUI
import MapKit

// MARK: - Toolbar

/// Day / Month / Upcoming switch on the left, the date in the middle, and
/// back / Today / forward on the right. Drops to two rows on narrow windows.
struct CalendarToolbar: View {
    @Binding var mode: CalendarViewMode
    let title: String
    let showsStepper: Bool
    let isShowingToday: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToday: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                CalendarModePicker(mode: $mode, stretches: false)
                titleText
                Spacer(minLength: 8)
                stepper
            }
            VStack(alignment: .leading, spacing: Theme.gap) {
                CalendarModePicker(mode: $mode, stretches: true)
                HStack(spacing: 10) {
                    titleText
                    Spacer(minLength: 8)
                    stepper
                }
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.dashTitle)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("calendar.title")
    }

    @ViewBuilder
    private var stepper: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if showsStepper {
                    DashIconButton(symbol: "chevron.left", label: "Previous", identifier: "calendar.previous",
                                   action: onPrevious)
                }
                DashPillButton(title: "Today", prominent: !isShowingToday, identifier: "calendar.today",
                               action: onToday)
                    .fixedSize()
                if showsStepper {
                    DashIconButton(symbol: "chevron.right", label: "Next", identifier: "calendar.next",
                                   action: onNext)
                }
            }
        }
    }
}

/// A glass segmented control: the selected segment is a glass capsule that
/// morphs from segment to segment.
struct CalendarModePicker: View {
    @Binding var mode: CalendarViewMode
    /// Fill the width (narrow windows) rather than hugging the labels.
    var stretches: Bool
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(CalendarViewMode.allCases) { item in
                    segment(item)
                }
            }
            .padding(4)
            .background(Theme.surface, in: Capsule())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.mode")
    }

    private func segment(_ item: CalendarViewMode) -> some View {
        let selected = mode == item
        return Button {
            withAnimation(.snappy) { mode = item }
        } label: {
            Text(item.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 18)
                .frame(minWidth: 84, maxWidth: stretches ? .infinity : nil, minHeight: Theme.minTouch - 8)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .contentShape(Capsule())
                .glassEffect(selected ? .regular.interactive() : .identity, in: Capsule())
                .glassEffectID(selected ? "selection" : item.rawValue, in: glass)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("calendar.mode.\(item.rawValue)")
    }
}

// MARK: - Month

/// The month grid with the selected day's events beside it (wide windows) or
/// below it (narrow). On a half-open Duo the fold sits between the two.
struct CalendarMonthLayout: View {
    @Environment(CalendarModel.self) private var calendar
    let month: Date
    @Binding var selectedDay: Date
    /// Tapping the already-selected day opens it in Day view, like iOS.
    let onOpenDay: (Date) -> Void
    let onSelect: (CalendarEvent) -> Void
    let onNavigate: (MKMapItem) -> Void
    let onSwipe: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fold = FoldGeometry.foldFrame(in: proxy)
            if let split = Self.sideBySide(width: size.width, fold: fold) {
                HStack(spacing: split.gap) {
                    grid(rowHeight: nil, compactSymbols: split.grid < 520)
                        .frame(width: split.grid)
                    dayList(scrolls: true)
                        .frame(width: split.list)
                }
            } else if let fold, fold.width > fold.height, fold.minY > 260, size.height - fold.maxY > 140 {
                // Half-open, top/bottom: grid above the hinge, events below.
                VStack(spacing: 0) {
                    grid(rowHeight: nil, compactSymbols: true)
                        .frame(height: fold.minY)
                    Color.clear.frame(height: fold.height)
                    dayList(scrolls: true)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        grid(rowHeight: Theme.minTouch, compactSymbols: true)
                        dayList(scrolls: false)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// Grid and list widths when they go side by side; with an active vertical
    /// fold, the gap sits exactly on it.
    static func sideBySide(width: CGFloat, fold: CGRect?) -> (grid: CGFloat, list: CGFloat, gap: CGFloat)? {
        if let fold, fold.height > fold.width, fold.minX >= 300, width - fold.maxX >= 300 {
            return (fold.minX, width - fold.maxX, max(Theme.gap, fold.width))
        }
        guard width >= 720 else { return nil }
        let list = min(460, max(340, width * 0.42))
        return (width - list - 16, list, 16)
    }

    private func grid(rowHeight: CGFloat?, compactSymbols: Bool) -> some View {
        MonthGridView(grid: MonthGrid.make(for: month, calendar: calendar.calendarSystem),
                      selectedDay: selectedDay, rowHeight: rowHeight, compactSymbols: compactSymbols) { day in
            if calendar.calendarSystem.isDate(day, inSameDayAs: selectedDay) {
                onOpenDay(day)
            } else if !calendar.calendarSystem.isDate(day, equalTo: month, toGranularity: .month) {
                // A padding day: go to that month, like iOS.
                onSwipe(day < month ? -1 : 1)
                selectedDay = calendar.calendarSystem.startOfDay(for: day)
            } else {
                withAnimation(.snappy) { selectedDay = day }
            }
        }
        .id(month)
        .transition(.opacity)
        .simultaneousGesture(SwipeGesture.make(onSwipe))
    }

    private func dayList(scrolls: Bool) -> some View {
        DayEventList(day: selectedDay, events: calendar.events(on: selectedDay), scrolls: scrolls,
                     onSelect: onSelect, onNavigate: onNavigate)
    }
}

/// iOS-style month: weekday initials, a hairline above each week, the date in a
/// circle (red for today, white when selected) and a dot per calendar with events.
struct MonthGridView: View {
    @Environment(CalendarModel.self) private var calendar
    let grid: MonthGrid
    let selectedDay: Date
    /// Fixed week height (in a scroll view); nil shares out the height available.
    var rowHeight: CGFloat?
    var compactSymbols = true
    let onTap: (Date) -> Void

    var body: some View {
        let cal = calendar.calendarSystem
        let symbols = MonthGrid.weekdaySymbols(calendar: cal, short: compactSymbols)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 28)
            .accessibilityHidden(true)
            ForEach(0..<grid.weeks, id: \.self) { week in
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { index in
                            cell(grid.days[week * 7 + index], cal: cal)
                        }
                    }
                }
                .frame(height: rowHeight)
                .frame(maxHeight: rowHeight == nil ? .infinity : nil)
            }
        }
        .accessibilityIdentifier("calendar.month")
    }

    private func cell(_ day: Date, cal: Calendar) -> some View {
        let inMonth = grid.contains(day, calendar: cal)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let colors = dotColors(for: day)
        let textColor: Color = isSelected ? (isToday ? .white : .black)
            : isToday ? Theme.danger
            : !inMonth ? Theme.textSecondary.opacity(0.45)
            : cal.isDateInWeekend(day) ? Theme.textSecondary : Theme.textPrimary
        return Button { onTap(day) } label: {
            VStack(spacing: 4) {
                Text(day, format: .dateTime.day())
                    .font(.system(size: 20, weight: isToday || isSelected ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(textColor)
                    .frame(width: 40, height: 40)
                    .background {
                        if isSelected {
                            Circle().fill(isToday ? Theme.danger : Color.white)
                        }
                    }
                HStack(spacing: 4) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 7, height: 7)
                    }
                }
                .frame(height: 7)
                .opacity(inMonth ? 1 : 0.45)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            + (colors.isEmpty ? "" : ", has events"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("calendar.day.\(Self.dayKey(day, cal: cal))")
    }

    /// Up to three dots, one per calendar with something on that day.
    private func dotColors(for day: Date) -> [Color] {
        var seen = Set<String>()
        return calendar.events(on: day)
            .filter { seen.insert($0.calendarTitle + ($0.colorRGB?.description ?? "")).inserted }
            .prefix(3)
            .map(\.color)
    }

    static func dayKey(_ day: Date, cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// The selected day's events under a date heading.
struct DayEventList: View {
    @Environment(CalendarModel.self) private var calendar
    let day: Date
    let events: [CalendarEvent]
    let scrolls: Bool
    let onSelect: (CalendarEvent) -> Void
    let onNavigate: (MKMapItem) -> Void

    var body: some View {
        if scrolls {
            ScrollView { content }
                .scrollIndicators(.hidden)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            CalendarDayHeader(day: day)
            if events.isEmpty {
                Text("No events")
                    .font(.dashBody)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier("calendar.empty")
            } else {
                ForEach(events) { event in
                    CalendarEventRow(event: event, isNext: event.id == calendar.nextEvent?.id,
                                     onNavigate: onNavigate, day: day, onSelect: { onSelect(event) })
                }
            }
        }
        .accessibilityIdentifier("calendar.dayList")
    }
}

/// "Today  Tuesday 17 November", "Tomorrow  …" or "Thursday  19 November".
struct CalendarDayHeader: View {
    @Environment(CalendarModel.self) private var calendar
    let day: Date

    var body: some View {
        let cal = calendar.calendarSystem
        let relative: String? = cal.isDateInToday(day) ? "Today" : cal.isDateInTomorrow(day) ? "Tomorrow"
            : cal.isDateInYesterday(day) ? "Yesterday" : nil
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(relative ?? day.formatted(.dateTime.weekday(.wide)))
                .font(.dashTitle)
                .foregroundStyle(cal.isDateInToday(day) ? Theme.danger : Theme.textPrimary)
            Text(relative == nil ? day.formatted(.dateTime.day().month(.wide))
                                 : day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.dashCaption)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Horizontal swipe to go back or forward; leaves vertical scrolling alone.
enum SwipeGesture {
    static func make(_ onSwipe: @escaping (Int) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > 80, abs(dx) > abs(dy) * 2 else { return }
                onSwipe(dx < 0 ? 1 : -1)
            }
    }
}

// MARK: - Day

/// One day as an hour timeline: all-day events in a row on top, blocks coloured
/// by calendar (overlaps side by side), and a red line at the current time.
struct CalendarDayView: View {
    @Environment(CalendarModel.self) private var calendar
    let day: Date
    let onSelect: (CalendarEvent) -> Void
    let onNavigate: (MKMapItem) -> Void
    let onSwipe: (Int) -> Void

    static let hourHeight: CGFloat = 76
    static let gutter: CGFloat = 70

    var body: some View {
        let cal = calendar.calendarSystem
        let events = calendar.events(on: day)
        let slots = TimelineSlot.layout(events, on: day, calendar: cal)
        let allDay = events.filter(\.isAllDay)
        VStack(alignment: .leading, spacing: Theme.gap) {
            if !allDay.isEmpty {
                allDayRow(allDay)
            }
            ScrollViewReader { reader in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // Scroll anchors sit 18 pt above each hour line so its label isn't clipped.
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 4)
                            ForEach(0..<24, id: \.self) { hour in
                                Color.clear.frame(height: Self.hourHeight).id(hour)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        timeline(slots, cal: cal)
                            .padding(.top, 22)
                            .padding(.bottom, 12)
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear { reader.scrollTo(anchorHour(slots, cal: cal), anchor: .top) }
            }
        }
        .simultaneousGesture(SwipeGesture.make(onSwipe))
        .accessibilityIdentifier("calendar.dayView")
    }

    /// Now (an hour back) on today, else the first event, else 8 AM.
    private func anchorHour(_ slots: [TimelineSlot], cal: Calendar) -> Int {
        if cal.isDateInToday(day) {
            return max(0, cal.component(.hour, from: .now) - 1)
        }
        if let first = slots.map(\.startMinute).min() {
            return max(0, Int(first / 60) - 1)
        }
        return 8
    }

    private func allDayRow(_ events: [CalendarEvent]) -> some View {
        HStack(spacing: 10) {
            Text("all-day")
                .font(.dashCaption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Self.gutter - 10, alignment: .trailing)
            ScrollView(.horizontal) {
                HStack(spacing: Theme.gap) {
                    ForEach(events) { event in
                        Button { onSelect(event) } label: {
                            HStack(spacing: 10) {
                                Circle().fill(event.color).frame(width: 10, height: 10)
                                Text(event.title).font(.dashBody).lineLimit(1)
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: Theme.minTouch)
                            .background(event.color.opacity(0.28), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("calendar.open.\(event.id)")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func timeline(_ slots: [TimelineSlot], cal: Calendar) -> some View {
        let hourHeight = Self.hourHeight
        let gutter = Self.gutter
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    HStack(alignment: .top, spacing: 8) {
                        Text(hourLabel(hour, cal: cal))
                            .font(.dashCaption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: gutter - 10, alignment: .trailing)
                            .offset(y: -10)
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                    }
                    .frame(height: hourHeight, alignment: .top)
                }
            }
            GeometryReader { geo in
                let columnsWidth = max(0, geo.size.width - gutter)
                ForEach(slots) { slot in
                    let width = columnsWidth / CGFloat(slot.columns)
                    let height = max(26, CGFloat(slot.endMinute - slot.startMinute) / 60 * hourHeight)
                    TimelineEventBlock(event: slot.event, height: height, width: width - 3,
                                       onSelect: { onSelect(slot.event) }, onNavigate: onNavigate)
                        .frame(width: width - 3, height: height - 2)
                        .offset(x: gutter + CGFloat(slot.column) * width,
                                y: CGFloat(slot.startMinute) / 60 * hourHeight + 1)
                }
            }
            if cal.isDateInToday(day) {
                TimelineView(.everyMinute) { context in
                    let minutes = context.date.timeIntervalSince(cal.startOfDay(for: day)) / 60
                    HStack(spacing: 0) {
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 13, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.danger)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: gutter - 14, alignment: .trailing)
                            .padding(.trailing, 4)
                            .background(Theme.background)
                        Circle().fill(Theme.danger).frame(width: 10, height: 10)
                        Rectangle().fill(Theme.danger).frame(height: 2)
                    }
                    .offset(y: CGFloat(minutes) / 60 * hourHeight - 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 24 * hourHeight)
    }

    private func hourLabel(_ hour: Int, cal: Calendar) -> String {
        guard let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { return "" }
        return date.formatted(.dateTime.hour())
    }
}

/// An event in the Day timeline: tinted block with a colour bar; "Go" when
/// there's room for a full-size button.
struct TimelineEventBlock: View {
    @Environment(CalendarModel.self) private var calendar
    let event: CalendarEvent
    let height: CGFloat
    let width: CGFloat
    let onSelect: () -> Void
    let onNavigate: (MKMapItem) -> Void

    private var showsGo: Bool { event.place.isNavigable && height >= Theme.minTouch + 6 && width >= 200 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                HStack(spacing: 0) {
                    Rectangle().fill(event.color).frame(width: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: height < 40 ? 15 : 17, weight: .bold))
                            .lineLimit(height < 70 ? 1 : 2)
                        if height >= 48 {
                            Text(subtitle)
                                .font(.dashCaption)
                                .foregroundStyle(Theme.textPrimary.opacity(0.75))
                                .lineLimit(height >= 90 ? 2 : 1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, height < 40 ? 2 : 6)
                    .padding(.trailing, showsGo ? Theme.minTouch + 4 : 0)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(event.color.opacity(0.32))
                .background(Theme.background)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("\(event.title), \(subtitle)")
            .accessibilityIdentifier("calendar.open.\(event.id)")
            if showsGo {
                EventGoButton(event: event, style: .round, onNavigate: onNavigate)
                    .padding(3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.block.\(event.id)")
    }

    private var subtitle: String {
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return [("\(start) – \(end)"), event.placeName].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Upcoming

/// iOS's list view: the next 14 days that have events, grouped by day, with
/// the day headings pinned while scrolling.
struct CalendarUpcomingView: View {
    @Environment(CalendarModel.self) private var calendar
    let onSelect: (CalendarEvent) -> Void
    let onNavigate: (MKMapItem) -> Void

    static let days = 14

    var body: some View {
        let groups = calendar.upcomingDays(Self.days)
        let today = calendar.calendarSystem.startOfDay(for: .now)
        Group {
            if groups.isEmpty {
                EmptyStateView(symbol: "calendar", title: "Nothing coming up",
                               message: "No events in the next two weeks.")
                    .accessibilityIdentifier("calendar.empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.gap, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.events) { event in
                                    CalendarEventRow(event: event, isNext: event.id == calendar.nextEvent?.id,
                                                     onNavigate: onNavigate, day: group.day,
                                                     onSelect: { onSelect(event) })
                                }
                            } header: {
                                CalendarDayHeader(day: group.day)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.background)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .task(id: today) {
            let end = calendar.calendarSystem.date(byAdding: .day, value: Self.days, to: today) ?? today
            calendar.load(from: today, to: end)
        }
        .accessibilityIdentifier("calendar.upcoming")
    }
}

// MARK: - Detail

/// A floating glass card with everything about one event: when, which
/// calendar, where, notes and link, plus Go and Open in Calendar.
struct EventDetailCard: View {
    @Environment(CalendarModel.self) private var calendar
    @Environment(\.openURL) private var openURL
    let event: CalendarEvent
    let onClose: () -> Void
    let onNavigate: (MKMapItem) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            ViewThatFits(in: .vertical) {
                card
                ScrollView { card }.scrollIndicators(.hidden)
            }
            .frame(maxWidth: 620)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding(12)
        }
        .accessibilityIdentifier("calendar.detail")
    }

    private var card: some View {
        let time = Self.timeDescription(event, calendar: calendar.calendarSystem)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(event.color).frame(width: 12, height: 12)
                        Text(event.calendarTitle.isEmpty ? "Calendar" : event.calendarTitle)
                            .font(.dashCaption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(event.title)
                        .font(.dashHero)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
                DashIconButton(symbol: "xmark", label: "Close", identifier: "calendar.detail.close", action: onClose)
            }
            infoLine(symbol: "clock") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(time.0).font(.dashBody)
                    if let second = time.1 {
                        Text(second).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                infoLine(symbol: event.place.isNavigable ? "mappin.and.ellipse" : "video") {
                    Text(location.replacingOccurrences(of: "\n", with: ", "))
                        .font(.dashBody)
                        .lineLimit(3)
                }
            }
            if let url = event.url {
                Button { openURL(url) } label: {
                    infoLine(symbol: "link") {
                        Text(url.host() ?? url.absoluteString)
                            .font(.dashBody)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    .frame(minHeight: Theme.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("calendar.detail.url")
            }
            if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                infoLine(symbol: "note.text") {
                    Text(notes)
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(4)
                }
            }
            GlassEffectContainer(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }
            }
            .padding(.top, 4)
        }
        .padding(22)
    }

    @ViewBuilder
    private var actions: some View {
        if event.place.isNavigable {
            EventGoButton(event: event, style: .pill, onNavigate: onNavigate)
                .fixedSize()
        }
        DashPillButton(title: "Open in Calendar", symbol: "calendar", prominent: false,
                       identifier: "calendar.detail.open") {
            if let url = Self.calendarURL(for: event) { openURL(url) }
        }
        .fixedSize()
    }

    private func infoLine<Content: View>(symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26)
            content()
            Spacer(minLength: 0)
        }
    }

    /// Opens Apple's Calendar at the event's date.
    static func calendarURL(for event: CalendarEvent) -> URL? {
        URL(string: "calshow:\(Int(event.start.timeIntervalSinceReferenceDate))")
    }

    /// ("Tuesday 17 November", "10:00 AM – 11:00 AM"), all-day and multi-day aware.
    static func timeDescription(_ event: CalendarEvent, calendar: Calendar = .current) -> (String, String?) {
        let dayStyle = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        let shortDay = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        let time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        if event.isAllDay {
            guard event.spansMultipleDays(calendar: calendar) else { return (event.start.formatted(dayStyle), "All day") }
            let last = event.end.addingTimeInterval(-1)
            return ("\(event.start.formatted(shortDay)) – \(last.formatted(shortDay))", "All day")
        }
        if event.spansMultipleDays(calendar: calendar) {
            return ("From \(event.start.formatted(shortDay)), \(time(event.start))",
                    "to \(event.end.formatted(shortDay)), \(time(event.end))")
        }
        return (event.start.formatted(dayStyle), "\(time(event.start)) – \(time(event.end))")
    }
}
