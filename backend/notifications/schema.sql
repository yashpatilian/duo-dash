-- Duo Dash announcements: one row per device that turned Announcements on.
-- Apply with: npx wrangler d1 execute duodash-notify --remote --file=schema.sql
CREATE TABLE IF NOT EXISTS devices (
  token       TEXT PRIMARY KEY,          -- APNs device token, lowercase hex
  bundle_id   TEXT NOT NULL,             -- com.duodash.app (App Store) or com.duodash.beta (TestFlight)
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  app_version TEXT NOT NULL DEFAULT '',
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_bundle_id ON devices (bundle_id);
