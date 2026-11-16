import SwiftUI
import MapKit

/// Round sparkles button that opens the assistant (switching to Maps). Usable
/// anywhere, e.g. Home: `AssistantButton()` or `AssistantButton(size: 72)`.
struct AssistantButton: View {
    var size: CGFloat = Theme.minTouch
    @Environment(AssistantModel.self) private var assistant

    var body: some View {
        let side = max(size, Theme.minTouch)
        Button { assistant.present() } label: {
            Image(systemName: "sparkles")
                .font(.system(size: side * 0.42, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .symbolEffect(.pulse, isActive: assistant.phase == .thinking)
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Theme.accent).interactive(), in: Circle())
        .accessibilityLabel("Assistant")
        .accessibilityIdentifier("assistant.open")
    }
}

/// Everything the Maps screen needs: the floating button, and the panel when open.
/// MapsView adds this as one overlay.
struct AssistantOverlay: View {
    @Environment(AssistantModel.self) private var assistant

    var body: some View {
        @Bindable var assistant = assistant
        GeometryReader { proxy in
            let narrow = proxy.size.width < 560
            ZStack(alignment: narrow ? .bottom : .trailing) {
                if assistant.isPresented {
                    AssistantPanel(compact: narrow || proxy.size.height < 520)
                        .frame(width: narrow ? proxy.size.width - 24 : min(460, max(340, proxy.size.width * 0.46)))
                        .frame(maxHeight: proxy.size.height - 24)
                        .padding(12)
                        .transition(.move(edge: narrow ? .bottom : .trailing).combined(with: .opacity))
                } else {
                    AssistantButton()
                        .padding(12)
                        // Clear of the Apple Maps logo and Legal link, which must stay visible.
                        .padding(.bottom, 30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: narrow ? .bottom : .trailing)
        }
        .animation(.snappy, value: assistant.isPresented)
        .mapItemDetailSheet(item: $assistant.detailItem)
    }
}

/// The Liquid Glass assistant panel: mic, what was heard, the reply, place cards
/// and the planned trip.
struct AssistantPanel: View {
    var compact = false
    @Environment(AssistantModel.self) private var assistant
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    conversation
                    if !assistant.choices.isEmpty { choices }
                    if showsPlan { AssistantTripCard() }
                    if !assistant.results.isEmpty || !navigation.legs.isEmpty { AssistantMap(height: compact ? 150 : 200) }
                    ForEach(Array(assistant.results.enumerated()), id: \.element.id) { index, place in
                        PlaceCard(index: index, place: place)
                    }
                }
            }
            .scrollIndicators(.hidden)
            inputBar
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.panel")
    }

