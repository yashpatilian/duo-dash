import SwiftUI
import UIKit

extension SettingsView.SettingsSection {
    /// Whether the page is listed. Notifications only appears in builds set up for
    /// announcements (DUODASH_NOTIFY_URL and DUODASH_PUSH = YES); every other page always does.
    var isListed: Bool {
        self != .notifications || PushNotifications.isConfiguredInThisBuild
    }
}

/// Settings → Notifications: the opt-in switch for announcements from the developer.
/// Drawn like the other Settings groups (inset-grouped, corner 26, green switch).
struct NotificationSettingsSection: View {
    private let push = PushNotifications.shared
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                row
                if push.status == .denied {
                    Theme.separator.frame(height: 0.5).padding(.leading, 18)
                    openSystemSettings
                }
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            Text(footer)
                .font(.dashCaption.weight(.regular))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 18)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Announcements").font(.dashBody.weight(.regular))
                Text(statusText).font(.dashCaption.weight(.regular)).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("settings.notifications.status")
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { push.isEnabled },
                set: { on in
                    working = true
                    Task { await push.setEnabled(on); working = false }
                }
            ))
            .labelsHidden()
            .tint(Theme.positive)
            .disabled(working)
            .accessibilityLabel("Announcements")
            .accessibilityIdentifier("settings.notifications.toggle")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(minHeight: Theme.minTouch + 2)
    }

    private var openSystemSettings: some View {
        Button {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            HStack {
                Text("Open iOS Settings").font(.dashBody.weight(.regular)).foregroundStyle(Theme.accent)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward").font(.dashCaption).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: Theme.minTouch + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.notifications.openSystemSettings")
    }

    private var statusText: String {
        switch push.status {
        case .off: "Off"
        case .asking: "Waiting for permission…"
        case .denied: "Notifications are off for Duo Dash in iOS Settings."
        case .registering: "Connecting…"
        case .registered: "On"
        case .failed: "Couldn't reach the server. Duo Dash tries again next time it opens."
        }
    }

    private var footer: String {
        "Occasional news from the developer, like a new version being out. Turning this on sends this "
            + "iPhone's notification token (a random ID Apple issues for push notifications), which Duo Dash "
            + "build it is and the app version. Nothing else: no name, location or usage. Turning it off "
            + "deletes the token from the server."
    }
}
