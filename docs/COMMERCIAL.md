# Duo Dash: commercial edition

This repo builds the **personal** edition by default: it can install as "CarPlay" with the
CarPlay logo and shows Apple's and Spotify's own app icons in the dock. None of that can go to
the App Store. The **commercial** edition is the same app with its own name, icon and tiles,
for a future App Store build.

## What the switch changes

| | Personal (default) | Commercial |
|---|---|---|
| Build setting `DUODASH_EDITION` | `personal` | `commercial` |
| Home screen name | `DUODASH_DISPLAY_NAME` (default "CarPlay") | "Duo Dash" |
| App icon | `AppIconCarPlay` (or your local one) | `AppIcon` (the Duo Dash icon) |
| Dock, app grid, Home media buttons | Official Apple / Spotify icons | The app's own SF Symbol `AppTile`s (`officialIconAsset` is nil) |
| `DuoDash/BrandedIcons.xcassets` (Apple app icons, CarPlay logo) | Bundled | Left out of the build (`EXCLUDED_SOURCE_FILE_NAMES`) |
| `DuoDash/PartnerIcons.xcassets` (Spotify, Apple Music icons) | Bundled | Bundled: they mark Spotify and Apple Music content, per each brand's guidelines |
| Welcome tour wording | "Have you used CarPlay before?", "What's new compared with CarPlay" | No "CarPlay" anywhere ("your phone on a car's screen", "What Duo Dash adds") |
| Settings → About | Not-affiliated notice | Not-affiliated notice |

The app reads the edition from the Info.plist key `DuoDashEdition` through `Edition.current`
(`DuoDash/App/Edition.swift`). For a quick look without rebuilding, launch with
`-Edition commercial`.

## Building it

`Config/Commercial.xcconfig` includes `Base.xcconfig` (and so your git-ignored
`Local.xcconfig` with the team and bundle ID) and then sets the edition, name and icon, so it
wins over any personal branding.

```
# Simulator check
xcodebuild build -project DuoDash.xcodeproj -scheme DuoDash \
  -xcconfig Config/Commercial.xcconfig \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/dd-commercial

# App Store archive (needs a paid team and an App Store bundle ID in Local.xcconfig)
xcodebuild archive -project DuoDash.xcodeproj -scheme DuoDash \
  -xcconfig Config/Commercial.xcconfig -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/DuoDash.xcarchive
```

Check the result: `CFBundleDisplayName` is "Duo Dash", `DuoDashEdition` is `commercial`, and
`xcrun assetutil --info <app>/Assets.car` lists `AppIconSpotify` and `AppIconMusic` but no `AppIconMaps`,
`AppIconCarPlay` etc.

Before shipping, also grep the user-facing strings: `grep -rn '"[^"]*CarPlay' DuoDash` should
only find the personal-edition branches that check `Edition.current`.

## App Store readiness checklist

### Trademarks and artwork
- [ ] No Apple or Spotify artwork in the bundle (the commercial build excludes
      `BrandedIcons.xcassets`; re-check `Assets.car`). No "CarPlay" in the name, icon,
      screenshots, keywords, description or in-app text. The app may *describe* compatibility
      ("works with Apple Music and Spotify") but not look like Apple's or Spotify's own UI.
- [ ] Name: search the App Store and trademark registers for "Duo Dash" before submitting.
- [ ] "iPhone Duo" in marketing: follow Apple's [Guidelines for Using Apple Trademarks](https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html)
      (e.g. "for iPhone Duo", never as part of the app name).
- [ ] The not-affiliated notice stays in Settings → About and in the App Store description.
- [ ] The Duo Dash mount promotion links to an external store (duodash.app/mount). Physical goods may
      be sold outside In-App Purchase (guideline 3.1.3(e)), but the promo must not be
      misleading, and the link must work at review time.

### App Review risks for a driving app
- [ ] **2.5.x / 4.x, "CarPlay-like" apps:** iOS apps may not imitate CarPlay or claim to be
      CarPlay. Present it as a dashboard app for a phone mount. Avoid CarPlay-identical
      layouts in screenshots (use the Duo Dash icon tiles).
- [ ] **Driver distraction (1.4.1 physical harm, 5.1.x):** large targets, voice control,
      nothing that needs reading long text while moving. Consider limiting typing (messages,
      search) while the car is moving, and say so in the review notes.
