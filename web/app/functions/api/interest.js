// Cloudflare Pages Function: the "Register your interest" form.
//   POST /api/interest  {email, region, source, website}  -> stores the email (once) in D1.
//   GET  /api/interest  with "Authorization: Bearer <INTEREST_ADMIN_TOKEN>" -> CSV export.
// Bindings (Pages project → Settings → Functions): D1 database as INTEREST_DB, and the
// secret INTEREST_ADMIN_TOKEN (a long random string). Schema: web/app/schema.sql.

// Starts with a letter or digit (no "=", "+", "-", "@" that a spreadsheet could run as a formula).
const EMAIL_RE = /^[A-Za-z0-9][^\s@"'<>,;]{0,63}@[A-Za-z0-9][A-Za-z0-9.-]{0,189}\.[A-Za-z]{2,24}$/;
const json = (status, body) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

export async function onRequestPost({ request, env }) {
  // Same-site form only (blocks other sites posting into the list).
  const origin = request.headers.get("Origin");
  if (origin) {
    let host = null;
    try { host = new URL(origin).host; } catch { /* "null" or junk */ }
    if (host !== new URL(request.url).host) return json(403, { error: "forbidden" });
  }
  // Read the body ourselves so a chunked upload can't dodge the size limit.
  const raw = await request.text();
  if (raw.length > 2048) return json(413, { error: "too large" });

  let data;
  try {
    const type = request.headers.get("Content-Type") || "";
    data = type.includes("application/json") ? JSON.parse(raw) : Object.fromEntries(new URLSearchParams(raw));
  } catch {
    return json(400, { error: "bad request" });
  }
  if (!data || typeof data !== "object") return json(400, { error: "bad request" });
  // Honeypot: real people never fill this in. Pretend it worked.
  if (data.website) return json(200, { ok: true });

  const email = String(data.email || "").trim().toLowerCase();
  if (email.length > 254 || !EMAIL_RE.test(email)) return json(400, { error: "invalid email" });
  const region = data.region === "AU" ? "AU" : "OTHER";
  const source = String(data.source || "").replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 120);

  if (!env.INTEREST_DB) return json(503, { error: "not configured" });
  await env.INTEREST_DB
    .prepare("INSERT INTO interest (email, region, source, created_at) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(email) DO NOTHING")
    .bind(email, region, source, new Date().toISOString())
    .run();
  // A plain form post (no JavaScript) gets sent back to the thank-you anchor.
  if (!(request.headers.get("Content-Type") || "").includes("application/json")) {
    return Response.redirect(new URL("/mount/?registered=1#register", request.url).toString(), 303);
  }
  return json(200, { ok: true });
}

export async function onRequestGet({ request, env }) {
  const token = env.INTEREST_ADMIN_TOKEN;
  const auth = request.headers.get("Authorization") || "";
  if (!token || token.length < 24 || !timingSafeEqual(auth, `Bearer ${token}`)) return json(401, { error: "unauthorized" });
  const { results } = await env.INTEREST_DB.prepare("SELECT email, region, source, created_at FROM interest ORDER BY created_at").all();
  // Quote every cell, and defuse anything a spreadsheet would treat as a formula.
  const esc = (v) => {
    let t = String(v ?? "");
    if (/^[=+\-@\t\r]/.test(t)) t = "'" + t;
    return `"${t.replace(/"/g, '""')}"`;
  };
  const csv = ["email,region,source,created_at", ...results.map((r) => [r.email, r.region, r.source, r.created_at].map(esc).join(","))].join("\n");
  return new Response(csv, { headers: { "Content-Type": "text/csv", "Cache-Control": "no-store" } });
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
