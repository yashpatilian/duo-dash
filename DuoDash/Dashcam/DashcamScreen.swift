import AVKit
import SwiftUI
import UIKit

/// The Dashcam app: live picture with a REC timer, a big Save clip button,
/// start/stop, loop and storage info, and the saved clips. Wide windows put the
/// clips beside the camera; narrow ones stack them underneath.
struct DashcamScreen: View {
    @Environment(DashcamModel.self) private var dashcam
    @State private var playing: DashcamClip?
    @State private var confirmDelete: DashcamClip?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let wide = size.width > size.height && size.width >= 700
            Group {
                if wide {
                    HStack(alignment: .top, spacing: Theme.gap) {
                        VStack(spacing: Theme.gap) {
                            cameraCard.frame(maxHeight: .infinity)
                            controls
                        }
                        clipsCard
                            .frame(width: min(420, size.width * 0.36))
                    }
                } else {
                    VStack(spacing: Theme.gap) {
                        cameraCard
                            .frame(height: min(size.height * 0.46, size.width * 0.75))
                        controls
                        clipsCard.frame(maxHeight: .infinity)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .overlay(alignment: .top) { messageBanner }
        .sheet(item: $playing) { clip in
            DashcamPlayerView(clip: clip, isDemo: dashcam.isDemo) { playing = nil }
        }
        .confirmationDialog("Delete this clip?", isPresented: deleteBinding, titleVisibility: .visible,
                            presenting: confirmDelete) { clip in
            Button("Delete", role: .destructive) { dashcam.delete(clip) }
            Button("Cancel", role: .cancel) {}
        } message: { clip in
            Text(clip.title)
        }
        .accessibilityIdentifier("dashcam")
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }

    // MARK: Camera

    private var cameraCard: some View {
        ZStack {
            if let session = dashcam.captureSession {
                DashcamCameraPreview(session: session)
            } else {
                DashcamDemoRoad()
            }
            if !dashcam.state.isRecording { stateOverlay }
        }
        .overlay(alignment: .topLeading) { recBadge.padding(12) }
        .overlay(alignment: .topTrailing) { qualityBadge.padding(12) }
        .overlay(alignment: .bottom) {
            if let warning = dashcam.heatWarning {
                Label(warning, systemImage: "thermometer.high")
                    .font(.dashCaption)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.warning, in: Capsule())
                    .padding(12)
                    .accessibilityIdentifier("dashcam.heat")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    @ViewBuilder
    private var recBadge: some View {
        if dashcam.state.isRecording, let start = dashcam.recordingStartedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.danger)
                        .symbolEffect(.pulse)
                    Text("REC \(Self.elapsed(from: start, to: context.date))")
                        .font(.dashCaption)
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
            }
            .accessibilityIdentifier("dashcam.rec")
        }
    }

    private var qualityBadge: some View {
        Text(dashcam.quality.title)
            .font(.dashCaption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
    }

    @ViewBuilder
    private var stateOverlay: some View {
        let state = dashcam.state
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 12) {
                Image(systemName: symbol(for: state))
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(state == .idle ? Theme.textSecondary : Theme.warning)
                Text(title(for: state))
                    .font(.dashTitle)
                    .multilineTextAlignment(.center)
                if state == .idle {
                    Text("Not recording. Point the Duo's rear cameras at the road, then start. It keeps the last \(dashcam.settings.loopMinutes) minutes; Save clip keeps a moment for good.")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    DashPillButton(title: "Start recording", symbol: "record.circle", tint: Theme.danger,
                                   identifier: "dashcam.startHint") {
                        Task { await dashcam.start() }
                    }
                    Text("To start every time Duo Dash opens: Settings → Dashcam → Start automatically.")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                if state == .permissionDenied {
                    Text("Allow camera access for Duo Dash in Settings.")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    DashPillButton(title: "Open Settings", symbol: "gear", identifier: "dashcam.openSettings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashcam.state")
    }

    private func symbol(for state: DashcamState) -> String {
        switch state {
        case .idle, .recording: "video.slash"
        case .starting: "video"
        case .interrupted: "pause.circle"
        case .unavailable: "exclamationmark.triangle"
        case .permissionDenied: "lock.fill"
        }
    }

    private func title(for state: DashcamState) -> String {
        switch state {
        case .idle: "Dashcam is off"
        case .permissionDenied: "Camera access is off"
        default: state.summary
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: Controls

    private var controls: some View {
        let active: Bool = {
            switch dashcam.state {
            case .recording, .starting: return true
            case .interrupted: return dashcam.wantsRecording
            default: return false
            }
        }()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                startStop(active: active)
                info
                Spacer(minLength: 0)
                saveButton
            }
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    startStop(active: active)
                    info
                    Spacer(minLength: 0)
                }
                saveButton.frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private func startStop(active: Bool) -> some View {
        DashIconButton(symbol: active ? "stop.fill" : "record.circle", size: 64, prominent: true,
                       tint: active ? Color(white: 0.35) : Theme.danger,
                       label: active ? "Stop dashcam" : "Start dashcam", identifier: "dashcam.toggle") {
            dashcam.toggle()
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dashcam.loopDescription).font(.dashBody).lineLimit(1)
            Text(dashcam.storageDescription)
                .font(.dashCaption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var saveButton: some View {
        DashPillButton(title: dashcam.isSaving ? "Saving…" : "Save clip", symbol: "star.fill",
                       tint: Theme.danger, identifier: "dashcam.save") {
            Task { await dashcam.saveClip() }
        }
        .disabled(dashcam.isSaving)
    }

    // MARK: Saved clips

    private var clipsCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Saved clips").font(.dashTitle)
                if dashcam.savedClips.isEmpty {
                    Text("Tap Save clip to keep the last minute or two. The loop never deletes saved clips.")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(dashcam.savedClips) { clip in clipRow(clip) }
                        }
                    }
                }
            }
        }
    }

    private func clipRow(_ clip: DashcamClip) -> some View {
        HStack(spacing: 8) {
            Button { playing = clip } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip.title).font(.dashBody).lineLimit(1)
                        Text(clip.subtitle)
                            .font(.dashCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("dashcam.clip.\(clip.id)")

            DashIconButton(symbol: "square.and.arrow.down", label: "Save to Photos",
                           identifier: "dashcam.clip.photos") {
                Task { await dashcam.saveToPhotos(clip) }
            }
            DashIconButton(symbol: "trash", label: "Delete clip", identifier: "dashcam.clip.delete") {
                confirmDelete = clip
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Messages

    @ViewBuilder
    private var messageBanner: some View {
        if let message = dashcam.message {
            Button { dashcam.message = nil } label: {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
                    Text(message).font(.dashBody).multilineTextAlignment(.leading)
                    Image(systemName: "xmark").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: Theme.minTouch)
                .background(Theme.surfaceRaised, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("dashcam.message")
            .task(id: message) {
                try? await Task.sleep(for: .seconds(4))
                if dashcam.message == message { withAnimation { dashcam.message = nil } }
            }
        }
    }
}

/// Plays a saved clip's segments back to back.
struct DashcamPlayerView: View {
    let clip: DashcamClip
    let isDemo: Bool
    let close: () -> Void
    @State private var player: AVQueuePlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.background.ignoresSafeArea()
            if isDemo {
                EmptyStateView(symbol: "film", title: clip.title,
                               message: "Demo clips are placeholders with no video. On an iPhone this plays the recording.")
            } else if let player {
                VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
            }
            DashIconButton(symbol: "xmark", label: "Close", identifier: "dashcam.player.close", action: close)
                .padding(16)
        }
        .onAppear {
            guard !isDemo, player == nil else { return }
            let queue = AVQueuePlayer(items: clip.segments.map { AVPlayerItem(url: $0) })
            player = queue
            queue.play()
        }
        .onDisappear { player?.pause() }
    }
}

/// Dashcam preferences, ready to drop into Settings.
struct DashcamSettingsPanel: View {
    @Environment(DashcamModel.self) private var dashcam

    var body: some View {
        @Bindable var settings = dashcam.settings
        VStack(alignment: .leading, spacing: 14) {
            Text("Keep the last").font(.dashBody)
            HStack(spacing: Theme.gap) {
                ForEach(DashcamSettings.loopOptions, id: \.self) { minutes in
                    let selected = settings.loopMinutes == minutes
                    Button {
                        settings.loopMinutes = minutes
                        dashcam.pruneLoop()
                    } label: {
                        Text("\(minutes) min")
                            .font(.dashBody)
                            .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                            .background(selected ? Theme.accent : Theme.surfaceRaised,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("dashcam.loop.\(minutes)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text("Lens").font(.dashBody)
            HStack(spacing: Theme.gap) {
                ForEach(DashcamLens.allCases, id: \.self) { lens in
                    let selected = settings.lens == lens
                    Button { settings.lens = lens } label: {
                        Text(lens.title)
                            .font(.dashBody)
                            .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                            .background(selected ? Theme.accent : Theme.surfaceRaised,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("dashcam.lens.\(lens.rawValue)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text("Ultra Wide sees both lanes and the kerb. A change applies the next time recording starts.")
                .font(.dashCaption).foregroundStyle(Theme.textSecondary)
            Toggle(isOn: $settings.recordsAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record sound").font(.dashBody)
                    Text("Uses the microphone. Off by default.").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.accent)
            .frame(minHeight: Theme.minTouch)
            .accessibilityIdentifier("dashcam.audio")
            Toggle(isOn: $settings.autoStart) {
                Text("Start when Duo Dash opens").font(.dashBody)
            }
            .tint(Theme.accent)
            .frame(minHeight: Theme.minTouch)
            .accessibilityIdentifier("dashcam.autoStart")
        }
    }
}
