import Foundation

// Pure helpers for the speech engines: no audio, no models, so they're unit-tested directly.

/// Splits a reply into pieces for the natural voice so the first words can play while
/// the rest is still being synthesised. The first piece is kept short (a clause) so it
/// comes back fastest; later pieces are whole sentences, merged when they're tiny.
enum SentenceChunker {
    /// Longest first piece before it's split at a comma, semicolon or dash.
    static let firstChunkLimit = 60
    /// Sentences shorter than this are merged with the next (one synthesis call each is wasteful).
    static let minimumChunk = 24
    /// Longest piece overall; longer sentences are split at clause, then word, boundaries.
    static let maximumChunk = 220

    static func chunks(_ text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { return [] }

        var pieces: [String] = []
        for sentence in sentences(in: cleaned) {
            for part in split(sentence, limit: maximumChunk) where !part.isEmpty {
                pieces.append(part)
            }
        }

        // Merge tiny sentences forward ("OK. Starting route to Sam's.").
        var merged: [String] = []
        for piece in pieces {
            if let last = merged.last, last.count < minimumChunk, last.count + piece.count + 1 <= maximumChunk {
                merged[merged.count - 1] = last + " " + piece
            } else {
                merged.append(piece)
            }
        }

        // A short first piece starts the audio sooner.
        if let first = merged.first, first.count > firstChunkLimit {
            let head = split(first, limit: firstChunkLimit)
            if head.count > 1 {
                let rest = head.dropFirst().joined(separator: " ")
                merged.replaceSubrange(0...0, with: [head[0], rest])
            }
        }
        return merged
    }

    /// Sentence boundaries: . ! ? followed by a space and not after a common abbreviation or a digit.
    static func sentences(in text: String) -> [String] {
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "rd", "ave", "mt", "vs", "etc", "approx", "no"]
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?".contains(character) else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            guard next == " " else { continue }
            if character == "." {
                let word = current.dropLast().split(separator: " ").last.map { $0.lowercased() } ?? ""
                if abbreviations.contains(word) { continue }
                // "3." followed by a digit is a decimal; "Exit 3. Then" is a sentence.
                if index + 2 < characters.count, characters[index + 2].isNumber, word.last?.isNumber == true { continue }
            }
            let sentence = current.trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { result.append(sentence) }
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// Splits at the last clause boundary (", ; : –") before `limit`, else the last space.
    static func split(_ text: String, limit: Int) -> [String] {
        var remaining = Substring(text)
        var parts: [String] = []
        while remaining.count > limit {
            let window = remaining.prefix(limit)
            let clause = window.lastIndex(where: { ",;:–—".contains($0) })
            let cut: Substring.Index
            if let clause, remaining.distance(from: remaining.startIndex, to: clause) >= 12 {
                cut = remaining.index(after: clause)
            } else if let space = window.lastIndex(of: " "), space > remaining.startIndex {
                cut = space
            } else {
                cut = window.endIndex
            }
            let head = remaining[..<cut].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { parts.append(head) }
            remaining = remaining[cut...].drop(while: { $0 == " " })
        }
        let tail = remaining.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }
}

/// The user's language as the speech engines need it.
struct SpeechLocale: Equatable {
    /// Whisper language code ("en", "de"…).
    var whisperLanguage: String
    /// British-style spelling (colour, metres) for English outside the US/Canada/Philippines.
    var prefersBritishSpelling: Bool
    var isEnglish: Bool { whisperLanguage == "en" }

    init(_ locale: Locale) {
        let language = locale.language.languageCode?.identifier ?? "en"
        whisperLanguage = language
        let region = locale.region?.identifier ?? "US"
        prefersBritishSpelling = language == "en" && !["US", "CA", "PH", "PR", "UM", "VI", "AS", "GU", "MP"].contains(region)
    }

    /// A short conditioning prompt nudging Whisper towards the local spelling.
    /// Whisper sometimes echoes a prompt back on near-silence, so it's filtered out of results.
    var whisperPrompt: String? {
        prefersBritishSpelling ? "Colour, favourite, centre, metres, kilometres, motorway." : nil
    }
}

/// Energy-based end-of-speech detection for the Whisper recogniser.
/// Fed one RMS level (dBFS) per audio frame; learns the background noise (cabin, road)
/// during the first moments and while nobody is talking, then reports when speech has
/// started and when it has been followed by enough silence.
struct EndOfSpeechDetector {
    enum Decision: Equatable { case waiting, speaking, endOfSpeech, noSpeech }

