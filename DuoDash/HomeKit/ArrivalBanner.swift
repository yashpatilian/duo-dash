import SwiftUI

/// "Open garage?" with Open / Not now, shown when the car nears home.
/// Draws nothing unless `HomeModel.activeArrival` is set (by
/// `HomeModel.arrivalSuggestion`). Dismisses itself after `timeout`.
struct ArrivalBanner: View {
    @Environment(HomeModel.self) private var model
    var timeout: Duration = .seconds(45)

    var body: some View {
        if let suggestion = model.activeArrival {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    message(suggestion)
                    Spacer(minLength: 8)
                    buttons(suggestion)
                }
                VStack(alignment: .leading, spacing: 10) {
                    message(suggestion)
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        buttons(suggestion)
                    }
                }
            }
            .padding(10)
            .padding(.leading, 4)
            .frame(maxWidth: 620)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("homekit.arrival")
            .task(id: suggestion.id) {
                try? await Task.sleep(for: timeout)
                if model.activeArrival?.id == suggestion.id { model.dismissArrival() }
            }
        }
    }

    private func message(_ suggestion: ArrivalSuggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .frame(width: 44, height: 44)
                .background(Theme.warning.opacity(0.16), in: Circle())
            Text(suggestion.wasPerformed ? performedTitle(suggestion) : suggestion.title)
                .font(.dashBody)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("homekit.arrival.title")
        }
    }

    @ViewBuilder private func buttons(_ suggestion: ArrivalSuggestion) -> some View {
        if suggestion.wasPerformed {
            DashPillButton(title: "OK", prominent: false, identifier: "homekit.arrival.dismiss") {
                model.dismissArrival()
            }
        } else {
            DashPillButton(title: "Not now", prominent: false, identifier: "homekit.arrival.dismiss") {
                model.dismissArrival()
            }
            DashPillButton(title: suggestion.actionTitle, identifier: "homekit.arrival.accept") {
                model.acceptArrival()
            }
        }
    }

    private func performedTitle(_ suggestion: ArrivalSuggestion) -> String {
        if case let .openDoor(id) = suggestion.action, let door = model.accessory(id) {
            return "Opening \(door.name.lowercased())"
        }
        return "Opening garage"
    }
}
