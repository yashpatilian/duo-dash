# Announcements (push notifications)

Duo Dash can show short announcements from the developer, like "Duo Dash 1.2 is out", to people
using the **TestFlight build** (`com.duodash.beta`) and the **App Store build**
(`com.duodash.app`). It's opt-in: users turn it on in **Settings → Notifications →
Announcements**, and only then does iOS ask for notification permission.

The feature is inert unless a build is set up for it: with the defaults in `Config/Base.xcconfig`
(`DUODASH_NOTIFY_URL` empty, `DUODASH_PUSH = NO`) the Settings page is hidden, nothing asks for
permission, and nothing is sent anywhere. Personal builds from source stay like that.

## How it works

- **App** (`DuoDash/Notifications/`): when the user turns Announcements on, it asks for
  permission, registers with APNs, and sends `POST <server>/register` with
  `{token, bundleId, environment, appVersion}`. `environment` is `production` for TestFlight and
  App Store builds and `sandbox` for builds run from Xcode. A failed upload is retried on the
  next launch. Turning it off sends `POST <server>/unregister {token}`. Announcements show as
  banners even while the app is open; one with a `duodash://` link opens that screen when tapped.
- **Server** (`backend/notifications/`): a Cloudflare Worker with a D1 table of devices. You send
  with `scripts/notify.sh`, which calls `POST /broadcast` with an admin token; the worker signs an
  APNs provider token (ES256) and sends to each device, removing tokens Apple reports as gone.
  Details in [backend/notifications/README.md](../backend/notifications/README.md).

## What the owner does to switch it on

1. **Apple Developer account**
   - Certificates, Identifiers & Profiles → **Identifiers**: open the App IDs `com.duodash.app`
     and `com.duodash.beta` (create them if needed) and tick **Push Notifications**. Save.
     Regenerate or refresh their provisioning profiles (automatic signing does this for you).
   - **Keys** → **+** → name it (e.g. "Duo Dash APNs"), tick **Apple Push Notifications service
     (APNs)**, continue, register, and **download the .p8 file** (you can only download it once).
     Note the **Key ID** shown with it and your **Team ID** (top right, or Membership).
     One key works for both apps and both environments. Keep the .p8 in a password manager,
     never in the repo.
2. **Deploy the worker** (once): follow "Deploy" in
   [backend/notifications/README.md](../backend/notifications/README.md): create the D1 database,
   apply `schema.sql`, set the secrets `ADMIN_TOKEN`, `APNS_KEY` (the .p8 contents),
   `APNS_KEY_ID`, `APNS_TEAM_ID`, and `wrangler deploy`. Note the worker URL it prints.
3. **Release build settings**: create the git-ignored `Config/Release.xcconfig` (included by
   `Config/Commercial.xcconfig` and `Config/TestFlight.xcconfig`):
   ```
   DUODASH_PUSH = YES
   DUODASH_NOTIFY_URL = duodash-notify.<you>.workers.dev
   ```
   Give the host only: `//` starts a comment in xcconfig files, and the app adds `https://`.
   `DUODASH_PUSH = YES` adds the `aps-environment` entitlement (`Config/DuoDash-Push.entitlements`,
   or `DuoDash-HomeKit-Push.entitlements` with `DUODASH_HOMEKIT = YES`). It says `development`;
   Xcode switches it to `production` when you archive and export for TestFlight / App Store.
4. **Build and upload** as usual:
   - App Store: `-xcconfig Config/Commercial.xcconfig` (bundle ID `com.duodash.app`)
   - TestFlight: `-xcconfig Config/TestFlight.xcconfig` (bundle ID `com.duodash.beta`, the CarPlay look)
5. **Test**: install the TestFlight build, turn on Settings → Notifications → Announcements,
   then from the Mac:
   ```sh
   export DUODASH_NOTIFY_URL=https://duodash-notify.<you>.workers.dev
   export DUODASH_NOTIFY_ADMIN_TOKEN=<the admin token>
   scripts/notify.sh "Test" "Hello from the developer" --bundle com.duodash.beta
   ```
   The reply shows `{total, sent, failed, removed, errors}`.

To send for real: `scripts/notify.sh "Duo Dash 1.2" "The new version is out." [--bundle com.duodash.app] [--url duodash://open/settings]`.

## Privacy

- Off by default. Nothing is requested or sent until the user turns Announcements on.
- What's stored on the server: the APNs device token (a random identifier Apple issues per app
  install, useless to anyone without the APNs key), the bundle ID, the APNs environment, the app
  version and when it was registered. No name, Apple ID, location, usage or device identifiers.
- Turning Announcements off deletes the row (retried at launch if offline). Uninstalling the
  app makes Apple report the token as gone, and the next broadcast deletes it.
- Cloudflare sees the requests' IP addresses like any web host; the worker doesn't log or store
  them.
- For the App Store privacy label, check Apple's current guidance on push tokens; nothing is
  linked to the user's identity or used for tracking.
- Secrets (`ADMIN_TOKEN`, the .p8 key, key ID, team ID) live only in Cloudflare's secret store
  and your password manager. The worker URL lives in the git-ignored `Config/Release.xcconfig`.
