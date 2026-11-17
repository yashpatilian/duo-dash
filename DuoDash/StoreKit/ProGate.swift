import Foundation

/// Which features need Duo Dash Pro, as pure functions of the edition and the Pro status,
/// so the decisions are unit-tested in one place.
///
/// | Feature | Personal / TestFlight | App Store (commercial) |
/// |---|---|---|
/// | Dashcam (recording, clips) | Free | Pro |
/// | Impact detection, 45/60-min loops | Pro | Pro |
/// | Themes, Home layout, app icons, trip history | Pro | Pro |
enum ProGate {
    /// The dashcam app itself: free in personal builds, Pro in the App Store edition.
    static func dashcamAvailable(edition: Edition, isPro: Bool) -> Bool {
        !edition.isCommercial || isPro
    }

    /// Everything else Pro adds is Pro in every edition.
    static func proFeatureAvailable(isPro: Bool) -> Bool { isPro }
}
