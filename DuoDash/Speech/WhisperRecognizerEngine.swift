import AVFoundation
import WhisperKit

/// WhisperKit is a non-Sendable class; the runtime only hands it between the main actor
/// and its own async calls, one session at a time.
final class WhisperPipeline: @unchecked Sendable {
    let kit: WhisperKit
    init(_ kit: WhisperKit) { self.kit = kit }
}

/// Owns the WhisperKit pipeline (one per app). Loading a model CoreML has already
/// specialised for this chip takes about a second, so a listening session can start
/// recording straight away and transcribe once the model is up.
@MainActor
final class WhisperRuntime {
    let downloadBase: URL
    private var kit: WhisperPipeline?
    private var loadedVariant: String?
    private var loading: Task<WhisperPipeline, Error>?
    private var loadingVariant: String?

    static let repo = "argmaxinc/whisperkit-coreml"

    init(downloadBase: URL) {
        self.downloadBase = downloadBase
    }

    /// Where WhisperKit's downloader puts a variant: <base>/models/<repo>/<variant>.
    func folder(for variant: String) -> URL {
        downloadBase.appending(component: "models").appending(path: Self.repo).appending(component: variant)
    }

    func isInstalled(_ variant: String) -> Bool {
        guard !variant.isEmpty else { return false }
        let folder = folder(for: variant)
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(component: "\($0).mlmodelc").path)
        }
    }

    var isLoaded: Bool { kit != nil }

    /// Loads (or returns) the pipeline. `prewarm` specialises each model one at a time,
    /// which keeps peak memory down on the first load after a download.
    func load(variant: String, prewarm: Bool = false) async throws -> WhisperPipeline {
        if let kit, loadedVariant == variant { return kit }
        if let loading, loadingVariant == variant { return try await loading.value }
        unload()
        let folder = folder(for: variant)
        let base = downloadBase
        let task = Task { () throws -> WhisperPipeline in
            let config = WhisperKitConfig(downloadBase: base, modelFolder: folder.path, tokenizerFolder: base,
                                          verbose: false, logLevel: .none, prewarm: prewarm,
                                          load: true, download: false)
            return WhisperPipeline(try await WhisperKit(config))
        }
        loading = task
        loadingVariant = variant
        do {
            let kit = try await task.value
            if loadingVariant == variant {
                self.kit = kit
                loadedVariant = variant
                loading = nil
                loadingVariant = nil
            }
            return kit
        } catch {
            if loadingVariant == variant {
                loading = nil
                loadingVariant = nil
            }
            throw error
        }
    }

    func unload() {
        loading?.cancel()
        loading = nil
        loadingVariant = nil
        if let kit { Task { await kit.kit.unloadModels() } }
        kit = nil
        loadedVariant = nil
    }

    /// Transcribes 16 kHz mono samples.
    static func transcribe(_ pipeline: WhisperPipeline, samples: [Float], locale: SpeechLocale) async throws -> String {
        let kit = pipeline.kit
        var options = DecodingOptions(task: .transcribe,
                                      language: locale.whisperLanguage,
                                      temperatureFallbackCount: 2,
                                      usePrefillPrompt: true,
                                      skipSpecialTokens: true,
                                      withoutTimestamps: true,
                                      suppressBlank: true)
        if let prompt = locale.whisperPrompt, let tokenizer = kit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return WhisperTextCleaner.clean(text, prompt: locale.whisperPrompt)
    }
}

/// Tidies Whisper output: strips non-speech tags ("[BLANK_AUDIO]", "(engine revving)"),
/// collapses spaces, and drops an echoed conditioning prompt.
enum WhisperTextCleaner {
    static func clean(_ raw: String, prompt: String? = nil) -> String {
        var text = raw
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\*[^*]*\*"#, #"<\|[^|]*\|>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let prompt, normalised(text) == normalised(prompt) { return "" }
        return text
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
    }
}

