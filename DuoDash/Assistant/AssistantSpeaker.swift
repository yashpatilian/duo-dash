import Foundation

/// Speaks the assistant's short replies through the speech layer. Same audio-session
/// rules as VoiceGuide (see `SpokenOutput`): music is ducked (never stopped) and comes
/// back up afterwards, spoken-word apps pause, and nothing is said during a phone call
/// or another app's interruption.
@MainActor
final class AssistantSpeaker {
    var isSpeaking: Bool { output.isSpeaking }
    var onFinish: (() -> Void)? {
        get { output.onFinish }
        set { output.onFinish = newValue }
    }

    private let output = SpokenOutput(channel: "assistant")

    func speak(_ text: String) {
        output.speak(text)
    }

    func stop() {
        output.stop()
    }
}
