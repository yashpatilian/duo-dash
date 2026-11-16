import Foundation
import Observation

/// Which music apps the user said they use (welcome tour).
enum OnboardingMusicChoice: String, CaseIterable, Sendable {
    case appleMusic, spotify, both, neither

    var usesAppleMusic: Bool { self == .appleMusic || self == .both }
    var usesSpotify: Bool { self == .spotify || self == .both }
}

/// One of the four short tour pages for people new to in-car phone screens.
enum OnboardingTourPage: String, CaseIterable, Sendable {
    case dock, maps, phone, settings
}

/// A page of the welcome tour.
enum OnboardingStep: Hashable, Sendable {
    case welcome
    case music
    case spotifyIntro
    /// One of the Spotify developer-dashboard steps, 1-based.
    case spotify(Int)
    case spotifyFinish
    case tour(OnboardingTourPage)
    case whatsNew
    case permissions
    case promo

    /// Number of screens in the Spotify walkthrough (docs/SPOTIFY_SETUP.md steps 1 to 5).
    static let spotifyStepCount = 7

    /// Stable string form, used for persistence, launch arguments and accessibility IDs.
    var id: String {
        switch self {
        case .welcome: "welcome"
        case .music: "music"
        case .spotifyIntro: "spotifyIntro"
        case .spotify(let n): "spotify.\(n)"
        case .spotifyFinish: "spotifyFinish"
        case .tour(let page): "tour.\(page.rawValue)"
        case .whatsNew: "whatsNew"
        case .permissions: "permissions"
        case .promo: "promo"
        }
    }

    init?(id: String) {
        switch id {
        case "welcome": self = .welcome
        case "music": self = .music
        case "spotifyIntro": self = .spotifyIntro
        case "spotifyFinish": self = .spotifyFinish
        case "whatsNew": self = .whatsNew
        case "permissions": self = .permissions
        case "promo": self = .promo
        default:
            if id.hasPrefix("spotify."), let n = Int(id.dropFirst("spotify.".count)),
               (1...Self.spotifyStepCount).contains(n) {
                self = .spotify(n)
            } else if id.hasPrefix("tour."), let page = OnboardingTourPage(rawValue: String(id.dropFirst("tour.".count))) {
                self = .tour(page)
            } else {
                return nil
            }
        }
    }
}

/// The first-launch welcome tour: where it is, what the user chose, and whether it's done.
/// Everything is saved, so a relaunch mid-tour resumes on the same page with the same answers.
@MainActor
@Observable
final class OnboardingModel {
    /// The tour is on screen (first launch, or replayed from Settings → About).
    private(set) var isPresented: Bool

    /// Pages visited, for Back. The last one is showing.
    private(set) var path: [OnboardingStep] {
        didSet { defaults.set(path.map(\.id), forKey: Keys.path) }
    }

    private(set) var usedCarPlay: Bool? {
        didSet { defaults.set(usedCarPlay.map { $0 ? "yes" : "no" }, forKey: Keys.usedCarPlay) }
    }

    private(set) var music: OnboardingMusicChoice? {
        didSet { defaults.set(music?.rawValue, forKey: Keys.music) }
    }

    /// true: walk through the Spotify setup now; false: later.
    private(set) var spotifySetupNow: Bool? {
        didSet { defaults.set(spotifySetupNow.map { $0 ? "now" : "later" }, forKey: Keys.spotifySetup) }
    }

    private(set) var completed: Bool {
        didSet { defaults.set(completed, forKey: Keys.completed) }
    }

    /// Whether any of Location, Contacts, Microphone/Speech is still undecided. The
    /// permissions page is skipped when nothing is left to ask. Set by the app.
    @ObservationIgnored var needsPermissions: () -> Bool = { true }

