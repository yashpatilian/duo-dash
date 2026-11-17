import Foundation
import Observation

/// One card on the Home dashboard.
enum HomeCard: String, CaseIterable, Identifiable, Sendable {
    case map, nowPlaying, nextTurn, extra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: "Map"
        case .nowPlaying: "Now Playing"
        case .nextTurn: "Directions & Places"
        case .extra: "Third card"
        }
    }

    var symbol: String {
        switch self {
        case .map: "map.fill"
        case .nowPlaying: "music.note"
        case .nextTurn: "arrow.triangle.turn.up.right.diamond.fill"
        case .extra: "square.grid.2x2.fill"
        }
    }
}

/// What the third card on Home shows.
enum HomeExtraCard: String, CaseIterable, Identifiable, Sendable {
    /// The free behaviour: car data when an OBD adapter is connected, else the next event, else contacts.
    case automatic, car, nextEvent, contacts, weather

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .car: "Car"
        case .nextEvent: "Next Event"
        case .contacts: "Favourite Contacts"
        case .weather: "Weather"
        }
    }

    var subtitle: String? {
        self == .automatic ? "Car when connected, else next event, else contacts" : nil
    }
}

/// Duo Dash Pro → Home layout: the order of the Home cards and what the third one shows.
/// Saved in UserDefaults; anything unknown or missing in the saved order is repaired.
/// Without Pro, Home uses the original layout.
@MainActor
@Observable
final class HomeLayoutSettings {
    static let defaultOrder: [HomeCard] = [.map, .nowPlaying, .nextTurn, .extra]

    var order: [HomeCard] {
        didSet {
            let repaired = Self.repair(order.map(\.rawValue))
            if repaired != order { order = repaired; return }
            defaults.set(order.map(\.rawValue), forKey: Keys.order)
        }
    }

    var extra: HomeExtraCard {
        didSet { defaults.set(extra.rawValue, forKey: Keys.extra) }
    }

    /// Mirrors `ProStore.isPro` (set by the app). Not saved.
    var isProActive = false

    enum Keys {
        static let order = "home.cardOrder"
        static let extra = "home.extraCard"
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = Self.repair(defaults.stringArray(forKey: Keys.order) ?? [])
        extra = defaults.string(forKey: Keys.extra).flatMap(HomeExtraCard.init(rawValue:)) ?? .automatic
    }

    /// Known cards in the saved order, each once, then any missing ones in the default order.
    static func repair(_ saved: [String]) -> [HomeCard] {
        var result: [HomeCard] = []
        for raw in saved {
            if let card = HomeCard(rawValue: raw), !result.contains(card) { result.append(card) }
        }
        for card in defaultOrder where !result.contains(card) { result.append(card) }
        return result
    }

    var isCustomised: Bool { order != Self.defaultOrder || extra != .automatic }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var copy = order
        copy.move(fromOffsets: source, toOffset: destination)
        order = copy
    }

    func reset() {
        order = Self.defaultOrder
        extra = .automatic
    }

    // MARK: What Home draws

    /// The user's order with Pro; the default without.
    var effectiveOrder: [HomeCard] { isProActive ? order : Self.defaultOrder }
    var effectiveExtra: HomeExtraCard { isProActive ? extra : .automatic }

    /// Wide windows: is the map the left column? It is when it's in the first half of the order.
    var mapOnLeft: Bool {
        let index = effectiveOrder.firstIndex(of: .map) ?? 0
        return index < (effectiveOrder.count + 1) / 2
    }

    /// The column of cards beside the map in wide windows, in order.
    var wideColumn: [HomeCard] { effectiveOrder.filter { $0 != .map } }

    /// Narrow windows (cover screen, Split View): the map always first, then directions and
    /// now playing. The original order is directions first; a customised order is followed.
    var narrowCards: [HomeCard] {
        let original: [HomeCard] = [.nextTurn, .nowPlaying]
        guard isProActive, order != Self.defaultOrder else { return original }
        return order.filter { original.contains($0) }
    }
}
