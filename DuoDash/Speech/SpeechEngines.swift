import Foundation
import Observation

// The speech layer. Everything in the app that listens (dictation, the assistant's mic)
// or speaks (turn-by-turn, assistant replies, voice preview) goes through `SpeechCenter`,
// which picks an engine from the user's `SpeechSettings`:
//
//   listening: Whisper on-device (WhisperKit)  — fallback: Apple's Speech framework
//   speaking:  Kokoro-82M on-device (CoreML)   — fallback: AVSpeechSynthesizer
//
// The natural engines are used only once their models are downloaded and prepared; until
// then (and in the Simulator, with -AppleSpeech, or during UI tests) Apple's engines run.
// -DemoSpeech swaps in deterministic fakes for tests.

/// What a recogniser reports while listening. Exactly one `.final` or `.failed` ends a session.
enum RecognitionEvent: Equatable {
    case partial(String)
    case final(String)
    case failed(String)
}

enum SpeechRecognizerKind: String, CaseIterable, Identifiable, Codable {
    case whisper, apple, demo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whisper: "Whisper"
        case .apple: "Apple"
        case .demo: "Demo"
        }
    }
    /// The choices offered in Settings.
    static let choices: [SpeechRecognizerKind] = [.whisper, .apple]
}

enum SpeechVoiceKind: String, CaseIterable, Identifiable, Codable {
    case natural, apple, demo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: "Natural"
        case .apple: "Apple"
        case .demo: "Demo"
        }
    }
    static let choices: [SpeechVoiceKind] = [.natural, .apple]
}

/// Speech to text. Engines own their microphone capture and end-of-speech detection.
@MainActor
protocol SpeechRecognizerEngine: AnyObject {
    var kind: SpeechRecognizerKind { get }
    /// Starts listening. Partial text arrives as `.partial`; the session ends with one
    /// `.final` (after a pause, or `finish()`) or `.failed`. Throws if it can't start.
    func start(locale: Locale, onEvent: @escaping @MainActor (RecognitionEvent) -> Void) async throws
    /// Stop listening and deliver the final text.
    func finish()
    /// Abandon the session: no further events.
    func cancel()
}

/// Text to speech. The caller owns the audio session (ducking); engines just play.
@MainActor
protocol SpeechSynthesizerEngine: AnyObject {
    var kind: SpeechVoiceKind { get }
    var isSpeaking: Bool { get }
    /// Speaks `text`, replacing anything in progress. `completion` runs exactly once:
    /// `true` when it played to the end, `false` when it was stopped, replaced or failed.
    func speak(_ text: String, completion: @escaping @MainActor (Bool) -> Void)
    func stop()
}

/// Which engines may run in this process.
enum SpeechRuntimeMode: Equatable {
    /// Natural engines when ready, Apple's otherwise.
    case full
    /// Simulator, `-AppleSpeech`, UI tests: never load or download models.
    case appleOnly
    /// `-DemoSpeech`: deterministic fakes.
    case demo

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> SpeechRuntimeMode {
        if arguments.contains("-DemoSpeech") { return .demo }
        #if targetEnvironment(simulator)
        return .appleOnly
        #else
        if arguments.contains("-AppleSpeech") || arguments.contains("-UITest") { return .appleOnly }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return .appleOnly }
        return .full
        #endif
    }
}

/// Picks the engine actually used. Pure, so the fallback rules are unit-tested.
enum SpeechEngineSelection {
    static func recognizer(choice: SpeechRecognizerKind, whisper: SpeechModelState,
                           mode: SpeechRuntimeMode) -> SpeechRecognizerKind {
        switch mode {
        case .demo: return .demo
        case .appleOnly: return .apple
        case .full: return choice == .whisper && whisper == .ready ? .whisper : .apple
        }
    }

    static func voice(choice: SpeechVoiceKind, natural: SpeechModelState,
                      mode: SpeechRuntimeMode) -> SpeechVoiceKind {
        switch mode {
        case .demo: return .demo
        case .appleOnly: return .apple
        case .full: return choice == .natural && natural == .ready ? .natural : .apple
        }
    }
}

/// Download and preparation state of an on-device model.
enum SpeechModelState: Equatable {
    case notDownloaded
    /// 0…1.
    case downloading(Double)
    /// Cancelled part-way; the next download continues where it stopped.
    case paused(Double)
    /// Downloaded; loading or compiling for this chip (first time can take a minute).
    case preparing
    case ready
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .preparing: true
        default: false
        }
    }

    var isInstalled: Bool { self == .ready || self == .preparing }
}

/// Speech preferences, persisted in UserDefaults like the rest of the app.
@MainActor
@Observable
final class SpeechSettings {
    /// The recogniser the user wants (Whisper by default; Apple runs until Whisper is ready).
    var recognizer: SpeechRecognizerKind {
        didSet {
            if !SpeechRecognizerKind.choices.contains(recognizer) { recognizer = .whisper }
            defaults.set(recognizer.rawValue, forKey: Keys.recognizer)
        }
    }

    /// The voice the user wants (Natural by default; Apple speaks until Kokoro is ready).
    var voice: SpeechVoiceKind {
        didSet {
            if !SpeechVoiceKind.choices.contains(voice) { voice = .natural }
            defaults.set(voice.rawValue, forKey: Keys.voice)
        }
    }

