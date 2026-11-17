import SwiftUI
import CoreLocation

/// A latitude/longitude pair that is Equatable and Sendable (CLLocationCoordinate2D is neither).
struct GeoPoint: Hashable, Sendable, Codable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    func distance(to other: GeoPoint) -> CLLocationDistance { location.distance(from: other.location) }
}

/// One calendar event, copied out of EventKit (or the demo backend) so the UI and
/// tests never touch `EKEvent`.
struct CalendarEvent: Identifiable, Hashable, Sendable {
    /// Unique per occurrence (recurring events share an identifier, so the start is part of it).
    let id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    /// The free-text location as typed into the event (often an address or place name).
    var location: String? = nil
    /// The place picked from Maps when the event was made: its name and exact coordinate.
    var structuredTitle: String? = nil
    var structuredCoordinate: GeoPoint? = nil
    var calendarTitle: String = ""
    /// Calendar colour as sRGB components, for the little colour bar.
    var colorRGB: [Double]? = nil
    /// The event's notes, for the detail card.
    var notes: String? = nil
    /// The event's URL field (a ticket, an agenda, a meeting link).
    var url: URL? = nil

    var color: Color {
        guard let rgb = colorRGB, rgb.count >= 3 else { return Theme.systemBlue }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    /// Short place name for a row: the structured title, else the first line of the location.
    var placeName: String? {
        if let structuredTitle, !structuredTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            return structuredTitle
        }
        guard let line = location?.split(whereSeparator: \.isNewline).first else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Where "Go" should take you. A coordinate picked in Maps beats free text,
    /// which has to be looked up first.
    var place: EventPlace {
        if let structuredCoordinate {
            return .coordinate(structuredCoordinate, name: placeName ?? title)
        }
        if let text = location?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           !EventPlace.looksLikeOnlineMeeting(text) {
            return .address(text)
        }
        return .none
    }

    func isInProgress(at now: Date) -> Bool { start <= now && end > now }
}

/// Where an event's "Go" button leads.
enum EventPlace: Hashable, Sendable {
    case coordinate(GeoPoint, name: String)
    /// Needs geocoding first.
    case address(String)
    /// No location, or only a video-call link.
    case none

    var isNavigable: Bool { self != .none }

    /// "Zoom", "https://meet.google.com/…" and the like aren't places you can drive to.
    static func looksLikeOnlineMeeting(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        let markers = ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com", "facetime"]
        if markers.contains(where: lower.contains) { return true }
        return ["zoom", "online", "teams", "google meet", "microsoft teams", "facetime", "phone", "call"]
            .contains(lower)
    }
}

/// Calendar permission, mapped from EventKit, with the words the screen shows.
enum CalendarAccess: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    /// "Add Events Only": we can't read anything.
    case writeOnly
    case granted

    var isGranted: Bool { self == .granted }

    /// The user can still be asked from inside the app.
    var canRequest: Bool { self == .notDetermined }

    var title: String {
        switch self {
        case .notDetermined: "See your next event"
        case .denied: "Calendar access is off"
        case .restricted: "Calendar access is restricted"
        case .writeOnly: "Duo Dash can't read your events"
        case .granted: "Calendar"
        }
    }

    var message: String {
        switch self {
        case .notDetermined:
            "Allow calendar access to show what's next and get directions to it with one tap."
        case .denied:
            "Turn on Full Access for Duo Dash in Settings › Apps › Duo Dash › Calendars."
        case .restricted:
            "Screen Time or a device profile blocks calendar access on this iPhone."
        case .writeOnly:
            "It only has \"Add Events Only\" access. Change it to Full Access in Settings › Apps › Duo Dash › Calendars."
        case .granted:
            ""
        }
    }

    /// Button title for the fix, if there is one the app can start.
    var actionTitle: String? {
        switch self {
        case .notDetermined: "Allow Calendar"
        case .denied, .writeOnly: "Open Settings"
        case .restricted, .granted: nil
        }
    }
}
