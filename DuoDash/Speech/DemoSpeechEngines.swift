import Foundation

/// `-DemoSpeech`: a recogniser that "hears" a fixed transcript word by word, no microphone.
/// `-DemoSpeechTranscript "take me home"` sets what it hears.
@MainActor
final class DemoRecognizerEngine: SpeechRecognizerEngine {
    let kind = SpeechRecognizerKind.demo
    var transcript: String
    /// Delay before each word.
    var step: Duration

    private var task: Task<Void, Never>?
    private var onEvent: (@MainActor (RecognitionEvent) -> Void)?
    private var heard = ""
    private var session = 0

    init(transcript: String? = nil, step: Duration = .milliseconds(60)) {
        let arguments = ProcessInfo.processInfo.arguments
        let injected = arguments.firstIndex(of: "-DemoSpeechTranscript").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        self.transcript = transcript ?? injected ?? "Take me home"
        self.step = step
    }

    func start(locale: Locale, onEvent: @escaping @MainActor (RecognitionEvent) -> Void) async throws {
        cancel()
        session += 1
        let current = session
        self.onEvent = onEvent
        heard = ""
        let words = transcript.split(separator: " ").map(String.init)
        let step = step
        task = Task { [weak self] in
            for index in words.indices {
                try? await Task.sleep(for: step)
                guard let self, self.session == current, !Task.isCancelled else { return }
                self.heard = words[0...index].joined(separator: " ")
                self.onEvent?(.partial(self.heard))
            }
            self?.deliverFinal(session: current)
        }
    }

    func finish() {
        deliverFinal(session: session)
    }

    func cancel() {
        session += 1
        task?.cancel()
        task = nil
        onEvent = nil
    }

    private func deliverFinal(session current: Int) {
        guard session == current, let callback = onEvent else { return }
        task?.cancel()
        task = nil
        onEvent = nil
        callback(.final(heard))
    }
}

/// `-DemoSpeech`: a synthesiser that records what it was asked to say and "plays" for a
/// fixed time, so tests can check speaking without audio.
@MainActor
final class DemoSynthesizerEngine: SpeechSynthesizerEngine {
    let kind = SpeechVoiceKind.demo
    private(set) var spoken: [String] = []
    private(set) var isSpeaking = false
    var duration: Duration

    private var task: Task<Void, Never>?
    private var completion: (@MainActor (Bool) -> Void)?

    init(duration: Duration = .milliseconds(150)) {
        self.duration = duration
    }

    func speak(_ text: String, completion: @escaping @MainActor (Bool) -> Void) {
        end(finished: false)
        spoken.append(text)
        isSpeaking = true
        self.completion = completion
        let duration = duration
        task = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.end(finished: true)
        }
    }

    func stop() {
        end(finished: false)
    }

    private func end(finished: Bool) {
        task?.cancel()
        task = nil
        isSpeaking = false
        let callback = completion
        completion = nil
        callback?(finished)
    }
}
