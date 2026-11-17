// Request validation for the announcements worker. Pure functions, no Cloudflare APIs,
// so `node --test` can check them directly.

/** Largest JSON body accepted by /register and /unregister. */
export const MAX_DEVICE_BODY = 2048;
/** Largest JSON body accepted by /broadcast. */
export const MAX_BROADCAST_BODY = 8192;

const TOKEN = /^[0-9a-f]{64,200}$/;
const BUNDLE_ID = /^[A-Za-z0-9.-]{1,155}$/;
const VERSION = /^[0-9A-Za-z .()_-]{1,32}$/;
const ENVIRONMENTS = new Set(["sandbox", "production"]);

/** The bundle IDs this server sends to, from the ALLOWED_BUNDLE_IDS var ("a,b"). */
export function allowedBundleIds(env) {
  return new Set(
    String(env?.ALLOWED_BUNDLE_IDS ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  );
}

/** Normalises a device token: lowercase hex, 64-200 characters. Returns null if invalid. */
export function normaliseToken(value) {
  if (typeof value !== "string") return null;
  const token = value.trim().toLowerCase();
  return TOKEN.test(token) ? token : null;
}

/** Reads a JSON object body no larger than `limit` bytes. Returns {value} or {error, status}. */
export async function readJson(request, limit) {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > limit) return { error: "body too large", status: 413 };
  const text = await request.text();
  if (new TextEncoder().encode(text).length > limit) return { error: "body too large", status: 413 };
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return { error: "invalid JSON", status: 400 };
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return { error: "expected a JSON object", status: 400 };
  }
  return { value };
}

/** Validates POST /register. Returns {value: {token, bundleId, environment, appVersion}} or {error}. */
export function validateRegistration(body, env) {
  const token = normaliseToken(body.token);
  if (!token) return { error: "token must be 64-200 hex characters" };
  const bundleId = body.bundleId;
  if (typeof bundleId !== "string" || !BUNDLE_ID.test(bundleId) || !allowedBundleIds(env).has(bundleId)) {
    return { error: "bundleId not allowed" };
  }
  if (!ENVIRONMENTS.has(body.environment)) return { error: "environment must be sandbox or production" };
  const appVersion = body.appVersion ?? "";
  if (typeof appVersion !== "string" || (appVersion !== "" && !VERSION.test(appVersion))) {
    return { error: "invalid appVersion" };
  }
  return { value: { token, bundleId, environment: body.environment, appVersion } };
}

/** Validates POST /unregister. */
export function validateUnregister(body) {
  const token = normaliseToken(body.token);
  return token ? { value: { token } } : { error: "token must be 64-200 hex characters" };
}

/** Validates POST /broadcast: {title, body, bundleId?, url?}. */
export function validateBroadcast(body, env) {
  const title = typeof body.title === "string" ? body.title.trim() : "";
  const text = typeof body.body === "string" ? body.body.trim() : "";
  if (!title || title.length > 200) return { error: "title is required (at most 200 characters)" };
  if (!text || text.length > 2000) return { error: "body is required (at most 2000 characters)" };
  let bundleId = null;
  if (body.bundleId !== undefined && body.bundleId !== null && body.bundleId !== "") {
    if (typeof body.bundleId !== "string" || !allowedBundleIds(env).has(body.bundleId)) {
      return { error: "bundleId not allowed" };
    }
    bundleId = body.bundleId;
  }
  let url = null;
  if (body.url !== undefined && body.url !== null && body.url !== "") {
    if (typeof body.url !== "string" || !body.url.startsWith("duodash://") || body.url.length > 512) {
      return { error: "url must be a duodash:// link" };
    }
    url = body.url;
  }
  return { value: { title, body: text, bundleId, url } };
}

/** Constant-time comparison of the Authorization header with `Bearer <ADMIN_TOKEN>`. */
export function isAuthorised(request, env) {
  const secret = env?.ADMIN_TOKEN;
  if (typeof secret !== "string" || secret.length < 16) return false; // not configured: nobody
  const given = new TextEncoder().encode(request.headers.get("authorization") ?? "");
  const expected = new TextEncoder().encode(`Bearer ${secret}`);
  let diff = given.length ^ expected.length;
  for (let i = 0; i < expected.length; i++) diff |= (given[i] ?? 0) ^ expected[i];
  return diff === 0;
}
