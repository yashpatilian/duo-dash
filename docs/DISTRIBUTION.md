# Distributing Duo Dash (TestFlight and the App Store)

Most people shouldn't have to build Duo Dash with Xcode. There are two signed builds for that:

| Build | Config | Bundle ID | Looks like | For |
|---|---|---|---|---|
| **TestFlight beta** | `Config/TestFlight.xcconfig` | `com.duodash.beta` | Named "CarPlay", CarPlay icon, Apple's app icons in the dock | Public beta link |
| **App Store** | `Config/Commercial.xcconfig` | `com.duodash.app` | Named "Duo Dash", Duo Dash icon, own icons except Spotify and Apple Music | The App Store |

Both need a paid Apple Developer Program membership, and Xcode signed in to it
(Xcode → Settings → Accounts).

## One-time setup in App Store Connect

1. **Certificates, Identifiers & Profiles → Identifiers → +:** register App IDs
   `com.duodash.beta` and `com.duodash.app`. Tick **HomeKit** and, for announcements,
   **Push Notifications** (see `docs/NOTIFICATIONS.md`). Xcode can create these for you on the
   first archive with automatic signing.
2. **App Store Connect → Apps → + → New App**, once per bundle ID:
   - Beta: name e.g. "Duo Dash Beta" (App Store Connect names must be unique, and "CarPlay"
     can't be used as a listing name), primary language, bundle ID `com.duodash.beta`, any SKU.
   - Store: name "Duo Dash", bundle ID `com.duodash.app`.
3. Privacy policy URL: `https://github.com/yashpatilian/duo-dash/blob/main/PRIVACY.md`.
   Support URL: `https://github.com/yashpatilian/duo-dash/issues`.

## Archive and upload

```bash
# TestFlight beta (CarPlay look)
xcodebuild -project DuoDash.xcodeproj -scheme DuoDash -configuration Release \
  -xcconfig Config/TestFlight.xcconfig -destination 'generic/platform=iOS' \
  -archivePath build/DuoDash-Beta.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/DuoDash-Beta.xcarchive \
  -exportOptionsPlist Config/ExportOptions-AppStore.plist -exportPath build/beta -allowProvisioningUpdates
```

Use `Config/Commercial.xcconfig` and `DuoDash.xcarchive` for the App Store build. With
`destination` set to `upload` in the export options, the export uploads straight to App Store
Connect. Raise `CURRENT_PROJECT_VERSION` for every upload.

## TestFlight public link

App Store Connect → the beta app → **TestFlight → External Testing → +** (a group), add the
build, fill in "What to Test", and submit it for **Beta App Review**. Once approved, turn on
**Public Link**. Anyone with the link installs TestFlight and taps Install. Builds expire
after 90 days, so upload a new one before then.

**Expect Beta App Review to question the CarPlay name and Apple's icons:** App Review
Guideline 5.2.5 says apps may not be confused with Apple products. If the beta is rejected
for this, ship the beta with the App Store look instead (archive with
`Config/Commercial.xcconfig` but `DUODASH_BUNDLE_ID = com.duodash.beta`). Internal testers
(up to 100 people added to your App Store Connect team) get builds without Beta App Review.

## App Store

Needs: screenshots (6.9" iPhone and 13" iPad, made by
`MarketingCaptureTests/testAppStoreScreenshots`), a description, keywords, the age rating
questionnaire, App Privacy answers (no data collected by the developer; announcements send a
device token only if the user turns them on), export compliance (standard encryption only),
and review notes (how to try it without a car: demo flags aren't available in the store
build, so explain that Maps, music and weather work anywhere).
