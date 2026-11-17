-- Duo Dash mount interest list (Cloudflare D1). Apply with:
--   npx wrangler d1 execute duo-dash-interest --remote --file=web/app/schema.sql
CREATE TABLE IF NOT EXISTS interest (
  email      TEXT PRIMARY KEY,
  region     TEXT NOT NULL,
  source     TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);
