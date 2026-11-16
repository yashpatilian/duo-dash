import SwiftUI

/// Dock (side or bottom), then the active screen and the now-playing bar.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(LocationManager.self) private var location
    @Environment(NavigationModel.self) private var navigation
    @Environment(AppleMusicModel.self) private var music
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
        .overlay(alignment: .bottom) { DictationErrorBanner() }
        .overlay {
            if app.showScreenInfo {
                ScreenInfoView()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                // Keep the display on for as long as the app is in front.
                UIApplication.shared.isIdleTimerDisabled = true
                location.start()
                music.refreshFromPlayer()
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                // Without a route there is no reason to use GPS in the background.
                if !navigation.isGuiding { location.stop() }
            default:
                break
            }
        }
    }

    private func shell(_ metrics: DashMetrics) -> some View {
        ShellLayout(sidebar: metrics.usesSidebar, dockThickness: metrics.dockThickness, spacing: 0) {
            DockView()
            MainColumn()
        }
        .environment(\.dashMetrics, metrics)
        .animation(.snappy(duration: 0.25), value: metrics.usesSidebar)
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
                            .allowsHitTesting(app.selected == item)
                            .accessibilityHidden(app.selected != item)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The dashboard has its own media widget (like CarPlay), and the full
            // player replaces the mini bar (like Apple Music).
            if app.selected != .home && !(app.selected == .music && app.isPlayerOpen) {
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
            case .settings:
                SettingsView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.\(item.rawValue)")
    }
}
