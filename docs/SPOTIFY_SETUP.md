# Spotify setup for Duo Dash

Duo Dash controls Spotify through the **Spotify iOS SDK (App Remote)**. Playback stays in the Spotify app, so it keeps working in the background and voice directions duck it like Apple Music.

## Spotify's limits, first
Every app that uses Spotify's SDK runs on a Spotify developer app. Duo Dash's shared one is in **development mode**, and it will stay there: since May 2025 Spotify only grants *extended quota* to registered businesses with 250,000+ monthly active users. In development mode:
- at most **5 Spotify accounts** (allow-listed by email in the dashboard, the owner included) can use the Web API sign-in;
- **every one of them needs Spotify Premium**, the owner too.

So Duo Dash has two ways to connect:

| Mode | Used by | How it gets access | Stays connected |
|---|---|---|---|
| **Sign in once** | Builds from source; anyone using their own developer app (Settings → Spotify) | Authorization Code with PKCE (no client secret): access + refresh token in the Keychain | Renews silently; you sign in again only if you sign out or revoke access |
| **App Remote only** | TestFlight and App Store builds; any account whose sign-in Spotify refuses | The Spotify app hands over an `app-remote-control` token when it opens for a moment. No Web API, no accounts.spotify.com sign-in | When the token runs out (about an hour), tapping Connect opens Spotify for a moment again, with no questions |

Everything on Duo Dash's Spotify screen (now playing, controls, artwork, your home feed's playlists and albums, every song in them) comes from App Remote talking to the Spotify app on the phone, in both modes. Duo Dash makes no Web API calls, so App Remote only loses nothing on screen; it only can't renew the token silently.

App Remote talks to the local Spotify app, so it **may** work for accounts that aren't allow-listed; that has to be confirmed on a real phone (see the checks at the end). If Spotify refuses an account there too, Duo Dash shows **"Spotify control is limited in this version"** with an **Open Spotify** button (and Try Again), instead of a loop of failed logins. Apple Music is never affected.

