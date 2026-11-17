import XCTest
@testable import DuoDash

/// The welcome tour's page order, persistence and launch rules, and the edition switch.
@MainActor
final class OnboardingTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "OnboardingTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Walks the tour by answering each question page, recording the pages seen.
    /// `bundled`: the build ships a Spotify client ID (explicit, so the result doesn't depend on
    /// whether this Mac's Secrets.xcconfig has one).
    private func walk(usedCarPlay: Bool, music: OnboardingMusicChoice, spotifyNow: Bool?,
                      needsPermissions: Bool = true, bundled: Bool = false) -> [String] {
        defaults.removePersistentDomain(forName: suite) // each walk is a first launch
        let model = OnboardingModel(defaults: defaults, arguments: [], spotifyClientBundled: bundled)
        model.needsPermissions = { needsPermissions }
        var seen = [model.step.id]
        while model.isPresented, seen.count < 40 {
            switch model.step {
            case .welcome: model.answerUsedCarPlay(usedCarPlay)
            case .music: model.chooseMusic(music)
            case .spotifyIntro: model.chooseSpotifySetup(now: spotifyNow ?? false)
            default: model.advance()
            }
            if model.isPresented { seen.append(model.step.id) }
        }
        return seen
    }

    func testUsedCarPlayAppleMusicPath() {
        XCTAssertEqual(walk(usedCarPlay: true, music: .appleMusic, spotifyNow: nil),
                       ["welcome", "music", "whatsNew", "permissions", "promo"])
    }

    func testNewUserSpotifyLaterPath() {
        XCTAssertEqual(walk(usedCarPlay: false, music: .spotify, spotifyNow: false),
                       ["welcome", "music", "spotifyIntro", "tour.dock", "tour.maps", "tour.phone", "tour.settings",
                        "permissions", "promo"])
    }

    func testSpotifySetupNowWalksEveryStep() {
        let pages = walk(usedCarPlay: true, music: .both, spotifyNow: true, needsPermissions: false)
        XCTAssertEqual(pages, ["welcome", "music", "spotifyIntro"]
                       + (1...OnboardingStep.spotifyStepCount).map { "spotify.\($0)" }
                       + ["spotifyFinish", "whatsNew", "promo"])
    }

    func testNeitherSkipsSpotify() {
        XCTAssertFalse(walk(usedCarPlay: false, music: .neither, spotifyNow: nil).contains("spotifyIntro"))
        XCTAssertFalse(walk(usedCarPlay: false, music: .neither, spotifyNow: nil, bundled: true).contains("spotifyIntro"))
    }

    /// A build with a client ID: "Connect now" signs in from the intro page; the
    /// developer-dashboard walkthrough never appears.
    func testBundledClientIDSkipsWalkthrough() {
        XCTAssertEqual(walk(usedCarPlay: true, music: .both, spotifyNow: true, needsPermissions: false, bundled: true),
                       ["welcome", "music", "spotifyIntro", "whatsNew", "promo"])
        XCTAssertEqual(walk(usedCarPlay: false, music: .spotify, spotifyNow: false, bundled: true),
                       ["welcome", "music", "spotifyIntro", "tour.dock", "tour.maps", "tour.phone", "tour.settings",
                        "permissions", "promo"])
    }

    func testNextHandlesBothBuilds() {
        func next(_ step: OnboardingStep, now: Bool?, bundled: Bool) -> OnboardingStep? {
            OnboardingModel.next(after: step, usedCarPlay: true, music: .spotify, spotifySetupNow: now,
                                 spotifyClientBundled: bundled, needsPermissions: true)
        }
        // Without a bundled client ID: Now → the walkthrough, Later → on with the tour.
        XCTAssertEqual(next(.spotifyIntro, now: true, bundled: false), .spotify(1))
        XCTAssertEqual(next(.spotifyIntro, now: false, bundled: false), .whatsNew)
        XCTAssertEqual(next(.spotify(3), now: true, bundled: false), .spotify(4))
        XCTAssertEqual(next(.spotify(OnboardingStep.spotifyStepCount), now: true, bundled: false), .spotifyFinish)
        XCTAssertEqual(next(.spotifyFinish, now: true, bundled: false), .whatsNew)
        // With one: never the walkthrough, even when resuming a tour saved in the middle of it.
        XCTAssertEqual(next(.spotifyIntro, now: true, bundled: true), .whatsNew)
        XCTAssertEqual(next(.spotifyIntro, now: false, bundled: true), .whatsNew)
        XCTAssertEqual(next(.spotify(3), now: true, bundled: true), .whatsNew)
        XCTAssertEqual(next(.music, now: nil, bundled: true), .spotifyIntro)
    }

    func testBundledClientIDDetection() {
        XCTAssertNil(SpotifyConfig.clientID(info: [:]))
        XCTAssertNil(SpotifyConfig.clientID(info: ["SpotifyClientID": ""]))
        XCTAssertNil(SpotifyConfig.clientID(info: ["SpotifyClientID": "  "]))
        XCTAssertNil(SpotifyConfig.clientID(info: ["SpotifyClientID": "$(SPOTIFY_CLIENT_ID)"]))
        XCTAssertEqual(SpotifyConfig.clientID(info: ["SpotifyClientID": " test-client \n"]), "test-client")
        XCTAssertFalse(SpotifyConfig.hasBundledClientID(info: [:], arguments: []))
        XCTAssertTrue(SpotifyConfig.hasBundledClientID(info: ["SpotifyClientID": "test-client"], arguments: []))
        // UI tests force either path, whatever this Mac's Secrets.xcconfig holds.
        XCTAssertFalse(SpotifyConfig.hasBundledClientID(info: ["SpotifyClientID": "test-client"],
                                                        arguments: ["-SpotifyBundledClientID", "NO"]))
        XCTAssertTrue(SpotifyConfig.hasBundledClientID(info: [:], arguments: ["-SpotifyBundledClientID", "YES"]))
        let model = OnboardingModel(defaults: defaults, arguments: ["-SpotifyBundledClientID", "YES"])
        XCTAssertTrue(model.spotifyClientBundled)
    }

    func testFinishPersistsAndHidesOnNextLaunch() {
        let model = OnboardingModel(defaults: defaults, arguments: [])
        XCTAssertTrue(model.isPresented, "first launch shows the tour")
        model.answerUsedCarPlay(false)
        model.chooseMusic(.spotify)
        model.chooseSpotifySetup(now: false)
        model.finish()
        XCTAssertFalse(model.isPresented)

        let relaunched = OnboardingModel(defaults: defaults, arguments: [])
        XCTAssertFalse(relaunched.isPresented, "finished tour must not come back")
        XCTAssertEqual(relaunched.usedCarPlay, false)
        XCTAssertEqual(relaunched.music, .spotify)
        XCTAssertEqual(relaunched.spotifySetupNow, false)

        relaunched.restart()
        XCTAssertTrue(relaunched.isPresented)
        XCTAssertEqual(relaunched.step, .welcome)
    }

    func testResumesMidTourAndBackWorks() {
        let model = OnboardingModel(defaults: defaults, arguments: [])
        model.answerUsedCarPlay(true)
        model.chooseMusic(.appleMusic)
        XCTAssertEqual(model.step, .whatsNew)
        let relaunched = OnboardingModel(defaults: defaults, arguments: [])
        XCTAssertEqual(relaunched.step, .whatsNew)
        relaunched.back()
        XCTAssertEqual(relaunched.step, .music)
        relaunched.back()
        relaunched.back()
        XCTAssertEqual(relaunched.step, .welcome)
        XCTAssertFalse(relaunched.canGoBack)
    }

    func testLaunchRules() {
        XCTAssertTrue(OnboardingModel.showsOnLaunch(completed: false, arguments: []))
        XCTAssertFalse(OnboardingModel.showsOnLaunch(completed: true, arguments: []))
        XCTAssertFalse(OnboardingModel.showsOnLaunch(completed: false, arguments: ["-UITest"]))
        XCTAssertFalse(OnboardingModel.showsOnLaunch(completed: false, arguments: ["-Capture"]))
        XCTAssertTrue(OnboardingModel.showsOnLaunch(completed: false, arguments: ["-UITest", "-Onboarding"]))
        XCTAssertTrue(OnboardingModel.showsOnLaunch(completed: true, arguments: ["-Capture", "-Onboarding"]))
    }

    func testStepIDsRoundTrip() {
        let steps: [OnboardingStep] = [.welcome, .music, .spotifyIntro, .spotifyFinish, .whatsNew, .permissions, .promo]
            + (1...OnboardingStep.spotifyStepCount).map { .spotify($0) }
            + OnboardingTourPage.allCases.map { .tour($0) }
        for step in steps { XCTAssertEqual(OnboardingStep(id: step.id), step) }
        XCTAssertNil(OnboardingStep(id: "spotify.99"))
        XCTAssertNil(OnboardingStep(id: "tour.nope"))
    }

    func testJumpToStepArgument() {
        let model = OnboardingModel(defaults: defaults, arguments: ["-UITest", "-OnboardingStep", "spotify.3"])
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.step, .spotify(3))
    }

    func testSpotifyWalkthroughMatchesStepCount() {
        XCTAssertEqual(SpotifyWalkthrough.steps.count, OnboardingStep.spotifyStepCount)
        let text = SpotifyWalkthrough.steps.map { $0.title + " " + $0.message }.joined(separator: " ")
        for required in ["developer.spotify.com/dashboard", "Create app", "duodash://spotify-callback", "iOS and Web API",
                         "iOS app bundles", "User Management", "Client ID"] {
            XCTAssertTrue(text.contains(required), "walkthrough is missing \(required)")
        }
    }

    func testEditionParsing() {
        XCTAssertEqual(Edition(infoValue: "commercial"), .commercial)
        XCTAssertEqual(Edition(infoValue: " Commercial "), .commercial)
        XCTAssertEqual(Edition(infoValue: "personal"), .personal)
        XCTAssertEqual(Edition(infoValue: nil), .personal)
        XCTAssertEqual(Edition(infoValue: "$(DUODASH_EDITION)"), .personal)
        XCTAssertFalse(Edition.commercial.usesOfficialIcons)
        XCTAssertFalse(Edition.commercial.carSystemName.contains("CarPlay"))
        XCTAssertFalse(Edition.notAffiliatedNotice.contains("CarPlay"))
    }

    func testDockStoreURL() {
        XCTAssertEqual(DockStore.url.absoluteString, "https://duodash.app/mount")
    }
}
