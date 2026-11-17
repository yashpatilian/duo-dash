import MapKit
import Contacts

/// The tools themselves: Maps search, Contacts, route planning, guidance.
extension AssistantModel {
    func runTool(named name: String, input: Data) async -> ToolOutcome {
        do {
            switch name {
            case AssistantTools.searchPlaces.name:
                let args = try AssistantToolSpec.decode(SearchPlacesInput.self, from: input, allowed: ["query", "near"]).validated()
                return await searchPlaces(args)
            case AssistantTools.findContactAddress.name:
                let args = try AssistantToolSpec.decode(FindContactInput.self, from: input, allowed: ["name"]).validated()
                return await findContactAddress(args)
            case AssistantTools.planRoute.name:
                let args = try AssistantToolSpec.decode(PlanRouteInput.self, from: input,
                                                        allowed: ["destination", "stops", "stop_along_the_way", "start_now"]).validated()
                return await planRoute(args)
            case AssistantTools.addStop.name:
                let args = try AssistantToolSpec.decode(AddStopInput.self, from: input, allowed: ["place", "category_along_the_way"]).validated()
                return await addStop(args)
            case AssistantTools.startNavigation.name:
                _ = try AssistantToolSpec.decode(EmptyInput.self, from: input, allowed: [])
                return await startNavigation()
            case AssistantTools.endNavigation.name:
                _ = try AssistantToolSpec.decode(EmptyInput.self, from: input, allowed: [])
                return endNavigation()
            default:
                return .failure("unknown tool \(name)")
            }
        } catch let error as ToolInputError {
            return ToolOutcome(text: "Error: invalid input: \(error.localizedDescription)", say: "Sorry, I didn't get that.", isError: true)
        } catch {
            return .failure("Something went wrong.")
        }
    }

    // MARK: search_places

    private func searchPlaces(_ input: SearchPlacesInput) async -> ToolOutcome {
        let category = PlaceCategory.match(input.query)
        let items: [MKMapItem]
        switch input.near ?? .current_location {
        case .destination:
            guard let destination = navigation.destination else {
                return .failure("There's no destination yet.")
            }
            items = await search(input.query, category: category, around: destination.location.coordinate)
        case .along_route:
            guard let route = navigation.route else { return .failure("There's no route yet.") }
            items = await corridorSearch(input.query, category: category, along: route.polyline.coordinates)
        case .current_location:
            items = await search(input.query, category: category, around: location.location?.coordinate)
        }
        guard !items.isEmpty else {
            results = []
            return ToolOutcome(text: "No results for \(input.query).", say: "I couldn't find any \(input.query) nearby.")
        }
        let found = await makeResults(Array(items.prefix(6)))
        results = found
        remember(found.map(\.item))
        let lines = found.enumerated().map { index, place in "\(index + 1). \(describe(place))" }
        let first = found[0]
        let when = first.eta.map { ", \(TripSummaryView.duration($0)) away" } ?? first.distance.map { ", \(DistanceText.speech($0)) away" } ?? ""
        return ToolOutcome(
            text: "Found \(found.count) places (shown to the driver as cards). No ratings are available from Apple Maps.\n" + lines.joined(separator: "\n"),
            say: found.count == 1 ? "I found \(first.name)\(when)." : "I found \(found.count) places. The closest is \(first.name)\(when).")
    }

    func describe(_ place: PlaceResult) -> String {
        var parts = [place.name]
        if let category = place.category { parts.append(category) }
        if let address = place.address { parts.append(address) }
        var travel: [String] = []
        if let distance = place.distance { travel.append(DistanceText.display(distance)) }
        if let eta = place.eta { travel.append("\(TripSummaryView.duration(eta)) drive") }
        if let added = place.addedTime { travel.append("adds \(TripSummaryView.duration(added)) to the trip") }
        if !travel.isEmpty { parts.append(travel.joined(separator: ", ")) }
        if let phone = place.phone { parts.append("phone \(phone)") }
        if let url = place.url { parts.append(url.absoluteString) }
        return parts.joined(separator: " — ")
    }

