import SwiftUI

/// Under the route preview when Google Maps or Waze guides: what wasn't passed on, the way back
/// to Duo Dash's own guidance, and the Split View tip.
struct ExternalHandoffFooter: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice = navigation.handoff.notice {
                Label(notice, systemImage: "exclamationmark.circle.fill")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nav.handoffNotice")
            }
            Button {
                navigation.startHere()
            } label: {
                Label("Guide in Duo Dash instead", systemImage: "location.north.fill")
                    .font(.dashCaption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: Theme.minTouch, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nav.startHere")
            Text(ExternalNavigationCopy.splitViewTip(for: navigation.handoff.preferred))
                .font(.dashCaption.weight(.regular))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum ExternalNavigationCopy {
    /// The way back to the dashboard: the Duo shows Duo Dash beside the other app.
    static func splitViewTip(for app: NavigationApp) -> String {
        "On iPhone Duo, open Duo Dash beside \(app.title) in Split View to keep your music and dashboard on screen."
    }

    static let settingsFooter = "Google Maps and Waze appear once they're installed. Every Go and Start in Duo Dash (search results, saved places, calendar events, the assistant) then opens the trip in that app; Duo Dash still shows the route, time and destination weather. Google Maps gets your stops too; Waze takes only the destination. On iPhone Duo, open Duo Dash beside the other app in Split View to keep your music and dashboard on screen."
}
