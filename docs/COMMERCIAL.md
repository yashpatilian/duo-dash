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
| `DuoDash/BrandedIcons.xcassets` (Apple/Spotify icons, CarPlay logo) | Bundled | Left out of the build (`EXCLUDED_SOURCE_FILE_NAMES`) |
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
`xcrun assetutil --info <app>/Assets.car` lists no `AppIconMaps`, `AppIconSpotify`,
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
- [ ] The Duo Dock promotion links to an external store (doc.yashyp.com). Physical goods may
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
      approval. A commercial app needs **Extended Quota Mode**, applied for in the developer
      dashboard; users then don't have to make their own developer app. The onboarding's
      bring-your-own-Client-ID walkthrough must be replaced by one shared Client ID for
      the store build.
- [ ] **Open-Meteo:** the free API is for non-commercial use. A commercial app needs a paid
      [Open-Meteo plan](https://open-meteo.com/en/pricing) (API key) or WeatherKit instead,
      and attribution (CC BY 4.0) in the Weather screen and About.
- [ ] **Anthropic:** users bring their own key under Anthropic's
      [Commercial Terms / Usage Policy](https://www.anthropic.com/legal). If the store build
      ever ships its own key or proxy, it needs its own agreement, rate limits and a
      server-side key (never in the app).
- [ ] **WhisperKit / Kokoro / model weights:** check each licence (MIT / Apache-2.0) and
      include notices in About → Licences.

### Entitlements and capabilities
- [ ] **HomeKit:** enable the HomeKit capability on the App Store App ID, set
      `DUODASH_HOMEKIT = YES` for the archive (it adds `Config/DuoDash.entitlements`), and keep
      the `NSHomeKitUsageDescription`. Review may ask why a car app needs HomeKit: garage
      door on arrival.
- [ ] MusicKit on the App ID if catalogue search is turned on.
- [ ] Bundle ID, team and version/build numbers set for distribution (not
      `com.example.duodash`).

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