Which setup you need:
- **TestFlight and App Store builds** ship with a Spotify Client ID: tap Spotify in the dock, then **Connect Spotify**. The welcome tour has the same button.
- **Building from source, or wanting full control:** make your own Spotify developer app once (steps 1 to 5 below, about 10 minutes). Build with its Client ID, or in any build enter it under **Settings → Spotify → Use My Own Spotify Developer App** (register that build's bundle ID in your app). Your own app has its own 5-account allow-list, so it isn't limited by Duo Dash's. A build without any Client ID shows the walkthrough in the welcome tour.

## What you need
- A **Spotify Premium** account. App Remote can only start specific songs or playlists with Premium, and development mode only lets Premium accounts in.
- The **Spotify app** installed on your iPhone and signed in to that account.

## 1. Open the Spotify developer dashboard
1. Go to <https://developer.spotify.com/dashboard> and log in with the **same Spotify account** you use on the phone.
2. Accept the Developer Terms if asked.

## 2. Create the app
Click **Create app** and fill in:

| Field | Value |
|---|---|
| App name | `Duo Dash` |
| App description | `Personal car dashboard` |
| Website | leave blank |
| **Redirect URI** | `duodash://spotify-callback` (type it exactly, then click **Add**) |
| **Which API/SDKs are you planning to use?** | tick **iOS** and **Web API** |

Tick the terms checkbox and click **Save**.

## 3. Add the iOS bundle ID
1. Open the new app, then **Settings**, then **Edit**.
2. Under **iOS app bundles**, add your app's bundle ID (the one you gave `scripts/setup.sh`, e.g. `com.yourname.duodash`).
3. Check that the Redirect URI shows `duodash://spotify-callback`.
4. Click **Save**.

## 4. Allow your own account (development mode)
Spotify apps run in *development mode*, which only lets allow-listed users connect (up to 5, each with Premium).
1. In the app, open **Settings**, then **User Management**.
2. Add your name and the **email address of your Spotify account**. The owner is usually allowed already, but adding it avoids a confusing "user not registered" error.

## 5. Add the Client ID to Duo Dash
1. In **Settings**, then **Basic Information**, copy the **Client ID**. It's a 32-character hex string.
2. Run `scripts/setup.sh --spotify-client-id <your-client-id> --install` (or give it to the agent installing Duo Dash for you).
- You don't need the **Client secret**. PKCE replaces it for apps like this; never put it in the app or share it.
- The Client ID is saved to `Config/Secrets.xcconfig` on your Mac, which is git-ignored. Never commit it.

## 6. Connect
Open Duo Dash on the phone, tap the Spotify icon in the dock, then **Connect Spotify**.

## What to expect (sign in once)
- **First time only:** a Spotify sign-in sheet opens (iOS first asks whether Duo Dash may use "spotify.com" to sign in). Sign in if asked, then tap **Agree**. If you're already signed in to Spotify in Safari, it's just Agree. Then Spotify opens for a moment to start playing and comes straight back.
- **After that:** Duo Dash reconnects by itself when it opens, renewing the sign-in silently in the background. It never asks you to sign in again unless Spotify stops accepting the saved sign-in.
- **Spotify must be running.** App Remote can't start the Spotify app. If Spotify has been closed (or iOS closed it), tapping **Connect** opens it for a moment, with no questions, and comes back.
- If the connection drops (Spotify killed, phone call), Duo Dash shows **Reconnect** rather than failing silently.
- **Sign out:** the button at the top right of the Spotify screen, **Sign Out** under Reconnect, or Settings → Spotify deletes the saved sign-in from the Keychain. To remove Duo Dash's access completely, also remove it under **Manage apps** at <https://www.spotify.com/account/apps/>.
- **Not allow-listed?** If Spotify refuses the sign-in ("user not registered", HTTP 403, `invalid_client`), Duo Dash switches to App Remote only by itself and opens Spotify for a moment instead. It remembers this, so it doesn't try the sign-in again (using your own developer app in Settings resets it).

## For the TestFlight and App Store builds (owner)
The store builds use the shared Spotify developer app, in development mode for good (see the limits above). Its dashboard has:
1. **iOS app bundles:** `com.duodash.dev`, `com.duodash.beta` (TestFlight) and `com.duodash.app` (App Store).
2. **Redirect URI:** `duodash://spotify-callback`. **APIs used:** iOS and Web API.
3. **User Management:** the owner plus up to 4 testers, each with Spotify Premium. Only they can use the sign-in mode with this app.
4. The Client ID goes in `Config/Secrets.xcconfig` on the Mac that archives (`SPOTIFY_CLIENT_ID = …`, or `scripts/setup.sh --spotify-client-id <id>`). It ends up in the app's Info.plist as `SpotifyClientID`; it's an identifier, not a secret, but it never goes in the repo.
5. `Config/TestFlight.xcconfig` and `Config/Commercial.xcconfig` set `DUODASH_SPOTIFY_MODE = app-remote`, so those builds connect through the Spotify app only. Source builds default to `sign-in`.
6. Don't plan on extended quota: Spotify only grants it to registered businesses with 250,000+ monthly active users. Describe Spotify support in the store listing as "control the Spotify app" and not as guaranteed for every account until the checks below pass.

### Check on a real iPhone with an account that is NOT allow-listed
Use a Spotify Premium account that isn't under User Management, a TestFlight or App Store build, and the Spotify app signed in to that account.
1. Spotify screen → **Connect Spotify**: does Spotify open and come straight back, and does the screen connect (tabs appear)? Or does Spotify show an error / come back with one?
2. If it connects: now playing, play/pause/skip/shuffle/repeat, album art, the Recents and Playlists shelves, opening a playlist or album and playing a song from it.
3. Close Spotify, reopen Duo Dash: does Connect bring it back (Spotify opens for a moment)? After an hour (token expiry): same.
4. If it doesn't connect: the screen must show "Spotify control is limited in this version" with **Open Spotify** working and no repeated sign-in attempts; Settings → Spotify shows "Limited". Note the exact error text Spotify showed, so `SpotifyRefusal` can match it.
5. Apple Music still plays and controls normally throughout.
6. Repeat 1 with an allow-listed account on a source build (sign-in mode): sign-in sheet once, then reconnects after an hour without asking.

## Troubleshooting
| Symptom | Fix |
|---|---|
| "INVALID_CLIENT: Invalid redirect URI" | The Redirect URI in the dashboard must be exactly `duodash://spotify-callback` (no trailing slash). |
| "User not registered in the Developer Dashboard" | Add your Spotify account email under User Management (step 4; at most 5 accounts, each Premium). In store builds Duo Dash falls back to the Spotify app by itself. |
| "Spotify control is limited in this version" | Spotify refused this account for App Remote too. **Open Spotify** still works. To get full control, make your own developer app and enter its Client ID under Settings → Spotify. |
| "Your Spotify sign-in has ended" | The saved sign-in was revoked or expired. Tap **Reconnect** and sign in again. |
| "Couldn't reach Spotify" | No internet when the sign-in needed renewing. Tap **Reconnect** once you're online; you stay signed in. |
| Connects but can't play a playlist | The account isn't Premium. |
| Nothing happens on Connect | Make sure the Spotify app is installed and signed in on the phone. |
