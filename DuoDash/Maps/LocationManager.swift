import CoreLocation
import Observation

/// Owns the single CLLocationManager for the app.
@MainActor
@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private(set) var location: CLLocation?
    private(set) var authorization: CLAuthorizationStatus

    /// Called on every fix. NavigationModel uses this to track progress along a route.
    @ObservationIgnored var onUpdate: (@MainActor (CLLocation) -> Void)?
    /// Further listeners (dashcam GPS track, Home arrival, calendar search bias).
    @ObservationIgnored private var listeners: [@MainActor (CLLocation) -> Void] = []
    func addListener(_ listener: @escaping @MainActor (CLLocation) -> Void) { listeners.append(listener) }

    private let manager: CLLocationManager
    /// False in unit tests: fixes come only from the test, never from the device's GPS.
    private let live: Bool

    init(live: Bool = true) {
        let manager = CLLocationManager()
        self.manager = manager
        self.live = live
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 10
        manager.pausesLocationUpdatesAutomatically = false
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func start() {
        guard live else { return }
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    /// While a route is active, keep getting fixes with the screen locked or the app
    /// in the background (needs the "location" background mode), at full rate.
    func setNavigating(_ navigating: Bool) {
        manager.allowsBackgroundLocationUpdates = navigating
        manager.showsBackgroundLocationIndicator = navigating
        manager.distanceFilter = navigating ? kCLDistanceFilterNone : 10
    }

    // MARK: CLLocationManagerDelegate (delivered on the main thread, where the manager was created)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        MainActor.assumeIsolated {
            location = latest
            onUpdate?(latest)
            for listener in listeners { listener(latest) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            if isAuthorized && live { self.manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (no fix yet, tunnel) are normal in a car; keep going.
    }
}