    /// Kokoro voice id, e.g. "af_heart".
    var naturalVoiceID: String {
        didSet {
            if NaturalVoice.voice(id: naturalVoiceID) == nil { naturalVoiceID = NaturalVoice.defaultID }
            defaults.set(naturalVoiceID, forKey: Keys.naturalVoice)
        }
    }

    /// Which Whisper checkpoint is installed (or being installed).
    var whisperVariantID: String {
        didSet { defaults.set(whisperVariantID, forKey: Keys.whisperVariant) }
    }

    /// The Whisper model has been loaded once on this device (CoreML has specialised it),
    /// so later loads are quick enough to start while the driver is already talking.
    var whisperPrepared: Bool {
        didSet { defaults.set(whisperPrepared, forKey: Keys.whisperPrepared) }
    }

    var whisperState: SpeechModelState = .notDownloaded
    var kokoroState: SpeechModelState = .notDownloaded

    @ObservationIgnored let mode: SpeechRuntimeMode
    @ObservationIgnored private let defaults: UserDefaults

    enum Keys {
        static let recognizer = "speech.recognizer"
        static let voice = "speech.voice"
        static let naturalVoice = "speech.naturalVoice"
        static let whisperVariant = "speech.whisperVariant"
        static let whisperPrepared = "speech.whisperPrepared"
    }

    init(defaults: UserDefaults = .standard, mode: SpeechRuntimeMode = .current()) {
        self.defaults = defaults
        self.mode = mode
        let recognizer = defaults.string(forKey: Keys.recognizer).flatMap(SpeechRecognizerKind.init(rawValue:)) ?? .whisper
        self.recognizer = SpeechRecognizerKind.choices.contains(recognizer) ? recognizer : .whisper
        let voice = defaults.string(forKey: Keys.voice).flatMap(SpeechVoiceKind.init(rawValue:)) ?? .natural
        self.voice = SpeechVoiceKind.choices.contains(voice) ? voice : .natural
        let voiceID = defaults.string(forKey: Keys.naturalVoice) ?? NaturalVoice.defaultID
        naturalVoiceID = NaturalVoice.voice(id: voiceID) == nil ? NaturalVoice.defaultID : voiceID
        whisperVariantID = defaults.string(forKey: Keys.whisperVariant) ?? ""
        whisperPrepared = defaults.bool(forKey: Keys.whisperPrepared)
    }

    /// The recogniser that will run right now.
    var activeRecognizer: SpeechRecognizerKind {
        SpeechEngineSelection.recognizer(choice: recognizer, whisper: whisperState, mode: mode)
    }

    /// The voice that will speak right now.
    var activeVoice: SpeechVoiceKind {
        SpeechEngineSelection.voice(choice: voice, natural: kokoroState, mode: mode)
    }

    var naturalVoice: NaturalVoice { NaturalVoice.voice(id: naturalVoiceID) ?? NaturalVoice.all[0] }
}

/// The app's single entry point to speech. Engines are created lazily and cached;
/// the model store keeps `settings.whisperState` / `kokoroState` up to date.
@MainActor
@Observable
final class SpeechCenter {
    static let shared = SpeechCenter()

    let settings: SpeechSettings
    let models: SpeechModelStore

    @ObservationIgnored private var recognizers: [SpeechRecognizerKind: SpeechRecognizerEngine] = [:]
    @ObservationIgnored private var synthesizers: [String: SpeechSynthesizerEngine] = [:]

    init(settings: SpeechSettings? = nil, models: SpeechModelStore? = nil) {
        let settings = settings ?? SpeechSettings()
        self.settings = settings
        self.models = models ?? SpeechModelStore(settings: settings)
        self.models.refresh()
    }

    /// The recogniser to use for a new listening session.
    func recognizer() -> SpeechRecognizerEngine {
        let kind = settings.activeRecognizer
        if let engine = recognizers[kind] { return engine }
        let engine: SpeechRecognizerEngine
        switch kind {
        case .whisper: engine = WhisperRecognizerEngine(runtime: models.whisperRuntime, settings: settings)
        case .apple: engine = AppleRecognizerEngine()
        case .demo: engine = DemoRecognizerEngine()
        }
        recognizers[kind] = engine
        return engine
    }

    /// A synthesiser for one output channel ("navigation", "assistant", "preview").
    /// Each channel has its own player so a turn prompt can cut in over a reply.
    func synthesizer(channel: String, forcing kind: SpeechVoiceKind? = nil) -> SpeechSynthesizerEngine {
        var resolved = kind ?? settings.activeVoice
        // Kokoro still warming up (first seconds after launch): Apple speaks this one.
        if resolved == .natural && !models.kokoroRuntime.isWarm {
            models.kokoroRuntime.warmUp()
            resolved = .apple
        }
        let key = "\(channel).\(resolved.rawValue)"
        if let engine = synthesizers[key] { return engine }
        let engine: SpeechSynthesizerEngine
        switch resolved {
        case .natural: engine = KokoroSynthesizerEngine(runtime: models.kokoroRuntime, settings: settings)
        case .apple: engine = AppleSynthesizerEngine(postUtteranceDelay: channel == "navigation" ? 0.1 : 0)
        case .demo: engine = DemoSynthesizerEngine()
        }
        synthesizers[key] = engine
        return engine
    }

    /// Stops every channel's synthesiser (e.g. before listening).
    func stopSpeaking(channel: String) {
        for (key, engine) in synthesizers where key.hasPrefix(channel + ".") { engine.stop() }
    }
}
