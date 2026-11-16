# Duo Dash: project notes

Source of truth for decisions and status. Update this at the end of each work session.

## Decisions
- **One app, no hand-offs.** Features that can't be done smoothly in-app are dropped (Shortcuts, Waze and Google Maps embedding, reading SMS or call history).
- **SwiftUI + Observation (`@Observable`)**, Swift 5 language mode with explicit `@MainActor` on the models. Deployment target **iOS 26.0** (for Liquid Glass), built with **Xcode 27.1+ / iOS 27.1 SDK** (needed for iPhone Duo full-screen and hinge APIs). The fold APIs in `FoldGeometry.swift` (`reservedRegions(kind: .division)`, `onHingeChange`) compile as written on Xcode 27.2.
- **Layout is size-driven, never orientation-driven.** Wider than tall → CarPlay-style sidebar **on the right** (iPhone Duo convention; clock on top, app icons, dashboard button at the bottom); otherwise → bottom bar of app icons + status row. This one rule covers inner landscape/portrait, cover screen, and Split View halves. `ShellLayout` keeps screen identity so nothing rebuilds when the window changes shape.
- **Edge to edge (session 3).** The shell ignores the safe area and fills the whole screen; only the clock/status row and the dock tiles are kept clear of the camera. Reason: the cover screen reports a right inset of 84 pt (a system status column with the camera) for the full height, plus 34 pt at the bottom, which left a third of the screen empty.
- **CarPlay look (session 3).** True black background, flush dock in `Theme.chrome`, solid dark tiles (`#1C1C1E`) for cards and list rows, SF Pro (not rounded), system blue for selection/primary. Home is the CarPlay dashboard: map + widgets; it has its own media widget, so the mini now-playing bar is hidden on Home.
- **Official app icons, committed (owner's decision).** The dock shows the real Maps / Music / Phone / Messages / Spotify / Settings icons, rendered from the apps on the Mac by `scripts/extract-app-icons.swift` into `DuoDash/Assets.xcassets/AppIcon*.imageset/` and included in the repo. They are Apple's/Spotify's artwork (see LICENSE §5); if a rights holder objects, remove them and the dock falls back to drawn tiles in the same colours. On macOS 27 the Music icon is the white tile with a black note.
- **Dock scrolls, never shrinks.** Icons keep their size; the strip scrolls and fades only at an end with icons beyond it. Press and hold to drag-reorder; the order is saved (`dock.order`), new apps are appended. Clock and dashboard button are pinned.
- **Everything the user sets is persisted** (UserDefaults; the Claude API key in the Keychain): dock order, selected tab, saved places, map orientation, voice guidance, AI provider/effort/model, favourite contacts, recents, Music tab state.
- **Branding (owner's decision).** The app installs as "CarPlay" with the CarPlay logo (`AppIconCarPlay`, committed; Apple trademarks). `Config/Base.xcconfig` sets this default and includes the git-ignored `Config/Local.xcconfig`; `scripts/local-branding.swift --duo-dash | --icon <image> [name] | --reset` changes it per build. `Config/Secrets.xcconfig` (git-ignored) holds the Spotify client ID.
- **AI assistant: two providers behind one set of tools** (`DuoDash/Assistant/`): Apple Intelligence (Foundation Models, on device, default) or Claude (Messages API over URLSession, model `claude-opus-5-5`, low effort, server-side refusal fallback, web search for reviews/hours). Tools: search places, contact address, plan route (incl. best stop on the way by total ETA), add stop, start/end navigation. A local intent parser is the fallback when a provider is unavailable. Apple Maps reviews aren't available to apps; Claude mode reads reviews via web search.
- **Multi-stop trips** in `NavigationModel`: one `MKRoute` per leg; `route` is always the current leg so the progress tracker is unchanged; resume restores all stops. Turn-by-turn voice is **off by default** (`nav.voiceEnabled`).
- **Saved places** (`FavouritesStore`, "places.v2"): any number of places with custom names and emoji drawn greyscale; migrated once from the old Home/Work/Uni (adds an unset "Home 2").
- **Phone & Messages:** favourites picked from Contacts; recents are only calls/messages started in Duo Dash (iOS gives apps no call history, no Phone favourites, no message history); texts go through Apple's compose sheet (user taps Send).
- **Copied addresses:** iOS doesn't let apps read messages, so Maps detects (without reading) an address on the clipboard and offers it via Apple's PasteButton (no paste prompt).
- **Dictation everywhere:** `DictationButton` (Speech framework, ducks music, stops after a pause) next to every text field except the API key.
- **Apple Music-style player (session 3).** `DuoDash/Music/NowPlayingScreen.swift`: the cover, blurred and saturated, washes the whole Music screen; big artwork that eases back when paused; left-aligned title/artist/album; thin white scrubber; the transport in one floating Liquid Glass capsule (shuffle and repeat move to a second capsule on narrow windows). While the full player is open the mini bar hides (`AppModel.isPlayerOpen`).
- **Liquid Glass** (`glassEffect`) on controls: map floating buttons, search/turn panels, the player's transport capsule, the selected Music tab. Content (map, artwork) and the CarPlay chrome/tiles are solid.
- **Apple Music = system Music player** (`MPMusicPlayerController.systemMusicPlayer`): audio lives in the Music app's process, so voice prompts duck it cleanly and our app never owns music audio. Library via MediaPlayer (no developer token); catalogue search via MusicKit (optional, needs MusicKit enabled on the App ID).
- **Now-playing arbitration:** the source that most recently *started playing* is active; a paused source stays active until another starts.
- **Simulator/tests use a demo music backend** (`DemoMusicBackend`, silent) because the Simulator has no Music app.
- **Testing is local** (Xcode on the Mac, iPhone Duo simulator, the real Duo). The GitHub Actions workflow (`.github/workflows/ios-ci.yml`) is manual-only (`workflow_dispatch`) since the repo went private: macOS minutes count 10× there.
- **Signing:** team and bundle ID come from the git-ignored `Config/Local.xcconfig` (written by `scripts/setup.sh`); public defaults are no team and `com.example.duodash` (tests: `.tests`, `.uitests`).
- **Test canvas:** `DUODASH_CANVAS=WxH` renders the app as exactly that window size (no screen safe area inside it), placed inside the safe area and scaled down to fit when bigger than the current screen, so inner-screen and Split View sizes can be tested while the simulator is folded.
- **Parallel work:** features were built by agents in separate git worktrees and cherry-picked; each feature is installed on the Duo as soon as it merges and passes the unit tests.
- **The Xcode project uses folder-synced groups** (objectVersion 77). Files added under `DuoDash/` need no project edits. `Config/Info.plist` sits outside the synced folder so it isn't copied as a resource.
- **Screens are kept alive** after their first visit (stacked with opacity) so switching is instant and keeps its state.
- **Map:** MapKit SwiftUI `Map`, routing with `MKDirections`, our own progress tracker (`NavigationModel`). Addresses use the iOS 26 `MKMapItem` `location` / `address` API (no `MKPlacemark`).
- **Voice:** `AVSpeechSynthesizer` on a `.playback` / `.voicePrompt` session with `.duckOthers`. The session is deactivated with `.notifyOthersOnDeactivation` so music comes back up.
- **Units:** `MKDistanceFormatter` follows the device locale (metric in AU).
- **System status bar and home indicator are hidden.** The app draws its own clock/status.
- **Reference:** [f-io/LIVI](https://github.com/f-io/LIVI) (GPL-3.0, ideas only, no code). It shows *real* projected CarPlay, which an iPhone can't do to itself. Ideas worth taking: dock on left/right/bottom (right-hand-drive cars), day/night themes.

## Screen measurements (screen-info overlay, iPhone Duo simulator, iOS 27.2)
| Posture | Screen (pt) | Native (px) | Scale | Safe area (T L B R) | Layout | Fold region | Hinge |
|---|---|---|---|---|---|---|---|
| Folded, cover screen, portrait | 466 × 678 | 1398 × 2034 | 3.0 | 0 0 34 84 | bottom dock, compact | none active | closed, 0° |
| Folded, cover screen, landscape | 678 × 466 | 2034 × 1398 | 3.0 | camera column moves to the left edge (sidebar absorbs it) | sidebar, compact | none active | closed |
| Unfolded inner screen, half-open, Split View | not measured yet | | | | | | |

## Status (2026-11-16, session 4)
- **Built and merged:** edge-to-edge CarPlay shell with right-hand scrolling, reorderable dock; Apple Music-style player; Music playlist/album pages (every song, play from any song); configurable saved places with greyscale emoji (Home kept, Home 2 added); north-up map option; AI assistant (Apple Intelligence / Claude) with multi-stop routing; Phone (favourites, Duo Dash recents, contacts, keypad) and Messages (favourites, recents, compose with voice and quick replies); Settings app; copied-address suggestion; dictation on text fields; "Open Duo Dash" Shortcuts action; navigation voice off by default; local CarPlay branding.
- **Tests:** 88 unit tests pass; UI suites per feature pass (assistant, places, music, phone/messages, settings, copied address, maps journey, window sizes); full UI suite re-run after merging.
- **Installed on the iPhone Duo** after each merge.
- **Spotify:** client ID wired (git-ignored `Config/Secrets.xcconfig`, `duodash://spotify-callback`); App Remote integration in progress.

## Blocked / not verified
- On the real Duo (needs the user): Apple Music playback/pause/skip and the playlist "start at song" queue; voice ducking (guidance, assistant, dictation); background/return; Contacts picker, calls, sending texts; Apple Intelligence on device; Claude with a real key; dictation; drag-reordering by touch; copied address from real apps.
- Unfolded inner screen, half-open hinge (fold-aligned Home split) and Split View with another app: checked only through the test canvas at those sizes, not on the unfolded device/Device Hub.
- GPS driving behaviour: prompt timing, reroute thresholds, multi-stop arrival.

## Next actions
1. Finish Spotify (App Remote): connect, now playing, controls, playlists; test on the Duo.
2. Device pass with the user on everything above; record unfolded/half-open/Split View screen-info numbers.
3. Demo video (3D app-video skill), mostly unfolded, after everything is verified.
4. Drive test: ducking, prompts, reroutes, stops.

## Open questions
- Is the Spotify App Remote wake-up tolerable in practice?
- Public name/branding: "Duo Dash" publicly; "CarPlay" only for personal builds (trademark).
- Should catalogue search be enabled (requires MusicKit on the App ID in the developer portal)?
- Music icon: keep macOS 27's white icon, or supply the iOS one?
- Restaurant booking: needs a booking partner API (OpenTable/Resy approval); for now the assistant can call the restaurant or open its page.
- Add OpenAI as a third assistant provider? (the tool layer is provider-neutral)

## Release (2026-11-16)
- Final suite before release: 126 tests passed (98 unit, 28 UI), 0 failures; marketing captures 4/4.
- Public release: https://github.com/yashpatilian/duo-dash. It's a single clean commit exported from this
  branch with `git archive`, leaving out `ci/` and `.github/`. This repo (carplaydupe) stays private
  and is the working copy. To update the public repo, re-export and push a new commit there.
- Demo video: 40 s, 1920×1080, rendered with the app-3d-video skill engine from real simulator captures
  (`MarketingCaptureTests`). The web copy (H.264, about 9 MB) is in docs/media/.
