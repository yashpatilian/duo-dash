# Spotify setup for Duo Dash

Duo Dash controls Spotify through the **Spotify iOS SDK (App Remote)**. Playback stays in the Spotify app, so it keeps working in the background and voice directions duck it like Apple Music. You do steps 1 to 5 once; it takes about 10 minutes.

## What you need
- A **Spotify Premium** account. App Remote can only start specific songs or playlists with Premium.
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
New Spotify apps start in *development mode*, which only lets allow-listed users connect.
1. In the app, open **Settings**, then **User Management**.
2. Add your name and the **email address of your Spotify account**. The owner is usually allowed already, but adding it avoids a confusing "user not registered" error.

## 5. Add the Client ID to Duo Dash
1. In **Settings**, then **Basic Information**, copy the **Client ID**. It's a 32-character hex string.
2. Run `scripts/setup.sh --spotify-client-id <your-client-id> --install` (or give it to the agent installing Duo Dash for you).
- You don't need the **Client secret**. The iOS SDK doesn't use it; never put it in the app or share it.
- The Client ID is saved to `Config/Secrets.xcconfig` on your Mac, which is git-ignored.

## 6. Connect
Open Duo Dash on the phone, tap the Spotify icon in the dock, then **Connect**.

## What to expect on first use
- **The first connect opens Spotify briefly** to authorise, then comes back to Duo Dash. Spotify requires this, and it may happen again if Spotify has been closed for a while: App Remote needs the Spotify app to be running.
- If the connection drops (Spotify killed, phone call), Duo Dash shows **Reconnect** rather than failing silently.

## Troubleshooting
| Symptom | Fix |
|---|---|
| "INVALID_CLIENT: Invalid redirect URI" | The Redirect URI in the dashboard must be exactly `duodash://spotify-callback` (no trailing slash). |
| "User not registered in the Developer Dashboard" | Add your Spotify account email under User Management (step 4). |
| Connects but can't play a playlist | The account isn't Premium. |
| Nothing happens on Connect | Make sure the Spotify app is installed and signed in on the phone. |
