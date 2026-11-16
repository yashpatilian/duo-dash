import AVFoundation
import CallKit

/// The app's audio-session rules for speech, shared by every engine.
///
/// - Speaking: `.playback` + `.voicePrompt`, ducking other audio (music comes back up
///   afterwards, never stops) and pausing spoken-word apps.
/// - Listening: `.playAndRecord` + `.measurement`, also ducking.
/// - The session is released (`.notifyOthersOnDeactivation`, which un-ducks music) only
///   when nothing is speaking or listening any more.
@MainActor
enum SpeechAudioSession {
    private static var speakers: Set<String> = []
    private static var isListening = false

    static func beginListening() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        isListening = true
    }

    static func endListening() {
        isListening = false
        releaseIfIdle()
    }

    /// Returns false when another app (e.g. a call) owns audio; skip the prompt then.
    static func beginSpeaking(channel: String) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            if !isListening {
                // .duckOthers lowers music from other apps; .interruptSpokenAudioAndMixWithOthers
                // pauses podcasts/audiobooks instead of talking over them.
                try session.setCategory(.playback, mode: .voicePrompt,
                                        options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            }
            try session.setActive(true)
        } catch {
            return false
        }
        speakers.insert(channel)
        return true
    }

    static func endSpeaking(channel: String) {
        speakers.remove(channel)
        releaseIfIdle()
    }

    private static func releaseIfIdle() {
        guard speakers.isEmpty, !isListening else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// One speech output channel (turn-by-turn, assistant replies, voice preview).
///
/// Robustness rules (unchanged from the AVSpeechSynthesizer days):
/// - A newer prompt replaces one still being spoken (stale directions are worse than none).
/// - The audio session is released a moment after the last prompt, and only if nothing
///   is queued, so music doesn't pump up and down between prompts.
/// - Phone calls and Siri interrupt us; we drop the prompt and never fight for audio.
@MainActor
final class SpokenOutput {
    let channel: String
    var isMuted = false {
        didSet { if isMuted { stop() } }
    }
    private(set) var isSpeaking = false
    /// Runs once the channel has gone quiet (finished or stopped).
    var onFinish: (() -> Void)?

    private let center: SpeechCenter
    private var engine: SpeechSynthesizerEngine?
    private var releaseTask: Task<Void, Never>?
    private var isInterrupted = false
    private var token = 0
    private var observer: NSObjectProtocol?
    private let callObserver = CXCallObserver()

    init(channel: String, center: SpeechCenter? = nil) {
        self.channel = channel
        self.center = center ?? .shared
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                MainActor.assumeIsolated {
                    guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    switch type {
                    case .began:
                        self.isInterrupted = true
                        self.engine?.stop()
                    case .ended:
                        self.isInterrupted = false
                    @unknown default:
                        break
                    }
                }
            }
    }

    /// Speaks `text` with the user's chosen voice, or `forcing` a particular engine (preview).
    func speak(_ text: String, forcing kind: SpeechVoiceKind? = nil) {
        guard !isMuted, !text.isEmpty else { return }
        // Interrupted, a phone call in progress, or another app owns audio: stay quiet
        // rather than talk over it.
        guard !isInterrupted, !callObserver.calls.contains(where: { !$0.hasEnded }),
              SpeechAudioSession.beginSpeaking(channel: channel) else {
            onFinish?()
            return
        }
        releaseTask?.cancel()

        let next = center.synthesizer(channel: channel, forcing: kind)
        if let engine, engine !== next { engine.stop() }
        engine = next
        token += 1
        let current = token
        isSpeaking = true
        next.speak(text) { [weak self] _ in
            guard let self, self.token == current else { return }   // replaced by a newer prompt
            self.scheduleRelease()
        }
    }

    func stop() {
        token += 1
        engine?.stop()
        scheduleRelease(after: .zero)
    }

    /// Deactivating with .notifyOthersOnDeactivation is what brings the music back up.
    private func scheduleRelease(after delay: Duration = .milliseconds(400)) {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled, self.engine?.isSpeaking != true else { return }
            self.isSpeaking = false
            SpeechAudioSession.endSpeaking(channel: self.channel)
            self.onFinish?()
        }
    }
}
