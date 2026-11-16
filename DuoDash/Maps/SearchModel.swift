import MapKit
import Observation

/// Type-ahead destination search (MKLocalSearchCompleter) plus full MKLocalSearch.
@MainActor
@Observable
final class SearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            results = []
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                completions = []
                completer.cancel()
            } else {
                completer.queryFragment = query
            }
        }
    }

    private(set) var completions: [MKLocalSearchCompletion] = []
    private(set) var results: [MKMapItem] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var region: MKCoordinateRegion?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Bias results towards where the car is.
    func focus(on coordinate: CLLocationCoordinate2D) {
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        self.region = region
        completer.region = region
    }

    func clear() {
        query = ""
        errorMessage = nil
    }

    /// Full search for the typed text (keyboard Search key).
    func submit() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let region { request.region = region }
        results = await run(request)
    }

    /// Turns a type-ahead suggestion into a map item.
    func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        let request = MKLocalSearch.Request(completion: completion)
        if let region { request.region = region }
        return await run(request).first
    }

    private func run(_ request: MKLocalSearch.Request) async -> [MKMapItem] {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let response = try await MKLocalSearch(request: request).start()
            if response.mapItems.isEmpty { errorMessage = "No places found" }
            return Array(response.mapItems.prefix(12))
        } catch {
            errorMessage = "Search failed. Check your connection."
            return []
        }
    }

    // MARK: MKLocalSearchCompleterDelegate (called on the main thread)

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let latest = Array(completer.results.prefix(8))
        MainActor.assumeIsolated { completions = latest }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { completions = [] }
    }
}
