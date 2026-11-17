// Self-contained tests: `node --test test/` (Node 20+, no packages, no network).
import { test } from "node:test";
import assert from "node:assert/strict";

import { handle } from "../src/index.js";
import { importApnsKey, makeProviderToken, mapLimit, payload } from "../src/apns.js";
import { normaliseToken, validateBroadcast, validateRegistration } from "../src/validate.js";

const env0 = { ALLOWED_BUNDLE_IDS: "com.duodash.app, com.duodash.beta", ADMIN_TOKEN: "test-admin-token-0123456789" };
const TOKEN = "ab".repeat(32);

// MARK: validation

test("tokens: 64-200 lowercase hex", () => {
  assert.equal(normaliseToken(TOKEN), TOKEN);
  assert.equal(normaliseToken(TOKEN.toUpperCase()), TOKEN);
  assert.equal(normaliseToken("ab".repeat(31)), null);
  assert.equal(normaliseToken("a".repeat(201)), null);
  assert.equal(normaliseToken("zz".repeat(32)), null);
  assert.equal(normaliseToken(42), null);
});

test("registration: allow-listed bundle IDs and known environments only", () => {
  const ok = { token: TOKEN, bundleId: "com.duodash.beta", environment: "production", appVersion: "1.2" };
  assert.deepEqual(validateRegistration(ok, env0).value, ok);
  assert.ok(validateRegistration({ ...ok, bundleId: "com.example.duodash" }, env0).error);
  assert.ok(validateRegistration({ ...ok, environment: "staging" }, env0).error);
  assert.ok(validateRegistration({ ...ok, token: "nope" }, env0).error);
  assert.ok(validateRegistration({ ...ok, appVersion: "<script>" }, env0).error);
  assert.ok(validateRegistration(ok, {}).error, "nothing allowed when ALLOWED_BUNDLE_IDS is unset");
});

test("broadcast: title and body required, duodash:// links only", () => {
  assert.deepEqual(validateBroadcast({ title: " Hi ", body: "New version" }, env0).value,
    { title: "Hi", body: "New version", bundleId: null, url: null });
  assert.ok(validateBroadcast({ title: "", body: "x" }, env0).error);
  assert.ok(validateBroadcast({ title: "x", body: "" }, env0).error);
  assert.ok(validateBroadcast({ title: "x", body: "y", url: "https://evil.example" }, env0).error);
  assert.ok(validateBroadcast({ title: "x", body: "y", bundleId: "com.other" }, env0).error);
  assert.equal(validateBroadcast({ title: "x", body: "y", url: "duodash://open/settings" }, env0).value.url,
    "duodash://open/settings");
});

// MARK: JWT

test("provider token: ES256 JWT with kid, iss and iat that verifies", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const pem = `-----BEGIN PRIVATE KEY-----\n${pkcs8.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`;
  const key = await importApnsKey(pem);
  const jwt = await makeProviderToken({ key, keyId: "KEYID12345", teamId: "TEAMID1234", now: 1_700_000_000_000 });

  const [h, c, s] = jwt.split(".");
  assert.ok(h && c && s);
  assert.doesNotMatch(jwt, /[+/=]/, "base64url, unpadded");
  const decode = (part) => JSON.parse(Buffer.from(part, "base64url").toString());
  assert.deepEqual(decode(h), { alg: "ES256", kid: "KEYID12345" });
  assert.deepEqual(decode(c), { iss: "TEAMID1234", iat: 1_700_000_000 });
  const signature = Buffer.from(s, "base64url");
  assert.equal(signature.length, 64, "raw r||s, not DER");
  const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, signature,
    new TextEncoder().encode(`${h}.${c}`));
  assert.ok(valid);
});

test("payload carries the alert and the optional link", () => {
  assert.deepEqual(payload({ title: "T", body: "B" }), { aps: { alert: { title: "T", body: "B" }, sound: "default" } });
  assert.equal(payload({ title: "T", body: "B", url: "duodash://open/settings" }).url, "duodash://open/settings");
});

test("mapLimit keeps at most N in flight and keeps order", async () => {
  let inFlight = 0;
  let peak = 0;
  const out = await mapLimit([1, 2, 3, 4, 5, 6, 7], 3, async (n) => {
    peak = Math.max(peak, ++inFlight);
    await new Promise((r) => setTimeout(r, 5));
    inFlight--;
    return n * 2;
  });
  assert.deepEqual(out, [2, 4, 6, 8, 10, 12, 14]);
  assert.equal(peak, 3);
});

