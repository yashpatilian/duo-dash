# Duo Dash

**A CarPlay-style dashboard for your iPhone, built for the foldable iPhone Duo.**

Unfold an iPhone Duo on a dash mount and it becomes a head unit: maps with turn-by-turn,
Apple Music and Spotify, calls and texts, and a voice assistant that plans your trip. It
follows the CarPlay layout, in one app with nothing to hand off.

[![Watch the demo](docs/media/demo-poster.jpg)](docs/media/duo-dash-demo.mp4)

*▶ [Watch the demo video](docs/media/duo-dash-demo.mp4)*

<p>
  <img src="docs/media/home-unfolded.jpg" width="49%" alt="Home dashboard, unfolded">
  <img src="docs/media/music-player.jpg" width="49%" alt="Apple Music-style player">
</p>
<p>
  <img src="docs/media/maps-route.jpg" width="49%" alt="Maps with a route and a stop on the way">
  <img src="docs/media/phone.jpg" width="49%" alt="Phone favourites">
</p>
<p>
  <img src="docs/media/assistant.jpg" width="49%" alt="Voice assistant">
  <img src="docs/media/folded.jpg" width="23%" alt="Folded, cover screen">
  <img src="docs/media/settings.jpg" width="25%" alt="Settings">
</p>

## Features

**The dashboard**
- The CarPlay layout: on a wide screen, a full-height dock on the right with the clock on
  top and a dashboard button at the bottom. On a tall or narrow screen, a bottom bar.
- The dock scrolls instead of shrinking icons. Press and hold an icon to drag it into a new
  order, and the order is remembered.
- Home dashboard:
  - a live map;
  - what's playing;
  - **Where to?** with your saved places;
  - favourite contacts;
  - the assistant.
- On the iPhone Duo, the dashboard's split lines up with the fold when the phone is half
  open.
- It works in every posture: unfolded landscape or portrait, folded on the cover screen,
  half open, and in Split View beside another app.

**Maps**
- Search by typing or by voice.
- **Saved places**: as many as you like, each with your own name and a greyscale emoji.
- Turn-by-turn directions with a turn banner and rerouting. Spoken directions lower your
  music, are off by default, and your choice is remembered.
- **Trips with stops**, and if the app is killed mid-trip it resumes where you were.
- **Heading up** or **north up** when you're just looking around.
- **Copied addresses**: copy one from Messages or Messenger and Maps offers to take you
  there, with no paste prompt.

**Voice assistant**
- Ask out loud:
  - "find somewhere for dinner";
  - "take me to Sam's house";
  - "take me to the airport but stop for petrol on the way".
- It searches Apple Maps, looks up addresses in your contacts, and picks the stop that adds
  the least time. Then it starts navigating.
- It runs on **Apple Intelligence**, on the device and free, or **Claude** with your own API
  key. Claude adds live web search for reviews and opening hours.

**Music**
- **Apple Music**:
  - recents, playlists and albums with **every song listed**; tap any song to play the
    list from there;
  - search by voice;
  - a full-screen player in the style of Apple Music, with blurred album art behind it and
    Liquid Glass controls.
- **Spotify** (Premium): connect, now playing, controls, your playlists and recently
  played.
- One now-playing bar and Home widget control whichever source is playing.

**Phone & Messages**
- Favourites picked from your contacts, one-tap calling, contact search and a keypad.
- Write texts by voice, or use quick replies, including **"On my way, ETA 5:42"** while
  you're navigating.

**And**
- A mic button on every text field, for voice input.
- **Settings** for the AI provider and key, voice, the map, places, the dock order, recents
  and auto-open.
- A Shortcuts action, **Open Duo Dash**, so the app can open when your car's Bluetooth
  connects.
- Everything you change is saved.

## Install

Duo Dash is installed from source with your own Apple ID, using Xcode 27.1 or later and an
iPhone on iOS 26 or later.

```bash
git clone https://github.com/yashpatilian/duo-dash.git duo-dash && cd duo-dash
scripts/setup.sh            # asks for your Apple Team ID and a bundle ID
scripts/setup.sh --install  # builds and installs on your connected iPhone
```