- [ ] **Messages and calls:** texts go through Apple's compose sheet and need the user to tap
      Send; calls use the system. No auto-sending.
- [ ] **Dashcam:** recording is visible on screen; explain in review notes that it only
      records while the app is in front, and that clips stay on device unless saved.
- [ ] **Background modes** (`audio`, `location`, `bluetooth-central`): each must be
      justified in review notes (voice guidance, navigation, OBD-II adapter). Background
      location only while navigating.
- [ ] **AI assistant (Claude):** the user brings their own API key. Review may ask for a
      working demo: provide a key in the review notes or make sure Apple Intelligence mode
      works without one. Generative content needs reporting/blocking if it shows user content
      (5.1.x / 1.2): the assistant only answers the driver, but describe that.
- [ ] Provide a demo video and test account details (Spotify Premium, an OBD-II adapter is
      optional: demo mode) in App Review notes.

### Privacy (nutrition label from real data use)
Declare what the code actually does; nothing is used for tracking and there are no analytics.
- [ ] **Location (precise):** map, navigation, weather, dashcam GPS track. On device; sent to
      Apple (MapKit), Open-Meteo (weather, coarse coordinates) and, when Claude is selected,
      Anthropic (approximate location with the request). Not linked to identity, not tracking.
- [ ] **Contacts:** favourites and addresses, on device; a contact the user names is sent to
      Anthropic only in Claude mode.
- [ ] **Audio data / voice:** dictation runs on device (Whisper, Apple Speech fallback).
      Apple Speech may use Apple's servers when on-device recognition isn't available.
- [ ] **User content (messages):** drafted in-app, sent via Apple's compose sheet.
- [ ] **Photos/video:** dashcam clips stored on device; saved to Photos only on request.
- [ ] **Search history / user content sent to Anthropic** in Claude mode (requests,
      route). Disclose as "App Functionality", not linked to identity.
- [ ] **HomeKit, Calendar, Bluetooth, Apple Music library:** on device only.
- [ ] Add `PrivacyInfo.xcprivacy` (required-reason APIs: UserDefaults `CA92.1`, file
      timestamps if used, disk space if the speech-model store checks it) and include the
      privacy manifests of WhisperKit / Kokoro / Spotify SDK.
- [ ] Privacy policy URL that matches the above.

### Export compliance
- [ ] Uses only HTTPS/TLS from the OS (URLSession) and Keychain: set
      `ITSAppUsesNonExemptEncryption = NO` in Info.plist (standard exemption), unless
      something with custom crypto is added.

