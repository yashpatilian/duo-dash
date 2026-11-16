# AGENTS.md: instructions for coding agents

This file is for AI coding agents (Claude Code, Codex, Cursor and the like) that a user has
asked to **install Duo Dash on their iPhone** or to **work on the code**. People should read
[README.md](README.md) and [docs/INSTALL.md](docs/INSTALL.md) instead.

## What this project is
Duo Dash is a SwiftUI iOS app that turns an iPhone (designed around the foldable
**iPhone Duo**, also runs on any iPhone or iPad on iOS 26+) into a CarPlay-style dashboard for a dash
mount. It's installed by building from source with the user's own Apple developer account.
There is no App Store build. Licence: personal use only (see [LICENSE](LICENSE)); don't
publish builds or copies of the code on the user's behalf.

## Installing for a user: follow these steps in order

1. **Check the Mac.**
   - macOS on Apple silicon or Intel, with **Xcode 27.1 or later**: `xcodebuild -version`.
     If it's older or missing, tell the user to install or update Xcode from the App Store.
     Don't try to install Xcode yourself.
   - `xcode-select -p` should point inside `Xcode.app`. If not, tell the user to run
     `sudo xcode-select -s /Applications/Xcode.app` (it needs their password).
2. **Get the code**: `git clone <repo URL>`, then `cd` into it.
3. **Ask the user for, or look up, their signing details.**
   - **Apple Developer Team ID** (10 characters). It's in Xcode → Settings → Accounts
     (select the team) or at developer.apple.com → Membership. Signing identities on the
     Mac show team IDs: `security find-identity -v -p codesigning`. If there are several,
     ask which one to use.
   - The user must be **signed in to Xcode** with that Apple ID (Xcode → Settings →
     Accounts). You can't do this for them; ask them to.
   - A free Apple ID works, but apps then expire after 7 days and need reinstalling.
     A paid Apple Developer Program membership lasts a year.
   - **Bundle ID**: suggest `com.<their-name-or-handle>.duodash`. It must be unique to them.
4. **Write the local signing config** (git-ignored, never committed):
   `scripts/setup.sh --team <TEAMID> --bundle-id <bundle.id>`
5. **Optional extras.** Ask the user whether they want each one.
   - The dock's official app icons are already in the repo. To refresh them from the apps on
     the user's Mac (e.g. after a macOS redesign): `scripts/setup.sh --icons`.
   - Spotify: the user creates a Spotify developer app (steps in
     [docs/SPOTIFY_SETUP.md](docs/SPOTIFY_SETUP.md)) and gives you the **Client ID**.
     Never ask for or store the client *secret*. Then run
     `scripts/setup.sh --spotify-client-id <id>`.
   - Claude for the assistant: the user pastes their own API key into the app (Settings →
     AI Assistant). It's stored in the iPhone Keychain. Don't put API keys in files.
6. **Connect the iPhone and install.**
   - The phone must be unlocked and connected by cable or on the same Wi‑Fi, have trusted
     this Mac, and have **Developer Mode** on (Settings → Privacy & Security → Developer
     Mode; the phone restarts). List phones with `xcrun devicectl list devices`.
   - Then run `scripts/setup.sh --install`. It asks which phone if there are several, or
     pass `--device <UDID>`.
   - If the build fails on signing ("No Account for Team", "No profiles"), the user isn't
     signed in to Xcode with the right account, or the bundle ID is taken. Fix that, don't
     change project settings.
   - First launch on the phone: the user may need to trust the developer under Settings →
     General → VPN & Device Management (free accounts), and allow Location, Media & Apple
     Music, Microphone, Speech Recognition and Contacts when asked.
7. **Optional: auto-open in the car.** iOS doesn't let apps launch themselves. Give the user
   the Shortcuts steps from [docs/INSTALL.md](docs/INSTALL.md#open-it-automatically-in-the-car).

Report back to the user: what was installed, which optional parts were set up, and anything
they still need to do on the phone.

## Working on the code
- **Layout.** `DuoDash/` is the app, with folder-synced Xcode groups: new files need no
  project edits. Unit tests are in `DuoDashTests/` and UI tests in `DuoDashUITests/`.
  Config lives in `Config/`: `Info.plist`, `Base.xcconfig`, and the git-ignored
  `Local.xcconfig` / `Secrets.xcconfig`.
- **Build and test** on an iPhone Duo simulator (or any iPhone or iPad simulator):
  ```
  xcodebuild test -project DuoDash.xcodeproj -scheme DuoDash \
    -destination 'platform=iOS Simulator,name=iPhone Duo' -only-testing:DuoDashTests
  ```
  UI tests take about 25 minutes. `DUODASH_CANVAS=WxH` makes the app render at a given window
  size (cover screen, Split View, inner screen). The Simulator uses demo backends for Apple
  Music and Spotify; `-DemoSpotify` and `-SeedContacts` launch arguments exist for tests.
- **Conventions.**
  - Swift 5 language mode, `@MainActor @Observable` models in the environment, zero compiler
    warnings in app sources.
  - Touch targets of at least 60 pt.
  - Use `Theme` and the shared components.
  - Every text field gets a `DictationButton`.
  - Layout is size-driven, never orientation-driven.
  - Everything the user changes must persist.
- **Never commit** personal details (team IDs, bundle IDs with names, device IDs, API keys,
  client IDs, addresses), or `Config/Local.xcconfig` /
  `Config/Secrets.xcconfig`.
- Decisions and status are in [docs/PROJECT_NOTES.md](docs/PROJECT_NOTES.md).
