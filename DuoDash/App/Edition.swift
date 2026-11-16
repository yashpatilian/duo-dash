import Foundation

/// Which build this is. `personal` is what this repo builds by default (official app icons
/// in the dock, the "CarPlay" name if you choose it). `commercial` is for a future App Store
/// build: the app's own SF Symbol tiles and wording only, and a not-affiliated notice.
/// Set with the `DUODASH_EDITION` build setting (Config/Commercial.xcconfig), read from the
/// Info.plist key `DuoDashEdition`.
enum Edition: String, CaseIterable, Sendable {
    case personal, commercial

    static let infoKey = "DuoDashEdition"

    /// Parses the Info.plist value; anything unknown or missing is `personal`.
    init(infoValue: String?) {
        self = infoValue.flatMap { Edition(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? .personal
    }

    /// This build's edition. `-Edition commercial` on launch overrides it (tests, screenshots).
    static let current: Edition = {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-Edition"), index + 1 < arguments.count {
            return Edition(infoValue: arguments[index + 1])
        }
        return Edition(infoValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
    }()

    var isCommercial: Bool { self == .commercial }

    /// The dock and app grid may use Apple's and Spotify's own icons (personal builds only).
    var usesOfficialIcons: Bool { self == .personal }

    /// How the app talks about the in-car system people already know. The commercial build
    /// never says "CarPlay" (Apple's trademark).
    var carSystemName: String { isCommercial ? "a phone on your car's screen" : "CarPlay" }

    /// Shown in Settings → About.
    static let notAffiliatedNotice = "Duo Dash is an independent app. It isn't affiliated with, endorsed or sponsored by Apple Inc. or Spotify AB. Apple Music, iPhone and Maps are trademarks of Apple Inc.; Spotify is a trademark of Spotify AB."
}