    /// Silence after speech that ends the dictation.
    var silenceTimeout: TimeInterval = 1.2
    /// Nobody spoke for this long: give up.
    var noSpeechTimeout: TimeInterval = 6
    /// Speech must last at least this long to count (ignores clicks and bumps).
    var minimumSpeech: TimeInterval = 0.15
    /// How far above the noise floor counts as speech.
    var marginDB: Float = 10
    /// Never treat anything quieter than this as speech.
    var absoluteFloorDB: Float = -50

    private(set) var noiseFloorDB: Float = -60
    private(set) var hasSpeech = false
    private var elapsed: TimeInterval = 0
    private var speechRun: TimeInterval = 0
    private var silenceRun: TimeInterval = 0
    private var calibrated: TimeInterval = 0

    var threshold: Float { max(noiseFloorDB + marginDB, absoluteFloorDB) }

    mutating func process(levelDB: Float, duration: TimeInterval) -> Decision {
        elapsed += duration
        // The first 0.25 s sets the noise floor (people rarely start talking that fast).
        if calibrated < 0.25 && !hasSpeech {
            noiseFloorDB = calibrated == 0 ? levelDB : (noiseFloorDB * 0.7 + levelDB * 0.3)
            calibrated += duration
            return .waiting
        }
        if levelDB > threshold {
            speechRun += duration
            silenceRun = 0
            if speechRun >= minimumSpeech { hasSpeech = true }
        } else {
            speechRun = 0
            silenceRun += duration
            // Track a slowly rising or falling background.
            noiseFloorDB = noiseFloorDB * 0.95 + levelDB * 0.05
        }
        if hasSpeech {
            return silenceRun >= silenceTimeout ? .endOfSpeech : .speaking
        }
        return elapsed >= noSpeechTimeout ? .noSpeech : .waiting
    }

    static func rmsDB(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }
}

/// Whisper checkpoints from argmaxinc/whisperkit-coreml (Hugging Face), all MIT-licensed OpenAI weights.
enum WhisperModelCatalog {
    struct Variant: Equatable {
        let id: String
        let title: String
        let downloadBytes: Int64
    }

    /// large-v3 "turbo" (v20240930), quantised: near large-v3 accuracy, multilingual, ~0.6 GB.
    static let largeTurbo = Variant(id: "openai_whisper-large-v3-v20240930_626MB",
                                    title: "Whisper Large v3 Turbo", downloadBytes: 627_000_000)
    /// For phones too old for the large model: English-only small, quantised.
    static let smallEnglish = Variant(id: "openai_whisper-small.en_217MB",
                                      title: "Whisper Small (English)", downloadBytes: 218_000_000)
    static let all = [largeTurbo, smallEnglish]

    /// The best model this device can run (from WhisperKit's device support table).
    static func preferred(supported: [String]) -> Variant {
        if supported.contains(largeTurbo.id) { return largeTurbo }
        return smallEnglish
    }

    static func variant(id: String) -> Variant? { all.first { $0.id == id } }
}

/// Kokoro-82M voices offered in Settings (Apache-2.0 voice packs shipped with the model).
/// The bundled pronunciation dictionary is American English, so the British voices
/// have a British timbre with mostly American pronunciation.
struct NaturalVoice: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String

    static let all: [NaturalVoice] = [
        NaturalVoice(id: "af_heart", name: "Heart", detail: "Warm, female"),
        NaturalVoice(id: "af_bella", name: "Bella", detail: "Bright, female"),
        NaturalVoice(id: "af_nicole", name: "Nicole", detail: "Soft, female"),
        NaturalVoice(id: "am_michael", name: "Michael", detail: "Calm, male"),
        NaturalVoice(id: "am_fenrir", name: "Fenrir", detail: "Deep, male"),
        NaturalVoice(id: "bf_emma", name: "Emma", detail: "British, female"),
        NaturalVoice(id: "bm_george", name: "George", detail: "British, male"),
    ]
    static let defaultID = "af_heart"

    static func voice(id: String) -> NaturalVoice? { all.first { $0.id == id } }

    /// Model download from the kokoro-coreml release (CoreML conversion of Kokoro-82M).
    static let modelURL = URL(string: "https://github.com/Jud/kokoro-coreml/releases/download/models-2026-03-23/kokoro-models.tar.gz")!
    static let modelDownloadBytes: Int64 = 103_394_124
    static let modelInstalledBytes: Int64 = 111_000_000
}
