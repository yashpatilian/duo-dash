import SwiftUI

/// Settings → Voice: which recogniser and voice to use, the natural voice to speak
/// with (with a preview), and the on-device model downloads.
/// Self-contained (reads `SpeechCenter.shared` unless given another), so it can be
/// dropped into SettingsView as-is.
struct SpeechSettingsSection: View {
    var center: SpeechCenter = .shared
    @State private var confirmCellular: SpeechModelKind?
    @State private var preview: SpokenOutput?

    enum SpeechModelKind: String, Identifiable {
        case whisper, kokoro
        var id: String { rawValue }
    }

    private var settings: SpeechSettings { center.settings }
    private var models: SpeechModelStore { center.models }

    var body: some View {
        @Bindable var settings = center.settings
        VStack(alignment: .leading, spacing: 14) {
            if settings.mode != .full {
                Label(settings.mode == .demo ? "Demo speech engines (testing)." : "The Simulator uses Apple's speech engines; on-device models run on the iPhone.",
                      systemImage: "info.circle.fill")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("speech.modeNotice")
            }

            // Listening
            Text("Voice input").font(.dashBody).foregroundStyle(Theme.textSecondary)
            group(footer: recognizerFooter) {
                segments(SpeechRecognizerKind.choices.map { ($0, $0.title) },
                         selection: $settings.recognizer, identifier: "speech.recognizer")
                divider
                row(title: models.whisperVariant.title,
                    subtitle: stateText(settings.whisperState, size: models.whisperVariant.downloadBytes,
                                        onDisk: models.storageRevision >= 0 ? models.whisperBytes : 0)) {
                    modelButtons(.whisper, state: settings.whisperState)
                }
                .accessibilityIdentifier("speech.whisper.row")
            }

            // Speaking
            Text("Voice").font(.dashBody).foregroundStyle(Theme.textSecondary).padding(.top, 4)
            group(footer: voiceFooter) {
                segments(SpeechVoiceKind.choices.map { ($0, $0.title) },
                         selection: $settings.voice, identifier: "speech.voice")
                divider
                row(title: "Natural voice (Kokoro)",
                    subtitle: stateText(settings.kokoroState, size: NaturalVoice.modelDownloadBytes,
                                        onDisk: models.storageRevision >= 0 ? models.kokoroBytes : 0)) {
                    modelButtons(.kokoro, state: settings.kokoroState)
                }
                .accessibilityIdentifier("speech.kokoro.row")
                divider
                voicePicker(selection: $settings.naturalVoiceID)
                divider
                row(title: "Preview", subtitle: "Plays a sample with the voice that will speak.") {
                    DashPillButton(title: "Preview", symbol: "play.fill", prominent: false,
                                   identifier: "speech.preview") {
                        playPreview()
                    }
                }
            }

            row(title: "Storage used", subtitle: storageText) { EmptyView() }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("speech.storage")
        }
        .confirmationDialog("Download on mobile data?", isPresented: Binding(
            get: { confirmCellular != nil }, set: { if !$0 { confirmCellular = nil } }),
                            titleVisibility: .visible, presenting: confirmCellular) { kind in
            Button("Download \(sizeText(kind == .whisper ? models.whisperVariant.downloadBytes : NaturalVoice.modelDownloadBytes))") {
                start(kind)
            }
            Button("Not now", role: .cancel) {}
        } message: { _ in
            Text("Wi‑Fi is recommended for the voice models.")
        }
    }

    // MARK: - Pieces