### Third-party terms
- [ ] **Spotify:** the App Remote SDK's [Developer Terms](https://developer.spotify.com/terms)
      and [Design Guidelines](https://developer.spotify.com/documentation/design) apply:
      attribution with the Spotify logo where Spotify content is shown (supplied by the
      SDK/guidelines, not our icon copy), no modifying artwork, no commercial use without
      approval.
- [ ] **Spotify access (done in code, needs a real-device check):** the shared Spotify developer
      app is in **development mode and can't leave it**: extended quota is only granted to
      registered businesses with 250,000+ monthly active users (since May 2025). Development
      mode allows at most **5 allow-listed accounts** (owner included), **each with Spotify
      Premium**. So:
  - the store builds (`Config/TestFlight.xcconfig`, `Config/Commercial.xcconfig`) set
    `DUODASH_SPOTIFY_MODE = app-remote`: no Web API sign-in; the Spotify app hands over an
    App Remote token when it opens for a moment. Everything on the Spotify screen (player,
    artwork, home-feed shelves, playlist and album pages) is App Remote, so nothing is
    hidden. Whether App Remote accepts accounts outside the allow-list must be checked on a
    phone ([checklist](SPOTIFY_SETUP.md#check-on-a-real-iphone-with-an-account-that-is-not-allow-listed));
  - if Spotify refuses an account anyway, the Spotify screen shows "Spotify control is
    limited in this version" with **Open Spotify** (no login loop); Apple Music is unaffected;
  - Settings → Spotify → **Use My Own Spotify Developer App** lets anyone use their own
    Client ID (full sign-in-once mode, their own 5-account allow-list);
  - the Client ID is in the git-ignored `Config/Secrets.xcconfig` on the archiving Mac, never
    in the repo. Dashboard: bundle IDs `com.duodash.dev`, `com.duodash.beta`,
    `com.duodash.app`; Redirect URI `duodash://spotify-callback`.
  - Store listing and review notes: describe Spotify as "controls the Spotify app (Premium)",
    don't promise it for every account until the device check passes, and give the reviewer
    an allow-listed Premium account.
- [ ] **Open-Meteo:** the free API is for non-commercial use. A commercial app needs a paid
      [Open-Meteo plan](https://open-meteo.com/en/pricing) (API key) or WeatherKit instead,
      and attribution (CC BY 4.0) in the Weather screen and About.
- [ ] **Anthropic:** users bring their own key under Anthropic's
      [Commercial Terms / Usage Policy](https://www.anthropic.com/legal). If the store build
      ever ships its own key or proxy, it needs its own agreement, rate limits and a
      server-side key (never in the app).
- [ ] **YouTube:** the YouTube screen follows the [YouTube API Services Terms](https://developers.google.com/youtube/terms/api-services-terms-of-service)
      and [Developer Policies](https://developers.google.com/youtube/terms/developer-policies):
      playback only through the official IFrame Player (`youtube-nocookie.com` embed, inline,
      the app's bundle ID as the `origin`); browsing on YouTube's own mobile site, unmodified;
      **no ad blocking** (only top-level navigation is restricted to YouTube / Google sign-in,
      every frame inside a YouTube page loads untouched); **no background playback**: the video
      pauses when the screen or the app is left, and picture in picture is WebKit's own,
      started by the user. No YouTube logo is bundled: the dock tile is Duo Dash's red SF
      Symbol tile. Read the terms again before submitting; they change.
- [ ] **Video while moving:** the YouTube screen doesn't lock while the car moves. That relies on
      Duo Dash's passenger-only positioning (`Edition.safetyNotice`, shown on the screen once
      per launch, in the welcome tour, Settings → About and the listing). App Review may ask
      about it under 1.4.1: answer in the review notes, and be ready to add a speed lock if
      asked.
- [ ] **Other apps' tiles** (Settings → Dock → Apps on this iPhone): drawn by Duo Dash (SF
      Symbol on a brand-ish colour, with the app's name); no third-party logos are bundled.
      They only open the app with its public URL scheme (`LSApplicationQueriesSchemes`, 18 of
      the 50 allowed). Google Maps / Waze hand-off uses their documented URL schemes.
- [ ] **WhisperKit / Kokoro / model weights:** check each licence (MIT / Apache-2.0) and
      include notices in About → Licences.

### Entitlements and capabilities
- [ ] **HomeKit:** enable the HomeKit capability on the App Store App ID, set
      `DUODASH_HOMEKIT = YES` for the archive (it adds `Config/DuoDash.entitlements`), and keep
      the `NSHomeKitUsageDescription`. Review may ask why a car app needs HomeKit: garage
      door on arrival.
- [ ] MusicKit on the App ID if catalogue search is turned on.
- [ ] Register the bundle ID `com.duodash.app` (set in `Config/Commercial.xcconfig`) and set
      the team and version/build numbers for distribution. Keep the ID brand-only, with no
      personal name: the Spotify setup step in the welcome tour shows it on screen.

### Speech models (see docs/PROJECT_NOTES.md, "speech models in release builds")
- [ ] Whisper (small.en or large-v3 turbo) and Kokoro ship with the app and are the default
      from first launch; the user never sees a separate download.
- [ ] Deliver them with Background Assets (essential download) or On-Demand Resources with
      initial-install tags, to stay within App Store size guidance (adds about 330–730 MB).
- [ ] Install them into `Application Support/Speech/` with the same model/variant IDs so
      `SpeechModelStore` finds them, and updates never re-download.

### Store listing
- [ ] Screenshots from the commercial build only (Duo Dash icon tiles).
- [ ] Age rating, support URL, marketing URL, review notes (as above).

## Duo Dash Pro (in-app purchase)

Everything that was free stays free, except that **the App Store edition makes the Dashcam a
Pro feature**. Pro is any active subscription in the "Duo Dash Pro" group or the lifetime
purchase (`ProStore.isPro`). The gating decisions live in `DuoDash/StoreKit/ProGate.swift`:

| Feature | Personal / TestFlight | App Store (commercial) |
|---|---|---|
| Dashcam (recording, Save clip, clips list) | Free | **Pro**: the dock tile stays; opening it shows an upsell, recording never starts (also not via "Start when Duo Dash opens" or `duodash://open/dashcam`); Settings → Dashcam shows PRO and opens the paywall |
| Impact detection (saves a clip after a jolt, Low/Medium/High), 45/60-min loops | Pro | Pro |
| Themes (accent colour, app grid wallpaper) | Pro | Pro |
| Home layout (card order, third card) | Pro | Pro |
| Alternate app icons (Midnight, Silver, Ocean, Sunset) | Pro | Pro |
| Trip history (recording and viewing; nothing is recorded without Pro) | Pro | Pro |

Without Pro the saved choices are kept but not applied (blue accent, original wallpaper and
layout, 30-min loop at most), so they come back on re-subscribing. Code: `DuoDash/StoreKit/`
(`ProStore`, `StoreKitProBackend`, `PaywallView`, `ProGate`), `DuoDash/Pro/`, `DuoDash/Trips/`,
`DuoDash/Settings/ProSettingsSection.swift`.

Testing: the shared scheme's Run action uses `DuoDash/StoreKit/DuoDashPro.storekit` (local
StoreKit testing, not bundled), so purchases work offline in the Simulator. `-ProUnlocked`
forces Pro; `-UITest` alone uses a demo store (fixed A$ prices) and is not Pro; `-DemoStore`
uses the demo store outside tests.

### App Store Connect setup
1. **Agreements, Tax and Banking:** the Paid Apps agreement must be active.
2. **Subscription group** "Duo Dash Pro" (Monetization → Subscriptions). Group display name
   (en-AU): "Duo Dash Pro".
3. **Subscriptions** in that group, both at the same level (level 1: same features,
   different durations):

   | Product ID | Reference name | Duration | Price (base AU) | Introductory offer |
   |---|---|---|---|---|
   | `com.duodash.pro.monthly` | Duo Dash Pro Monthly | 1 month | A$2.99 | none |
   | `com.duodash.pro.yearly` | Duo Dash Pro Yearly | 1 year | A$19.99 | Free trial, 1 week, new subscribers |

   Localisation (en-AU) for each: display name "Duo Dash Pro Monthly" / "Duo Dash Pro Yearly",
   description "Themes, Home layout, app icons, dashcam extras and trip history."
4. **In-app purchase** (Monetization → In-App Purchases), type **Non-Consumable**:
   `com.duodash.pro.lifetime`, reference name "Duo Dash Pro Lifetime", price A$39.99,
   display name "Duo Dash Pro Lifetime", description "Every Pro feature, forever. One-time
   purchase." Family Sharing: off (matches the StoreKit file; turn on for all three if wanted).
5. **Review information** for each product: a screenshot of the paywall (Settings → Duo Dash
   Pro → Unlock Duo Dash Pro; on the cover screen and the inner screen) and review notes
   ("Pro unlocks themes, Home layout, alternate icons, dashcam impact detection, 45/60-min loops
   and trip history; in this build the Dashcam itself is Pro").
6. Attach all three products to the **app version** being submitted (first IAPs must ship
   with a binary).
7. App Information: **Privacy Policy URL**
   https://github.com/yashpatilian/duo-dash/blob/main/PRIVACY.md; the paywall links Apple's
   standard EULA (https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) as the
   Terms of Use, so the app description should also include a "Terms of Use (EULA)" link
   (guideline 3.1.2).
8. Optional: App Store Server Notifications are not needed (entitlements are checked on
   device with `Transaction.currentEntitlements` and `Transaction.updates`).

### Info.plist
- Impact detection uses `CMMotionManager` device motion, which **needs no permission prompt**,
  so no `NSMotionUsageDescription` is required (it's only for motion activity / pedometer).
  Add one only if motion activity is used later.
- Trip history uses the location the app already has (`NSLocationWhenInUseUsageDescription`).

### Privacy label
Trip history stays on the device (Application Support/Trips, at most 200 trips). Start and end
place names come from Apple's MapKit reverse geocoder. Nothing new is collected by the developer.
Purchases are handled by Apple (no purchase data reaches the developer beyond App Store Connect
reports).
