import Foundation

/// Speaks turn instructions through the speech layer (natural Kokoro voice once it's
/// downloaded, Apple's otherwise). Music from the Music app or Spotify is ducked while a
/// prompt plays and comes back to full volume afterwards; it is never stopped.
///
/// The robustness rules (newer prompt replaces a stale one, delayed session release,
/// silence during calls and interruptions) live in `SpokenOutput`.
@MainActor
final class VoiceGuide {
    var isMuted: Bool {
        get { output.isMuted }
        set { output.isMuted = newValue }
    }

    private let output = SpokenOutput(channel: "navigation")

    func speak(_ text: String) {
        output.speak(text)
    }

    func stop() {
        output.stop()
    }
}
