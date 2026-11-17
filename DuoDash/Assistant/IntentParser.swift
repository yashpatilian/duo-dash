import Foundation
import MapKit

/// What the driver asked for, worked out without a language model. Used when the
/// chosen AI isn't available (no key, no network, Apple Intelligence off).
enum AssistantIntent: Equatable {
    /// "take me to X", "navigate to X but stop for petrol on the way".
    case navigate(destination: String, stopAlongTheWay: String?, startNow: Bool)
    /// "find coffee near me", "suggest some places for dinner".
    case findPlaces(query: String, nearDestination: Bool)
    /// "stop at a petrol station on the way" (no destination named).
    case addStopAlongTheWay(category: String)
    /// "add a stop at Costco".
    case addStop(place: String)
    case startNavigation
    case endNavigation
    /// "does it have good reviews?"
    case reviews
    case unknown
}

enum IntentParser {
    static func parse(_ raw: String) -> AssistantIntent {
        var text = normalise(raw)
        guard !text.isEmpty else { return .unknown }
        text = stripPoliteness(text)

        if matches(text, #"^(cancel|cancel (the )?(route|trip|navigation)|end (the )?(route|trip|navigation)|stop (the )?(navigation|navigating|route|guidance))$"#) {
            return .endNavigation
        }
        if matches(text, #"^(start|go|let'?s go|start (the )?(route|navigation|trip|driving)|yes( please)?|yep|ok( go)?|okay|sure|do it|begin)$"#) {
            return .startNavigation
        }
        if text.contains("review") || text.contains("rating") || text.contains("stars") {
            return .reviews
        }

        // "... but stop for petrol on the way" can follow a destination; split it off first.
        let (main, along) = splitAlongTheWay(text)

        if let place = capture(main, #"^add (a )?stop (at|to|for) (.+)$"#, group: 3) ?? capture(main, #"^add (.+) as a stop$"#, group: 1) {
            return .addStop(place: cleanPlace(place))
        }

        let goNow = #"^(take me|navigate|drive me|get me|bring me|route me|directions|give me directions|head|go|drive)( to| towards| over to)? (.+)$"#
        let goLater = #"^(i want to go|i wanna go|i'd like to go|i would like to go|i need to go|i need to get|how do i get|how far is it|we're going|we are going|let's go)( to)? (.+)$"#
        if let destination = capture(main, goNow, group: 3) {
            return .navigate(destination: cleanPlace(destination), stopAlongTheWay: along, startNow: along == nil)
        }
        if let destination = capture(main, goLater, group: 3) {
            return .navigate(destination: cleanPlace(destination), stopAlongTheWay: along, startNow: false)
        }
        if main.isEmpty, let along {
            return .addStopAlongTheWay(category: along)
        }

        if let query = placeQuery(main) {
            let nearDestination = matches(main, #"(near|at|around|close to) (my |the )?(destination|there)"#)
            return .findPlaces(query: query, nearDestination: nearDestination)
        }
        if let along { return .addStopAlongTheWay(category: along) }
        return .unknown
    }

    /// "Sam's house" → "Sam". nil when the text doesn't name a person's place.
    static func contactName(in destination: String) -> String? {
        let text = normalise(destination)
        if let name = capture(text, #"^(.+?)'s (house|place|home|flat|apartment|unit|work|office)$"#, group: 1) { return name }
        if let name = capture(text, #"^(.+?)'s$"#, group: 1) { return name }
        return nil
    }

    // MARK: - Pieces

    static func normalise(_ raw: String) -> String {
        var text = raw.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[\.\!\?,;]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(" please") { text = String(text.dropLast(7)) }
        return text
    }

    private static func stripPoliteness(_ text: String) -> String {
        var text = text
        let prefixes = ["hey siri ", "hey ", "ok ", "okay ", "please ", "can you ", "could you ", "would you ", "will you ",
                        "please ", "can you please ", "i'd like you to ", "i want you to "]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where text.hasPrefix(prefix) && text.count > prefix.count {
                text = String(text.dropFirst(prefix.count))
                changed = true
            }
        }
        return text
    }

    /// Splits "go to X but stop for petrol on the way" into ("go to x", "petrol").
    private static func splitAlongTheWay(_ text: String) -> (String, String?) {
        let pattern = #"(?:,? ?(?:but|and|then)? ?)(?:i want to |i need to |we need to |let's |can we )?(?:stop|stopping|pull in|pull over|get|grab|fill up|top up)(?: off)?(?: (?:for|at|to get|to grab|with))? (?:a |an |some |the )?(.+?) (?:on the way|along the way|on my way|on our way|en route|on route|along the route)(?: there)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text),
              let what = Range(match.range(at: 1), in: text) else {
            if let fill = capture(text, #"^(.*?)(?:,? (?:but|and) )?(?:fill up|top up|refuel)(?: on the way)?$"#, group: 1) {
                return (fill.trimmingCharacters(in: .whitespaces), "petrol station")
            }
            return (text, nil)
        }
        let main = String(text[..<whole.lowerBound]).trimmingCharacters(in: .whitespaces)
        return (main, String(text[what]))
    }

    /// "suggest some places for dinner near me" → "dinner".
    private static func placeQuery(_ text: String) -> String? {
        let verbs = #"^(find|find me|search for|search|look for|look up|show me|suggest|recommend|any|are there any|is there an?|where's|where is|where can i get|where can i find|i need|i'm hungry for|i want|i feel like|get me)( an?| some| the| good| nice| nearby| a good| some good)* "#
        guard let range = text.range(of: verbs, options: .regularExpression) else {
            // A bare category: "petrol", "coffee nearby".
            let bare = trimLocation(text)
            return PlaceCategory.match(bare) != nil ? bare : nil
        }
        var query = String(text[range.upperBound...])
        query = query.replacingOccurrences(of: #"^(places|place|spots|somewhere|options|restaurants?)( (for|to( get| have)?|with|that (do|serve)))? "#,
                                           with: "", options: .regularExpression)
        query = trimLocation(query)
        if ["places", "somewhere", "something", ""].contains(query) { return nil }
        if PlaceCategory.match(query)?.isMeal == true { return "restaurant" }
        return query
    }

    private static func trimLocation(_ text: String) -> String {
        text.replacingOccurrences(of: #" ?(near me|nearby|near here|around here|close by|close to me|around me|in the area|on the way|near (my |the )?destination|near there|at (my |the )?destination|around (my |the )?destination|close to (my |the )?destination)$"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func cleanPlace(_ text: String) -> String {
        var place = text.trimmingCharacters(in: .whitespaces)
        for article in ["the ", "a "] where place.hasPrefix(article) && place.count > article.count + 2 {
            // Keep "The Glass Den"-style names when they're the whole thing; drop "the" only before a generic word.
            if PlaceCategory.match(String(place.dropFirst(article.count))) != nil { place = String(place.dropFirst(article.count)) }
        }
        return place
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func capture(_ text: String, _ pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range(at: group).location != NSNotFound,
              let range = Range(match.range(at: group), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// Everyday words for kinds of place, mapped to a search phrase and a MapKit category.
struct PlaceCategory: Equatable {
    var query: String
    var category: MKPointOfInterestCategory?
    var isMeal = false

    private static let table: [(words: [String], query: String, category: MKPointOfInterestCategory?, meal: Bool)] = [
        (["petrol", "fuel", "gas station", "servo", "service station", "petrol station", "diesel", "gas"], "petrol station", .gasStation, false),
        (["ev charger", "charger", "charging", "charging station", "supercharger", "ev charging"], "EV charger", .evCharger, false),
        (["coffee", "cafe", "café", "latte"], "cafe", .cafe, false),
        (["dinner", "lunch", "breakfast", "brunch", "food", "something to eat", "eat", "restaurant", "restaurants", "a bite"], "restaurant", .restaurant, true),
        (["toilet", "toilets", "restroom", "bathroom", "loo"], "public toilet", .restroom, false),
        (["parking", "car park", "carpark"], "parking", .parking, false),
        (["supermarket", "groceries", "grocery store"], "supermarket", .foodMarket, false),
        (["pharmacy", "chemist"], "pharmacy", .pharmacy, false),
        (["atm", "cash"], "ATM", .atm, false),
        (["bakery", "bread", "pastries"], "bakery", .bakery, false),
        (["pub", "bar", "beer"], "pub", .brewery, false),
        (["hotel", "motel", "somewhere to stay"], "hotel", .hotel, false),
        (["hospital", "emergency"], "hospital", .hospital, false),
    ]

    static func match(_ text: String) -> PlaceCategory? {
        var t = text.lowercased().trimmingCharacters(in: .whitespaces)
        // "a bakery", "the nearest servo": generic phrasing. A name that merely ends in a
        // category word ("Corner Bakery") is a specific place, not a category search.
        let generic = ["a ", "an ", "the ", "some ", "nearest ", "closest ", "nearby ", "cheapest ", "good ", "any "]
        var stripped = true
        while stripped {
            stripped = false
            for g in generic where t.hasPrefix(g) { t.removeFirst(g.count); stripped = true }
        }
        guard !t.isEmpty else { return nil }
        for row in table {
            if row.words.contains(where: { t == $0 || t == $0 + "s" || t.hasPrefix($0 + " ") || t.hasPrefix($0 + "s ") }) {
                return PlaceCategory(query: row.query, category: row.category, isMeal: row.meal)
            }
        }
        return nil
    }
}
