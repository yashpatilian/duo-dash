import SwiftUI
import MapKit
import Observation
import Contacts

/// A place found by the assistant, shown as a card and a map pin.
struct PlaceResult: Identifiable {
    let id = UUID()
    let item: MKMapItem
    var name: String
    var category: String?
    var address: String?
    var distance: CLLocationDistance?
    var eta: TimeInterval?
    var phone: String?
    var url: URL?
    /// For stops on the way: extra time compared with driving straight there.
    var addedTime: TimeInterval?
}

/// Someone in Contacts the driver might have meant.
struct ContactChoice: Identifiable, Equatable {
    let id: String
    var name: String
    var detail: String
}

/// Test and debugging switches read from launch arguments.
enum AssistantLaunchOptions {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    /// `-AssistantTranscript "take me to …"`: sent once, when the panel first opens.
    static var injectedTranscript: String? {
        guard let i = arguments.firstIndex(of: "-AssistantTranscript"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// `-AssistantLocal`: always use the simple intent parser (deterministic tests).
    static var forcesLocal: Bool { arguments.contains("-AssistantLocal") }
}

/// The driving assistant: listens, asks the chosen AI (or the local fallback),
/// runs its tools against Maps, speaks and shows the reply.
@MainActor
@Observable
final class AssistantModel: AssistantToolRunner {
    enum Phase: Equatable { case idle, thinking, speaking }

    var isPresented = false
    var phase: Phase = .idle
    /// The text field (typed, or filled live while dictating).
    var draft = ""
    /// What the driver said last.
    var heard = ""
    var reply = ""
    /// Provider problems and fallbacks ("Using simple commands…").
    private(set) var notice: String?
    var results: [PlaceResult] = []
    var choices: [ContactChoice] = []
    /// Extra detail about the planned trip, e.g. "The Shell adds about 2 min".
    var planNote: String?
    /// Opens Apple's place card (ratings, hours, photos).
    var detailItem: MKMapItem?
    private(set) var brainName = ""

    let settings: AssistantSettings
    let navigation: NavigationModel
    let location: LocationManager
    let favourites: FavouritesStore
    @ObservationIgnored weak var app: AppModel?

    @ObservationIgnored let micID = UUID()
    @ObservationIgnored var forcesLocal = AssistantLaunchOptions.forcesLocal
    @ObservationIgnored private var pendingTranscript = AssistantLaunchOptions.injectedTranscript
    @ObservationIgnored private lazy var claude = ClaudeBrain(settings: settings)
    @ObservationIgnored private lazy var apple = AppleIntelligenceBrain()
    @ObservationIgnored private let local = LocalBrain()
    @ObservationIgnored private let speaker = AssistantSpeaker()
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var localityFix: CLLocation?
    @ObservationIgnored private var locality: (name: String?, city: String?, region: String?) = (nil, nil, nil)

    /// Places the conversation has mentioned, by lowercased name, so "take me to the
    /// second one" or "go to Sam Lee" resolve to exactly what was shown.
    @ObservationIgnored var knownPlaces: [String: MKMapItem] = [:]
    /// A route waiting on "which Sam?".
    @ObservationIgnored var pendingRoute: PlanRouteInput?
    @ObservationIgnored var pendingContacts: [String: CNContact] = [:]

    init(settings: AssistantSettings, navigation: NavigationModel, location: LocationManager,
         favourites: FavouritesStore, app: AppModel? = nil) {
        self.settings = settings
        self.navigation = navigation
        self.location = location
        self.favourites = favourites
        self.app = app
        speaker.onFinish = { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.phase = .idle
        }
    }

    var toolSpecs: [AssistantToolSpec] { AssistantTools.all }

    var isListening: Bool { Dictation.shared.activeID == micID }

    // MARK: - Panel

    /// Opens the panel on the Maps screen (switching to it if needed).
    func present() {
        app?.open(.maps)
        isPresented = true
        Task { await refreshLocality() }
        if let transcript = pendingTranscript {
            pendingTranscript = nil
            send(transcript)
        }
    }

    func dismiss() {
        if isListening { Dictation.shared.finish() }
        speaker.stop()
        isPresented = false
    }

    /// Clears the conversation (both providers forget it too).
    func reset() {
        turnTask?.cancel()
        speaker.stop()
        claude.reset()
        apple.reset()
        heard = ""; reply = ""; notice = nil; draft = ""
        results = []; choices = []; planNote = nil
        knownPlaces = [:]; pendingRoute = nil; pendingContacts = [:]
        phase = .idle
    }

    /// The big microphone: listen, and send what was heard when the driver pauses.
    func toggleListening() {
        speaker.stop()
        let id = micID
        Task { [weak self] in
            await Dictation.shared.toggle(id: id) { [weak self] text in
                self?.draft = text
            } onFinish: { [weak self] text in
                self?.send(text)
            }
        }
    }

    // MARK: - A turn

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        turnTask?.cancel()
        speaker.stop()
        heard = text
        draft = ""
        reply = ""
        notice = nil
        choices = []
        phase = .thinking
        let wasGuiding = navigation.state == .navigating
        turnTask = Task { [weak self] in
            guard let self else { return }
            defer { if !wasGuiding { self.stepAsideIfGuidanceStarted() } }
            let context = await self.makeContext()
            let (brain, note) = self.chooseBrain()
            self.brainName = brain.displayName
            self.notice = note
            var answer: String
            do {
                answer = try await brain.respond(to: text, context: context, tools: self)
            } catch is CancellationError {
                return
            } catch let error as AssistantBrainError where error.fallBack && !(brain is LocalBrain) {
                self.notice = "\(error.message) Using simple commands."
                self.brainName = self.local.displayName
                answer = (try? await self.local.respond(to: text, context: context, tools: self)) ?? ""
            } catch {
                answer = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            }
            guard !Task.isCancelled else { return }
            self.finish(with: answer)
        }
    }

    func finish(with answer: String) {
        reply = answer
        if settings.speaksReplies && !answer.isEmpty {
            phase = .speaking
            speaker.speak(answer)
        } else {
            phase = .idle
        }
    }

    /// Once a turn has started guidance, the panel gets out of the way of the turn
    /// banner after a moment (unless the driver has started another turn).
    private func stepAsideIfGuidanceStarted() {
        guard navigation.state == .navigating, isPresented else { return }
        let turn = turnTask
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, self.turnTask == turn, !self.isListening, self.phase != .thinking else { return }
            self.isPresented = false
        }
    }

