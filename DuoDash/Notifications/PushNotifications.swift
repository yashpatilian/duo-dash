import Foundation
import Observation
import UIKit
import UserNotifications

/// Announcements from the developer ("a new version is out"), sent as push notifications by
/// the server in backend/notifications. Opt-in and off by default: permission is asked only
/// when the user turns Announcements on in Settings. Inert (hidden, never registers) unless
/// the build sets DUODASH_NOTIFY_URL and DUODASH_PUSH = YES (see docs/NOTIFICATIONS.md).
@MainActor @Observable
final class PushNotifications {
    static let shared = PushNotifications.live()

    enum Status: Equatable {
        case off
        /// Waiting for the user to answer the iOS permission prompt.
        case asking
        /// Notifications are turned off for Duo Dash in iOS Settings.
        case denied
        /// Waiting for a device token from iOS, or for the server.
        case registering
        case registered
        /// The server couldn't be reached; it's tried again on the next launch.
        case failed
    }

    /// Hooks into iOS, replaceable in tests.
    struct System {
        /// Shows the permission prompt if needed; true when alerts are allowed.
        var requestAuthorization: @MainActor () async -> Bool
        /// True when alerts are currently allowed (no prompt).
        var isAuthorized: @MainActor () async -> Bool
        var registerForRemoteNotifications: @MainActor () -> Void

        static let live = System(
            requestAuthorization: {
                (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            },
            isAuthorized: {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                return [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            },
            registerForRemoteNotifications: { UIApplication.shared.registerForRemoteNotifications() }
        )
    }

    private enum Key {
        static let enabled = "notify.enabled"
        static let token = "notify.token"
        /// The registration the server last accepted; a mismatch (new token, new version) re-sends it.
        static let uploaded = "notify.uploaded"
        /// A token the server still has to forget (turned off while offline).
        static let pendingUnregister = "notify.pendingUnregister"
    }

    /// The server; nil when the build doesn't configure one.
    let baseURL: URL?
    let bundleId: String
    let appVersion: String
    let environment: PushRegistration.Environment
    /// Whether this build carries the aps-environment entitlement (DUODASH_PUSH = YES).
    let pushEntitled: Bool

    private(set) var isEnabled: Bool
    private(set) var status: Status

    /// Shown in Settings only when the build is set up for it.
    var isAvailable: Bool { baseURL != nil && pushEntitled }

    private let defaults: UserDefaults
    private let session: URLSession
    private let system: System

    init(baseURL: URL?, bundleId: String, appVersion: String, environment: PushRegistration.Environment,
         pushEntitled: Bool = true, defaults: UserDefaults = .standard, session: URLSession = .shared,
         system: System = .live) {
        self.baseURL = baseURL
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.environment = environment
        self.pushEntitled = pushEntitled
        self.defaults = defaults
        self.session = session
        self.system = system
        let enabled = baseURL != nil && pushEntitled && defaults.bool(forKey: Key.enabled)
        isEnabled = enabled
        status = enabled ? .registering : .off
    }

    /// Whether this build is set up for announcements (a server URL and the push entitlement).
    /// Readable from anywhere, e.g. to decide whether Settings lists the page.
    nonisolated static let isConfiguredInThisBuild: Bool = {
        let info = Bundle.main.infoDictionary ?? [:]
        return PushRegistration.baseURL(from: info["DuoDashNotifyURL"] as? String) != nil
            && (info["DuoDashPush"] as? String)?.uppercased() == "YES"
    }()

    /// Configured from Info.plist (DuoDashNotifyURL, DuoDashPush) and the running build.
    static func live(bundle: Bundle = .main) -> PushNotifications {
        let info = bundle.infoDictionary ?? [:]
        let profileURL = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return PushNotifications(
            baseURL: PushRegistration.baseURL(from: info["DuoDashNotifyURL"] as? String),
            bundleId: bundle.bundleIdentifier ?? "",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            environment: PushRegistration.environment(provisioningProfile: profileURL.flatMap { try? Data(contentsOf: $0) },
                                                      isSimulator: simulator),
            pushEntitled: (info["DuoDashPush"] as? String)?.uppercased() == "YES"
        )
    }

    // MARK: Turning it on and off

    /// The Settings toggle. On: asks permission, then registers with APNs and the server.
    /// Off: the server forgets this device.
    func setEnabled(_ on: Bool) async {
        guard isAvailable, on != isEnabled else { return }
        isEnabled = on
        defaults.set(on, forKey: Key.enabled)
        if on {
            status = .asking
            guard await system.requestAuthorization() else {
                isEnabled = false
                defaults.set(false, forKey: Key.enabled)
                status = .denied
                return
            }
            guard isEnabled else { return }   // turned off again while the prompt was up
            status = .registering
            system.registerForRemoteNotifications()
        } else {
            status = .off
            defaults.removeObject(forKey: Key.uploaded)
            if let token = defaults.string(forKey: Key.token) {
                defaults.set(token, forKey: Key.pendingUnregister)
                await sendUnregister(token)
            }
        }
    }

    /// At launch: finish an unregister that failed, and re-register when on (iOS may hand out
    /// a new token; an upload that failed last time is retried).
    func resumeOnLaunch() async {
        guard isAvailable else { return }
        if let pending = defaults.string(forKey: Key.pendingUnregister) {
            await sendUnregister(pending)
        }
        guard isEnabled else { return }
        if await system.isAuthorized() {
            status = .registering
            system.registerForRemoteNotifications()
        } else {
            status = .denied
        }
    }

    // MARK: From the app delegate

    func didRegister(deviceToken: Data) async {
        guard isAvailable else { return }
        let token = PushRegistration.hex(deviceToken)
        defaults.set(token, forKey: Key.token)
        guard isEnabled, let baseURL else { return }
        if defaults.string(forKey: Key.pendingUnregister) == token {
            defaults.removeObject(forKey: Key.pendingUnregister)   // on again before the server forgot it
        }
        let registration = PushRegistration(token: token, bundleId: bundleId, environment: environment, appVersion: appVersion)
        let fingerprint = [token, bundleId, environment.rawValue, appVersion].joined(separator: "|")
        if defaults.string(forKey: Key.uploaded) == fingerprint {
            status = .registered
            return
        }
        status = .registering
        if await send(registration.registerRequest(base: baseURL)) {
            defaults.set(fingerprint, forKey: Key.uploaded)
            status = isEnabled ? .registered : .off
        } else {
            status = isEnabled ? .failed : .off
        }
    }

    func didFailToRegister() {
        guard isAvailable, isEnabled else { return }
        status = .failed
    }

    // MARK: Server

    private func sendUnregister(_ token: String) async {
        guard let baseURL else { return }
        if await send(PushRegistration.unregisterRequest(base: baseURL, token: token)) {
            defaults.removeObject(forKey: Key.pendingUnregister)
        }
    }

    private func send(_ request: URLRequest) async -> Bool {
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}

/// Receives the APNs device token (SwiftUI has no hook for it) and shows announcements while
/// Duo Dash is in front. Does nothing unless the build is set up for announcements.
final class DuoDashAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let push = PushNotifications.shared
        guard push.isAvailable else { return true }
        UNUserNotificationCenter.current().delegate = self
        Task { await push.resumeOnLaunch() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await PushNotifications.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.shared.didFailToRegister()
    }

    // Show announcements as banners even while the app is open (it usually is, on the dash).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // Tapping one with a duodash:// link (e.g. duodash://open/settings) opens that screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: link), url.scheme == "duodash" else { return }
        await MainActor.run { UIApplication.shared.open(url) }
    }
}
