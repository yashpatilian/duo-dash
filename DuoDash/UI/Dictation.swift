import SwiftUI

/// Voice-to-text for every text field in the app (one microphone at a time).
/// Speech streams into the field as it's recognised; it stops by itself after a
/// short pause, or when the button is tapped again. Music is ducked, not paused.
///
/// The recogniser comes from `SpeechCenter`: Whisper on-device once its model is
/// downloaded, Apple's Speech framework otherwise (and if Whisper fails to start).
@MainActor
@Observable
final class Dictation {
    static let shared = Dictation()

    /// The field currently listening, if any.
    private(set) var activeID: UUID?
    /// The engine listening right now.
    private(set) var activeEngine: SpeechRecognizerKind?
    var errorMessage: String?

    var isListening: Bool { activeID != nil }

    @ObservationIgnored var center: SpeechCenter = .shared
    @ObservationIgnored private var engine: SpeechRecognizerEngine?
    @ObservationIgnored private var onText: ((String) -> Void)?
    @ObservationIgnored private var onFinish: ((String) -> Void)?
    @ObservationIgnored private var latest = ""
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?

    /// Longest wait for the final text after the mic stops (Whisper's last pass).
    @ObservationIgnored var finishTimeoutDuration: Duration = .seconds(8)

    /// Starts listening for `id`, or stops if that field is already listening.
    func toggle(id: UUID, onText: @escaping (String) -> Void, onFinish: @escaping (String) -> Void) async {
        if activeID == id { finish(); return }
        if activeID != nil { finish() }

        var engine = center.recognizer()
        activeID = id
        activeEngine = engine.kind
        self.engine = engine
        self.onText = onText
        self.onFinish = onFinish
        latest = ""
        do {
            try await start(engine, id: id)
        } catch let error as SpeechEngineError where engine.kind == .whisper && !Self.isPermission(error) {
            // Whisper couldn't start: Apple dictation instead, this time.
            engine = AppleRecognizerEngine()
            self.engine = engine
            activeEngine = .apple
            do { try await start(engine, id: id) } catch { fail(error, id: id) }
        } catch {
            fail(error, id: id)
        }
    }

    private func start(_ engine: SpeechRecognizerEngine, id: UUID) async throws {
        try await engine.start(locale: .current) { [weak self] event in
            self?.handle(event, id: id)
        }
    }

    private func fail(_ error: Error, id: UUID) {
        guard activeID == id else { return }
        reset()
        errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't start the microphone."
    }

    private static func isPermission(_ error: SpeechEngineError) -> Bool {
        if case .notAuthorized = error { return true }
        return false
    }

    private func handle(_ event: RecognitionEvent, id: UUID) {
        guard activeID == id else { return }
        switch event {
        case .partial(let text):
            latest = text
            onText?(text)
        case .final(let text):
            let final = text.isEmpty ? latest : text
            if final != latest, !final.isEmpty { onText?(final) }
            complete(with: final)
        case .failed(let message):
            if latest.isEmpty { errorMessage = message }
            complete(with: latest)
        }
    }

    /// Stops listening; the field gets the final text (straight away with Apple's
    /// recogniser, after one last pass with Whisper).
    func finish() {
        guard activeID != nil, let engine else { return }
        engine.finish()
        guard activeID != nil else { return }   // the final arrived synchronously
        finishTimeout?.cancel()
        let id = activeID
        let timeout = finishTimeoutDuration
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, self.activeID == id else { return }
            self.engine?.cancel()
            self.complete(with: self.latest)
        }
    }

    private func complete(with text: String) {
        let callback = onFinish
        reset()
        if !text.isEmpty { callback?(text) }
    }

    private func reset() {
        finishTimeout?.cancel()
        finishTimeout = nil
        engine = nil
        onText = nil
        onFinish = nil
        activeID = nil
        activeEngine = nil
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
