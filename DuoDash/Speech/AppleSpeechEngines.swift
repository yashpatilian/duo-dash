import AVFoundation
import Speech

/// Apple's on-device Speech framework. The fallback recogniser, and the only one in the
/// Simulator. Stops by itself after a short pause in the partial results.
@MainActor
final class AppleRecognizerEngine: SpeechRecognizerEngine {
    let kind = SpeechRecognizerKind.apple

    /// How long a pause ends the dictation.
    var silenceTimeout: Duration = .seconds(1.6)

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var onEvent: (@MainActor (RecognitionEvent) -> Void)?
    private var latest = ""
    private var session = 0

    func start(locale: Locale, onEvent: @escaping @MainActor (RecognitionEvent) -> Void) async throws {
        cancel()
        guard await Self.authorize() else { throw SpeechEngineError.notAuthorized(needsSpeech: true) }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-AU")),
              recognizer.isAvailable else {
            throw SpeechEngineError.unavailable
        }

        try SpeechAudioSession.beginListening()
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
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            SpeechAudioSession.endListening()
            throw SpeechEngineError.microphone
        }

        session += 1
        let current = session
        self.request = request
        self.onEvent = onEvent
        latest = ""
        armSilenceTimer()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                guard let self, self.session == current, self.onEvent != nil else { return }
                if let text, !text.isEmpty {
                    self.latest = text
                    self.onEvent?(.partial(text))
                    self.armSilenceTimer()
                }
                if isFinal || error != nil { self.finish() }
            }
        }
    }

    func finish() {
        guard let callback = onEvent else { return }
        let text = latest
        teardown()
        callback(.final(text))
    }

    func cancel() {
        guard onEvent != nil else { return }
        teardown()
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
        onEvent = nil
        SpeechAudioSession.endListening()
    }

    static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// AVSpeechSynthesizer in the system language. The fallback voice.
@MainActor
final class AppleSynthesizerEngine: NSObject, SpeechSynthesizerEngine, AVSpeechSynthesizerDelegate {
    let kind = SpeechVoiceKind.apple
    private let synthesizer = AVSpeechSynthesizer()
    private let postUtteranceDelay: TimeInterval
    private var pending: [ObjectIdentifier: @MainActor (Bool) -> Void] = [:]

    init(postUtteranceDelay: TimeInterval = 0) {
        self.postUtteranceDelay = postUtteranceDelay
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    var isSpeaking: Bool { synthesizer.isSpeaking || !pending.isEmpty }

    func speak(_ text: String, completion: @escaping @MainActor (Bool) -> Void) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = postUtteranceDelay
        pending[ObjectIdentifier(utterance)] = completion
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func complete(_ id: ObjectIdentifier, finished: Bool) {
        pending.removeValue(forKey: id)?(finished)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.complete(id, finished: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.complete(id, finished: false) }
    }
}

enum SpeechEngineError: LocalizedError, Equatable {
    case notAuthorized(needsSpeech: Bool)
    case unavailable
    case microphone
    case modelMissing

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let needsSpeech):
            needsSpeech
                ? "Turn on Microphone and Speech Recognition for Duo Dash in Settings to use voice input."
                : "Turn on Microphone for Duo Dash in Settings to use voice input."
        case .unavailable: "Voice input isn't available right now."
        case .microphone: "Couldn't start the microphone."
        case .modelMissing: "The Whisper model isn't downloaded."
        }
    }
}
