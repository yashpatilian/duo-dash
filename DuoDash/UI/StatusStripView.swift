import SwiftUI
import Observation

/// Time, ETA and battery along the top. Only used when the dock is at the bottom
/// (in sidebar mode the clock lives at the top of the sidebar, like CarPlay).
struct StatusStripView: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @State private var battery = BatteryMonitor()

    var body: some View {
        HStack(spacing: 14) {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("status.clock")
            .onLongPressGesture(minimumDuration: 0.8) { app.showScreenInfo.toggle() }

            if navigation.state == .navigating, let eta = navigation.eta {
                Label {
                    Text("ETA \(eta, format: .dateTime.hour().minute())")
                } icon: {
                    Image(systemName: "flag.checkered")
                }
                .font(.dashCaption)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if let level = battery.level {
                    Text(level, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                Image(systemName: battery.symbol)
                    .foregroundStyle(battery.tint)
            }
            .font(.dashCaption)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
    }
}

/// Wraps UIDevice battery monitoring for SwiftUI.
@MainActor
@Observable
final class BatteryMonitor {
    private(set) var level: Double?
    private(set) var state: UIDevice.BatteryState = .unknown

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func refresh() {
        let raw = UIDevice.current.batteryLevel
        level = raw < 0 ? nil : Double(raw)
        state = UIDevice.current.batteryState
    }

    var symbol: String {
        if state == .charging || state == .full { return "battery.100.bolt" }
        guard let level else { return "battery.100" }
        switch level {
        case 0.88...: return "battery.100"
        case 0.63..<0.88: return "battery.75"
        case 0.38..<0.63: return "battery.50"
        case 0.13..<0.38: return "battery.25"
        default: return "battery.0"
        }
    }

    var tint: Color {
        if state == .charging || state == .full { return Theme.accent }
        if let level, level < 0.2 { return Theme.danger }
        return Theme.textPrimary
    }
}
