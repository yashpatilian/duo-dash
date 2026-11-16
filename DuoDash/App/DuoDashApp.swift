import SwiftUI

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

    init() {
        if LaunchOptions.resetState, let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
        }
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
    }

    var body: some Scene {
        WindowGroup {
            CanvasHost {
                RootView()
            }
            // Spotify returns here (duodash://spotify-callback) after authorising.
            .onOpenURL { url in spotify.handleOpenURL(url) }
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
