import Foundation
import Observation
import Contacts
import UIKit

/// One phone number on a contact, with its label ("mobile", "work", …).
struct LabeledNumber: Codable, Equatable, Hashable, Identifiable {
    var label: String
    var number: String
    var id: String { label + "|" + number }
}

/// A person on the user's own Duo Dash favourites list (not the Phone app's
/// Favourites, which third-party apps can't read).
struct FavouriteContact: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// `CNContact.identifier`, used to refresh the name and photo later.
    var contactID: String?
    var name: String
    var number: String
    var numberLabel: String = ""
    var thumbnail: Data?

    var recipient: Recipient {
        Recipient(name: name, number: number, contactID: contactID, thumbnail: thumbnail)
    }
}

/// Someone to call or text.
struct Recipient: Equatable, Identifiable {
    var name: String
    var number: String
    var contactID: String?
    var thumbnail: Data?
    var id: String { (contactID ?? "") + "|" + number }

    /// Name for display, falling back to the number.
    var displayName: String { name.isEmpty ? number : name }
}

/// A call or message started from Duo Dash (the system call log and Messages
/// history are off limits to third-party apps).
struct RecentEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case call, message }

    var id: UUID = UUID()
    var kind: Kind
    var name: String
    var number: String
    var contactID: String?
    var date: Date

    var recipient: Recipient { Recipient(name: name, number: number, contactID: contactID) }
}

/// A contact from the address book (Contacts tab), only held in memory.
struct DirectoryContact: Identifiable, Equatable {
    var id: String
    var name: String
    var numbers: [LabeledNumber]
    var thumbnail: Data?
}

/// What to do when a contact is chosen for a call or a favourite.
enum NumberChoice: Equatable {
    /// No usable number.
    case none
    /// Exactly one number (or a preferred one matched): use it straight away.
    case single(LabeledNumber)
    /// Several numbers: the user picks one.
    case multiple([LabeledNumber])

    static func resolve(_ numbers: [LabeledNumber], preferred: String? = nil) -> NumberChoice {
        let usable = numbers.filter { !PhoneNumber.digits($0.number).isEmpty }
        var seen = Set<String>()
        let unique = usable.filter { seen.insert(PhoneNumber.digits($0.number)).inserted }
        if let preferred, let match = unique.first(where: { PhoneNumber.digits($0.number) == PhoneNumber.digits(preferred) }) {
            return .single(match)
        }
        switch unique.count {
        case 0: return .none
        case 1: return .single(unique[0])
        default: return .multiple(unique)
        }
    }
}

enum PhoneNumber {
    /// Digits plus a leading +, *, # kept, everything else dropped.
    static func digits(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            if ch.isASCII, ch.isNumber || ch == "*" || ch == "#" { out.append(ch) }
            else if ch == "+", out.isEmpty { out.append(ch) }
        }
        return out
    }

    /// `tel:` URL for dialling, or nil when there is nothing to dial.
    static func dialURL(_ raw: String) -> URL? {
        let cleaned = digits(raw)
        guard !cleaned.isEmpty else { return nil }
        let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "+"))) ?? cleaned
        return URL(string: "tel://\(encoded)")
    }

    /// `facetime-audio:` URL, the fallback on devices without a cellular radio (iPad).
    static func faceTimeAudioURL(_ raw: String) -> URL? {
        let cleaned = digits(raw)
        guard !cleaned.isEmpty else { return nil }
        let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "+"))) ?? cleaned
        return URL(string: "facetime-audio://\(encoded)")
    }

    /// Contacts' label (e.g. `_$!<Mobile>!$_`) as plain text.
    static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "phone" }
        return CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: raw)
    }
}

/// Duo Dash's favourites and recents, kept on the device in UserDefaults, plus a
/// read-only view of the address book for the Contacts tab.
@MainActor
@Observable
final class ContactsStore {
    private(set) var favourites: [FavouriteContact] = []
    private(set) var recents: [RecentEntry] = []

    enum Access: Equatable { case notDetermined, authorized, limited, denied }
    private(set) var access: Access
    private(set) var directory: [DirectoryContact] = []
    private(set) var isLoadingDirectory = false

    /// A person the Messages screen should open a compose view for (set from
    /// anywhere, e.g. the Home favourites strip).
    var pendingCompose: Recipient?

    /// Short-lived message for the user (e.g. "this device can't make calls").
    var notice: String?

    static let recentsCap = 50

    /// Fake data only: never touches the real Contacts database (UI tests).
    let isSeeded: Bool

    private let defaults: UserDefaults
    private static let favouritesKey = "contacts.favourites.v1"
    private static let recentsKey = "contacts.recents.v1"

    init(defaults: UserDefaults = .standard, seed: Bool = ProcessInfo.processInfo.arguments.contains("-SeedContacts")) {
        self.defaults = defaults
        self.isSeeded = seed
        self.access = seed ? .authorized : Self.systemAccess()
        if seed {
            favourites = Self.seedFavourites
            recents = Self.seedRecents
            directory = Self.seedDirectory
            save()
        } else {
            favourites = Self.decode([FavouriteContact].self, defaults.data(forKey: Self.favouritesKey)) ?? []
            recents = Self.decode([RecentEntry].self, defaults.data(forKey: Self.recentsKey)) ?? []
        }
    }