The **full step-by-step guide** is [docs/INSTALL.md](docs/INSTALL.md). It covers Developer
Mode, free and paid Apple IDs, and the optional extras: Spotify, Claude,
auto-open in the car, and the app's Home Screen name and icon (CarPlay by default, or Duo Dash).

### Let an AI agent install it
Give this repository's link to Claude Code (or another coding agent):

> Install Duo Dash on my iPhone from https://github.com/yashpatilian/duo-dash

It follows [AGENTS.md](AGENTS.md): it checks Xcode, sets up your signing, and builds and
installs the app. It asks you for the few things only you can do, like signing in to Xcode,
trusting the phone and turning on Developer Mode.

## What iOS doesn't allow (and what Duo Dash does instead)

| You might expect | iOS limit | Duo Dash |
|---|---|---|
| Your call history and Phone favourites | Apps can't read them | Favourites you pick from Contacts; recents of calls made from Duo Dash |
| Reading your texts | Apps can't read Messages or Messenger | Detects an address you **copy**, and offers to navigate there |
| Sending a text silently | Apps must show Apple's compose sheet | Compose by voice; you tap Send |
| Opening when the car connects | Apps can't launch themselves | A Shortcuts automation with the **Open Duo Dash** action |
| Apple Maps reviews | Not available to apps | Claude mode searches the web for reviews; Apple's place card shows ratings |
| Real CarPlay | An iPhone can't project CarPlay to itself | Its own CarPlay-style interface |

## Privacy
- Everything stays on your iPhone: places, contacts, settings and history.
- **Apple Intelligence** runs on the device.
- **Claude** is used only if you choose it and add your own key. Then what you ask, your
  approximate location, your route, and any contact you name are sent to Anthropic to answer.
- Your Claude key and Spotify token are kept in the iPhone's Keychain.
- No analytics, no tracking, no accounts.

## How it's built
- SwiftUI with Observation, Swift 5 mode, iOS 26+ (Liquid Glass). Built with Xcode 27.1+ for
  the iPhone Duo's fold and hinge APIs.
- **Maps:** MapKit, routing with `MKDirections`, and its own progress tracker: distance
  along the route, off-route detection, and multi-leg trips.
- **Music:**
  - Apple Music through the system Music player, so voice prompts duck it cleanly.
  - Spotify through the Spotify iOS SDK (App Remote).
- **Assistant:** one set of tools (search places, contact address, plan route, add stop,
  start navigation) behind two brains: Apple's Foundation Models, and the Claude Messages
  API.
- **Tests:** about 100 unit tests, plus UI tests covering every window size and orientation,
  each screen, and relaunch and persistence.

```
DuoDash/
  App/         app entry, dock state, Shortcuts action
  UI/          shell, dock, theme, components, dictation
  Home/        the dashboard
  Maps/        navigation engine, map, search, copied addresses
  Places/      saved places
  Assistant/   voice assistant (Apple Intelligence + Claude)
  Music/       Apple Music, Spotify, player
  NowPlaying/  shared now-playing state and bar
  Contacts/ Phone/ Messages/
  Settings/
```

## Roadmap
More is on the way: day and night themes, a dock-side option, more assistant actions, and
widgets for the dashboard. Ideas and bug reports are welcome in Issues.

## Licence and disclaimer
- **Licence:** Duo Dash is **source-available for personal use only**. You may read the
  code, and build and modify it for yourself. You may not redistribute it, publish modified
  versions, or ship it on the App Store. See [LICENSE](LICENSE).
- **Not affiliated:** Duo Dash isn't affiliated with, endorsed by or sponsored by Apple,
  Spotify or Anthropic. CarPlay, Apple Music and iPhone are trademarks of Apple Inc.;
  Spotify is a trademark of Spotify AB; Claude is a trademark of Anthropic. The app is
  labelled "CarPlay" on the Home Screen and uses the official app icons; they belong to their
  owners and are used for identification only.
- **Safety:** this isn't certified automotive software. Set things up before you drive,
  keep your eyes on the road, and follow your local laws on phone use and mounts.
