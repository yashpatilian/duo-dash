import SwiftUI
import MapKit

/// CarPlay-style dashboard: map plus stacked cards.
/// Wide windows split side by side (aligned to the fold when the phone is half
/// open); tall or narrow windows (portrait, cover screen, Split View) stack.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dashMetrics) private var metrics
    @State private var position: MapCameraPosition = MapOrientation.current().followPosition(guiding: false)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let wide = metrics.homeIsSplit
            let split = Self.splitWidths(width: size.width, fold: wide ? FoldGeometry.foldFrame(in: proxy) : nil)
            let layout = wide ? AnyLayout(HStackLayout(spacing: split.gap))
                              : AnyLayout(VStackLayout(spacing: Theme.gap))
            layout {
                map
                    .frame(width: wide ? split.map : nil)
                    .layoutPriority(1)

                VStack(spacing: Theme.gap) {
                    if wide {
                        NowPlayingCard()
                        NextTurnCard()
                        if size.height >= 520 {
                            FavouriteContactsCard().fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        NextTurnCard().fixedSize(horizontal: false, vertical: true)
                        NowPlayingCard(compact: true).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: wide ? split.cards : nil)
            }
        }
    }

    private var map: some View {
        DashMapView(position: $position)
            .overlay(alignment: .topTrailing) {
                DashIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Open Maps",
                               identifier: "home.openMaps") {
                    app.open(.maps)
                }
                .padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                MapControls(position: $position).padding(10)
            }
            .overlay(alignment: .topLeading) {
                LocationDeniedBanner().padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                // Sits above the Apple Maps logo and Legal link, which must stay visible.
                AssistantButton().padding(.leading, 10).padding(.bottom, 40)
            }
    }

    /// Map / card widths. With an active fold, the gap sits exactly on the fold.
    static func splitWidths(width: CGFloat, fold: CGRect?) -> (map: CGFloat, cards: CGFloat, gap: CGFloat) {
        if let fold, fold.height > fold.width, fold.minX > 200, width - fold.maxX > 200 {
            let gap = max(Theme.gap, fold.width)
            return (fold.minX, width - fold.maxX, gap)
        }
        let cards = min(420, max(250, width * 0.4))
        return (max(0, width - cards - Theme.gap), cards, Theme.gap)
    }
}

struct NowPlayingCard: View {
    @Environment(NowPlayingModel.self) private var nowPlaying
    @Environment(AppModel.self) private var app
    /// One row (art, title, controls) for the stacked dashboard.
    var compact = false

    var body: some View {
        Card(padding: compact ? 10 : 16) {
            if compact {
                HStack(spacing: 10) {
                    header
                    controls(showsPrevious: false)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    Spacer(minLength: 0)
                    controls(showsPrevious: true).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var header: some View {
        Button {
            app.open(nowPlaying.source.dockItem ?? .music)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(image: nowPlaying.artwork, size: compact ? 48 : 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlaying.title ?? "Nothing playing").font(.dashBody).lineLimit(1)
                    Text(nowPlaying.artist ?? "Tap to choose music")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Theme.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(nowPlaying.title ?? "Nothing playing")
        .accessibilityIdentifier("home.nowplaying")
    }

    @ViewBuilder
    private func controls(showsPrevious: Bool) -> some View {
        if nowPlaying.source != .none {
            HStack(spacing: 10) {
                if showsPrevious {
                    DashIconButton(symbol: "backward.fill", label: "Previous") { nowPlaying.skipToPrevious() }
                }
                DashIconButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", prominent: true,
                               label: nowPlaying.isPlaying ? "Pause" : "Play", identifier: "home.playpause") {
                    nowPlaying.togglePlayPause()
                }
                DashIconButton(symbol: "forward.fill", label: "Next", identifier: "home.next") { nowPlaying.skipToNext() }
            }
        }
    }
}

/// Next manoeuvre while guiding; otherwise resume or one-tap favourite destinations.
struct NextTurnCard: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(AppModel.self) private var app
    @State private var editor: PlacesEditorTarget?

    var body: some View {
        Card {
            switch navigation.state {
            case .navigating, .arrived:
                VStack(alignment: .leading, spacing: 10) {
                    TurnBannerView(compact: true)
                    Spacer(minLength: 0)
                    HStack {
                        if let eta = navigation.eta, navigation.state == .navigating {
                            Text("ETA \(eta, format: .dateTime.hour().minute()) · \(TripSummaryView.duration(navigation.remainingTime))")
                                .font(.dashCaption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Spacer(minLength: 4)
                        DashPillButton(title: navigation.state == .arrived ? "Done" : "End", tint: Theme.danger,
                                       identifier: "home.end") { navigation.end() }
                    }
                }
            case .calculating:
                HStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Finding route…").font(.dashBody)
                }
            case .previewing:
                VStack(alignment: .leading, spacing: 10) {
                    Text(navigation.destination?.name ?? "Route ready").font(.dashTitle).lineLimit(1)
                    Spacer(minLength: 0)
                    HStack {
                        DashPillButton(title: "Start", symbol: "location.north.fill") { navigation.start() }
                        DashPillButton(title: "View", prominent: false) { app.open(.maps) }
                    }
                }
            case .idle:
                VStack(alignment: .leading, spacing: 10) {
                    if let resumable = navigation.resumable {
                        Text("Resume route to \(resumable.name)?").font(.dashBody).lineLimit(2)
                        HStack(spacing: 10) {
                            DashPillButton(title: "Resume", symbol: "location.north.fill", identifier: "home.resume") {
                                navigation.resume()
                            }
                            DashIconButton(symbol: "xmark", label: "Dismiss", identifier: "home.resume.dismiss") {
                                navigation.dismissResume()
                            }
                        }
                    } else {
                        HStack {
                            Text("Where to?").font(.dashTitle)
                            Spacer(minLength: 0)
                            // Full 60 pt target; it overhangs the card padding instead of growing the header.
                            EditPlacesButton(identifier: "home.fav.edit") { editor = PlacesEditorTarget() }
                                .padding(.vertical, -10)
                                .padding(.trailing, -12)
                        }
                        FavouritesRow { item in
                            navigation.go(to: item)
                        } onEdit: { id in
                            editor = PlacesEditorTarget(placeID: id)
                        }
                    }
                    if let error = navigation.errorMessage {
                        Text(error).font(.dashCaption).foregroundStyle(Theme.warning).lineLimit(2)
                    }
                }
            }
        }
        // Keep the card a container so its id doesn't replace the ids of the
        // End / Resume / favourite buttons inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.nextturn")
        .placesEditor($editor)
    }
}

/// Favourite contacts with one-tap call / message (Phone and Messages screens).
struct FavouriteContactsCard: View {
    var body: some View {
        Card(padding: 12) {
            FavouriteContactsStrip()
        }
    }
}
