# Duo Dash: project notes

Source of truth for decisions and status. Update this at the end of each work session.

## Decisions
- **One app, few hand-offs.** Features that can't be done smoothly in-app are dropped (Shortcuts, Waze and Google Maps embedding, reading SMS or call history). Exception (2026-11-17): drivers who prefer Google Maps or Waze can choose it in Settings → Navigation, and Go/Start then hands the trip off by URL scheme (see "Navigation apps, other apps' tiles, YouTube" below).
- **SwiftUI + Observation (`@Observable`)**, Swift 5 language mode with explicit `@MainActor` on the models. Deployment target **iOS 26.0** (for Liquid Glass), built with **Xcode 27.1+ / iOS 27.1 SDK** (needed for iPhone Duo full-screen and hinge APIs). The fold APIs in `FoldGeometry.swift` (`reservedRegions(kind: .division)`, `onHingeChange`) compile as written on Xcode 27.2.
- **Layout is size-driven, never orientation-driven.** Wider than tall → CarPlay-style sidebar **on the right** (iPhone Duo convention; clock on top, app icons, dashboard button at the bottom); otherwise → bottom bar of app icons + status row. This one rule covers inner landscape/portrait, cover screen, and Split View halves. `ShellLayout` keeps screen identity so nothing rebuilds when the window changes shape.
- **Edge to edge (session 3).** The shell ignores the safe area and fills the whole screen; only the clock/status row and the dock tiles are kept clear of the camera. Reason: the cover screen reports a right inset of 84 pt (a system status column with the camera) for the full height, plus 34 pt at the bottom, which left a third of the screen empty.
- **CarPlay look (session 3).** True black background, flush dock in `Theme.chrome`, solid dark tiles (`#1C1C1E`) for cards and list rows, SF Pro (not rounded), system blue for selection/primary. Home is the CarPlay dashboard: map + widgets; it has its own media widget, so the mini now-playing bar is hidden on Home.
- **Official app icons, committed (owner's decision).** The dock shows the real Maps / Music / Phone / Messages / Spotify / Settings icons, rendered from the apps on the Mac by `scripts/extract-app-icons.swift` into `DuoDash/BrandedIcons.xcassets/AppIcon*.imageset/` (their own catalog, with `AppIconCarPlay`, so the commercial build can leave them out) and included in the repo. They are Apple's/Spotify's artwork (see LICENSE §5); if a rights holder objects, remove them and the dock falls back to drawn tiles in the same colours. On macOS 27 the Music icon is the white tile with a black note.
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

## Decision: speech models in release builds (2026-11-17)
- For the App Store / commercial release, **Whisper (speech-to-text) and Kokoro (Natural
  Voice) ship with the app and are the default from first launch**. They override Apple's
  dictation and text-to-speech everywhere: dictation buttons, the assistant, and turn-by-turn
  voice. Apple's engines stay only as a fallback if a model can't load.
- Packaging: bundling adds about 330–730 MB (Whisper small.en 218 MB or large-v3 turbo 627 MB,
  plus Kokoro 111 MB). Deliver them with the install via Background Assets (essential
  download) or On-Demand Resources (initial install tags) to stay within App Store size
  guidance. The user should never see a separate download step.
- In development builds the models are downloaded once, into Application Support/Speech.
  Updates must never make users download them again (see AGENTS.md).

## Session 2026-11-17 (overnight)
- New apps: Weather (iOS Weather style), Calendar (Day / Month / Upcoming), Car (OBD-II),
  Home (HomeKit, opt-in per build), Dashcam (Ultra Wide, 10-min loop). On-device speech
  (Whisper + Kokoro). CarPlay app grid. iPad/iPhone universal with whole-UI scaling.
- Business: `web/dock/` product site (not deployed). Business plans and the mount's design
  files are kept outside this repository.
- GitHub agent pipeline (`.github/workflows`, `docs/AGENT_PIPELINE.md`): off until the
  ANTHROPIC_API_KEY secret is added to the public repo.
- Testing notes: UI tests use `revealInDock` (DockHelpers.swift) because the dock scrolls
  with 11 apps; window-size sweeps run on the iPad Pro 13 simulator, where every Duo canvas
  fits unscaled (scaled canvases report misaligned frames to XCTest). Each visible screen has
  a 1-pt marker element `screen.<app>`; never wrap a screen in an accessibility container
  (it overwrites the app's own ids).
- Known follow-up: `music.row.N` ids can repeat across sections; make them unique.
## Welcome tour, Duo Dash mount, commercial edition (2026-11-17)
- **Welcome tour** (`DuoDash/Onboarding/`): first launch only (`onboarding.completed` in UserDefaults);
  replay from Settings → About → "Show the welcome tour". Flow: welcome + "used CarPlay?" → music
  (Apple Music asks for Media access via `AppleMusicModel.requestAccess()`; Spotify → with a bundled
  client ID, "Connect Spotify" (sign in once); without one, Now = 7-step walkthrough of
  docs/SPOTIFY_SETUP.md + Mac command + QR to the guide + video slot)
  → 4 tour pages (new users) or "What's new compared with CarPlay" → permissions (Location, Contacts,
  Microphone & Speech; only undecided ones; page skipped when none) → Duo Dash mount sheet. Answers and
  the current page persist (`onboarding.*` keys). Hidden under `-UITest`/`-Capture` unless
  `-Onboarding`; `-OnboardingStep <id>` opens a page directly (screenshots). Location isn't
  started while the tour is up, so its Allow button asks.
- Layout follows the app's rules: size-driven (wide = art beside text, otherwise stacked), split on
  the fold when the Duo is half open (`FoldGeometry`), iPad scaled like the dashboard. Buttons use
  system Liquid Glass (`.glass` / `.glassProminent`, `GlassEffectContainer`, `glassEffectID`).
- **Duo Dash mount** car mount: promo sheet at the end of the tour and Settings → Duo Dash mount; store link is
  one constant, `DockStore.url` (https://duodash.app/mount).
- **Editions:** `DUODASH_EDITION` (`personal` default, `commercial`) → Info.plist `DuoDashEdition`
  → `Edition.current`. Commercial (`-xcconfig Config/Commercial.xcconfig`): "Duo Dash" name and
  icon, SF Symbol tiles, no "CarPlay" wording, `BrandedIcons.xcassets` excluded. See docs/COMMERCIAL.md.
- **Announcements (push):** opt-in Settings → Notifications (hidden unless `DUODASH_NOTIFY_URL` and
  `DUODASH_PUSH = YES`), Cloudflare Worker + D1 in `backend/notifications/`, sent with
  `scripts/notify.sh`. TestFlight = `Config/TestFlight.xcconfig` (`com.duodash.beta`, CarPlay look). See docs/NOTIFICATIONS.md.

## Navigation apps, other apps' tiles, YouTube (2026-11-17)
- **Navigate with** (Settings → Navigation, `nav.app`): Apple Maps (Duo Dash's own guidance, default),
  Google Maps or Waze, selectable once installed (`canOpenURL` on `comgooglemaps://` / `waze://`).
  `NavigationHandoff` (`DuoDash/Maps/ExternalNavigation.swift`) is owned by `NavigationModel`, so every
  path that calls `go(to:via:)` or `start()` (search result Start, saved places, calendar Go, Next Up,
  the assistant's plan_route / start_navigation, resume) hands off. Google Maps gets the stops
  (`comgooglemaps://?saddr=&daddr=A+to:B+to:dest&directionsmode=driving`); Waze only the destination
  (`waze://?ll=…&navigate=yes`), and the preview says the stops weren't passed. Not installed, or iOS
  refuses the scheme → the web links (google.com/maps/dir/?api=1…, waze.com/ul…). Coordinates are
  POSIX-formatted, names percent-encoded. The in-app preview (route, ETA, destination weather) stays,
  with "Open in Google Maps/Waze", "Guide in Duo Dash instead" and the Split View tip.
- **Apps on this iPhone** (Settings → Dock): `ExternalAppCatalog` (`DuoDash/App/ExternalApps.swift`),
  16 apps with URL schemes, all in `LSApplicationQueriesSchemes` (18 of 50 with spotify and
  facetime-audio). Tiles are Duo Dash's own drawing (SF Symbol, brand colour, small ↗), never logos.
  The dock order (`dock.order`) now holds `DockEntry` ids: a screen's raw value or `ext.<id>`. Old
  orders load unchanged; unknown screens and apps dropped; `AppModel.dockOrder` is still the built-in
  screens in order. Added apps hide while uninstalled and come back if reinstalled. The app grid shows
  every installed catalogue app. `-DemoExternalApps` pretends Google Maps, Waze, WhatsApp, YouTube and
  Audible are installed (UI tests, screenshots).
- **YouTube** (`DuoDash/YouTube/`, `screen.youtube`, `duodash://open/youtube`): browser web view on
  m.youtube.com (home, search `results?search_query=`) + player web view with the official IFrame
  Player (`youtube-nocookie.com` host, `playsinline`, origin = https://<bundle id>). A capture-phase tap
  handler (Duo Dash's own script world) sends video links to the player; a URL observer catches the
  rest. Wide windows (≥ 560 pt and wider than tall): video half + browser half, split on the fold;
  otherwise stacked. Only main-frame navigation is checked (YouTube, youtu.be, youtube-nocookie and
  Google sign-in hosts stay; anything else opens in Safari): frames and ads are untouched. Videos the
  embed refuses get "Play on YouTube's site". Playing takes a `.playback`/`.moviePlayback` session
  (music pauses); pausing releases it with `notifyOthersOnDeactivation`. Leaving the screen or the app
  pauses unless picture in picture is on. No speed lock: passenger use only, `Edition.safetyNotice`
  as a dismissible banner once per launch.
- Not verified on device: real Google Maps/Waze hand-off, YouTube playback/PiP/audio ducking with
  Apple Music and Spotify, Google sign-in inside the web view, embed referrer acceptance (YouTube
  error 153 if the origin is rejected).

- **Spotify sign in once (2026-11-17):** Authorization Code with PKCE (`DuoDash/Music/SpotifyAuth.swift`,
  `ASWebAuthenticationSession` → accounts.spotify.com, scope `app-remote-control`, no client secret);
  access + refresh token + expiry in the Keychain (`KeychainSpotifyTokenStore`, after-first-unlock,
  this device only). Before each App Remote connect the token is renewed silently when expired or
  within 5 minutes of it (`SpotifyTokenPlan`); only `invalid_grant` after a tap asks to sign in again
  (on launch it just shows Reconnect). `authorizeAndPlayURI` is kept only to wake Spotify when it isn't
  running. Sign out (Spotify screen) clears the Keychain item. Chose own PKCE over `SPTSessionManager`
  so the verifier/state are ours and testable and the refresh token is stored by us. A bundled client
  ID (`SpotifyConfig.hasBundledClientID`, `-SpotifyBundledClientID YES|NO` for UI tests) skips the
  developer-app walkthrough in the tour.
- **Spotify development mode is permanent (owner, 2026-11-17):** extended quota is only for registered
  businesses with 250k+ MAU, so the shared developer app allows 5 allow-listed Premium accounts.
  Hence `SpotifySignInMode` (`DuoDash/Music/SpotifyAccess.swift`): `sign-in` (PKCE, source builds) or
  `app-remote` (TestFlight/App Store via `DUODASH_SPOTIFY_MODE`; token only from the Spotify app's
  `authorizeAndPlayURI`). A refused PKCE sign-in/refresh (403, `invalid_client`, "not registered")
  falls back to `app-remote` and remembers it; a refused App Remote authorise shows `.limited`
  ("Open Spotify", Try Again), remembered, no automatic retries. Settings → Spotify → "Use My Own
  Spotify Developer App" stores a Client ID in UserDefaults and forces `sign-in`. The Spotify screen
  makes no Web API calls in either mode. Not yet verified: whether App Remote accepts accounts outside
  the allow-list (checklist in docs/SPOTIFY_SETUP.md).

## Duo Dash Pro (2026-11-17)
- **StoreKit 2 in-app purchase.** `com.duodash.pro.monthly` (A$2.99), `com.duodash.pro.yearly`
  (A$19.99, 1-week free trial) in the group "Duo Dash Pro", and the non-consumable
  `com.duodash.pro.lifetime` (A$39.99). `ProStore` (DuoDash/StoreKit) wraps StoreKit behind
  `ProStoreBackend`; `ProGate` holds the gating decisions. Setup and the feature table:
  docs/COMMERCIAL.md → "Duo Dash Pro".
- **Pro adds:** themes (`ThemeSettings`; `Theme.accent` follows it), Home layout
  (`HomeLayoutSettings`: card order + third card; narrow windows keep the map first), alternate
  app icons, dashcam impact detection (CoreMotion, `ImpactDetector`) and 45/60-min loops, trip
  history (`TripDetector` / `TripStore`, Application Support/Trips, recorded only with Pro).
  In the App Store edition the whole Dashcam is Pro; in personal/TestFlight builds it stays free.
- Paywall and trip history are overlays drawn by RootView (not system sheets), so they fit the
  app's window at every size, including the test canvas. Launch arguments: `-ProUnlocked`
  (Pro), `-UITest` alone = demo store, not Pro; `-DemoStore` = demo store outside tests.
