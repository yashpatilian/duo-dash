import AVFoundation
import CallKit

/// Speaks the assistant's short replies. Same audio-session rules as VoiceGuide:
/// music is ducked (never stopped) and comes back up afterwards, spoken-word apps
/// pause, and nothing is said during a phone call or another app's interruption.
@MainActor
final class AssistantSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    var onFinish: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let callObserver = CXCallObserver()
    private var releaseTask: Task<Void, Never>?
    private var isInterrupted = false
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                MainActor.assumeIsolated {
                    guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    self.isInterrupted = type == .began
                    if type == .began { self.synthesizer.stopSpeaking(at: .immediate) }
                }
            }
    }

    func speak(_ text: String) {
        guard !isInterrupted, !text.isEmpty else { return }
        if callObserver.calls.contains(where: { !$0.hasEnded }) { return }
        releaseTask?.cancel()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        scheduleRelease(after: .zero)
    }

    private func scheduleRelease(after delay: Duration = .milliseconds(400)) {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled, !self.synthesizer.isSpeaking else { return }
            self.isSpeaking = false
            self.onFinish?()
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