    enum Keys {
        static let completed = "onboarding.completed"
        static let path = "onboarding.path"
        static let usedCarPlay = "onboarding.usedCarPlay"
        static let music = "onboarding.music"
        static let spotifySetup = "onboarding.spotifySetup"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        let completed = defaults.bool(forKey: Keys.completed)
        self.completed = completed
        usedCarPlay = defaults.string(forKey: Keys.usedCarPlay).map { $0 == "yes" }
        music = defaults.string(forKey: Keys.music).flatMap(OnboardingMusicChoice.init(rawValue:))
        spotifySetupNow = defaults.string(forKey: Keys.spotifySetup).map { $0 == "now" }
        let saved = (defaults.stringArray(forKey: Keys.path) ?? []).compactMap(OnboardingStep.init(id:))
        path = saved.isEmpty ? [.welcome] : saved
        isPresented = Self.showsOnLaunch(completed: completed, arguments: arguments)
        // Screenshots: `-OnboardingStep spotify.3` opens straight on that page.
        if let index = arguments.firstIndex(of: "-OnboardingStep"), index + 1 < arguments.count,
           let step = OnboardingStep(id: arguments[index + 1]) {
            path = step == .welcome ? [.welcome] : [.welcome, step]
            isPresented = true
        }
    }

    /// First launch only. UI tests and marketing captures never see it unless they pass
    /// `-Onboarding` (which shows it even if it was finished before).
    static func showsOnLaunch(completed: Bool, arguments: [String]) -> Bool {
        if arguments.contains("-Onboarding") { return true }
        if arguments.contains("-UITest") || arguments.contains("-Capture") { return false }
        return !completed
    }

    var step: OnboardingStep { path.last ?? .welcome }
    var canGoBack: Bool { path.count > 1 }

    // MARK: Answers

    func answerUsedCarPlay(_ used: Bool) {
        usedCarPlay = used
        advance()
    }

    func chooseMusic(_ choice: OnboardingMusicChoice) {
        music = choice
        advance()
    }

    func chooseSpotifySetup(now: Bool) {
        spotifySetupNow = now
        advance()
    }

    // MARK: Moving through

    func advance() {
        guard let next = Self.next(after: step, usedCarPlay: usedCarPlay, music: music,
                                   spotifySetupNow: spotifySetupNow, needsPermissions: needsPermissions()) else {
            finish()
            return
        }
        path.append(next)
    }

    func back() {
        guard path.count > 1 else { return }
        path.removeLast()
    }

    /// Skip the rest of the tour from any page: straight to the last step (the Duo Dock card,
    /// whose "Not now" closes the tour). Permissions not granted here are asked for when
    /// each feature first needs them.
    func skip() {
        guard path.last != .promo else { finish(); return }
        path.append(.promo)
    }

    /// Done (the Duo Dock sheet's "Get Duo Dock" or "Not now").
    func finish() {
        completed = true
        isPresented = false
        path = [.welcome]
    }

    /// Settings → About → "Show the welcome tour". Starts again with the old answers.
    func restart() {
        path = [.welcome]
        isPresented = true
    }

    /// The page after `step`, given the answers so far. nil when the tour is over.
    static func next(after step: OnboardingStep, usedCarPlay: Bool?, music: OnboardingMusicChoice?,
                     spotifySetupNow: Bool?, needsPermissions: Bool) -> OnboardingStep? {
        let afterMusic: () -> OnboardingStep = {
            usedCarPlay == true ? .whatsNew : .tour(.dock)
        }
        let afterTour: OnboardingStep = needsPermissions ? .permissions : .promo
        switch step {
        case .welcome:
            return .music
        case .music:
            return music?.usesSpotify == true ? .spotifyIntro : afterMusic()
        case .spotifyIntro:
            return spotifySetupNow == true ? .spotify(1) : afterMusic()
        case .spotify(let n):
            return n < OnboardingStep.spotifyStepCount ? .spotify(n + 1) : .spotifyFinish
        case .spotifyFinish:
            return afterMusic()
        case .tour(let page):
            let pages = OnboardingTourPage.allCases
            guard let index = pages.firstIndex(of: page), index + 1 < pages.count else { return afterTour }
            return .tour(pages[index + 1])
        case .whatsNew:
            return afterTour
        case .permissions:
            return .promo
        case .promo:
            return nil
        }
    }
}

/// Where the Duo Dock car mount is sold. One constant for the onboarding sheet and Settings.
enum DockStore {
    static let url = URL(string: "https://doc.yashyp.com")!
}

/// The Spotify setup guide, linked (and QR-coded) from the walkthrough.
enum SpotifyGuide {
    static let url = URL(string: "https://github.com/yashpatilian/duo-dash/blob/main/docs/SPOTIFY_SETUP.md")!
}
