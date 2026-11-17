// Duo Dash announcements: a Cloudflare Worker with a D1 table of device tokens.
//
//   POST /register    {token, bundleId, environment, appVersion}   (from the app)
//   POST /unregister  {token}                                       (from the app)
//   POST /broadcast   {title, body, bundleId?, url?}                (Authorization: Bearer ADMIN_TOKEN)
//
// See README.md for deploying and docs/NOTIFICATIONS.md for the whole setup.

import {
  MAX_BROADCAST_BODY,
  MAX_DEVICE_BODY,
  isAuthorised,
  readJson,
  validateBroadcast,
  validateRegistration,
  validateUnregister,
} from "./validate.js";
import { mapLimit, payload, providerToken, sendOne } from "./apns.js";

/** Requests to APNs in flight at once during a broadcast. */
const CONCURRENCY = 10;

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

async function register(request, env) {
  const body = await readJson(request, MAX_DEVICE_BODY);
  if (body.error) return json({ error: body.error }, body.status);
  const checked = validateRegistration(body.value, env);
  if (checked.error) return json({ error: checked.error }, 400);
  const { token, bundleId, environment, appVersion } = checked.value;
  const now = new Date().toISOString();
  await env.DB.prepare(
    `INSERT INTO devices (token, bundle_id, environment, app_version, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?5)
     ON CONFLICT(token) DO UPDATE SET bundle_id = excluded.bundle_id, environment = excluded.environment,
       app_version = excluded.app_version, updated_at = excluded.updated_at`,
  )
    .bind(token, bundleId, environment, appVersion, now)
    .run();
  return json({ ok: true });
}

async function unregister(request, env) {
  const body = await readJson(request, MAX_DEVICE_BODY);
  if (body.error) return json({ error: body.error }, body.status);
  const checked = validateUnregister(body.value);
  if (checked.error) return json({ error: checked.error }, 400);
  await env.DB.prepare("DELETE FROM devices WHERE token = ?1").bind(checked.value.token).run();
  return json({ ok: true });
}

async function broadcast(request, env, fetchImpl) {
  if (!isAuthorised(request, env)) return json({ error: "unauthorised" }, 401);
  const body = await readJson(request, MAX_BROADCAST_BODY);
  if (body.error) return json({ error: body.error }, body.status);
  const checked = validateBroadcast(body.value, env);
  if (checked.error) return json({ error: checked.error }, 400);
  const { title, body: text, bundleId, url } = checked.value;

  const query = bundleId
    ? env.DB.prepare("SELECT token, bundle_id, environment FROM devices WHERE bundle_id = ?1").bind(bundleId)
    : env.DB.prepare("SELECT token, bundle_id, environment FROM devices");
  const devices = (await query.all()).results ?? [];
  if (devices.length === 0) return json({ total: 0, sent: 0, failed: 0, removed: 0 });

  let jwt;
  try {
    jwt = await providerToken(env);
  } catch (error) {
    return json({ error: String(error?.message ?? error) }, 500);
  }
  const message = payload({ title, body: text, url });
  const results = await mapLimit(devices, CONCURRENCY, (device) => sendOne({ device, jwt, message, fetchImpl }));

  const dead = devices.filter((_, i) => results[i].dead).map((d) => d.token);
  if (dead.length > 0) {
    const remove = env.DB.prepare("DELETE FROM devices WHERE token = ?1");
    await env.DB.batch(dead.map((token) => remove.bind(token)));
  }
  const errors = {};
  for (const r of results) {
    if (!r.ok) {
      const key = r.reason ?? `HTTP ${r.status}`;
      errors[key] = (errors[key] ?? 0) + 1;
    }
  }
  const sent = results.filter((r) => r.ok).length;
  return json({ total: devices.length, sent, failed: devices.length - sent, removed: dead.length, errors });
}

/** The request handler. `fetchImpl` is replaceable for tests. */
export async function handle(request, env, fetchImpl = fetch) {
  const { pathname } = new URL(request.url);
  if (request.method !== "POST") return json({ error: "not found" }, 404);
  try {
    switch (pathname) {
      case "/register":
        return await register(request, env);
      case "/unregister":
        return await unregister(request, env);
      case "/broadcast":
        return await broadcast(request, env, fetchImpl);
      default:
        return json({ error: "not found" }, 404);
    }
  } catch (error) {
    console.error(error);
    return json({ error: "server error" }, 500);
  }
}

export default {
  fetch(request, env) {
    return handle(request, env);
  },
};