    private func chooseBrain() -> (AssistantBrain, String?) {
        if forcesLocal { return (local, nil) }
        switch settings.provider {
        case .claude:
            guard settings.hasClaudeKey else {
                return (local, "Add your Claude API key in Settings. Using simple commands.")
            }
            return (claude, nil)
        case .appleIntelligence:
            if let reason = AppleIntelligenceBrain.unavailableReason {
                return (local, "\(reason) Using simple commands.")
            }
            if apple.recentlyFailed {
                return (local, "Apple Intelligence isn't responding on this device. Using simple commands.")
            }
            return (apple, nil)
        }
    }

    // MARK: - Context

    func makeContext() async -> AssistantContext {
        AssistantContext(now: Date(), coordinate: location.location?.coordinate,
                         locality: locality.name, city: locality.city, region: locality.region,
                         routeSummary: routeSummary)
    }

    var routeSummary: String? {
        guard let destination = navigation.destination else { return nil }
        let name = destination.name ?? "the destination"
        let via = navigation.stops.isEmpty ? "" : " via \(navigation.stops.compactMap(\.name).joined(separator: ", "))"
        switch navigation.state {
        case .calculating:
            return "Working out a route to \(name)\(via)."
        case .previewing:
            return "Previewing a route to \(name)\(via): \(TripSummaryView.duration(navigation.tripTime)), \(DistanceText.display(navigation.tripDistance)). Not started yet."
        case .navigating:
            let next = navigation.isHeadingToStop ? " Next stop: \(navigation.currentTarget?.name ?? "a stop")." : ""
            return "Guiding to \(name)\(via), \(TripSummaryView.duration(navigation.remainingTime)) and \(DistanceText.display(navigation.remainingDistance)) left.\(next)"
        case .arrived:
            return "Just arrived at \(name)."
        case .idle:
            return nil
        }
    }

    /// Suburb and city for the prompt, looked up again only after the car moves ~2 km.
    private func refreshLocality() async {
        guard let fix = location.location else { return }
        if let last = localityFix, last.distance(from: fix) < 2_000 { return }
        localityFix = fix
        guard let request = MKReverseGeocodingRequest(location: fix),
              let item = (try? await request.mapItems)?.first else { return }
        let address = item.addressRepresentations
        locality = (address?.cityWithContext ?? address?.cityName, address?.cityName, address?.regionName)
    }

    // MARK: - Card actions

    /// Go now: guidance straight to that place.
    func go(to result: PlaceResult) {
        navigation.go(to: result.item)
        reply = "Starting route to \(result.name)."
        isPresented = false
    }

    var canAddStop: Bool {
        navigation.destination != nil && [.previewing, .navigating].contains(navigation.state)
    }

    func addStop(_ result: PlaceResult) {
        navigation.addStop(result.item)
        planNote = nil
        reply = "Added \(result.name) as a stop."
        if settings.speaksReplies { speaker.speak(reply) }
    }

    func showDetails(_ result: PlaceResult) {
        detailItem = result.item
    }

    func startPlannedRoute() {
        navigation.start()
        isPresented = false
    }

    func cancelPlannedRoute() {
        navigation.end()
        planNote = nil
    }
}
