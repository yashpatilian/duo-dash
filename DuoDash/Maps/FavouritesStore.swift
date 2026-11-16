import MapKit
import Observation

/// A saved coordinate with a display name. Also used by `NavigationModel` to
/// resume a route after the app was killed, so keep it backwards compatible.
struct SavedPlace: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
    /// One-line address, when known (added with configurable places; older data has none).
    var address: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func mapItem(fallbackName: String) -> MKMapItem {
        let item = MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
        item.name = name.isEmpty ? fallbackName : name
        return item
    }
}

/// One user-configurable saved place: a name, an icon (emoji or SF Symbol) and,
/// once set, a location.
struct Favourite: Codable, Equatable, Identifiable {
    /// Stable id. The original places keep "home" / "work" / "uni".
    var id: String
    var name: String
    /// A single emoji chosen by the user. Wins over `symbol` when set.
    var emoji: String?
    /// SF Symbol shown when there's no emoji.
    var symbol: String?
    var location: SavedPlace?

    static let defaultSymbol = "mappin.and.ellipse"

    var isSet: Bool { location != nil }
    var displaySymbol: String { symbol ?? Self.defaultSymbol }

    /// Accessibility id of its tile: `fav.<slug>`, e.g. "fav.work", "fav.home-2".
    var tileIdentifier: String { "fav.\(Self.slug(name))" }

    func mapItem() -> MKMapItem? { location?.mapItem(fallbackName: name) }

    static func slug(_ name: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            // Letters and digits only (CharacterSet.alphanumerics also counts emoji variation selectors).
            if scalar.properties.isAlphabetic || scalar.properties.generalCategory == .decimalNumber {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return slug.isEmpty ? "place" : slug
    }

    /// Returns `text` as one emoji (trimmed), or nil when it isn't exactly one emoji.
    static func validatedEmoji(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let character = trimmed.first else { return nil }
        let scalars = character.unicodeScalars
        // Digits, # and * are "emoji" scalars too; only accept them as keycaps.
        let isEmoji = scalars.contains { $0.properties.isEmojiPresentation }
            || (scalars.count > 1 && scalars.contains { $0.properties.isEmoji && $0.value > 0x7F })
            || scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
        return isEmoji ? String(character) : nil
    }
}

/// The user's saved places, in their order, kept on the device in UserDefaults.
@MainActor
@Observable
final class FavouritesStore {
    private(set) var places: [Favourite] = []

    private let defaults: UserDefaults
    /// The ordered list (current format).
    static let key = "places.v2"
    /// The original Home / Work / Uni dictionary. Read once for migration, never written or removed.
    static let legacyKey = "favourites.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if ProcessInfo.processInfo.arguments.contains("-SeedPlaces") {
            // Sample places for UI tests and screenshots (around Apple Park, Cupertino).
            places = Self.samplePlaces
            persist()
            return
        }
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Favourite].self, from: data) {
            places = decoded
        } else {
            places = Self.migrated(from: defaults.data(forKey: Self.legacyKey))
            persist()
        }
    }

    static let samplePlaces: [Favourite] = [
        Favourite(id: "home", name: "Home", symbol: "house.fill",
                  location: SavedPlace(name: "Home", latitude: 37.3230, longitude: -122.0322, address: "Cupertino")),
        Favourite(id: "work", name: "Work", symbol: "briefcase.fill",
                  location: SavedPlace(name: "Work", latitude: 37.3349, longitude: -122.0090, address: "Apple Park")),
        Favourite(id: "gym", name: "Gym", emoji: "🏋️",
                  location: SavedPlace(name: "Gym", latitude: 37.3236, longitude: -122.0094, address: "Stevens Creek Blvd")),
        Favourite(id: "coffee", name: "Coffee", emoji: "☕️",
                  location: SavedPlace(name: "Coffee", latitude: 37.3318, longitude: -122.0312, address: "De Anza Blvd")),
    ]

    /// Builds the list from the old `[home|work|uni: SavedPlace]` data: Home, a new
    /// unset "Home 2", Work, Uni, keeping every saved location as it was.
    static func migrated(from legacy: Data?) -> [Favourite] {
        let old = legacy.flatMap { try? JSONDecoder().decode([String: SavedPlace].self, from: $0) } ?? [:]
        return [
            Favourite(id: "home", name: "Home", symbol: "house.fill", location: old["home"]),
            Favourite(id: "home2", name: "Home 2", symbol: "house.fill", location: nil),
            Favourite(id: "work", name: "Work", symbol: "briefcase.fill", location: old["work"]),
            Favourite(id: "uni", name: "Uni", symbol: "graduationcap.fill", location: old["uni"]),
        ]
    }

    // MARK: Reading

    func place(id: String) -> Favourite? { places.first { $0.id == id } }

    func mapItem(for id: String) -> MKMapItem? { place(id: id)?.mapItem() }

    // MARK: Editing

    /// Adds a place at the end. Blank names become "New place".
    @discardableResult
    func add(name: String, emoji: String? = nil, location: SavedPlace? = nil) -> Favourite {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = Favourite(id: UUID().uuidString,
                              name: trimmed.isEmpty ? "New place" : trimmed,
                              emoji: emoji.flatMap(Favourite.validatedEmoji),
                              symbol: nil,
                              location: location)
        places.append(place)
        persist()
        return place
    }

    /// Adds a place named after and located at `item`.
    @discardableResult
    func add(item: MKMapItem) -> Favourite {
        add(name: item.name ?? "New place", location: Self.savedPlace(for: item, fallbackName: "New place"))
    }

    /// Renames a place. Returns false (and changes nothing) for a blank name.
    @discardableResult
    func rename(_ id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return update(id) { $0.name = trimmed }
    }

    /// Sets the place's emoji. Returns false for anything that isn't a single emoji.
    @discardableResult
    func setEmoji(_ id: String, to text: String) -> Bool {
        guard let emoji = Favourite.validatedEmoji(text) else { return false }
        return update(id) { $0.emoji = emoji }
    }

    /// Goes back to the place's SF Symbol.
    func clearEmoji(_ id: String) {
        update(id) { $0.emoji = nil }
    }

    func setLocation(_ id: String, item: MKMapItem) {
        let fallback = place(id: id)?.name ?? "Place"
        update(id) { $0.location = Self.savedPlace(for: item, fallbackName: fallback) }
    }

    func setLocation(_ id: String, coordinate: CLLocationCoordinate2D, name: String? = nil, address: String? = nil) {
        let fallback = place(id: id)?.name ?? "Place"
        update(id) {
            $0.location = SavedPlace(name: name ?? fallback, latitude: coordinate.latitude,
                                     longitude: coordinate.longitude, address: address)
        }
    }

    func clearLocation(_ id: String) {
        update(id) { $0.location = nil }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        places.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func delete(_ id: String) {
        places.removeAll { $0.id == id }
        persist()
    }

    // MARK: Private

    @discardableResult
    private func update(_ id: String, _ change: (inout Favourite) -> Void) -> Bool {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return false }
        change(&places[index])
        persist()
        return true
    }

    private static func savedPlace(for item: MKMapItem, fallbackName: String) -> SavedPlace {
        let coordinate = item.location.coordinate
        return SavedPlace(name: item.name ?? fallbackName, latitude: coordinate.latitude,
                          longitude: coordinate.longitude, address: item.addressLine)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(places) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