/// Microphone capture for Whisper: converts to 16 kHz mono and measures loudness per
/// buffer. The audio tap runs on a realtime thread, so state is behind a lock and the
/// main actor polls it.
final class WhisperMicrophone: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Whisper sees at most 30 s at once.
    static let maxSamples = Int(sampleRate * 29.5)

    private let lock = NSLock()
    private var samples: [Float] = []
    private var levels: [(db: Float, duration: TimeInterval)] = []
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw SpeechEngineError.microphone
        }
        self.converter = converter
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, target: target)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SpeechEngineError.microphone
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func append(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData?[0], output.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(output.frameLength))
        let db = EndOfSpeechDetector.rmsDB(chunk)
        let duration = Double(output.frameLength) / Self.sampleRate
        lock.lock()
        if samples.count < Self.maxSamples { samples.append(contentsOf: chunk.prefix(Self.maxSamples - samples.count)) }
        levels.append((db, duration))
        lock.unlock()
    }

    /// Levels measured since the last call.
    func drainLevels() -> [(db: Float, duration: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        let drained = levels
        levels.removeAll(keepingCapacity: true)
        return drained
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    var isFull: Bool {
        lock.lock()
        defer { lock.unlock() }
        return samples.count >= Self.maxSamples
    }
}

/// Whisper on-device (WhisperKit). Records while the model loads, shows partial text
/// every ~0.7 s while the driver talks, and stops by itself after a pause
/// (`EndOfSpeechDetector`), then transcribes the whole utterance once more for the final.
@MainActor
final class WhisperRecognizerEngine: SpeechRecognizerEngine {
    let kind = SpeechRecognizerKind.whisper

    /// Time between partial transcriptions.
    var partialInterval: TimeInterval = 0.7

    private let runtime: WhisperRuntime
    private let settings: SpeechSettings
    private var microphone: WhisperMicrophone?
    private var detector = EndOfSpeechDetector()
    private var onEvent: (@MainActor (RecognitionEvent) -> Void)?
    private var poller: Task<Void, Never>?
    private var decoding: Task<Void, Never>?
    private var kit: WhisperPipeline?
    private var locale = SpeechLocale(.current)
    private var lastPartialAt = Date.distantPast
    private var latest = ""
    private var session = 0
    private var isFinishing = false

    init(runtime: WhisperRuntime, settings: SpeechSettings) {
        self.runtime = runtime
        self.settings = settings
    }

    func start(locale: Locale, onEvent: @escaping @MainActor (RecognitionEvent) -> Void) async throws {
        cancel()
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SpeechEngineError.notAuthorized(needsSpeech: false)
        }
        let variant = settings.whisperVariantID
        guard runtime.isInstalled(variant) else { throw SpeechEngineError.modelMissing }

        try SpeechAudioSession.beginListening()
        let microphone = WhisperMicrophone()
        do {
            try microphone.start()
        } catch {
            SpeechAudioSession.endListening()
            throw error
        }

        session += 1
        let current = session
        self.microphone = microphone
        self.onEvent = onEvent
        self.locale = SpeechLocale(locale)
        detector = EndOfSpeechDetector()
        latest = ""
        kit = nil
        isFinishing = false
        lastPartialAt = Date()

        // Load in parallel with recording (about a second once CoreML has specialised it).
        Task { [weak self] in
            let loaded = try? await self?.runtime.load(variant: variant)
            guard let self, self.session == current else { return }
            if let loaded {
                self.kit = loaded
            } else {
                self.fail("Whisper couldn't load. Using Apple dictation until it's fixed in Settings.", session: current)
            }
        }

        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.session == current, !self.isFinishing else { return }
                self.tick(session: current)
            }
        }
    }

    func finish() {
        guard onEvent != nil, !isFinishing else { return }
        isFinishing = true
        poller?.cancel()
        microphone?.stop()
        SpeechAudioSession.endListening()
        let current = session
        let samples = microphone?.snapshot() ?? []
        let heardSpeech = detector.hasSpeech
        let previous = decoding
        decoding = Task { [weak self] in
            await previous?.value
            guard let self, self.session == current else { return }
            guard heardSpeech, !samples.isEmpty else {
                self.deliver(.final(self.latest), session: current)
                return
            }
            // Wait for the model if it's still loading.
            var kit = self.kit
            if kit == nil { kit = try? await self.runtime.load(variant: self.settings.whisperVariantID) }
            guard self.session == current else { return }
            guard let kit else {
                self.deliver(.failed("Whisper couldn't load."), session: current)
                return
            }
            let text = (try? await WhisperRuntime.transcribe(kit, samples: samples, locale: self.locale)) ?? self.latest
            self.deliver(.final(text.isEmpty ? self.latest : text), session: current)
        }
    }

    func cancel() {
        guard onEvent != nil else { return }
        session += 1
        teardown()
    }

    private func tick(session current: Int) {
        guard let microphone else { return }
        var decision = EndOfSpeechDetector.Decision.waiting
        for level in microphone.drainLevels() {
            decision = detector.process(levelDB: level.db, duration: level.duration)
            if decision == .endOfSpeech || decision == .noSpeech { break }
        }
        if decision == .endOfSpeech || decision == .noSpeech || microphone.isFull {
            finish()
            return
        }
        guard detector.hasSpeech, decoding == nil, let kit,
              Date().timeIntervalSince(lastPartialAt) >= partialInterval else { return }
        lastPartialAt = Date()
        let samples = microphone.snapshot()
        let locale = self.locale
        decoding = Task { [weak self] in
            let text = try? await WhisperRuntime.transcribe(kit, samples: samples, locale: locale)
            guard let self, self.session == current, !self.isFinishing else { return }
            self.decoding = nil
            if let text, !text.isEmpty {
                self.latest = text
                self.onEvent?(.partial(text))
            }
        }
    }

    private func fail(_ message: String, session current: Int) {
        // Apple dictation takes over until the model is downloaded again or reloads.
        settings.whisperState = .failed(message)
        deliver(.failed(message), session: current)
    }

    private func deliver(_ event: RecognitionEvent, session current: Int) {
        guard session == current, let callback = onEvent else { return }
        if case .partial = event { callback(event); return }
        teardown()
        callback(event)
    }

    private func teardown() {
        poller?.cancel()
        poller = nil
        decoding?.cancel()
        decoding = nil
        microphone?.stop()
        microphone = nil
        if !isFinishing { SpeechAudioSession.endListening() }
        onEvent = nil
        kit = nil
        isFinishing = false
    }
}
