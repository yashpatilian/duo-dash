import SwiftUI

/// Compact car card for the Dashboard: speed (or RPM), coolant, battery voltage and a
/// warning dot when trouble codes are stored. Tapping it calls `onOpen` (open the Car app).
struct CarDashboardCard: View {
    @Environment(CarDataModel.self) private var car
    var compact = false
    var onOpen: (() -> Void)?

    var body: some View {
        Card(padding: compact ? 10 : 16) {
            Button {
                onOpen?()
            } label: {
                content
                    .frame(maxWidth: .infinity, minHeight: Theme.minTouch, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)
        }
        .accessibilityIdentifier("car.dashboardCard")
    }

    @ViewBuilder
    private var content: some View {
        if car.state.hasAdapter {
            HStack(alignment: .center, spacing: compact ? 14 : 20) {
                primary
                Spacer(minLength: 0)
                if car.supportedPIDs.contains(.coolantTemp) {
                    reading(symbol: "thermometer.medium",
                            text: car.value(.coolantTemp).map { "\(Int($0.rounded()))°" } ?? "–",
                            tint: CarScreen.tint(for: .coolantTemp, value: car.value(.coolantTemp)))
                }
                reading(symbol: "minus.plus.batteryblock",
                        text: car.batteryVoltage.map { String(format: "%.1f V", $0) } ?? "–",
                        tint: CarScreen.batteryTint(car.batteryVoltage))
                if car.hasTroubleCodes {
                    Circle().fill(Theme.warning).frame(width: 14, height: 14)
                        .accessibilityLabel("Trouble codes stored")
                        .accessibilityIdentifier("car.dashboardCard.warning")
                }
            }
        } else {
            let info = CarStatusCard.guidance(for: car.state, remembered: car.rememberedAdapterName)
            HStack(spacing: 12) {
                Image(systemName: info.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(info.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title).font(.dashBody).lineLimit(1)
                    if !compact {
                        Text("Car data").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    /// Speed when the car reports it, otherwise RPM, otherwise a short status.
    @ViewBuilder
    private var primary: some View {
        let pid: OBDPID? = car.supportedPIDs.contains(.speed) ? .speed : car.supportedPIDs.contains(.rpm) ? .rpm : nil
        if let pid {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(car.value(pid).map(pid.format) ?? "–")
                    .font(.system(size: compact ? 34 : 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(pid.unit).font(.dashCaption).foregroundStyle(Theme.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Car").font(.dashBody)
                Text(car.state.isConnected ? "Connected" : "Battery only")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func reading(symbol: String, text: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.dashCaption).foregroundStyle(Theme.textSecondary)
            Text(text).font(.dashBody).monospacedDigit().foregroundStyle(tint).lineLimit(1)
        }
    }
}
