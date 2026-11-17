import SwiftUI
import MapKit

/// CarPlay-style dashboard: map plus stacked cards.
/// Wide windows split side by side (aligned to the fold when the phone is half
/// open); tall or narrow windows (portrait, cover screen, Split View) stack.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(CalendarModel.self) private var calendar
    @Environment(CarDataModel.self) private var car
    @Environment(NavigationModel.self) private var navigation
    @Environment(HomeLayoutSettings.self) private var homeLayout
    @Environment(\.dashMetrics) private var metrics
    @State private var position: MapCameraPosition = MapOrientation.current().followPosition(guiding: false)

    var body: some View {
        if app.showsAppGrid {
            AppGridView().transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else {
            dashboard.transition(.opacity)
        }
    }

    private var dashboard: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let wide = metrics.homeIsSplit
            // Duo Dash Pro → Home layout can put the map on the right and reorder the cards.
            let mapLeft = !wide || homeLayout.mapOnLeft
            let fold = wide ? FoldGeometry.foldFrame(in: proxy) : nil
            let split = Self.columnWidths(width: size.width, fold: fold, mapOnLeft: mapLeft)
            let layout = wide ? AnyLayout(HStackLayout(spacing: split.gap))
                              : AnyLayout(VStackLayout(spacing: Theme.gap))
            layout {
                if mapLeft {
                    map
                        .frame(width: wide ? split.map : nil)
                        .layoutPriority(1)
                }

                VStack(spacing: Theme.gap) {
                    if wide {
                        // Now Playing takes the spare height (big artwork); the others keep their natural size.
                        ForEach(homeLayout.wideColumn) { card in
                            wideCard(card, height: size.height)
                        }
                    } else {
                        ForEach(homeLayout.narrowCards) { card in
                            if card == .nextTurn {
                                NextTurnCard().fixedSize(horizontal: false, vertical: true)
                            } else {
                                NowPlayingCard(compact: true).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(width: wide ? split.cards : nil)

                if !mapLeft {
                    map
                        .frame(width: split.map)
                        .layoutPriority(1)
                }
            }
        }
    }

    @ViewBuilder
    private func wideCard(_ card: HomeCard, height: CGFloat) -> some View {
        switch card {
        case .nowPlaying:
            NowPlayingCard()
        case .nextTurn:
            NextTurnCard().fixedSize(horizontal: false, vertical: true)
        case .extra:
            if height >= 520 { extraCard }
        case .map:
            EmptyView()
        }
    }

    /// The third card. Automatic (the free behaviour): live car data when an OBD adapter is
    /// connected; else the next event + weather; else favourite contacts.
    @ViewBuilder
    private var extraCard: some View {
        switch homeLayout.effectiveExtra {
        case .automatic:
            if car.state.isConnected {
                carCard
            } else if calendar.nextEvent != nil {
                nextUpCard
            } else {
                FavouriteContactsCard().fixedSize(horizontal: false, vertical: true)
            }
        case .car: carCard
        case .nextEvent: nextUpCard
        case .contacts: FavouriteContactsCard().fixedSize(horizontal: false, vertical: true)
        case .weather: HomeWeatherCard(onOpen: { app.open(.weather) }).frame(maxHeight: 150)
        }
    }

    private var carCard: some View {
        CarDashboardCard(compact: true, onOpen: { app.open(.car) })
            .frame(maxHeight: 150)
    }

    private var nextUpCard: some View {
        NextUpCard(onNavigate: { navigation.go(to: $0) }, onOpenCalendar: { app.open(.calendar) })
            .frame(maxHeight: 150)
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
                MapControls(position: $position, idPrefix: "home.map").padding(10)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    LocationDeniedBanner()
                    WeatherChip(showsText: false)
                }
                .padding(10)
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

    /// `splitWidths` with the map on either side. On the fold, each column keeps its own half;
    /// otherwise the map keeps the larger share wherever it is.
    static func columnWidths(width: CGFloat, fold: CGRect?, mapOnLeft: Bool) -> (map: CGFloat, cards: CGFloat, gap: CGFloat) {
        let split = splitWidths(width: width, fold: fold)
        guard !mapOnLeft, let fold, fold.height > fold.width, fold.minX > 200, width - fold.maxX > 200 else { return split }
        // Fold-aligned and the map on the right: the right half is the map's.
        return (split.cards, split.map, split.gap)
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
            } else if nowPlaying.source == .none && nowPlaying.title == nil {
                idle
            } else {
                GeometryReader { proxy in
                    // Artwork as big as the card allows, with the controls in a row underneath.
                    let art = min(proxy.size.height - Theme.minTouch - 14, proxy.size.width * 0.46, 176)
                    VStack(alignment: .leading, spacing: 14) {
                        if art >= 72 {
                            HStack(alignment: .top, spacing: 16) {
                                artworkButton(size: art)
                                titles(large: true)
                                Spacer(minLength: 0)
                            }
                        } else {
                            header
                        }
                        Spacer(minLength: 0)
                        controls(showsPrevious: true).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// Nothing playing: quick ways in, instead of an empty card.
    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    sourceButton(.music, title: "Apple Music", showsTitle: true)
                    sourceButton(.spotify, title: "Spotify", showsTitle: true)
                }
                HStack(spacing: 10) {
                    sourceButton(.music, title: "Apple Music", showsTitle: false)
                    sourceButton(.spotify, title: "Spotify", showsTitle: false)
                }
            }
        }
    }

    private func sourceButton(_ item: DockItem, title: String, showsTitle: Bool) -> some View {
        Button { app.open(item) } label: {
            HStack(spacing: 12) {
                if let asset = item.officialIconAsset {
                    Image(asset).resizable().scaledToFit().frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    AppTile(item: item, size: 40)
                }
                if showsTitle {
                    Text(title).font(.dashBody).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch + 12)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
        .accessibilityIdentifier("home.nowplaying.open.\(item.rawValue)")
    }

    private func artworkButton(size: CGFloat) -> some View {
        Button { app.open(nowPlaying.source.dockItem ?? .music) } label: {
            ArtworkView(image: nowPlaying.artwork, size: size)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(nowPlaying.title ?? "Now playing")
        .accessibilityIdentifier("home.nowplaying")
    }

    private func titles(large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nowPlaying.title ?? "Nothing playing")
                .font(large ? .dashTitle : .dashBody).lineLimit(2)
            Text(nowPlaying.artist ?? "Tap to choose music")
                .font(large ? .dashBody : .dashCaption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if large, nowPlaying.source != .none {
                Text(nowPlaying.source.displayName)
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
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
            GlassTransport(isPlaying: nowPlaying.isPlaying, showsPrevious: showsPrevious,
                           scale: showsPrevious ? 1.1 : 1, idPrefix: "home",
                           previous: { nowPlaying.skipToPrevious() },
                           playPause: { nowPlaying.togglePlayPause() },
                           next: { nowPlaying.skipToNext() })
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