    // MARK: Favourites

    /// Adds a favourite (or updates the number if that contact is already there).
    @discardableResult
    func addFavourite(name: String, number: LabeledNumber, contactID: String?, thumbnail: Data?) -> FavouriteContact {
        let label = number.label
        if let index = favourites.firstIndex(where: { fav in
            if let contactID, fav.contactID == contactID { return PhoneNumber.digits(fav.number) == PhoneNumber.digits(number.number) }
            return contactID == nil && PhoneNumber.digits(fav.number) == PhoneNumber.digits(number.number)
        }) {
            favourites[index].name = name
            favourites[index].thumbnail = thumbnail ?? favourites[index].thumbnail
            save()
            return favourites[index]
        }
        let fav = FavouriteContact(contactID: contactID, name: name, number: number.number,
                                   numberLabel: label, thumbnail: thumbnail)
        favourites.append(fav)
        save()
        return fav
    }

    func removeFavourite(id: UUID) {
        favourites.removeAll { $0.id == id }
        save()
    }

    func removeFavourites(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) where favourites.indices.contains(index) {
            favourites.remove(at: index)
        }
        save()
    }

    func moveFavourites(fromOffsets source: IndexSet, toOffset destination: Int) {
        // Same semantics as Array.move(fromOffsets:toOffset:) (SwiftUI's onMove).
        let moving = source.sorted().map { favourites[$0] }
        var rest = favourites.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        favourites = rest
        save()
    }

    func isFavourite(contactID: String?, number: String) -> Bool {
        favourites.contains { fav in
            (contactID != nil && fav.contactID == contactID) || PhoneNumber.digits(fav.number) == PhoneNumber.digits(number)
        }
    }

    // MARK: Recents

    func logRecent(_ kind: RecentEntry.Kind, to recipient: Recipient, at date: Date = Date()) {
        recents.insert(RecentEntry(kind: kind, name: recipient.name, number: recipient.number,
                                   contactID: recipient.contactID, date: date), at: 0)
        recents.sort { $0.date > $1.date }
        if recents.count > Self.recentsCap { recents.removeLast(recents.count - Self.recentsCap) }
        save()
    }

    func recents(of kind: RecentEntry.Kind) -> [RecentEntry] {
        recents.filter { $0.kind == kind }
    }

    func clearRecents(of kind: RecentEntry.Kind? = nil) {
        if let kind { recents.removeAll { $0.kind == kind } } else { recents.removeAll() }
        save()
    }

    /// Photo for a recent, taken from a matching favourite.
    func thumbnail(for recipient: Recipient) -> Data? {
        if let data = recipient.thumbnail { return data }
        return favourites.first { fav in
            (recipient.contactID != nil && fav.contactID == recipient.contactID)
                || PhoneNumber.digits(fav.number) == PhoneNumber.digits(recipient.number)
        }?.thumbnail
    }

    // MARK: Calling

    /// Starts a call through iOS (which shows its own confirm prompt) and logs it.
    func call(_ recipient: Recipient) {
        guard let url = PhoneNumber.dialURL(recipient.number) else {
            notice = "That number can't be dialled."
            return
        }
        UIApplication.shared.open(url) { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                if success {
                    self.logRecent(.call, to: recipient)
                } else if let facetime = PhoneNumber.faceTimeAudioURL(recipient.number) {
                    // iPad, or an iPhone without a SIM: fall back to a FaceTime audio call.
                    UIApplication.shared.open(facetime) { ok in
                        Task { @MainActor in
                            if ok { self.logRecent(.call, to: recipient) }
                            else { self.notice = "This device can't make phone calls. On iPad, turn on Calls from iPhone in Settings → FaceTime." }
                        }
                    }
                } else {
                    self.notice = "This device can't make phone calls."
                }
            }
        }
    }

    // MARK: Address book

    private static func systemAccess() -> Access {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .authorized
        case .limited: .limited
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Asks for Contacts access (only when the Contacts tab opens), then loads it.
    func prepareDirectory() async {
        guard !isSeeded else { return }
        access = Self.systemAccess()
        if access == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
            access = Self.systemAccess()
        }
        if access == .authorized || access == .limited {
            await loadDirectory()
            await refreshFavouritesFromContacts()
        }
    }

    func loadDirectory() async {
        guard !isSeeded, access == .authorized || access == .limited else { return }
        isLoadingDirectory = true
        let loaded = await Task.detached(priority: .userInitiated) { Self.fetchDirectory() }.value
        directory = loaded
        isLoadingDirectory = false
    }

    /// Picks up name and photo changes for favourites from Contacts, if allowed.
    func refreshFavouritesFromContacts() async {
        guard !isSeeded else { return }
        access = Self.systemAccess()
        guard access == .authorized || access == .limited else { return }
        let ids = favourites.compactMap(\.contactID)
        guard !ids.isEmpty else { return }
        let fresh = await Task.detached(priority: .utility) { Self.fetchSummaries(ids: ids) }.value
        var changed = false
        for index in favourites.indices {
            guard let id = favourites[index].contactID, let found = fresh[id] else { continue }
            if !found.name.isEmpty, found.name != favourites[index].name {
                favourites[index].name = found.name; changed = true
            }
            if let photo = found.thumbnail, photo != favourites[index].thumbnail {
                favourites[index].thumbnail = photo; changed = true
            }
        }
        if changed { save() }
    }

    /// Contacts whose name or number matches `query`.
    func search(_ query: String) -> [DirectoryContact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        let digits = PhoneNumber.digits(trimmed)
        return directory.filter { contact in
            contact.name.localizedStandardContains(trimmed)
                || (digits.count >= 3 && contact.numbers.contains { PhoneNumber.digits($0.number).contains(digits) })
        }
    }

    nonisolated private static var fetchKeys: [CNKeyDescriptor] {
        [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
         CNContactPhoneNumbersKey as CNKeyDescriptor,
         CNContactThumbnailImageDataKey as CNKeyDescriptor,
         CNContactOrganizationNameKey as CNKeyDescriptor]
    }

    nonisolated static func displayName(of contact: CNContact) -> String {
        let full = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        if !full.isEmpty { return full }
        if contact.isKeyAvailable(CNContactOrganizationNameKey) { return contact.organizationName }
        return ""
    }

    nonisolated static func numbers(of contact: CNContact) -> [LabeledNumber] {
        guard contact.isKeyAvailable(CNContactPhoneNumbersKey) else { return [] }
        return contact.phoneNumbers.map {
            LabeledNumber(label: PhoneNumber.label($0.label), number: $0.value.stringValue)
        }
    }

    nonisolated static func thumbnail(of contact: CNContact) -> Data? {
        contact.isKeyAvailable(CNContactThumbnailImageDataKey) ? contact.thumbnailImageData : nil
    }

    nonisolated private static func fetchDirectory() -> [DirectoryContact] {
        let request = CNContactFetchRequest(keysToFetch: fetchKeys)
        request.sortOrder = .userDefault
        var out: [DirectoryContact] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            let numbers = numbers(of: contact)
            guard !numbers.isEmpty else { return }
            out.append(DirectoryContact(id: contact.identifier, name: displayName(of: contact),
                                        numbers: numbers, thumbnail: thumbnail(of: contact)))
        }
        return out
    }

    nonisolated private static func fetchSummaries(ids: [String]) -> [String: (name: String, thumbnail: Data?)] {
        let predicate = CNContact.predicateForContacts(withIdentifiers: ids)
        let contacts = (try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: fetchKeys)) ?? []
        var out: [String: (name: String, thumbnail: Data?)] = [:]
        for contact in contacts { out[contact.identifier] = (displayName(of: contact), thumbnail(of: contact)) }
        return out
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(favourites) { defaults.set(data, forKey: Self.favouritesKey) }
        if let data = try? JSONEncoder().encode(recents) { defaults.set(data, forKey: Self.recentsKey) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: Seed data (UI tests, -SeedContacts)

    static let seedFavourites: [FavouriteContact] = [
        FavouriteContact(contactID: "seed-1", name: "Alex Chen", number: "+61 400 000 001", numberLabel: "mobile"),
        FavouriteContact(contactID: "seed-2", name: "Priya Patel", number: "+61 400 000 002", numberLabel: "mobile"),
        FavouriteContact(contactID: "seed-3", name: "Sam Taylor", number: "+61 400 000 003", numberLabel: "work"),
    ]

    static var seedRecents: [RecentEntry] {
        let now = Date()
        return [
            RecentEntry(kind: .call, name: "Alex Chen", number: "+61 400 000 001", contactID: "seed-1",
                        date: now.addingTimeInterval(-600)),
            RecentEntry(kind: .message, name: "Priya Patel", number: "+61 400 000 002", contactID: "seed-2",
                        date: now.addingTimeInterval(-3600)),
        ]
    }

    static let seedDirectory: [DirectoryContact] = [
        DirectoryContact(id: "seed-1", name: "Alex Chen", numbers: [LabeledNumber(label: "mobile", number: "+61 400 000 001")]),
        DirectoryContact(id: "seed-4", name: "Jordan Lee", numbers: [
            LabeledNumber(label: "mobile", number: "+61 400 000 004"),
            LabeledNumber(label: "home", number: "+61 3 9000 0004"),
        ]),
        DirectoryContact(id: "seed-2", name: "Priya Patel", numbers: [LabeledNumber(label: "mobile", number: "+61 400 000 002")]),
        DirectoryContact(id: "seed-3", name: "Sam Taylor", numbers: [LabeledNumber(label: "work", number: "+61 400 000 003")]),
    ]
}
