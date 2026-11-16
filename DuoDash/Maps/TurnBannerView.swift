import SwiftUI

/// Next manoeuvre, distance to it and, optionally, the one after.
struct TurnBannerView: View {
    @Environment(NavigationModel.self) private var navigation
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(alignment: .center, spacing: compact ? 12 : 16) {
                Image(systemName: navigation.maneuverSymbol)
                    .font(.system(size: compact ? 38 : 56, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: compact ? 52 : 76)

                VStack(alignment: .leading, spacing: 2) {
                    if navigation.state == .arrived {
                        Text("Arrived")
                            .font(compact ? .dashTitle : .dashHero)
                    } else {
                        Text(DistanceText.display(navigation.distanceToManeuver))
                            .font(compact ? .dashTitle : .dashHero)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("nav.distance")
                    }
                    Text(navigation.maneuverInstruction)
                        .font(compact ? .dashCaption : .dashBody)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .accessibilityIdentifier("nav.instruction")
                }
                Spacer(minLength: 0)
            }

            if let then = navigation.thenInstruction, let symbol = navigation.thenSymbol {
                Label(then, systemImage: symbol)
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceRaised, in: Capsule())
            }

            if let stop = navigation.stopProgressText {
                Label(stop, systemImage: "mappin.and.ellipse")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.35), in: Capsule())
                    .accessibilityIdentifier("nav.stop")
            }

            if navigation.isRerouting {
                Label("Rerouting…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.warning)
            }
        }
    }
}

/// ETA, time and distance remaining.
struct TripSummaryView: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        HStack(spacing: 16) {
            summary(value: navigation.eta.map { $0.formatted(.dateTime.hour().minute()) } ?? "--", label: "arrival")
            summary(value: Self.duration(navigation.remainingTime), label: "remaining")
            summary(value: DistanceText.display(navigation.remainingDistance), label: "to go")
        }
    }

    private func summary(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.dashTitle).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)   // never break a word ("remainin/g")
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 0)) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Guidance for small windows (cover screen in either orientation, phones): one slim
/// glass card, so the map stays visible. Line 1: arrow, distance, instruction.
/// Line 2: arrival · time · distance (or the next stop), and a small End button.
struct CompactGuidanceCard: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: navigation.state == .arrived ? "flag.checkered" : navigation.maneuverSymbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if navigation.state == .arrived {
                        Text("Arrived").font(.dashTitle)
                    } else {
                        Text(DistanceText.display(navigation.distanceToManeuver))
                            .font(.dashTitle)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .fixedSize()
                            .accessibilityIdentifier("nav.distance")
                    }
                    Text(navigation.maneuverInstruction)
                        .font(.dashBody)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityIdentifier("nav.instruction")
                }
                Text(secondLine)
                    .font(.dashCaption)
                    .foregroundStyle(navigation.isRerouting ? Theme.warning : Theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityIdentifier(navigation.stopProgressText != nil ? "nav.stop" : "nav.summary")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DashIconButton(symbol: navigation.state == .arrived ? "checkmark" : "xmark",
                           tint: Theme.danger, label: navigation.state == .arrived ? "Done" : "End",
                           identifier: "nav.end") {
                navigation.end()
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }

    /// "9:17 pm · 23 min · 28 km", or the next stop, or rerouting.
    private var secondLine: String {
        if navigation.isRerouting { return "Rerouting…" }
        if let stop = navigation.stopProgressText { return stop }
        let eta = navigation.eta.map { $0.formatted(.dateTime.hour().minute()) } ?? "--"
        return "\(eta) · \(TripSummaryView.duration(navigation.remainingTime)) · \(DistanceText.display(navigation.remainingDistance))"
    }
}
