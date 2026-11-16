import SwiftUI
import Speech
import AVFoundation

/// Voice-to-text for every text field in the app (one microphone at a time).
/// Speech streams into the field as it's recognised; it stops by itself after a
/// short pause, or when the button is tapped again. Music is ducked, not paused.
@MainActor
@Observable
final class Dictation {
    static let shared = Dictation()

    /// The field currently listening, if any.
    private(set) var activeID: UUID?
    var errorMessage: String?

    var isListening: Bool { activeID != nil }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var onFinish: ((String) -> Void)?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var latest = ""

    /// How long a pause ends the dictation.
    var silenceTimeout: Duration = .seconds(1.6)

    /// Starts listening for `id`, or stops if that field is already listening.
    func toggle(id: UUID, onText: @escaping (String) -> Void, onFinish: @escaping (String) -> Void) async {
        if activeID == id { finish(); return }
        if activeID != nil { finish() }

        guard await Self.authorize() else {
            errorMessage = "Turn on Microphone and Speech Recognition for Duo Dash in Settings to use voice input."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-AU")),
              recognizer.isAvailable else {
            errorMessage = "Voice input isn't available right now."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            self.request = request
            self.onFinish = onFinish
            self.latest = ""
            self.activeID = id
            armSilenceTimer()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                Task { @MainActor [weak self] in
                    guard let self, self.activeID == id else { return }
                    if let text, !text.isEmpty {
                        self.latest = text
                        onText(text)
                        self.armSilenceTimer()
                    }
                    if isFinal || error != nil { self.finish() }
                }
            }
        } catch {
            teardown()
            errorMessage = "Couldn't start the microphone."
        }
    }

    /// Stops listening and hands the final text to the field.
    func finish() {
        guard activeID != nil else { return }
        let text = latest
        let callback = onFinish
        teardown()
        if !text.isEmpty { callback?(text) }
    }

    private func armSilenceTimer() {
        silenceTask?.cancel()
        let timeout = silenceTimeout
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func teardown() {
        silenceTask?.cancel()
        silenceTask = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        onFinish = nil
        activeID = nil
        // Let ducked music come back up.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Microphone button that sits at the end of a text field.
/// `onFinish` runs with the final text (e.g. to submit a search).
struct DictationButton: View {
    @Binding var text: String
    var identifier: String
    var onFinish: ((String) -> Void)? = nil

    @State private var id = UUID()
    private var dictation: Dictation { .shared }

    var body: some View {
        let listening = dictation.activeID == id
        Button {
            let prefix = text.trimmingCharacters(in: .whitespaces)
            Task {
                await dictation.toggle(id: id) { heard in
                    text = prefix.isEmpty ? heard : prefix + " " + heard
                } onFinish: { _ in
                    onFinish?(text)
                }
            }
        } label: {
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: listening)
                .foregroundStyle(listening ? Theme.onAccent : Theme.textSecondary)
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .background {
                    if listening { Circle().fill(Theme.accent).padding(8) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? "Stop dictation" : "Dictate")
        .accessibilityIdentifier(identifier)
        .onDisappear { if dictation.activeID == id { dictation.finish() } }
    }
}

/// Shows voice-input problems (permissions, no recogniser) briefly at the bottom.
struct DictationErrorBanner: View {
    private var dictation: Dictation { .shared }

    var body: some View {
        if let message = dictation.errorMessage {
            Label(message, systemImage: "mic.slash.fill")
                .font(.dashCaption)
                .padding(14)
                .background(Theme.surfaceRaised, in: Capsule())
                .padding(16)
                .onTapGesture { dictation.errorMessage = nil }
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(5))
                    if dictation.errorMessage == message { dictation.errorMessage = nil }
                }
                .accessibilityIdentifier("dictation.error")
        }
    }
}
