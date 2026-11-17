import XCTest
import MapKit
@testable import DuoDash

@MainActor
final class PlacesTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "test.places.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// Exactly what the old app wrote under "favourites.v1".
    private func legacyData(_ places: [String: SavedPlace]) throws -> Data {
        try JSONEncoder().encode(places)
    }

    // MARK: Migration

    func testMigrationKeepsSavedPlacesAndAddsHome2AfterHome() throws {
        let d = freshDefaults()
        let home = SavedPlace(name: "12 Smith St", latitude: 37.29, longitude: -122.04)
        let work = SavedPlace(name: "Office", latitude: 37.2, longitude: -121.9)
        let legacy = try legacyData(["home": home, "work": work])
        d.set(legacy, forKey: FavouritesStore.legacyKey)

        let store = FavouritesStore(defaults: d)
        XCTAssertEqual(store.places.map(\.name), ["Home", "Home 2", "Work", "Uni"])
        XCTAssertEqual(store.place(id: "home")?.location, home, "Home's saved address must survive")
        XCTAssertEqual(store.place(id: "work")?.location, work)
        XCTAssertNil(store.place(id: "uni")?.location)

        let home2 = store.places[1]
        XCTAssertNil(home2.location, "Home 2 starts unset")
        XCTAssertEqual(home2.symbol, "house.fill")
        XCTAssertEqual(store.places[0].symbol, "house.fill")
        XCTAssertEqual(store.places[2].symbol, "briefcase.fill")
        XCTAssertEqual(store.places[3].symbol, "graduationcap.fill")
        XCTAssertTrue(store.places.allSatisfy { $0.emoji == nil })

        // The old data is left exactly as it was.
        XCTAssertEqual(d.data(forKey: FavouritesStore.legacyKey), legacy)
    }

    func testMigrationRunsOnceAndDeletedHome2StaysDeleted() throws {
        let d = freshDefaults()
        d.set(try legacyData(["home": SavedPlace(name: "Home", latitude: 1, longitude: 2)]),
              forKey: FavouritesStore.legacyKey)
        let store = FavouritesStore(defaults: d)
        store.delete("home2")
        XCTAssertEqual(store.places.map(\.name), ["Home", "Work", "Uni"])

        let reloaded = FavouritesStore(defaults: d)
        XCTAssertEqual(reloaded.places.map(\.name), ["Home", "Work", "Uni"], "Home 2 must not come back")
        XCTAssertEqual(reloaded.place(id: "home")?.location?.latitude, 1)
        XCTAssertEqual(FavouritesStore(defaults: d).places.count, 3)
    }

    func testFreshInstallGetsDefaultPlacesUnset() {
        let store = FavouritesStore(defaults: freshDefaults())
        XCTAssertEqual(store.places.map(\.name), ["Home", "Home 2", "Work", "Uni"])
        XCTAssertTrue(store.places.allSatisfy { !$0.isSet })
    }

    func testCorruptLegacyDataStillMigrates() {
        let d = freshDefaults()
        d.set(Data("not json".utf8), forKey: FavouritesStore.legacyKey)
        XCTAssertEqual(FavouritesStore(defaults: d).places.count, 4)
    }

    // MARK: Editing

    func testAddRenameReorderDelete() {
        let d = freshDefaults()
        let store = FavouritesStore(defaults: d)
        let gym = store.add(name: "  Gym  ", emoji: "🏋️")
        XCTAssertEqual(gym.name, "Gym")
        XCTAssertEqual(gym.emoji, "🏋️")
        XCTAssertEqual(store.places.last?.id, gym.id)

        XCTAssertTrue(store.rename(gym.id, to: "Gym (North)"))
        XCTAssertFalse(store.rename(gym.id, to: "   "), "blank names are rejected")
        XCTAssertEqual(store.place(id: gym.id)?.name, "Gym (North)")

        // Move the gym to the front.
        store.move(fromOffsets: IndexSet(integer: store.places.count - 1), toOffset: 0)
        XCTAssertEqual(store.places.map(\.name), ["Gym (North)", "Home", "Home 2", "Work", "Uni"])

        store.delete("work")
        XCTAssertNil(store.place(id: "work"))
        XCTAssertEqual(FavouritesStore(defaults: d).places.map(\.name), ["Gym (North)", "Home", "Home 2", "Uni"])

        let blank = store.add(name: "")
        XCTAssertEqual(blank.name, "New place")
    }

    func testAddFromMapItemTakesNameAndLocation() {
        let store = FavouritesStore(defaults: freshDefaults())
        let item = MKMapItem(location: CLLocation(latitude: 37.282, longitude: -122.033), address: nil)
        item.name = "Central Station"
        let place = store.add(item: item)
        XCTAssertEqual(place.name, "Central Station")
        XCTAssertEqual(place.location?.latitude ?? 0, 37.282, accuracy: 1e-9)
        XCTAssertEqual(place.tileIdentifier, "fav.central-station")
    }

    func testEmojiValidation() {
        XCTAssertEqual(Favourite.validatedEmoji("☕️"), "☕️")
        XCTAssertEqual(Favourite.validatedEmoji(" 🏠 "), "🏠")
        XCTAssertEqual(Favourite.validatedEmoji("👨‍👩‍👧"), "👨‍👩‍👧", "ZWJ family is one emoji")
        XCTAssertEqual(Favourite.validatedEmoji("🇦🇺"), "🇦🇺", "flags are one emoji")
        XCTAssertEqual(Favourite.validatedEmoji("👍🏽"), "👍🏽", "skin tones are one emoji")
        XCTAssertEqual(Favourite.validatedEmoji("1️⃣"), "1️⃣", "keycaps are emoji")
        XCTAssertNil(Favourite.validatedEmoji(""))
        XCTAssertNil(Favourite.validatedEmoji("A"))
        XCTAssertNil(Favourite.validatedEmoji("1"), "a plain digit is not an emoji")
        XCTAssertNil(Favourite.validatedEmoji("#"))
        XCTAssertNil(Favourite.validatedEmoji("🏠🏢"), "only one emoji")
        XCTAssertNil(Favourite.validatedEmoji("Home"))
    }

    func testSetEmojiRejectsInvalidAndClearReturnsToSymbol() {
        let store = FavouritesStore(defaults: freshDefaults())
        XCTAssertFalse(store.setEmoji("home", to: "ab"))
        XCTAssertNil(store.place(id: "home")?.emoji)
        XCTAssertTrue(store.setEmoji("home", to: "🏡"))
        XCTAssertEqual(store.place(id: "home")?.emoji, "🏡")
        XCTAssertEqual(store.place(id: "home")?.symbol, "house.fill", "symbol kept for later")
        store.clearEmoji("home")
        XCTAssertNil(store.place(id: "home")?.emoji)
        XCTAssertNil(store.add(name: "X", emoji: "nope").emoji)
    }

    func testSpokenEmojiMatching() {
        XCTAssertEqual(PlaceEmoji.match(spoken: "Coffee"), "☕️")
        XCTAssertEqual(PlaceEmoji.match(spoken: "the gym"), "🏋️")
        XCTAssertEqual(PlaceEmoji.match(spoken: "🍕"), "🍕")
        XCTAssertNil(PlaceEmoji.match(spoken: "xylophone"))
        XCTAssertTrue(PlaceEmoji.palette.allSatisfy { Favourite.validatedEmoji($0.emoji) != nil })
    }

    func testTileIdentifiersAreSlugsOfNames() {
        let store = FavouritesStore(defaults: freshDefaults())
        XCTAssertEqual(store.places.map(\.tileIdentifier), ["fav.home", "fav.home-2", "fav.work", "fav.uni"])
        XCTAssertEqual(Favourite.slug("  Mum & Dad's "), "mum-dad-s")
        XCTAssertEqual(Favourite.slug("☕️"), "place")
    }

    // MARK: Persistence

    func testPersistenceRoundTrip() {
        let d = freshDefaults()
        let store = FavouritesStore(defaults: d)
        let beach = store.add(name: "Beach", emoji: "🏖️")
        store.setLocation(beach.id, coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.6),
                          name: "Beach", address: "Santa Cruz CA")
        store.setEmoji("uni", to: "🎓")
        store.move(fromOffsets: IndexSet(integer: 3), toOffset: 1)

        let reloaded = FavouritesStore(defaults: d)
        XCTAssertEqual(reloaded.places, store.places)
        XCTAssertEqual(reloaded.place(id: beach.id)?.location?.address, "Santa Cruz CA")
        XCTAssertEqual(reloaded.place(id: "uni")?.emoji, "🎓")
    }

    func testSavedPlaceStillDecodesWithoutAddress() throws {
        // Resume-after-kill data written before addresses existed.
        let json = Data(#"{"name":"Dest","latitude":1.5,"longitude":2.5}"#.utf8)
        let place = try JSONDecoder().decode(SavedPlace.self, from: json)
        XCTAssertEqual(place, SavedPlace(name: "Dest", latitude: 1.5, longitude: 2.5))
        XCTAssertNil(place.address)
    }

    // MARK: Map orientation

    func testMapOrientationDefaultsAndPersistence() {
        let d = freshDefaults()
        XCTAssertEqual(MapOrientation.current(d), .headingUp)
        d.set(MapOrientation.northUp.rawValue, forKey: MapOrientation.storageKey)
        XCTAssertEqual(MapOrientation.current(d), .northUp)
        XCTAssertEqual(MapOrientation.northUp.toggled, .headingUp)
    }

    func testGuidanceAlwaysFollowsHeading() {
        XCTAssertTrue(MapOrientation.northUp.followsHeading(guiding: true))
        XCTAssertFalse(MapOrientation.northUp.followsHeading(guiding: false))
        XCTAssertTrue(MapOrientation.headingUp.followsHeading(guiding: false))
        XCTAssertFalse(MapOrientation.northUp.followPosition(guiding: false).followsUserHeading)
        XCTAssertTrue(MapOrientation.northUp.followPosition(guiding: false).followsUserLocation)
        XCTAssertTrue(MapOrientation.northUp.followPosition(guiding: true).followsUserHeading)
    }

    /// One unreadable saved place (damaged, or from a newer version) must not wipe the rest.
    func testOneBadPlaceKeepsTheOthers() throws {
        let suite = "places.lossy.\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let good = try JSONEncoder().encode(FavouritesStore.samplePlaces)
        var array = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [Any])
        array.insert(["id": 42, "nonsense": true], at: 1)
        let saved = try JSONSerialization.data(withJSONObject: array)
        d.set(saved, forKey: FavouritesStore.key)
        let store = FavouritesStore(defaults: d)
        XCTAssertEqual(store.places.map(\.id), FavouritesStore.samplePlaces.map(\.id))
        XCTAssertEqual(d.data(forKey: FavouritesStore.key), saved, "saved data left alone")
        d.set(Data("not json".utf8), forKey: FavouritesStore.key)
        _ = FavouritesStore(defaults: d)
        XCTAssertEqual(d.data(forKey: FavouritesStore.key), Data("not json".utf8), "unreadable data isn't overwritten")
    }
}
