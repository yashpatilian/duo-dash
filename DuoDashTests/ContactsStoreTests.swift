import XCTest
@testable import DuoDash

@MainActor
final class ContactsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "ContactsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> ContactsStore { ContactsStore(defaults: defaults, seed: false) }
    private func person(_ name: String, _ number: String) -> Recipient { Recipient(name: name, number: number) }

    func testFavouritesPersistAcrossInstances() {
        let store = makeStore()
        store.addFavourite(name: "Alex", number: LabeledNumber(label: "mobile", number: "0400 000 001"),
                           contactID: "c1", thumbnail: Data([1, 2, 3]))
        store.addFavourite(name: "Bo", number: LabeledNumber(label: "work", number: "0400 000 002"),
                           contactID: "c2", thumbnail: nil)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.favourites.map(\.name), ["Alex", "Bo"])
        XCTAssertEqual(reloaded.favourites[0].contactID, "c1")
        XCTAssertEqual(reloaded.favourites[0].number, "0400 000 001")
        XCTAssertEqual(reloaded.favourites[0].numberLabel, "mobile")
        XCTAssertEqual(reloaded.favourites[0].thumbnail, Data([1, 2, 3]))
    }

    func testAddingTheSameContactAndNumberTwiceDoesNotDuplicate() {
        let store = makeStore()
        let number = LabeledNumber(label: "mobile", number: "+61 400 000 001")
        store.addFavourite(name: "Alex", number: number, contactID: "c1", thumbnail: nil)
        store.addFavourite(name: "Alex Chen", number: LabeledNumber(label: "mobile", number: "+61400000001"),
                           contactID: "c1", thumbnail: nil)
        XCTAssertEqual(store.favourites.count, 1)
        XCTAssertEqual(store.favourites[0].name, "Alex Chen", "name refreshed on re-add")
    }

    func testReorderAndRemoveFavourites() {
        let store = makeStore()
        for (i, name) in ["A", "B", "C", "D"].enumerated() {
            store.addFavourite(name: name, number: LabeledNumber(label: "mobile", number: "040000000\(i)"),
                               contactID: name, thumbnail: nil)
        }
        store.moveFavourites(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(store.favourites.map(\.name), ["D", "A", "B", "C"])
        store.moveFavourites(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(store.favourites.map(\.name), ["A", "B", "C", "D"])
        var expected = store.favourites.map(\.name)
        expected.move(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        store.moveFavourites(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        XCTAssertEqual(store.favourites.map(\.name), expected, "matches Array.move semantics")

        store.removeFavourite(id: store.favourites[0].id)
        store.removeFavourites(atOffsets: IndexSet(integer: 0))
        XCTAssertEqual(makeStore().favourites.count, 2, "removals persisted")
    }

    func testRecentsAreNewestFirstAndCapped() {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(ContactsStore.recentsCap + 10) {
            store.logRecent(i.isMultiple(of: 2) ? .call : .message, to: person("P\(i)", "0400\(i)"),
                            at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(store.recents.count, ContactsStore.recentsCap)
        XCTAssertEqual(store.recents.first?.name, "P59", "newest first")
        XCTAssertEqual(store.recents.last?.name, "P10", "oldest dropped past the cap")
        XCTAssertEqual(store.recents, store.recents.sorted { $0.date > $1.date })

        // An older entry logged late still lands in date order.
        store.logRecent(.call, to: person("Late", "1"), at: start.addingTimeInterval(30.5))
        XCTAssertEqual(store.recents, store.recents.sorted { $0.date > $1.date })

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.recents.count, ContactsStore.recentsCap)
        XCTAssertEqual(reloaded.recents.first?.name, "P59")
    }

    func testClearRecentsByKind() {
        let store = makeStore()
        store.logRecent(.call, to: person("A", "1"))
        store.logRecent(.message, to: person("B", "2"))
        store.logRecent(.call, to: person("C", "3"))
        XCTAssertEqual(store.recents(of: .call).map(\.name), ["C", "A"])
        store.clearRecents(of: .call)
        XCTAssertEqual(store.recents.map(\.name), ["B"])
        store.clearRecents()
        XCTAssertTrue(makeStore().recents.isEmpty)
    }

    func testNumberChoice() {
        let mobile = LabeledNumber(label: "mobile", number: "+61 400 000 001")
        let home = LabeledNumber(label: "home", number: "(03) 9000 0001")
        XCTAssertEqual(NumberChoice.resolve([]), .none)
        XCTAssertEqual(NumberChoice.resolve([LabeledNumber(label: "x", number: "n/a")]), .none)
        XCTAssertEqual(NumberChoice.resolve([mobile]), .single(mobile))
        XCTAssertEqual(NumberChoice.resolve([mobile, home]), .multiple([mobile, home]))
        // The same number stored twice with different formatting is one choice.
        XCTAssertEqual(NumberChoice.resolve([mobile, LabeledNumber(label: "iPhone", number: "+61400000001")]), .single(mobile))
        // A previously chosen number is used without asking again.
        XCTAssertEqual(NumberChoice.resolve([mobile, home], preferred: "0499 999 999"), .multiple([mobile, home]))
        XCTAssertEqual(NumberChoice.resolve([mobile, home], preferred: "(03) 9000-0001"), .single(home))
    }

    func testDialURL() {
        XCTAssertEqual(PhoneNumber.dialURL("+61 (400) 000-001")?.absoluteString, "tel://+61400000001")
        XCTAssertEqual(PhoneNumber.digits("1+2"), "12", "only a leading + is kept")
        XCTAssertNotNil(PhoneNumber.dialURL("*#06#"))
        XCTAssertNil(PhoneNumber.dialURL("call me"))
        XCTAssertEqual(PhoneNumber.faceTimeAudioURL("+61 (400) 000-001")?.absoluteString, "facetime-audio://+61400000001")
        XCTAssertNil(PhoneNumber.faceTimeAudioURL("call me"))
    }

    func testSeedModeNeverTouchesRealData() {
        let store = ContactsStore(defaults: defaults, seed: true)
        XCTAssertTrue(store.isSeeded)
        XCTAssertEqual(store.access, .authorized)
        XCTAssertFalse(store.favourites.isEmpty)
        XCTAssertFalse(store.directory.isEmpty)
        XCTAssertEqual(store.search("jordan").map(\.name), ["Jordan Lee"])
        XCTAssertEqual(store.search("000 002").map(\.name), ["Priya Patel"], "search by number")
    }
}
