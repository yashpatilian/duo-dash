import Foundation
import MapKit
import Observation
import UIKit

/// Which app guides the drive. Apple Maps means Duo Dash's own guidance (MapKit);
/// Google Maps and Waze get the trip handed to them with their official URL schemes.
enum NavigationApp: String, CaseIterable, Identifiable, Sendable {
    case appleMaps, googleMaps, waze

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMaps: "Apple Maps"
        case .googleMaps: "Google Maps"
        case .waze: "Waze"
        }
    }

    /// The URL whose `canOpenURL` answer says the app is installed (listed in
    /// LSApplicationQueriesSchemes). Apple Maps is Duo Dash itself, always there.
    var probeURL: URL? {
        switch self {
        case .appleMaps: nil
        case .googleMaps: URL(string: "comgooglemaps://")
        case .waze: URL(string: "waze://")
        }
    }

    /// Waze's link takes one destination only.
    var supportsStops: Bool { self != .waze }
}

/// A place to hand to another app: a coordinate when there is one, else a name or address.
struct NavigationTarget: Equatable, Sendable {
    var name: String?
    var latitude: Double?
    var longitude: Double?

    init(name: String?, latitude: Double?, longitude: Double?) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    init(item: MKMapItem) {
        let c = item.location.coordinate
        let valid = CLLocationCoordinate2DIsValid(c) && !(c.latitude == 0 && c.longitude == 0)
        self.init(name: item.addressLine ?? item.name,
                  latitude: valid ? c.latitude : nil,
                  longitude: valid ? c.longitude : nil)
        if valid { name = item.name }
    }

    /// "lat,lon" with a '.' decimal point whatever the phone's locale; else the name/address.
    var query: String? {
        if let latitude, let longitude { return NavigationLinks.coordinate(latitude, longitude) }
        let text = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    var hasCoordinate: Bool { latitude != nil && longitude != nil }
}

/// The official deep links (and their web fallbacks) for Google Maps and Waze.
enum NavigationLinks {
    /// Six decimals (about 10 cm), POSIX formatting so a German or French phone doesn't write "37,5".
    static func coordinate(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    /// RFC 3986 unreserved characters plus ',' (kept so coordinates stay readable). Everything else,
    /// including '&', '+', '=', '#', spaces and non-ASCII letters, is percent-encoded.
    private static let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// `comgooglemaps://?daddr=<lat>,<lon>&directionsmode=driving`; with stops,
    /// `comgooglemaps://?saddr=&daddr=<stop>+to:<stop>+to:<destination>&directionsmode=driving`
    /// (an empty saddr means "from my location").
    static func googleMapsApp(to destination: NavigationTarget, via stops: [NavigationTarget] = []) -> URL? {
        let points = (stops + [destination]).compactMap(\.query).map(encode)
        guard destination.query != nil, !points.isEmpty else { return nil }
        let start = stops.isEmpty ? "" : "saddr=&"
        return URL(string: "comgooglemaps://?\(start)daddr=\(points.joined(separator: "+to:"))&directionsmode=driving")
    }

    /// Google's cross-platform Maps URL: opens the app if it's there, otherwise the website.
    static func googleMapsWeb(to destination: NavigationTarget, via stops: [NavigationTarget] = []) -> URL? {
        guard let target = destination.query else { return nil }
        var link = "https://www.google.com/maps/dir/?api=1&destination=\(encode(target))&travelmode=driving"
        let waypoints = stops.compactMap(\.query).map(encode)
        if !waypoints.isEmpty { link += "&waypoints=" + waypoints.joined(separator: "%7C") }
        return URL(string: link)
    }

    /// `waze://?ll=<lat>,<lon>&navigate=yes`, or a search (`q=`) when there's no coordinate.
    static func wazeApp(to destination: NavigationTarget) -> URL? {
        wazeLink(base: "waze://", destination)
    }

    /// `https://waze.com/ul?ll=<lat>,<lon>&navigate=yes`: Waze's universal link.
    static func wazeWeb(to destination: NavigationTarget) -> URL? {
        wazeLink(base: "https://waze.com/ul", destination)
    }

    private static func wazeLink(base: String, _ destination: NavigationTarget) -> URL? {
        guard let query = destination.query else { return nil }
        let key = destination.hasCoordinate ? "ll" : "q"
        return URL(string: "\(base)?\(key)=\(encode(query))&navigate=yes")
    }

    /// The app link and the web fallback for `app`. Nil for Apple Maps (guided in Duo Dash).
    static func links(for app: NavigationApp, to destination: NavigationTarget,
                      via stops: [NavigationTarget] = []) -> (app: URL, web: URL)? {
        switch app {
        case .appleMaps:
            return nil
        case .googleMaps:
            guard let a = googleMapsApp(to: destination, via: stops), let w = googleMapsWeb(to: destination, via: stops) else { return nil }
            return (a, w)
        case .waze:
            guard let a = wazeApp(to: destination), let w = wazeWeb(to: destination) else { return nil }
            return (a, w)
        }
    }

    /// What to tell the driver when the chosen app can't take the trip's stops.
    static func stopsNotice(for app: NavigationApp, stopCount: Int) -> String? {
        guard stopCount > 0, !app.supportsStops else { return nil }
        let stops = stopCount == 1 ? "your stop isn't" : "your \(stopCount) stops aren't"
        return "\(app.title) takes only the destination, so \(stops) passed on. Add \(stopCount == 1 ? "it" : "them") in \(app.title)."
    }
}

/// Settings → Navigation → "Navigate with", and the hand-off itself.
@MainActor
@Observable
final class NavigationHandoff {
    static let storageKey = "nav.app"

