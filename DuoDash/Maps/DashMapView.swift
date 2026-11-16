import SwiftUI
import MapKit

/// How the map turns while you're not navigating. Guidance always follows the heading.
enum MapOrientation: String, CaseIterable {
    /// Turns with the car (the original behaviour).
    case headingUp
    /// Fixed with north at the top.
    case northUp

    static let storageKey = "map.orientation"

    /// The saved choice.
    static func current(_ defaults: UserDefaults = .standard) -> MapOrientation {
        defaults.string(forKey: storageKey).flatMap(MapOrientation.init(rawValue:)) ?? .headingUp
    }

    var toggled: MapOrientation { self == .headingUp ? .northUp : .headingUp }

    /// Whether the camera should follow the device heading.
    func followsHeading(guiding: Bool) -> Bool { guiding || self == .headingUp }

    /// Follow-the-user camera for this mode.
    func followPosition(guiding: Bool) -> MapCameraPosition {
        .userLocation(followsHeading: followsHeading(guiding: guiding), fallback: .automatic)
    }

    var symbol: String {
        switch self {
        case .headingUp: "location.north.line.fill"
        case .northUp: "n.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .headingUp: "Heading up"
        case .northUp: "North up"
        }
    }
}

/// The map used on both Home and Maps: user puck, active route and destination pins.
struct DashMapView: View {
    @Environment(NavigationModel.self) private var navigation
    @Binding var position: MapCameraPosition
    @AppStorage(MapOrientation.storageKey) private var orientation: MapOrientation = .headingUp
    @State private var lastCamera: MapCamera?
    @State private var settleTask: Task<Void, Never>?

    private var followsHeading: Bool { orientation.followsHeading(guiding: navigation.isGuiding) }

    var body: some View {
        // North up is fixed: two-finger rotation is off until guidance starts.
        Map(position: $position, interactionModes: followsHeading ? .all : [.pan, .zoom, .pitch]) {
            UserAnnotation()

            // Multi-stop trips: other legs drawn lighter (done ones faded), the
            // current leg on top in full colour.
            ForEach(Array(navigation.legs.enumerated()), id: \.offset) { index, leg in
                if index != navigation.legIndex {
                    MapPolyline(leg.polyline)
                        .stroke(Theme.route.opacity(index < navigation.legIndex ? 0.2 : 0.5),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
            }

            if let route = navigation.route {
                MapPolyline(route.polyline)
                    .stroke(Theme.route, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            }

            ForEach(Array(navigation.stops.enumerated()), id: \.offset) { index, stop in
                Marker(stop.name ?? "Stop \(index + 1)", systemImage: "\(index + 1).circle.fill",
                       coordinate: stop.location.coordinate)
                    .tint(Theme.warning)
            }

            if let destination = navigation.destination {
                Marker(item: destination)
                    .tint(Theme.accent)
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted,
                            pointsOfInterest: .excludingAll, showsTraffic: true))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in lastCamera = context.camera }
        .onAppear { applyOrientation(modeChanged: false) }
        .onChange(of: followsHeading) { _, _ in applyOrientation(modeChanged: true) }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    /// Brings the camera in line with the chosen mode. A camera that follows the
    /// user switches follow mode; a panned camera is turned to north in place
    /// (North up) or recentred (Heading up) when the mode flips.
    private func applyOrientation(modeChanged: Bool) {
        settleTask?.cancel()
        let heading = followsHeading
        if position.followsUserLocation {
            guard position.followsUserHeading != heading else { return }
            if heading {
                withAnimation { position = .userLocation(followsHeading: true, fallback: .automatic) }
            } else {
                // Turn to north first: plain follow mode keeps whatever rotation it had.
                rotateToNorth()
                settleTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled, !followsHeading else { return }
                    withAnimation { position = .userLocation(followsHeading: false, fallback: .automatic) }
                }
            }
        } else if modeChanged, !navigation.isGuiding, navigation.state != .previewing {
            if heading {
                withAnimation { position = .userLocation(followsHeading: true, fallback: .automatic) }
            } else {
                rotateToNorth()
            }
        }
    }

    private func rotateToNorth() {
        guard let camera = lastCamera else { return }
        let heading = camera.heading.truncatingRemainder(dividingBy: 360)
        guard abs(heading) > 0.5, abs(heading) < 359.5 else { return }
        withAnimation {
            position = .camera(MapCamera(centerCoordinate: camera.centerCoordinate, distance: camera.distance,
                                         heading: 0, pitch: camera.pitch))
        }
    }
}

/// The floating map buttons side by side: recenter (when panned away) and the
/// heading-up / north-up switch (hidden while guiding, which always follows heading).
struct MapControls: View {
    @Binding var position: MapCameraPosition
    /// Prefix for the buttons' ids, so the Home map's and the Maps map's controls differ.
    var idPrefix = "map"
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        HStack(spacing: Theme.gap) {
            RecenterButton(position: $position)
            if !navigation.isGuiding {
                MapOrientationButton(identifier: "\(idPrefix).orientation")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: navigation.isGuiding)
    }
}

/// Glass button that flips between Heading up and North up. Its symbol shows the current mode.
struct MapOrientationButton: View {
    @AppStorage(MapOrientation.storageKey) private var orientation: MapOrientation = .headingUp
    var identifier = "map.orientation"

    var body: some View {
        DashIconButton(symbol: orientation.symbol, label: "Map orientation: \(orientation.title)",
                       identifier: identifier) {
            orientation = orientation.toggled
        }
        .accessibilityValue(orientation.title)
        .accessibilityHint("Switches to \(orientation.toggled.title)")
        .contentTransition(.symbolEffect(.replace))
    }
}

/// Large "follow me" button shown whenever the map has been panned away.
/// Recentres in the chosen orientation (always heading up while guiding).
struct RecenterButton: View {
    @Binding var position: MapCameraPosition
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        if !position.followsUserLocation {
            DashPillButton(title: "Recenter", symbol: "location.fill", prominent: false, identifier: "map.recenter") {
                withAnimation { position = MapOrientation.current().followPosition(guiding: navigation.isGuiding) }
            }
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// Shown on top of a map when location access is off.
struct LocationDeniedBanner: View {
    @Environment(LocationManager.self) private var location

    var body: some View {
        if location.authorization == .denied || location.authorization == .restricted {
            HStack(spacing: 12) {
                Image(systemName: "location.slash.fill").foregroundStyle(Theme.warning)
                Text("Location is off for Duo Dash").font(.dashCaption)
                Spacer(minLength: 0)
                DashPillButton(title: "Settings", prominent: false) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            .padding(.leading, 16)
            .padding(6)
            .glassEffect(.regular, in: Capsule())
        }
    }
}
