import AppIntents

/// Screens a Shortcut can open Duo Dash on.
enum DuoDashScreen: String, AppEnum {
    case home, maps, music, spotify, phone, messages, youtube, settings

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Duo Dash Screen"
    static let caseDisplayRepresentations: [DuoDashScreen: DisplayRepresentation] = [
        .home: "Home", .maps: "Maps", .music: "Music", .spotify: "Spotify", .phone: "Phone", .messages: "Messages",
        .youtube: "YouTube", .settings: "Settings",
    ]
}

/// "Open Duo Dash" for Shortcuts. Used by a personal automation such as
/// "When Bluetooth device your car connects → Open Duo Dash" (iOS doesn't let an app
/// launch itself when a Bluetooth device connects; Shortcuts automations can).
struct OpenDuoDashIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Duo Dash"
    static let description = IntentDescription("Opens Duo Dash on the dashboard, optionally on a specific screen.")
    static let openAppWhenRun = true

    @Parameter(title: "Screen", default: nil)
    var screen: DuoDashScreen?

    @MainActor
    func perform() async throws -> some IntentResult {
        if let screen, let item = DockItem(rawValue: screen.rawValue) {
            if let app = AppModel.current {
                app.open(item)
            } else {
                // Not running yet: the app restores this tab when it launches.
                UserDefaults.standard.set(item.rawValue, forKey: "app.selectedTab")
            }
        }
        return .result()
    }
}

struct DuoDashShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenDuoDashIntent(),
                    phrases: ["Open \(.applicationName)", "Start \(.applicationName)"],
                    shortTitle: "Open Duo Dash",
                    systemImageName: "car.fill")
    }
}
