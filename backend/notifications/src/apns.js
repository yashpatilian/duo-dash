// Apple Push Notification service: the provider JWT (ES256, signed with WebCrypto) and
// one HTTP/2 request per device. No dependencies; runs in Workers and in Node 20+.

export const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

const encoder = new TextEncoder();

export function base64url(bytes) {
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const b of data) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlJson(value) {
  return base64url(encoder.encode(JSON.stringify(value)));
}

/** Imports the APNs auth key (.p8 file contents, PKCS#8 PEM) for ES256 signing. */
export async function importApnsKey(pem) {
  const b64 = String(pem)
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\\n/g, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/**
 * The provider authentication token: header {alg: ES256, kid}, claims {iss: team ID, iat}.
 * WebCrypto's ECDSA signature is already the raw r||s form JWS wants.
 */
export async function makeProviderToken({ key, keyId, teamId, now = Date.now() }) {
  const header = base64urlJson({ alg: "ES256", kid: keyId });
  const claims = base64urlJson({ iss: teamId, iat: Math.floor(now / 1000) });
  const input = `${header}.${claims}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(input));
  return `${input}.${base64url(signature)}`;
}

// APNs rejects tokens older than an hour and throttles ones refreshed more often than every
// 20 minutes, so one is reused for 40 minutes within a worker instance.
let cached = null;

export async function providerToken(env, now = Date.now()) {
  if (cached && cached.keyId === env.APNS_KEY_ID && now - cached.issuedAt < 40 * 60 * 1000) return cached.jwt;
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
    throw new Error("APNS_KEY, APNS_KEY_ID and APNS_TEAM_ID secrets must be set");
  }
  const key = await importApnsKey(env.APNS_KEY);
  const jwt = await makeProviderToken({ key, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, now });
  cached = { jwt, keyId: env.APNS_KEY_ID, issuedAt: now };
  return jwt;
}

/** The notification payload: an alert, plus the optional duodash:// link the app opens on tap. */
export function payload({ title, body, url }) {
  const message = { aps: { alert: { title, body }, sound: "default" } };
  if (url) message.url = url;
  return message;
}

/** Reasons that mean the token will never work again: forget the device. */
const DEAD = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]);

/**
 * Sends one notification. Returns {ok, status, reason, dead}.
 * `dead` is true for 410 and for reasons that mean the token is gone for good.
 */
export async function sendOne({ device, jwt, message, fetchImpl = fetch }) {
  const host = APNS_HOSTS[device.environment] ?? APNS_HOSTS.production;
  let response;
  try {
    response = await fetchImpl(`${host}/3/device/${device.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": device.bundle_id,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor(Date.now() / 1000) + 7 * 24 * 3600),
        "content-type": "application/json",
      },
      body: JSON.stringify(message),
    });
  } catch (error) {
    return { ok: false, status: 0, reason: String(error?.message ?? error), dead: false };
  }
  if (response.status === 200) return { ok: true, status: 200, reason: null, dead: false };
  let reason = null;
  try {
    reason = (await response.json())?.reason ?? null;
  } catch {
    // no JSON body
  }
  return { ok: false, status: response.status, reason, dead: response.status === 410 || DEAD.has(reason) };
}

/** Runs `worker` over `items` with at most `limit` in flight. */
export async function mapLimit(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  async function lane() {
    while (next < items.length) {
      const index = next++;
      results[index] = await worker(items[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, lane));
  return results;
}
