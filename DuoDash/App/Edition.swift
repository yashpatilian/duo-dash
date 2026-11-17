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

    /// The dock and app grid may use Apple's own app icons (personal and TestFlight builds only).
    var usesOfficialIcons: Bool { self == .personal }

    /// Music services' own icons, shown in every edition (including the App Store build) to mark
    /// their content, as Spotify's and Apple Music's brand guidelines describe. They live in
    /// PartnerIcons.xcassets, which every edition ships.
    static let partnerIconAssets: Set<String> = ["AppIconSpotify", "AppIconMusic"]

    /// How the app talks about the in-car system people already know. The commercial build
    /// never says "CarPlay" (Apple's trademark).
    var carSystemName: String { isCommercial ? "a phone on your car's screen" : "CarPlay" }

    /// The safety line: on the welcome page, in Settings → About, the README, the website and
    /// the App Store description.
    static let safetyNotice = "For passenger use only. Don't use Duo Dash while driving: set your route and music before you set off, and follow your local road rules."

    /// Shown in Settings → About.
    static let notAffiliatedNotice = "Duo Dash is an independent app. It isn't affiliated with, endorsed or sponsored by Apple Inc. or Spotify AB. Apple Music, iPhone and Maps are trademarks of Apple Inc.; Spotify is a trademark of Spotify AB."
}
