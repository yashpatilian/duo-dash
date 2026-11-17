import MapKit
import SwiftUI

/// Duo Dash Pro → Trip history: the list of drives, and each one's route on a map.
/// Drawn over the app by RootView (so it fits any window size, like the paywall).
struct TripsScreen: View {
    @Environment(TripStore.self) private var store
    @State private var selected: Trip?
    @State private var confirmDeleteAll = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let selected {
                TripDetailView(trip: selected) { withAnimation(.smooth(duration: 0.3)) { self.selected = nil } }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            } else {
                list.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trips.screen")
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    GlassBackButton(label: "Back", identifier: "trips.close") { store.isBrowsing = false }
                    Spacer()
                    if !store.trips.isEmpty {
                        Button("Delete All", role: .destructive) { confirmDeleteAll = true }
                            .font(.dashBody)
                            .frame(minHeight: Theme.minTouch)
                            .padding(.horizontal, 12)
                            .accessibilityIdentifier("trips.deleteAll")
                    }
                }
                Text("Trip History").font(.system(size: 30, weight: .bold)).accessibilityAddTraits(.isHeader)
                if store.trips.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "car.rear.road.lane").font(.system(size: 36)).foregroundStyle(Theme.accent)
                        Text("No trips yet").font(.dashTitle)
                        Text(store.isRecordingEnabled
                             ? "Drives are saved here automatically once you've driven faster than 15 km/h for 30 seconds."
                             : "Turn on Record trips in Settings → Duo Dash Pro to keep your drives here.")
                            .font(.dashCaption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
                } else {
                    Text("\(store.trips.count) \(store.trips.count == 1 ? "trip" : "trips") · \(TripFormat.distance(store.totalDistance))")
                        .font(.dashCaption).foregroundStyle(Theme.textSecondary).padding(.horizontal, 6)
                    VStack(spacing: 0) {
                        ForEach(Array(store.trips.enumerated()), id: \.element.id) { index, trip in
                            if index > 0 { Theme.separator.frame(height: 0.5).padding(.leading, 18) }
                            Button { withAnimation(.smooth(duration: 0.3)) { selected = trip } } label: {
                                TripRow(trip: trip)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("trips.row.\(index)")
                        }
                    }
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
                }
                Text("Trips stay on this iPhone. Duo Dash keeps the latest \(TripStore.maxTrips).")
                    .font(.dashCaption).foregroundStyle(Theme.textSecondary).padding(.horizontal, 6)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .confirmationDialog("Delete all trips?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All Trips", role: .destructive) { store.deleteAll() }
        }
    }
}

private struct TripRow: View {
    let trip: Trip

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "car.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.title).font(.dashBody.weight(.regular)).lineLimit(1)
                Text("\(trip.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(TripFormat.duration(trip.duration))")
                    .font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(TripFormat.distance(trip.distanceMeters)).font(.dashBody.weight(.regular)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
            Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Theme.minTouch + 10)
        .contentShape(Rectangle())
    }
}

/// One trip: the route on a map, then its numbers.
struct TripDetailView: View {
    @Environment(TripStore.self) private var store
    let trip: Trip
    let back: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height && proxy.size.width >= 600
            let layout = wide ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    GlassBackButton(label: "Trips", identifier: "trips.back", action: back)
                    Text(trip.title).font(.dashTitle).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        store.delete(trip)
                        back()
                    } label: {
                        Image(systemName: "trash").font(.system(size: 20, weight: .semibold))
                            .frame(width: Theme.minTouch, height: Theme.minTouch)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.danger)
                    .accessibilityLabel("Delete trip")
                    .accessibilityIdentifier("trips.delete")
                }
                layout {
                    TripRouteMap(trip: trip)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        .accessibilityIdentifier("trips.map")
                    ScrollView {
                        stats.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: wide ? min(320, proxy.size.width * 0.4) : nil)
                    .frame(maxHeight: wide ? .infinity : 220)
                    .scrollIndicators(.hidden)
                }
            }
            .padding(14)
        }
    }

    private var stats: some View {
        VStack(spacing: 0) {
            stat("Distance", TripFormat.distance(trip.distanceMeters))
            divider
            stat("Duration", TripFormat.duration(trip.duration))
            divider
            stat("Average speed", TripFormat.speed(trip.averageSpeed))
            divider
            stat("Top speed", TripFormat.speed(trip.maxSpeed))
            divider
            stat("Started", "\(trip.startName.map { "\($0), " } ?? "")\(trip.startedAt.formatted(date: .omitted, time: .shortened))")
            divider
            stat("Ended", "\(trip.endName.map { "\($0), " } ?? "")\(trip.endedAt.formatted(date: .omitted, time: .shortened))")
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
    }

    private var divider: some View { Theme.separator.frame(height: 0.5).padding(.leading, 18) }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.dashBody.weight(.regular))
            Spacer(minLength: 8)
            Text(value).font(.dashBody.weight(.regular)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 50)
    }
}

/// The route as a line, with markers at both ends.
private struct TripRouteMap: View {
    let trip: Trip

    var body: some View {
        Map(initialPosition: position) {
            MapPolyline(coordinates: trip.route.map(\.coordinate))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let first = trip.route.first {
                Marker(trip.startName ?? "Start", systemImage: "flag", coordinate: first.coordinate).tint(Theme.positive)
            }
            if let last = trip.route.last {
                Marker(trip.endName ?? "End", systemImage: "flag.checkered", coordinate: last.coordinate).tint(Theme.danger)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private var position: MapCameraPosition {
        guard !trip.route.isEmpty else { return .automatic }
        let lats = trip.route.map(\.latitude), lons = trip.route.map(\.longitude)
        let span = MKCoordinateSpan(latitudeDelta: max(0.005, (lats.max()! - lats.min()!) * 1.4),
                                    longitudeDelta: max(0.005, (lons.max()! - lons.min()!) * 1.4))
        let centre = CLLocationCoordinate2D(latitude: (lats.max()! + lats.min()!) / 2, longitude: (lons.max()! + lons.min()!) / 2)
        return .region(MKCoordinateRegion(center: centre, span: span))
    }
}

/// The round Liquid Glass back button used by Settings pages.
struct GlassBackButton: View {
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

enum TripFormat {
    static func distance(_ meters: Double) -> String {
        Measurement(value: meters / 1000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func speed(_ metresPerSecond: Double) -> String {
        Measurement(value: metresPerSecond, unit: UnitSpeed.metersPerSecond).converted(to: .kilometersPerHour)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