    /// The app chosen in Settings. Apple Maps (Duo Dash's own guidance) by default.
    var preferred: NavigationApp {
        didSet { defaults.set(preferred.rawValue, forKey: Self.storageKey) }
    }

    /// Shown in the route preview after a hand-off that dropped the stops (Waze).
    private(set) var notice: String?
    /// The last link handed over (tests, and the preview's "Open again").
    private(set) var lastOpened: URL?

    typealias Opener = @MainActor (URL, @escaping @MainActor (Bool) -> Void) -> Void

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let canOpen: @MainActor (URL) -> Bool
    @ObservationIgnored private let opener: Opener

    init(defaults: UserDefaults = .standard,
         canOpen: (@MainActor (URL) -> Bool)? = nil,
         opener: Opener? = nil) {
        self.defaults = defaults
        // -DemoExternalApps (screenshots, UI tests) pretends Google Maps and Waze are installed.
        self.canOpen = canOpen ?? { LaunchOptions.demoExternalApps || UIApplication.shared.canOpenURL($0) }
        self.opener = opener ?? { url, done in
            UIApplication.shared.open(url, options: [:]) { ok in Task { @MainActor in done(ok) } }
        }
        preferred = defaults.string(forKey: Self.storageKey).flatMap(NavigationApp.init(rawValue:)) ?? .appleMaps
    }

    /// Guidance happens in another app.
    var usesExternalApp: Bool { preferred != .appleMaps }

    func isInstalled(_ app: NavigationApp) -> Bool {
        app.probeURL.map { canOpen($0) } ?? true
    }

    /// "Open in Waze": the label of the hand-off button.
    var actionTitle: String { "Open in \(preferred.title)" }

    /// Opens the trip in the chosen app: its own URL scheme when it's installed (falling back to
    /// the web link if iOS refuses), otherwise straight to the web link. Returns the first URL tried.
    @discardableResult
    func handOff(to destination: NavigationTarget, via stops: [NavigationTarget] = []) -> URL? {
        let app = preferred
        guard let links = NavigationLinks.links(for: app, to: destination, via: app.supportsStops ? stops : []) else { return nil }
        notice = NavigationLinks.stopsNotice(for: app, stopCount: stops.count)
        let first = isInstalled(app) ? links.app : links.web
        lastOpened = first
        opener(first) { [weak self] ok in
            guard !ok, first != links.web else { return }
            self?.lastOpened = links.web
            self?.opener(links.web) { _ in }
        }
        return first
    }

    func handOff(to destination: MKMapItem, via stops: [MKMapItem]) {
        handOff(to: NavigationTarget(item: destination), via: stops.map(NavigationTarget.init(item:)))
    }

    func clearNotice() { notice = nil }
}
