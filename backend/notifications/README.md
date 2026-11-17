# Duo Dash announcements server

A Cloudflare Worker with a D1 database that stores APNs device tokens and sends announcements
("a new version is out") to every TestFlight and App Store user who turned **Settings →
Notifications → Announcements** on. No npm dependencies: plain JavaScript and WebCrypto.
The whole setup, including the Apple side, is in [docs/NOTIFICATIONS.md](../../docs/NOTIFICATIONS.md).

| Route | Who calls it | Body |
|---|---|---|
| `POST /register` | the app | `{token, bundleId, environment, appVersion}`; upserts the device |
| `POST /unregister` | the app | `{token}`; deletes the device |
| `POST /broadcast` | you (`scripts/notify.sh`) | `{title, body, bundleId?, url?}` with `Authorization: Bearer <ADMIN_TOKEN>` |

- Tokens must be 64-200 hex characters; `bundleId` must be in `ALLOWED_BUNDLE_IDS`
  (`wrangler.toml`); `environment` is `sandbox` or `production`. Device bodies over 2 KB are
  rejected.
- A broadcast sends to each device's own APNs host (`api.push.apple.com` or
  `api.sandbox.push.apple.com`) with `apns-topic` = its bundle ID, 10 requests at a time, and
  deletes tokens APNs reports as gone (410, `BadDeviceToken`, `Unregistered`,
  `DeviceTokenNotForTopic`). It returns `{total, sent, failed, removed, errors}`.
- `url` must be a `duodash://` link (e.g. `duodash://open/settings`); tapping the notification
  opens it.

## Deploy

You need a Cloudflare account and Node.js. `npx wrangler` downloads Wrangler the first time.

```sh
cd backend/notifications
npx wrangler login
npx wrangler d1 create duodash-notify          # copy the printed database_id into wrangler.toml (don't commit it)
npx wrangler d1 execute duodash-notify --remote --file=schema.sql

# Secrets (prompted for, stored by Cloudflare, never in this repo):
openssl rand -hex 32 | npx wrangler secret put ADMIN_TOKEN   # keep a copy for scripts/notify.sh
npx wrangler secret put APNS_KEY < /path/to/AuthKey_XXXXXXXXXX.p8
npx wrangler secret put APNS_KEY_ID                          # the 10-character key ID
npx wrangler secret put APNS_TEAM_ID                         # your 10-character team ID

npx wrangler deploy                                          # prints https://duodash-notify.<you>.workers.dev
```

To print the admin token for yourself instead of piping it, run `openssl rand -hex 32`, save the
value in your password manager, then `npx wrangler secret put ADMIN_TOKEN` and paste it.

## Send

```sh
export DUODASH_NOTIFY_URL=https://duodash-notify.<you>.workers.dev
export DUODASH_NOTIFY_ADMIN_TOKEN=<the admin token>
scripts/notify.sh "Duo Dash 1.2" "The new version is out, with Spotify playlists."
scripts/notify.sh "Beta 1.3 (40)" "New TestFlight build: please try the dashcam." --bundle com.duodash.beta
scripts/notify.sh "New settings" "Have a look." --url duodash://open/settings
```

Try it first on your own phone with `--bundle com.duodash.beta` and a TestFlight build.

## Limits and notes

- Each APNs request is a Worker subrequest, and plans cap subrequests per request (the Free
  plan's cap has been 50). Check your plan's current limit; a broadcast to more devices than
  that needs the Workers Paid plan.
- APNs needs HTTP/2; the Worker's outbound `fetch` negotiates it with Apple's servers. If sends
  fail with protocol errors, check Cloudflare's current notes on HTTP/2 to origins.
- The provider JWT is reused for 40 minutes per Worker instance (APNs accepts tokens up to an
  hour old and throttles more frequent refreshes).
- The database holds only token, bundle ID, APNs environment, app version and timestamps.

## Test

```sh
cd backend/notifications && node --test     # Node 20+, no packages, no network
```