    func search(_ query: String, category: PlaceCategory?, around center: CLLocationCoordinate2D?,
                radius: CLLocationDistance = 6_000) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let poi = category?.category {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [poi])
            request.resultTypes = .pointOfInterest
        } else {
            request.resultTypes = [.pointOfInterest, .address]
        }
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        }
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        // Nearest first when we know where we are.
        guard let center else { return items }
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return items.sorted { here.distance(from: $0.location) < here.distance(from: $1.location) }
    }

    /// Searches a few points along a route and keeps the places closest to it.
    func corridorSearch(_ query: String, category: PlaceCategory?, along points: [CLLocationCoordinate2D],
                        limit: Int = 5) async -> [MKMapItem] {
        let samples = StopPlanner.samplePoints(along: points, spacing: 4_000, maxCount: 5)
        var tasks: [Task<[MKMapItem], Never>] = []
        for sample in samples {
            tasks.append(Task { await self.search(query, category: category, around: sample, radius: 2_500) })
        }
        var byID: [String: MKMapItem] = [:]
        var candidates: [StopPlanner.Candidate] = []
        for task in tasks {
            for item in await task.value {
                let c = item.location.coordinate
                let id = "\(item.name ?? "")|\(String(format: "%.4f,%.4f", c.latitude, c.longitude))"
                if byID[id] == nil {
                    byID[id] = item
                    candidates.append(.init(id: id, coordinate: c))
                }
            }
        }
        return StopPlanner.shortlist(candidates, route: points, limit: limit, maxOffset: 3_000).compactMap { byID[$0.id] }
    }

    private var userItem: MKMapItem {
        location.location.map { MKMapItem(location: $0, address: nil) } ?? .forCurrentLocation()
    }

    func makeResults(_ items: [MKMapItem]) async -> [PlaceResult] {
        let source = userItem
        let here = location.location
        var tasks: [Task<TimeInterval?, Never>] = []
        for item in items {
            tasks.append(Task { await Self.eta(from: source, to: item) })
        }
        var results: [PlaceResult] = []
        for (item, task) in zip(items, tasks) {
            results.append(PlaceResult(item: item, name: item.name ?? "Unnamed place",
                                       category: Self.categoryName(item.pointOfInterestCategory),
                                       address: item.addressLine,
                                       distance: here.map { $0.distance(from: item.location) },
                                       eta: await task.value,
                                       phone: item.phoneNumber, url: item.url))
        }
        return results
    }

    static func eta(from source: MKMapItem, to destination: MKMapItem) async -> TimeInterval? {
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = .automobile
        return try? await MKDirections(request: request).calculateETA().expectedTravelTime
    }

    /// "MKPOICategoryGasStation" → "Gas station" (petrol station in AU English).
    static func categoryName(_ category: MKPointOfInterestCategory?) -> String? {
        guard let raw = category?.rawValue else { return nil }
        let name = raw.replacingOccurrences(of: "MKPOICategory", with: "")
        if name == "GasStation" { return "Petrol station" }
        if name == "EVCharger" { return "EV charger" }
        let spaced = name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.prefix(1).uppercased() + spaced.dropFirst().lowercased()
    }

    func remember(_ items: [MKMapItem]) {
        for item in items { if let name = item.name { knownPlaces[name.lowercased()] = item } }
    }

    // MARK: Resolving what the driver named

    enum Resolution {
        case found(MKMapItem)
        /// Needs the driver (e.g. which contact), or failed; say this.
        case stop(ToolOutcome)
    }

    func resolvePlace(_ text: String, pending: PlanRouteInput?) async -> Resolution {
        let key = IntentParser.normalise(text)

        // Saved places, by their own (custom) names, plus everyday ways of
        // saying home / work / uni.
        let synonyms: [String: [String]] = [
            "home": ["my house", "my place", "house"],
            "work": ["the office", "my office", "office"],
            "uni": ["university", "campus"],
        ]
        for place in favourites.places {
            let name = IntentParser.normalise(place.name)
            let words = [name, "my \(name)", "the \(name)"] + (synonyms[name] ?? [])
            guard words.contains(key) else { continue }
            if let item = place.mapItem() { return .found(item) }
            return .stop(.failure("\(place.name) has no address yet. Set it in Saved places (Edit on the Where to card)."))
        }

        // "the second one", "number 3".
        let ordinals = ["first": 0, "1st": 0, "one": 0, "second": 1, "2nd": 1, "two": 1, "third": 2, "3rd": 2, "three": 2,
                        "fourth": 3, "4th": 3, "four": 3, "fifth": 4, "5th": 4, "five": 4, "last": results.count - 1]
        if !results.isEmpty {
            for (word, index) in ordinals where index >= 0 && index < results.count {
                if key == "the \(word) one" || key == "\(word) one" || key == "number \(word)" || key == "the \(word)" || key == "\(word)" {
                    return .found(results[index].item)
                }
            }
            if let n = Int(key.replacingOccurrences(of: "number ", with: "")), n >= 1, n <= results.count {
                return .found(results[n - 1].item)
            }
            if ["that one", "that", "there", "it", "this one"].contains(key) { return .found(results[0].item) }
        }

        // Something already shown or found.
        if let item = knownPlaces[key] { return .found(item) }
        if key.count > 3, let match = knownPlaces.first(where: { $0.key.contains(key) || key.contains($0.key) }) {
            return .found(match.value)
        }

        // A person's place.
        if let person = IntentParser.contactName(in: text) {
            return await lookUpContact(person, pending: pending)
        }

        // Maps search near the car.
        let items = await search(text, category: PlaceCategory.match(text), around: location.location?.coordinate, radius: 40_000)
        if let item = items.first {
            remember([item])
            return .found(item)
        }
        return .stop(ToolOutcome(text: "Error: couldn't find \(text) on the map.", say: "I couldn't find \(text).", isError: true))
    }

    // MARK: find_contact_address

    private func findContactAddress(_ input: FindContactInput) async -> ToolOutcome {
        switch await lookUpContact(input.name, pending: nil) {
        case .stop(let outcome):
            return outcome
        case .found(let item):
            let found = await makeResults([item])
            results = found
            let name = item.name ?? input.name
            return ToolOutcome(text: "Found \(describe(found[0])). Use plan_route with destination \"\(name)\".",
                               say: "Found \(name)'s address.")
        }
    }

    func lookUpContact(_ name: String, pending: PlanRouteInput?) async -> Resolution {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            if !granted { return .stop(contactsOff) }
        case .denied, .restricted:
            return .stop(contactsOff)
        case .authorized, .limited:
            break
        @unknown default:
            break
        }
        let limited = CNContactStore.authorizationStatus(for: .contacts) == .limited

        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                                       CNContactOrganizationNameKey, CNContactPostalAddressesKey] as [CNKeyDescriptor]
            + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        let contacts: [CNContact] = await Task.detached {
            (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        }.value
        let withAddress = contacts.filter { !$0.postalAddresses.isEmpty }

        guard !withAddress.isEmpty else {
            let hint = limited ? " Duo Dash can only see the contacts you've shared with it." : ""
            let message = contacts.isEmpty ? "I couldn't find \(name) in your contacts.\(hint)"
                                           : "\(Self.fullName(contacts[0])) has no address in Contacts."
            return .stop(ToolOutcome(text: "Error: \(message)", say: message, isError: true))
        }
        if withAddress.count > 1 {
            let options = withAddress.prefix(4)
            choices = options.map { ContactChoice(id: $0.identifier, name: Self.fullName($0), detail: Self.addressLine(Self.bestAddress($0).value)) }
            pendingContacts = Dictionary(uniqueKeysWithValues: options.map { ($0.identifier, $0) })
            pendingRoute = pending
            let names = choices.map(\.name)
            let list = names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
            return .stop(ToolOutcome(text: "Several contacts match \"\(name)\": \(names.joined(separator: "; ")). Ask the driver which one they mean.",
                                     say: "Which \(name)? \(list)?"))
        }
        return await geocode(withAddress[0], spokenName: name)
    }

    private var contactsOff: ToolOutcome {
        .failure("Contacts access is off. Allow Contacts for Duo Dash in Settings to find people's addresses.")
    }

    func geocode(_ contact: CNContact, spokenName: String?) async -> Resolution {
        let labelled = Self.bestAddress(contact)
        let line = Self.addressLine(labelled.value)
        let name = Self.fullName(contact)
        guard let request = MKGeocodingRequest(addressString: line),
              let item = (try? await request.mapItems)?.first else {
            return .stop(ToolOutcome(text: "Error: couldn't find \(name)'s address (\(line)) on the map.",
                                     say: "I couldn't find \(name)'s address on the map.", isError: true))
        }
        item.name = name
        knownPlaces[name.lowercased()] = item
        if let spokenName { knownPlaces[IntentParser.normalise(spokenName)] = item }
        return .found(item)
    }

    /// The driver picked one of several matching contacts.
    func choose(_ choice: ContactChoice) {
        guard let contact = pendingContacts[choice.id] else { return }
        let pending = pendingRoute
        choices = []
        pendingContacts = [:]
        pendingRoute = nil
        heard = choice.name
        phase = .thinking
        Task {
            var answer: String
            switch await geocode(contact, spokenName: nil) {
            case .stop(let outcome):
                answer = outcome.say
            case .found(let item):
                if var route = pending {
                    route.destination = item.name ?? choice.name
                    answer = await planRoute(route).say
                } else {
                    results = await makeResults([item])
                    answer = "Found \(choice.name)'s address. Tap Go to head there."
                }
            }
            finish(with: answer)
        }
    }

    static func fullName(_ contact: CNContact) -> String {
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        return name.isEmpty ? (contact.organizationName.isEmpty ? "Contact" : contact.organizationName) : name
    }

    static func bestAddress(_ contact: CNContact) -> CNLabeledValue<CNPostalAddress> {
        contact.postalAddresses.first { $0.label == CNLabelHome } ?? contact.postalAddresses[0]
    }

    static func addressLine(_ address: CNPostalAddress) -> String {
        CNPostalAddressFormatter.string(from: address, style: .mailingAddress)
            .split(whereSeparator: \.isNewline).joined(separator: ", ")
    }

    // MARK: plan_route

    func planRoute(_ input: PlanRouteInput) async -> ToolOutcome {
        let destination: MKMapItem
        switch await resolvePlace(input.destination, pending: input) {
        case .stop(let outcome): return outcome
        case .found(let item): destination = item
        }
        var stops: [MKMapItem] = []
        for name in input.stops ?? [] {
            switch await resolvePlace(name, pending: input) {
            case .stop(let outcome): return outcome
            case .found(let item): stops.append(item)
            }
        }

        var note: String?
        if let along = input.stop_along_the_way {
            let category = PlaceCategory.match(along)
            let what = category?.query ?? along
            let target = stops.first ?? destination
            if let pick = await bestStop(what, category: category, from: userItem, to: target) {
                stops.insert(pick.item, at: 0)
                results = pick.results
                remember(pick.results.map(\.item))
                let added = pick.results.first?.addedTime.map { " adds about \(TripSummaryView.duration($0))" } ?? " is the quickest stop"
                note = "\(pick.item.name ?? what)\(added)."
            } else {
                note = "No \(what) found along the way, so this route has no stop."
            }
        }

        let startNow = input.start_now ?? false
        if startNow { navigation.go(to: destination, via: stops) } else { navigation.preview(to: destination, via: stops) }
        await waitForRoute()
        guard navigation.route != nil, navigation.destination === destination else {
            return .failure(navigation.errorMessage ?? "Couldn't find a driving route.")
        }
        planNote = note
        if !startNow, input.stop_along_the_way == nil { results = [] }

        let name = destination.name ?? "your destination"
        let via = stops.isEmpty ? "" : " via \(stops.map { $0.name ?? "a stop" }.joined(separator: " and "))"
        let time = TripSummaryView.duration(navigation.tripTime)
        let distance = DistanceText.display(navigation.tripDistance)
        let handoff = navigation.handoff
        let opened = "Opened in \(handoff.preferred.title)." + (handoff.notice.map { " \($0)" } ?? "")
        let status = startNow ? (handoff.usesExternalApp ? opened : "Guidance has started.")
                              : "Showing a preview; ask the driver whether to start."
        return ToolOutcome(
            text: "Route to \(name)\(via): \(time), \(distance) in total. \(status)\(note.map { " \($0)" } ?? "")",
            say: startNow ? "Starting route to \(name)\(via). \(time)."
                          : "\(name)\(via) is \(time) away. \(note.map { "\($0) " } ?? "")Say start when you're ready.")
    }

    /// The stop of that kind that adds the least time between `source` and `target`.
    func bestStop(_ query: String, category: PlaceCategory?, from source: MKMapItem, to target: MKMapItem,
                  along known: [CLLocationCoordinate2D]? = nil) async -> (item: MKMapItem, results: [PlaceResult])? {
        var points = known
        var direct: TimeInterval?
        if points == nil {
            let request = MKDirections.Request()
            request.source = source
            request.destination = target
            request.transportType = .automobile
            guard let base = try? await MKDirections(request: request).calculate().routes.first else { return nil }
            points = base.polyline.coordinates
            direct = base.expectedTravelTime
        } else {
            direct = await Self.eta(from: source, to: target)
        }
        let candidates = await corridorSearch(query, category: category, along: points ?? [])
        guard !candidates.isEmpty else { return nil }

        var legs: [(Task<TimeInterval?, Never>, Task<TimeInterval?, Never>)] = []
        for item in candidates {
            legs.append((Task { await Self.eta(from: source, to: item) }, Task { await Self.eta(from: item, to: target) }))
        }
        var options: [StopPlanner.Option] = []
        for (index, pair) in legs.enumerated() {
            options.append(.init(id: "\(index)", toStop: await pair.0.value, toDestination: await pair.1.value))
        }
        let ranked = StopPlanner.rank(options, direct: direct)
        guard let best = ranked.first, let bestIndex = Int(best.id) else { return nil }

        var shown = await makeResults(ranked.compactMap { Int($0.id).map { candidates[$0] } })
        for (k, rank) in ranked.enumerated() where k < shown.count { shown[k].addedTime = rank.added }
        return (candidates[bestIndex], shown)
    }

    func waitForRoute(timeout: TimeInterval = 30) async {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(50))
        while (navigation.state == .calculating || navigation.isRerouting) && Date() < end && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: add_stop

    private func addStop(_ input: AddStopInput) async -> ToolOutcome {
        guard navigation.destination != nil, [.previewing, .navigating, .calculating].contains(navigation.state) else {
            return .failure("There's no trip yet. Tell me where you're going first.")
        }
        await waitForRoute()
        let item: MKMapItem
        var note = ""
        if let place = input.place, !place.assistantTrimmed.isEmpty {
            switch await resolvePlace(place, pending: nil) {
            case .stop(let outcome): return outcome
            case .found(let found): item = found
            }
        } else {
            let along = input.category_along_the_way ?? ""
            let category = PlaceCategory.match(along)
            let what = category?.query ?? along
            // Guiding: detour on the leg being driven. Previewing: the stop goes before the destination.
            let guiding = navigation.state == .navigating
            let source = guiding ? userItem : (navigation.stops.last ?? userItem)
            guard let target = guiding ? navigation.currentTarget : navigation.destination else {
                return .failure("There's no trip yet.")
            }
            let leg = guiding ? navigation.route : navigation.legs.last
            guard let pick = await bestStop(what, category: category, from: source, to: target,
                                            along: leg?.polyline.coordinates) else {
                return ToolOutcome(text: "No \(what) found along the route.", say: "I couldn't find a \(what) along the way.")
            }
            item = pick.item
            results = pick.results
            if let added = pick.results.first?.addedTime { note = " It adds about \(TripSummaryView.duration(added))." }
        }
        navigation.addStop(item)
        await waitForRoute()
        let name = item.name ?? "the stop"
        return ToolOutcome(text: "Added \(name) as the next stop.\(note) Trip now \(TripSummaryView.duration(navigation.tripTime)).",
                           say: "Added a stop at \(name).\(note)")
    }

    // MARK: start / end

    private func startNavigation() async -> ToolOutcome {
        await waitForRoute()
        switch navigation.state {
        case .previewing:
            navigation.start()
            if navigation.handoff.usesExternalApp {
                let app = navigation.handoff.preferred.title
                return ToolOutcome(text: "Opened the route in \(app).\(navigation.handoff.notice.map { " \($0)" } ?? "")",
                                   say: "Opening \(app).")
            }
            return ToolOutcome(text: "Guidance started.", say: "Starting route to \(navigation.destination?.name ?? "your destination").")
        case .navigating:
            return ToolOutcome(text: "Already guiding.", say: "You're already on your way.")
        default:
            return .failure("There's no route to start. Tell me where to go.")
        }
    }

    private func endNavigation() -> ToolOutcome {
        guard navigation.destination != nil else {
            return ToolOutcome(text: "No route to cancel.", say: "There's no route to cancel.")
        }
        navigation.end()
        planNote = nil
        return ToolOutcome(text: "Route cancelled.", say: "Route cancelled.")
    }
}