// MARK: the worker, with an in-memory D1

function fakeD1() {
  const rows = new Map();
  const statement = (sql, args = []) => ({
    bind: (...a) => statement(sql, a),
    async run() {
      if (sql.startsWith("INSERT")) {
        const [token, bundle_id, environment, app_version] = args;
        rows.set(token, { token, bundle_id, environment, app_version });
      } else if (sql.startsWith("DELETE")) {
        rows.delete(args[0]);
      }
      return { success: true };
    },
    async all() {
      const all = [...rows.values()];
      return { results: args.length ? all.filter((r) => r.bundle_id === args[0]) : all };
    },
  });
  return { rows, prepare: (sql) => statement(sql.trim()), batch: (list) => Promise.all(list.map((s) => s.run())) };
}

const post = (path, body, headers = {}) =>
  new Request(`https://notify.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

test("register, unregister and size limit", async () => {
  const env = { ...env0, DB: fakeD1() };
  const reg = { token: TOKEN, bundleId: "com.duodash.app", environment: "sandbox", appVersion: "1.0" };
  assert.equal((await handle(post("/register", reg), env)).status, 200);
  assert.equal(env.DB.rows.get(TOKEN).environment, "sandbox");
  assert.equal((await handle(post("/register", { ...reg, bundleId: "com.example.x" }), env)).status, 400);
  assert.equal((await handle(post("/register", "x".repeat(3000)), env)).status, 413);
  assert.equal((await handle(post("/register", "{not json"), env)).status, 400);
  assert.equal((await handle(post("/unregister", { token: TOKEN }), env)).status, 200);
  assert.equal(env.DB.rows.size, 0);
  assert.equal((await handle(new Request("https://notify.test/register"), env)).status, 404);
});

test("broadcast needs the admin token, sends per device and drops dead tokens", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const env = {
    ...env0, DB: fakeD1(),
    APNS_KEY: `-----BEGIN PRIVATE KEY-----\n${pkcs8}\n-----END PRIVATE KEY-----`, APNS_KEY_ID: "K", APNS_TEAM_ID: "T",
  };
  const live = "11".repeat(32), gone = "22".repeat(32), bad = "33".repeat(32), beta = "44".repeat(32);
  for (const [token, bundleId, environment] of [[live, "com.duodash.app", "production"], [gone, "com.duodash.app", "production"],
    [bad, "com.duodash.app", "sandbox"], [beta, "com.duodash.beta", "production"]]) {
    await handle(post("/register", { token, bundleId, environment, appVersion: "1" }), env);
  }

  const calls = [];
  const fakeFetch = async (url, init) => {
    calls.push({ url, init });
    if (url.endsWith(gone)) return new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
    if (url.endsWith(bad)) return new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 });
    return new Response(null, { status: 200 });
  };

  const message = { title: "New version", body: "1.1 is out", url: "duodash://open/settings" };
  assert.equal((await handle(post("/broadcast", message), env, fakeFetch)).status, 401);
  assert.equal((await handle(post("/broadcast", message, { authorization: "Bearer wrong" }), env, fakeFetch)).status, 401);

  const auth = { authorization: `Bearer ${env0.ADMIN_TOKEN}` };
  const res = await handle(post("/broadcast", { ...message, bundleId: "com.duodash.app" }, auth), env, fakeFetch);
  assert.equal(res.status, 200);
  const counts = await res.json();
  assert.equal(counts.total, 3);
  assert.equal(counts.sent, 1);
  assert.equal(counts.failed, 2);
  assert.equal(counts.removed, 2);
  assert.deepEqual([...env.DB.rows.keys()].sort(), [live, beta].sort());

  const first = calls.find((c) => c.url.endsWith(live));
  assert.equal(first.url, `https://api.push.apple.com/3/device/${live}`);
  assert.equal(first.init.headers["apns-topic"], "com.duodash.app");
  assert.equal(first.init.headers["apns-push-type"], "alert");
  assert.match(first.init.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.equal(JSON.parse(first.init.body).url, "duodash://open/settings");
  assert.ok(calls.find((c) => c.url.endsWith(bad)).url.startsWith("https://api.sandbox.push.apple.com/"));
  assert.ok(!calls.some((c) => c.url.endsWith(beta)), "bundle filter");
});