    private var showsPlan: Bool {
        navigation.destination != nil && [.calculating, .previewing].contains(navigation.state)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Assistant").font(.dashTitle)
                Text(assistant.brainName.isEmpty ? assistant.settings.provider.title : assistant.brainName)
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !assistant.heard.isEmpty {
                DashIconButton(symbol: "arrow.counterclockwise", label: "New conversation", identifier: "assistant.reset") {
                    assistant.reset()
                }
            }
            DashIconButton(symbol: "xmark", label: "Close assistant", identifier: "assistant.close") {
                assistant.dismiss()
            }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        let listening = assistant.isListening
        if listening || assistant.heard.isEmpty && assistant.reply.isEmpty {
            Text(listening ? (assistant.draft.isEmpty ? "Listening…" : assistant.draft)
                           : "Ask for places or directions: \"take me to Sam's house\", \"find dinner near me\", \"stop for petrol on the way\".")
                .font(listening ? .dashTitle : .dashBody)
                .foregroundStyle(listening ? Theme.textPrimary : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !assistant.heard.isEmpty && !listening {
            Label(assistant.heard, systemImage: "person.wave.2.fill")
                .font(.dashCaption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .accessibilityIdentifier("assistant.heard")
        }
        if assistant.phase == .thinking {
            HStack(spacing: 10) {
                ProgressView()
                Text("Thinking…").font(.dashBody).foregroundStyle(Theme.textSecondary)
            }
        } else if !assistant.reply.isEmpty {
            Text(assistant.reply)
                .font(.dashTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistant.reply")
        }
        if let notice = assistant.notice {
            Label(notice, systemImage: "exclamationmark.circle.fill")
                .font(.dashCaption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistant.notice")
        }
    }

    private var choices: some View {
        VStack(spacing: 6) {
            ForEach(assistant.choices) { choice in
                ResultRow(title: choice.name, subtitle: choice.detail, symbol: "person.crop.circle.fill") {
                    assistant.choose(choice)
                }
            }
        }
    }

    private var inputBar: some View {
        @Bindable var assistant = assistant
        let listening = assistant.isListening
        return HStack(spacing: 10) {
            Button { assistant.toggleListening() } label: {
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 30, weight: .bold))
                    .symbolEffect(.variableColor.iterative, isActive: listening)
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: Theme.minTouch + 16, height: Theme.minTouch + 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(listening ? Theme.danger : Theme.accent).interactive(), in: Circle())
            .accessibilityLabel(listening ? "Stop listening" : "Speak")
            .accessibilityIdentifier("assistant.mic")

            HStack(spacing: 4) {
                TextField("Ask anything…", text: $assistant.draft)
                    .font(.dashBody)
                    .submitLabel(.send)
                    .onSubmit { assistant.send(assistant.draft) }
                    .accessibilityIdentifier("assistant.field")
                if !assistant.draft.isEmpty && !listening {
                    Button { assistant.send(assistant.draft) } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.accent)
                            .frame(width: Theme.minTouch, height: Theme.minTouch)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("assistant.send")
                }
            }
            .padding(.leading, 16)
            .frame(minHeight: Theme.minTouch)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// The planned trip: stops, total time and distance, Start.
struct AssistantTripCard: View {
    @Environment(AssistantModel.self) private var assistant
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if navigation.state == .calculating {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Planning the route…").font(.dashBody)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(TripSummaryView.duration(navigation.tripTime)).font(.dashHero).monospacedDigit()
                    Text(DistanceText.display(navigation.tripDistance))
                        .font(.dashBody)
                        .foregroundStyle(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(navigation.stops.enumerated()), id: \.offset) { index, stop in
                        Label("Stop \(index + 1): \(stop.name ?? "Stop")", systemImage: "mappin.and.ellipse")
                    }
                    Label(navigation.destination?.name ?? "Destination", systemImage: "flag.checkered")
                }
                .font(.dashCaption)
                .lineLimit(1)
                if let note = assistant.planNote {
                    Text(note).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 10) {
                    DashPillButton(title: "Start", symbol: "location.north.fill", identifier: "assistant.plan.start") {
                        assistant.startPlannedRoute()
                    }
                    Spacer(minLength: 0)
                    DashIconButton(symbol: "xmark", label: "Cancel route", identifier: "assistant.plan.cancel") {
                        assistant.cancelPlannedRoute()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.plan")
    }
}

/// One search result: name, category, distance/time, and Go / Add as stop / Details.
struct PlaceCard: View {
    let index: Int
    let place: PlaceResult
    @Environment(AssistantModel.self) private var assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(index + 1)")
                    .font(.dashBody)
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.dashBody).lineLimit(2)
                    Text(subtitle).font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                DashPillButton(title: "Go", symbol: "arrow.triangle.turn.up.right.diamond.fill", identifier: "assistant.result.go") {
                    assistant.go(to: place)
                }
                if assistant.canAddStop {
                    DashPillButton(title: "Add stop", symbol: "plus", prominent: false, identifier: "assistant.result.stop") {
                        assistant.addStop(place)
                    }
                }
                Spacer(minLength: 0)
                DashIconButton(symbol: "info", label: "Details", identifier: "assistant.result.details") {
                    assistant.showDetails(place)
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.result")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let category = place.category { parts.append(category) }
        if let eta = place.eta { parts.append(TripSummaryView.duration(eta)) }
        if let distance = place.distance { parts.append(DistanceText.display(distance)) }
        if let added = place.addedTime { parts.append("+\(TripSummaryView.duration(added))") }
        if let address = place.address { parts.append(address) }
        return parts.joined(separator: " · ")
    }
}

/// Small map with the results as numbered pins and every leg of the planned trip.
struct AssistantMap: View {
    var height: CGFloat
    @Environment(AssistantModel.self) private var assistant
    @Environment(NavigationModel.self) private var navigation
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            UserAnnotation()
            ForEach(Array(navigation.legs.enumerated()), id: \.offset) { index, leg in
                MapPolyline(leg.polyline)
                    .stroke(index == navigation.legIndex ? Theme.route : Theme.route.opacity(0.6),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(navigation.stops.enumerated()), id: \.offset) { index, stop in
                Marker("Stop \(index + 1)", systemImage: "mappin", coordinate: stop.location.coordinate)
                    .tint(Theme.warning)
            }
            if let destination = navigation.destination {
                Marker(item: destination).tint(Theme.accent)
            }
            ForEach(Array(assistant.results.enumerated()), id: \.element.id) { index, place in
                Marker(place.name, monogram: Text("\(index + 1)"), coordinate: place.item.location.coordinate)
                    .tint(Theme.positive)
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {}
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onChange(of: assistant.results.map(\.id)) { _, _ in position = .automatic }
        .onChange(of: navigation.legs.count) { _, _ in position = .automatic }
        .accessibilityIdentifier("assistant.map")
    }
}
