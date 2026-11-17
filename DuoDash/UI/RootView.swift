import SwiftUI

/// Dock (side or bottom), then the active screen and the now-playing bar.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(LocationManager.self) private var location
    @Environment(NavigationModel.self) private var navigation
    @Environment(AppleMusicModel.self) private var music
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(ProStore.self) private var pro
    @Environment(TripStore.self) private var trips
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // The outer reader respects the safe area only to learn the insets; the shell
        // itself ignores them and fills the whole screen, edge to edge, like CarPlay.
        Group {
            if let canvas = LaunchOptions.forcedCanvas {
                // Test canvas: exactly the requested window size, no screen safe area.
                shell(DashMetrics(size: canvas))
                    .frame(width: canvas.width, height: canvas.height)
            } else {
                GeometryReader { proxy in
                    let insets = proxy.safeAreaInsets
                    let full = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                                      height: proxy.size.height + insets.top + insets.bottom)
                    shell(DashMetrics(size: full, insets: insets))
                        .ignoresSafeArea()
                }
            }
        }
        .background { DashBackground() }
        .foregroundStyle(Theme.textPrimary)
        // System controls follow the accent (Duo Dash Pro → Themes).
        .tint(Theme.accent)
        .overlay(alignment: .bottom) { DictationErrorBanner() }
        // "Impact detected: clip saved" (dashcam, Duo Dash Pro), on whatever screen is open.
        .overlay(alignment: .top) { ImpactBanner().padding(.top, 8) }
        // Trip history (Settings → Duo Dash Pro).
        .overlay {
            if trips.isBrowsing && pro.isPro {
                TripsScreen().transition(.move(edge: .trailing))
            }
        }
        .animation(.smooth(duration: 0.3), value: trips.isBrowsing)
        // The Duo Dash Pro paywall, over everything, opened by any locked control.
        .overlay {
            if pro.isPaywallPresented {
                PaywallView().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: pro.isPaywallPresented)
        .manageSubscriptionsSheet(isPresented: Binding(get: { pro.isManagingSubscriptions },
                                                       set: { pro.isManagingSubscriptions = $0 }))
        // "Open garage?" when arriving home (HomeKit).
        .overlay(alignment: .top) { ArrivalBanner().padding(.top, 8) }
        .overlay {
            if app.showScreenInfo {
                ScreenInfoView()
            }
        }
        // The welcome tour (first launch, or replayed from Settings → About).
        .overlay {
            if onboarding.isPresented {
                OnboardingView().transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.35), value: onboarding.isPresented)
        // The tour asks for Location itself; once it's over, start as usual.
        .onChange(of: onboarding.isPresented) { _, showing in
            if !showing { location.start() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                // Keep the display on for as long as the app is in front.
                UIApplication.shared.isIdleTimerDisabled = true
                // During the welcome tour, Location is asked for on its permissions page.
                if !onboarding.isPresented || location.authorization != .notDetermined { location.start() }
                music.refreshFromPlayer()
                trips.becameActive()
                Task { await pro.refreshEntitlements() }
                // Apps may have been installed or deleted while we were away (dock tiles).
                app.refreshInstalledApps()
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                trips.enteredBackground()
                // Without a route there is no reason to use GPS in the background.
                if !navigation.isGuiding { location.stop() }
            default:
                break
            }
        }
    }

    /// Big screens (iPad) lay out at a phone-like size and are scaled up as a whole, the way
    /// CarPlay scales to the car's display, so nothing looks lost in empty space.
    private func shell(_ window: DashMetrics) -> some View {
        let metrics = window.scaledForDisplay()
        return ShellLayout(sidebar: metrics.usesSidebar, dockThickness: metrics.dockThickness, spacing: 0) {
            DockView()
            MainColumn()
        }
        .environment(\.dashMetrics, metrics)
        .animation(.snappy(duration: 0.25), value: metrics.usesSidebar)
        .frame(width: metrics.size.width, height: metrics.size.height)
        .scaleEffect(metrics.scale, anchor: .topLeading)
        .frame(width: window.size.width, height: window.size.height, alignment: .topLeading)
    }
}

/// Places the dock on the right (sidebar) or along the bottom, keeping both
/// children's identity so screens don't rebuild when the window changes shape.
struct ShellLayout: Layout {
    var sidebar: Bool
    var dockThickness: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let dock = subviews[0]
        let main = subviews[1]
        if sidebar {
            // Dock on the right, content on the left (the iPhone Duo's convention).
            main.place(at: bounds.origin, anchor: .topLeading,
                       proposal: ProposedViewSize(width: max(0, bounds.width - dockThickness - spacing),
                                                  height: bounds.height))
            dock.place(at: CGPoint(x: bounds.maxX - dockThickness, y: bounds.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: dockThickness, height: bounds.height))
        } else {
            main.place(at: bounds.origin, anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width,
                                                  height: max(0, bounds.height - dockThickness - spacing)))
            dock.place(at: CGPoint(x: bounds.minX, y: bounds.maxY - dockThickness), anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: dockThickness))
        }
    }
}

/// Status (compact only), the screens, and the now-playing bar.
struct MainColumn: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dashMetrics) private var metrics

    var body: some View {
        VStack(spacing: Theme.gap) {
            if !metrics.usesSidebar {
                StatusStripView()
                    .padding(.trailing, metrics.insets.trailing)
                    .padding(.top, metrics.insets.top)
                    .frame(height: metrics.statusHeight + metrics.insets.top)
            }

            ZStack {
                ForEach(DockItem.allCases) { item in
                    if app.visited.contains(item) {
                        screen(for: item)
                            .opacity(app.selected == item ? 1 : 0)
                            // Kept-alive screens also move out of the way: at opacity 0 alone
                            // they still overlapped the open screen for UI automation (iOS 27),
                            // which saw their controls on top of the visible ones.
                            .offset(x: app.selected == item ? 0 : 20_000)
                            .transaction { $0.animation = nil }
                            .allowsHitTesting(app.selected == item)
                            .accessibilityHidden(app.selected != item)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The dashboard has its own media widget (like CarPlay), and the full
            // player replaces the mini bar (like Apple Music).
            if (app.selected != .home || app.showsAppGrid) && !(app.selected == .music && app.isPlayerOpen) {
                NowPlayingBar()
            }
        }
        .padding(Theme.gap)
        // With the dock on the right, a camera column on the left edge (cover
        // screen in landscape) must not sit over the content.
        .padding(.leading, metrics.usesSidebar ? metrics.insets.leading : 0)
    }

    @ViewBuilder
    private func screen(for item: DockItem) -> some View {
        Group {
            switch item {
            case .home:
                HomeView()
            case .maps:
                MapsView()
            case .music:
                MusicView()
            case .spotify:
                SpotifyView()
            case .phone:
                PhoneView()
            case .messages:
                MessagesView()
            case .calendar:
                CalendarScreen(onNavigate: { item in navigation.go(to: item); app.open(.maps) })
            case .weather:
                WeatherScreen()
            case .car:
                CarScreen()
            case .homekit:
                HomeScreen()
            case .dashcam:
                DashcamScreen()
            case .youtube:
                YouTubeScreen()
            case .settings:
                SettingsView()
            }
        }
        // A tiny marker element names the screen for UI tests. Wrapping the screen in its own
        // accessibility container instead would merge with each app's root and overwrite the
        // app's own identifiers (e.g. homekit.screen, calendar.screen).
        .overlay(alignment: .topLeading) {
            if app.selected == item {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(item.title)
                .accessibilityIdentifier("screen.\(item.rawValue)")
                .allowsHitTesting(false)
            }
        }
    }
}
