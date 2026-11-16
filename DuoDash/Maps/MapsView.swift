import SwiftUI
import MapKit

/// Full-screen map with search, route preview and turn-by-turn guidance.
struct MapsView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dashMetrics) private var metrics
    @State private var position: MapCameraPosition = MapOrientation.current().followPosition(guiding: false)
    @State private var search = SearchModel()

    var body: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < 560
            // Guiding on a small window: one slim card across the top (see GuidancePanel).
            let slimGuidance = metrics.isCompact && (navigation.state == .navigating || navigation.state == .arrived)
            let panelWidth = narrow ? proxy.size.width - 24
                : slimGuidance ? min(560, proxy.size.width - 24)
                : min(420, max(320, proxy.size.width * 0.4))
            ZStack(alignment: .topLeading) {
                DashMapView(position: $position)

                HStack(alignment: .top, spacing: Theme.gap) {
                    VStack(alignment: .leading, spacing: Theme.gap) {
                        LocationDeniedBanner()
                        panel(maxHeight: proxy.size.height - 24)
                        Spacer(minLength: 0)
                    }
                    .frame(width: panelWidth)

                    if !narrow { Spacer(minLength: 0) }
                }
                .padding(12)

                // Floating map buttons, bottom-right (clear of the compass).
                VStack(alignment: .trailing, spacing: Theme.gap) {
                    if navigation.isGuiding {
                        DashIconButton(symbol: navigation.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                       label: navigation.voiceEnabled ? "Mute voice" : "Unmute voice",
                                       identifier: "nav.voice") {
                            navigation.voiceEnabled.toggle()
                        }
                    }
                    MapControls(position: $position)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                // Voice assistant: its button and panel (DuoDash/Assistant).
                // On short windows the left panel reaches the bottom, so the button moves past it.
                AssistantOverlay(buttonLeading: !narrow && !slimGuidance && proxy.size.height < 520 ? panelWidth + 12 : 0)
            }
            .animation(.snappy, value: navigation.state)
        }
        .onChange(of: navigation.state) { _, state in
            switch state {
            case .previewing:
                if let rect = navigation.route?.polyline.boundingMapRect {
                    withAnimation { position = .rect(rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25)) }
                }
            case .navigating, .idle:
                withAnimation { position = MapOrientation.current().followPosition(guiding: state == .navigating) }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private func panel(maxHeight: CGFloat) -> some View {
        switch navigation.state {
        case .idle:
            SearchPanel(search: search, maxHeight: maxHeight) { item in
                navigation.preview(to: item)
            }
        case .calculating:
            HStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Finding route to \(navigation.destination?.name ?? "destination")…")
                    .font(.dashBody)
                    .lineLimit(2)
                Spacer(minLength: 0)
                DashIconButton(symbol: "xmark", label: "Cancel", identifier: "nav.cancel") { navigation.end() }
            }
            .padding(16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        case .previewing:
            RoutePreviewCard(onCancel: { navigation.end() })
        case .navigating, .arrived:
            GuidancePanel()
        }
    }
}

/// Shown after a search result is picked: time, distance, Start, Save.
struct RoutePreviewCard: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(FavouritesStore.self) private var favourites
    @State private var editor: PlacesEditorTarget?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(navigation.destination?.name ?? "Destination")
                .font(.dashTitle)
                .lineLimit(2)
            if let address = navigation.destination?.addressLine {
                Text(address)
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            if let route = navigation.route {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    // Whole trip, including any stops on the way.
                    Text(TripSummaryView.duration(navigation.tripTime)).font(.dashHero)
                    Text(DistanceText.display(navigation.tripDistance))
                        .font(.dashBody)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !route.name.isEmpty {
                    Text("via \(route.name)").font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                if let destination = navigation.destination {
                    DestinationWeatherBadge(coordinate: destination.location.coordinate,
                                            eta: Date().addingTimeInterval(navigation.tripTime), showsAttribution: true)
                }
            }
            HStack(spacing: 10) {
                DashPillButton(title: "Start", symbol: "location.north.fill", identifier: "nav.start") { navigation.start() }
                if let destination = navigation.destination {
                    Menu {
                        ForEach(favourites.places) { place in
                            Button {
                                favourites.setLocation(place.id, item: destination)
                            } label: {
                                Label("Save as \(place.name)", systemImage: place.isSet ? "star.fill" : "plus.circle")
                            }
                        }
                        Divider()
                        Button("New place…", systemImage: "plus") {
                            let place = favourites.add(item: destination)
                            editor = PlacesEditorTarget(placeID: place.id)
                        }
                    } label: {
                        Image(systemName: "star.fill")
                            .font(.system(size: 22, weight: .bold))
                            .frame(width: Theme.minTouch, height: Theme.minTouch)
                            .contentShape(Circle())
                    }
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Save as favourite")
                    .accessibilityIdentifier("nav.save")
                }
                Spacer(minLength: 0)
                DashIconButton(symbol: "xmark", label: "Cancel", identifier: "nav.cancel", action: onCancel)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .placesEditor($editor)
    }
}

/// Banner, trip summary and End button during guidance.
struct GuidancePanel: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dashMetrics) private var metrics

    var body: some View {
        if metrics.isCompact {
            // Folded / small windows: one slim card so most of the map stays visible.
            CompactGuidanceCard()
                .contentShape(Rectangle())
                .onTapGesture { navigation.repeatInstruction() }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nav.banner")
        } else {
            fullPanel
        }
    }

    private var fullPanel: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            TurnBannerView()
                .padding(16)
                .contentShape(Rectangle())
                .onTapGesture { navigation.repeatInstruction() }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nav.banner")

            HStack(alignment: .center) {
                TripSummaryView()
                Spacer(minLength: 8)
                DashPillButton(title: navigation.state == .arrived ? "Done" : "End", tint: Theme.danger,
                               identifier: "nav.end") {
                    navigation.end()
                }
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
    }
}
