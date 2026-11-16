import SwiftUI
import CoreLocation

@main
struct DuoDashApp: App {
    @State private var app: AppModel
    @State private var location: LocationManager
    @State private var navigation: NavigationModel
    @State private var favourites: FavouritesStore
    @State private var nowPlaying: NowPlayingModel
    @State private var music: AppleMusicModel
    @State private var spotify: SpotifyModel
    @State private var assistantSettings: AssistantSettings
    @State private var assistant: AssistantModel
    @State private var contacts: ContactsStore
    @State private var copiedAddress = CopiedAddressWatcher()
    @State private var calendar = CalendarModel()
    @State private var weather = WeatherModel()
    @State private var home: HomeModel
    @State private var dashcamSettings: DashcamSettings
    @State private var dashcam: DashcamModel
    @State private var car = CarDataModel()
    @State private var onboarding: OnboardingModel

    init() {
        if LaunchOptions.resetState, let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
        }
        // After any -ResetState wipe, so a reset run starts the tour afresh.
        _onboarding = State(initialValue: OnboardingModel())
        let location = LocationManager()
        let nowPlaying = NowPlayingModel()
        let app = AppModel()
        let navigation = NavigationModel(location: location)
        let favourites = FavouritesStore()
        _app = State(initialValue: app)
        _location = State(initialValue: location)
        _navigation = State(initialValue: navigation)
        _favourites = State(initialValue: favourites)
        _nowPlaying = State(initialValue: nowPlaying)
        _music = State(initialValue: AppleMusicModel(nowPlaying: nowPlaying))
        _spotify = State(initialValue: SpotifyModel(nowPlaying: nowPlaying))
        // Voice assistant (DuoDash/Assistant).
        let assistantSettings = AssistantSettings()
        _assistantSettings = State(initialValue: assistantSettings)
        _assistant = State(initialValue: AssistantModel(settings: assistantSettings, navigation: navigation,
                                                        location: location, favourites: favourites, app: app))
        _contacts = State(initialValue: ContactsStore())
        // Home (HomeKit), dashcam: the location feed drives the arrival offer and the clip GPS track.
        let home = HomeModel()
        let dashcamSettings = DashcamSettings()
        let dashcam = DashcamModel(settings: dashcamSettings)
        _home = State(initialValue: home)
        _dashcamSettings = State(initialValue: dashcamSettings)
        _dashcam = State(initialValue: dashcam)
        location.addListener { [weak navigation, weak favourites] fix in
            dashcam.ingest(fix)
            let homePlace = favourites?.place(id: "home")?.location
            let distance = homePlace.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: fix) }
            let headingHome = navigation?.isGuiding == true && homePlace != nil
                && navigation?.destination.map { item in
                    homePlace.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                        .distance(from: CLLocation(latitude: item.location.coordinate.latitude,
                                                   longitude: item.location.coordinate.longitude)) < 150 } ?? false
                } == true
            _ = home.arrivalSuggestion(distanceToHome: distance, isNavigatingHome: headingHome, speed: max(0, fix.speed))
        }
    }

    var body: some Scene {
        WindowGroup {
            CanvasHost {
                // Inside the .environment(...) calls below, so it can read the weather and location models.
                RootView().weatherFollowsLocation()
            }
            // Spotify returns here (duodash://spotify-callback) after authorising.
            .onOpenURL { url in
                // duodash://open/<app> (e.g. duodash://open/maps): for Shortcuts, automations and UI tests.
                if url.scheme == "duodash", url.host == "open", let item = DockItem(rawValue: url.lastPathComponent) {
                    app.open(item)
                    return
                }
                _ = spotify.handleOpenURL(url)
            }
            .environment(app)
            .environment(location)
            .environment(navigation)
            .environment(favourites)
            .environment(nowPlaying)
            .environment(music)
            .environment(spotify)
            .environment(assistantSettings)
            .environment(assistant)
            .environment(contacts)
            .environment(copiedAddress)
            .environment(calendar)
            .environment(weather)
            .environment(home)
            .environment(dashcamSettings)
            .environment(dashcam)
            .environment(car)
            .environment(onboarding)
            .task { await dashcam.startIfAutoStart() }
            .task {
                // Reconnect to a paired OBD adapter; first-time setup happens on the Car screen
                // (creating the Bluetooth manager is what asks for permission).
                if UserDefaults.standard.string(forKey: BLEOBDTransport.rememberedIDKey) != nil || car.isDemo { car.start() }
            }
            .preferredColorScheme(.dark)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
        }
    }
}

/// Normally passes straight through. With DUODASH_CANVAS set (tests), renders the
/// app inside a fixed-size frame to exercise cover-screen / Split View layouts.
struct CanvasHost<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if let canvas = LaunchOptions.forcedCanvas {
            // Behaves like a real window of that size: no safe-area insets leak in
            // from the screen, and it is scaled down to fit when the canvas is
            // bigger than the current screen (e.g. inner-screen sizes while folded).
            GeometryReader { proxy in
                let scale = min(1, proxy.size.width / canvas.width, proxy.size.height / canvas.height)
                content
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
                    .border(Color.gray.opacity(LaunchOptions.isCapture ? 0 : 0.4))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("canvas")
                    .scaleEffect(scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            // Fit the canvas inside the safe area: the cover screen's system status
            // column (camera, clock) sits over the right edge and would swallow taps.
            .background(Color.black.ignoresSafeArea())
        } else {
            content
        }
    }
}
