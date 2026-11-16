import AVFoundation
import CallKit

/// Speaks turn instructions. Music from the Music app or Spotify is ducked while a
/// prompt plays and comes back to full volume afterwards; it is never stopped.
///
/// Robustness rules:
/// - A newer prompt replaces one still being spoken (stale directions are worse than none).
/// - The audio session is released a moment after the last prompt, and only if
///   nothing is queued, so music doesn't pump up and down between prompts.
/// - Phone calls and Siri interrupt us; we drop the prompt and never fight for audio.
@MainActor
final class VoiceGuide: NSObject, AVSpeechSynthesizerDelegate {
    var isMuted = false {
        didSet { if isMuted { stop() } }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var releaseTask: Task<Void, Never>?
    private var isInterrupted = false
    private var observers: [NSObjectProtocol] = []
    private let callObserver = CXCallObserver()

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                MainActor.assumeIsolated {
                    guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    switch type {
                    case .began:
                        self.isInterrupted = true
                        self.synthesizer.stopSpeaking(at: .immediate)
                    case .ended:
                        self.isInterrupted = false
                    @unknown default:
                        break
                    }
                }
            })
    }

    func speak(_ text: String) {
        guard !isMuted, !isInterrupted, !text.isEmpty else { return }
        releaseTask?.cancel()

        // A phone call in progress: stay quiet rather than talk over it.
        if callObserver.calls.contains(where: { !$0.hasEnded }) { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // .duckOthers lowers music from other apps; .interruptSpokenAudioAndMixWithOthers
            // pauses podcasts/audiobooks instead of talking over them.
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            // Another app (e.g. a call) owns audio right now. Skip this prompt.
            return
        }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        scheduleRelease(after: .zero)
    }

    /// Deactivating with .notifyOthersOnDeactivation is what brings the music back up.
    private func scheduleRelease(after delay: Duration = .milliseconds(400)) {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled, !self.synthesizer.isSpeaking else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.scheduleRelease() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.scheduleRelease() }
    }
}
