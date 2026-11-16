import UIKit
import EventKit
import MapKit

/// Where CalendarModel gets events from: EventKit on a phone, a fixed demo day
/// in the Simulator and tests.
@MainActor
protocol CalendarBackend: AnyObject {
    var isDemo: Bool { get }
    /// Current permission, without asking.
    func access() -> CalendarAccess
    /// Shows the system prompt if it hasn't been answered yet.
    func requestAccess() async -> CalendarAccess
    /// Events overlapping `start..<end`, sorted by start.
    func events(from start: Date, to end: Date) -> [CalendarEvent]
    /// Called when the calendar database changes (an event added on the Mac, etc.).
    var onChange: (@MainActor () -> Void)? { get set }
}

/// Real calendars via EventKit (iOS 17+ full-access API).
@MainActor
final class EventKitCalendarBackend: CalendarBackend {
    let isDemo = false
    var onChange: (@MainActor () -> Void)?
    private let store = EKEventStore()

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    func access() -> CalendarAccess {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> CalendarAccess {
        guard access() == .notDetermined else { return access() }
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // The status below says what happened; an error here just means "not granted".
        }
        store.reset()
        return access()
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard access() == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map(Self.convert)
            .sorted { $0.start < $1.start }
    }

    static func map(_ status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }

    private static func convert(_ event: EKEvent) -> CalendarEvent {
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        let start: Date = event.startDate ?? .distantPast
        let end: Date = event.endDate ?? start
        let structured = event.structuredLocation
        return CalendarEvent(
            id: "\(base)@\(Int(start.timeIntervalSince1970))",
            title: (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled event",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            location: event.location,
            structuredTitle: structured?.title,
            structuredCoordinate: structured?.geoLocation.map { GeoPoint($0.coordinate) },
            calendarTitle: event.calendar?.title ?? "",
            colorRGB: event.calendar.flatMap { rgb(of: $0.cgColor) },
            notes: event.hasNotes ? event.notes : nil,
            url: event.url
        )
    }

    private static func rgb(of color: CGColor?) -> [Double]? {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return nil }
        return components.prefix(3).map { Double($0) }
    }
}

/// Turns an event's free-text location into a map item.
@MainActor
protocol PlaceGeocoder: AnyObject {
    func mapItem(for query: String, near: CLLocationCoordinate2D?) async -> MKMapItem?
}

/// MapKit lookup: a place search first (handles "Blue Bottle Coffee, Palo Alto"),
/// then a plain address geocode.
@MainActor
final class MapKitPlaceGeocoder: PlaceGeocoder {
    func mapItem(for query: String, near: CLLocationCoordinate2D?) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let near {
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
        }
        if let item = try? await MKLocalSearch(request: request).start().mapItems.first {
            return item
        }
        if let geocode = MKGeocodingRequest(addressString: query),
           let item = try? await geocode.mapItems.first {
            return item
        }
        return nil
    }
}