    private func voicePicker(selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Natural voice").font(.dashBody).padding(.horizontal, 16).padding(.top, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(NaturalVoice.all) { voice in
                        let selected = selection.wrappedValue == voice.id
                        Button {
                            selection.wrappedValue = voice.id
                            playPreview()
                        } label: {
                            VStack(spacing: 2) {
                                Text(voice.name).font(.dashCaption.weight(.semibold))
                                Text(voice.detail).font(.caption).opacity(0.75)
                            }
                            .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(minWidth: 96, minHeight: Theme.minTouch)
                            .background(selected ? Theme.accent : Theme.surfaceRaised,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("speech.naturalVoice.\(voice.id)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func modelButtons(_ kind: SpeechModelKind, state: SpeechModelState) -> some View {
        let id = "speech.\(kind.rawValue)"
        switch state {
        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction).frame(width: 90).tint(Theme.accent)
                DashPillButton(title: "Pause", prominent: false, identifier: "\(id).pause") {
                    kind == .whisper ? models.cancelWhisper() : models.cancelKokoro()
                }
            }
        case .preparing:
            ProgressView().accessibilityIdentifier("\(id).preparing")
        case .ready:
            DashPillButton(title: "Delete", symbol: "trash", prominent: false, tint: Theme.danger,
                           identifier: "\(id).delete") {
                kind == .whisper ? models.deleteWhisper() : models.deleteKokoro()
            }
        case .notDownloaded, .paused, .failed:
            HStack(spacing: 8) {
                if case .paused = state {
                    DashPillButton(title: "Delete", prominent: false, identifier: "\(id).delete") {
                        kind == .whisper ? models.deleteWhisper() : models.deleteKokoro()
                    }
                }
                DashPillButton(title: buttonTitle(state), symbol: "arrow.down.circle", identifier: "\(id).download") {
                    if models.isExpensiveNetwork { confirmCellular = kind } else { start(kind) }
                }
                .disabled(settings.mode != .full || models.isOffline)
            }
        }
    }

    private func buttonTitle(_ state: SpeechModelState) -> String {
        switch state {
        case .paused: "Resume"
        case .failed: "Retry"
        default: "Download"
        }
    }

    private func start(_ kind: SpeechModelKind) {
        kind == .whisper ? models.downloadWhisper() : models.downloadKokoro()
    }

    private func playPreview() {
        let output = preview ?? SpokenOutput(channel: "preview", center: center)
        preview = output
        output.speak("Hi, I'm your Duo Dash voice. In 300 metres, turn left onto the highway.")
    }

    private var recognizerFooter: String {
        switch settings.activeRecognizer {
        case .whisper: "Whisper runs on this iPhone. Nothing you say leaves the phone."
        case .demo: "Demo recogniser."
        case .apple:
            settings.recognizer == .whisper && settings.mode == .full
                ? "Apple dictation is used until the Whisper model is downloaded and ready."
                : "Apple's on-device dictation."
        }
    }

    private var voiceFooter: String {
        switch settings.activeVoice {
        case .natural: "Kokoro runs on this iPhone. Music ducks while it speaks."
        case .demo: "Demo voice."
        case .apple:
            settings.voice == .natural && settings.mode == .full
                ? "Apple's voice speaks until the natural voice is downloaded."
                : "Apple's built-in voice."
        }
    }

    private func stateText(_ state: SpeechModelState, size: Int64, onDisk: Int64) -> String {
        let wifi = models.isExpensiveNetwork ? " · Wi‑Fi recommended" : ""
        switch state {
        case .notDownloaded: return "\(sizeText(size)) download\(wifi)"
        case .downloading(let fraction): return "Downloading… \(Int(fraction * 100))% of \(sizeText(size))"
        case .paused(let fraction): return "Paused at \(Int(fraction * 100))%\(wifi)"
        case .preparing: return "Preparing for this iPhone… (first time can take a minute)"
        case .ready: return "Ready · \(sizeText(onDisk)) on iPhone"
        case .failed(let message): return message
        }
    }

    private var storageText: String {
        _ = models.storageRevision
        return sizeText(models.whisperBytes + models.kokoroBytes)
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Layout helpers (CarPlay look, 60 pt targets)

    private var divider: some View { Theme.separator.frame(height: 1).padding(.leading, 16) }

    private func group<Content: View>(footer: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) { content() }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(footer)
                .font(.dashCaption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
        }
    }

    private func row<Trailing: View>(title: String, subtitle: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dashBody)
                if let subtitle {
                    Text(subtitle).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Theme.minTouch + 6)
    }

    private func segments<Value: Hashable>(_ options: [(Value, String)], selection: Binding<Value>,
                                           identifier: String) -> some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, title in
                let selected = selection.wrappedValue == value
                Button { withAnimation(.snappy) { selection.wrappedValue = value } } label: {
                    Text(title)
                        .font(.dashCaption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                        .background(selected ? Theme.accent : Theme.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("\(identifier).\(value)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(8)
    }
}
