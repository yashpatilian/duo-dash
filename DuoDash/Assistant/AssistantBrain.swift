import Foundation
import CoreLocation

/// What the assistant knows about the moment, sent with each request. Kept coarse
/// on purpose: no contact data, no precise history.
struct AssistantContext: Equatable {
    var now: Date = Date()
    var coordinate: CLLocationCoordinate2D?
    /// Suburb / city, e.g. "Downtown, Springfield".
    var locality: String?
    var city: String?
    var region: String?
    /// e.g. "Guiding to Central Station via a petrol station, 18 min left."
    var routeSummary: String?

    static func == (a: AssistantContext, b: AssistantContext) -> Bool {
        a.now == b.now && a.locality == b.locality && a.routeSummary == b.routeSummary
            && a.coordinate?.latitude == b.coordinate?.latitude && a.coordinate?.longitude == b.coordinate?.longitude
    }

    var localTime: String {
        now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
    }

    /// Rounded to about a kilometre: enough for "near me", not a precise fix.
    var coarseCoordinate: String? {
        coordinate.map { String(format: "%.2f, %.2f", $0.latitude, $0.longitude) }
    }

    /// The phone's locale, e.g. "en_AU, metric" or "en_US, imperial (miles)".
    static var localeHint: String {
        let locale = Locale.current
        let units = locale.measurementSystem == .metric ? "metric" : "imperial (miles)"
        return "\(locale.identifier), \(units)"
    }

    /// Shared instructions for both models.
    func instructions(webSearch: Bool) -> String {
        var lines = [
            "You are Duo Dash, a voice assistant in a car's dashboard. The driver is driving: keep every reply to one or two short spoken sentences, no lists, no markdown, no URLs.",
            "Use the driver's English variant and units: \(Self.localeHint).",
            "It is \(localTime) (\(TimeZone.current.identifier)).",
        ]
        if let locality { lines.append("The car is near \(locality)\(coarseCoordinate.map { " (about \($0))" } ?? "").") }
        else if let coarseCoordinate { lines.append("The car is at about \(coarseCoordinate).") }
        else { lines.append("The car's location isn't known yet.") }
        lines.append(routeSummary.map { "Trip: \($0)" } ?? "No route is planned.")
        lines.append(contentsOf: [
            "Tools: use search_places to find places (the driver sees them as cards and pins, so just mention the best one or two). Use find_contact_address when the driver names a person's place, then plan_route with that person's name. Use plan_route for any trip; pass stop_along_the_way for requests like \"stop for petrol on the way\". When the driver says \"take me to\" or \"navigate to\", set start_now to true. Otherwise preview the route and ask if they want to start, then call start_navigation when they confirm. Use add_stop to add a stop to the current trip, end_navigation to cancel.",
            "Never make up places, addresses, phone numbers or drive times: only use what the tools return.",
        ])
        if webSearch {
            lines.append("Apple Maps has no ratings or reviews. If the driver asks about reviews, ratings or opening hours, you may use web_search and summarise briefly what you found, saying where it came from. The driver can also tap Details on a card to open Apple's place card.")
        } else {
            lines.append("You can't see ratings or reviews. If asked, say so honestly and suggest tapping Details on a place card, which opens Apple Maps' place card with ratings.")
        }
        return lines.joined(separator: "\n")
    }
}

/// An AI provider behind the assistant. Each keeps its own conversation history
/// until `reset()`.
@MainActor
protocol AssistantBrain: AnyObject {
    var displayName: String { get }
    func respond(to transcript: String, context: AssistantContext, tools: AssistantToolRunner) async throws -> String
    func reset()
}

/// Why a provider couldn't answer. The message is safe to show the driver.
struct AssistantBrainError: Error, LocalizedError, Equatable {
    var message: String
    /// The local parser should try instead (no key, offline, model off…).
    var fallBack = true
    var errorDescription: String? { message }
}
