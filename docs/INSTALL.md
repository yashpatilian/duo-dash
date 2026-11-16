# Installing Duo Dash

Duo Dash isn't on the App Store. You build it from the source code and install it on your
own iPhone with Xcode, which takes about 15 minutes the first time. Or have an AI agent do
it for you (see the end of this guide).

## What you need
- **A Mac** with **Xcode 27.1 or later** (free from the Mac App Store).
- **An iPhone Duo, or any iPhone or iPad, on iOS 26 or later.** It's designed for the
  foldable **iPhone Duo** (cover screen, unfolded, half-open and Split View) and also works on
  other iPhones and iPads, including iPad Split View and Stage Manager. On an iPad, calls go
  through your iPhone (Settings → FaceTime → Calls from iPhone) or FaceTime audio.
- **An Apple ID signed in to Xcode.**
  - A free Apple ID works, but iOS removes the app after **7 days** and you reinstall it.
  - A paid **Apple Developer Program** membership keeps it for a year.
- **A cable**, or the iPhone and Mac on the same Wi‑Fi.
- Optional:
  - a **Spotify Premium** account, for Spotify control;
  - a **Claude API key**, for the cloud assistant (Apple Intelligence works without one).

## 1. Get the code
```bash
git clone https://github.com/yashpatilian/duo-dash.git duo-dash
cd duo-dash
```
Or download the ZIP from GitHub and unzip it.

## 2. Sign in to Xcode
Open Xcode → **Settings → Accounts** → **+** → **Apple ID**, and sign in. Select your team
and note its **Team ID**: 10 letters and digits, also shown at developer.apple.com →
Membership.

## 3. Set your signing details
```bash
scripts/setup.sh
```
It checks your Xcode version, then asks for:
- your **Team ID**, and
- a **Bundle ID**: anything unique to you, for example `com.yourname.duodash`.

They're saved to `Config/Local.xcconfig`, which stays on your Mac and is never committed.

## 4. Prepare the iPhone
1. Connect it by cable, or put it on the same Wi‑Fi as the Mac. Unlock it and tap **Trust**
   when it asks about this computer.
2. Turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode, then restart
   when asked. If you don't see the option, connect the phone to Xcode once first: open
   `DuoDash.xcodeproj` and choose your iPhone as the run destination.

## 5. Build and install
```bash
scripts/setup.sh --install
```
If you have more than one iPhone connected it asks which one. Or do it from Xcode: open
`DuoDash.xcodeproj`, choose your iPhone at the top, and press **Run** (⌘R).

**Free Apple ID only:** the first time, open Settings → General → **VPN & Device
Management** on the iPhone, then trust your developer certificate.

## 6. First launch
Allow the permissions as each feature first needs them:

| Permission | Used for |
|---|---|
| Location (While Using) | The map and turn-by-turn directions |
| Media & Apple Music | Your library and playback |
| Microphone and Speech Recognition | Voice input and the assistant |
| Contacts | Phone and Messages favourites, and "take me to Sam's" |

## Optional extras

### Refresh the app icons in the dock
The dock uses the official Maps, Music, Phone, Messages, Spotify and Settings icons, which are
included. To re-render them from the apps on your own Mac (for example after a macOS update
redesigns them):
```bash
scripts/setup.sh --icons
```

### Spotify
Follow [SPOTIFY_SETUP.md](SPOTIFY_SETUP.md) to create a free Spotify developer app, then:
```bash
scripts/setup.sh --spotify-client-id <your-client-id> --install
```
You need Spotify Premium and the Spotify app on the phone. The first time you connect,
Spotify opens briefly to authorise.

### Claude for the assistant
- **Default:** the assistant uses **Apple Intelligence**, on the device and free.
- **To use Claude:**
  1. Create an API key at console.anthropic.com.
  2. On the phone, open **Settings → AI Assistant**, choose **Claude**, paste the key and
     tap **Test**.
- The key is stored in the iPhone's Keychain.
- Claude adds live web search, which is how it gets reviews and opening hours.

### Open it automatically in the car
iOS doesn't let apps open themselves when Bluetooth connects, but Shortcuts can:
1. Open the **Shortcuts** app → **Automation** → **+**.
2. Choose **Bluetooth**, pick your car's Bluetooth, select **Is Connected**, and choose
   **Run Immediately**.
3. Add the action **Open Duo Dash**. Optionally choose a screen, for example Maps.

### The app's name and icon
Duo Dash installs on your Home Screen as **CarPlay** with the CarPlay logo. To use the
**Duo Dash** name and icon instead, or your own:
```bash
swift scripts/local-branding.swift --duo-dash
swift scripts/local-branding.swift --icon /path/to/icon.png "My Dash"
swift scripts/local-branding.swift --reset      # back to CarPlay
```
Then reinstall with `scripts/setup.sh --install`. With the CarPlay name, Siri's "Open CarPlay"
may clash with the system's CarPlay; "Open Duo Dash" always works.

## Updating
```bash
git pull
scripts/setup.sh --install
```
Your settings, places, favourites and keys are kept on the phone.

## Troubleshooting
| Problem | Fix |
|---|---|
| "No Account for Team" / "No profiles for …" | Sign in to Xcode (Settings → Accounts) with the Apple ID for that team, and use a bundle ID nobody else uses. |
| "Untrusted Developer" on launch | Settings → General → VPN & Device Management → trust your certificate. |
| `setup.sh` finds no iPhone | Unlock the phone, check the cable/Wi‑Fi, tap Trust, turn on Developer Mode. |
| The app disappeared after a week | That's the free Apple ID limit. Run `scripts/setup.sh --install` again. |
| Spotify won't connect | See the troubleshooting table in [SPOTIFY_SETUP.md](SPOTIFY_SETUP.md). |
| The assistant says Apple Intelligence isn't available | Turn on Apple Intelligence in iOS Settings, let its models finish downloading, or switch to Claude in Duo Dash → Settings. |

## Install it with an AI agent
If you use Claude Code (or another coding agent), you can hand it the repository link:

> Install Duo Dash on my iPhone from https://github.com/yashpatilian/duo-dash

The repository has an [AGENTS.md](../AGENTS.md) the agent follows.
- **The agent does:** checks Xcode, clones the code, writes your signing config, and builds
  and installs the app.
- **You do:** sign in to Xcode, unlock and trust the phone, and turn on Developer Mode.
