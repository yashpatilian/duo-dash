# duodash.app

The Duo Dash website: the app's landing page (`/`) and the Duo Dash mount page (`/mount/`)
with its **Register your interest** form. It is the only website for Duo Dash; nothing should
link anywhere else for the mount.

Plain static files, no build step, no frameworks, no CDNs, no web fonts (system font stack),
no trackers and no cookies. The only server code is the form endpoint, a Cloudflare Pages
Function.

```
web/app/
  index.html            landing page
  mount/index.html      mount page (served at /mount/)
  404.html              not-found page
  styles.css, app.js    shared by every page
  assets/               images (WebP), film (MP4), icons, Open Graph images
  functions/api/interest.js   POST /api/interest (store an email), GET (CSV export)
  schema.sql            D1 table for the interest list
  _headers              security headers + CSP for Cloudflare Pages
  vercel.json           the same headers for Vercel
  robots.txt, sitemap.xml
```

## Try it locally

```bash
cd web/app && python3 -m http.server 8765
# open http://localhost:8765/ and http://localhost:8765/mount/
```

The form needs the Pages Function, so locally it shows "That didn't go through" unless you
run `npx wrangler pages dev .` from `web/app` instead (with a local D1, see below).

## Deploy on Cloudflare Pages (recommended)

You need a Cloudflare account and Node (for `npx wrangler`). Run these from `web/app`, so
Wrangler finds the `functions/` folder next to the site.

1. **Create the database and its table** (once):
   ```bash
   cd web/app
   npx wrangler d1 create duo-dash-interest
   npx wrangler d1 execute duo-dash-interest --remote --file=schema.sql
   ```
2. **Create the Pages project and upload the site** (the first run creates the project):
   ```bash
   npx wrangler pages deploy . --project-name duodash
   ```
   Or connect the GitHub repo in the dashboard (Workers & Pages → Create → Pages → Connect
   to Git) with **root directory `web/app`**, no build command, and output directory `.`.
3. **Bind the database and add the admin secret.** Dashboard → Workers & Pages → `duodash`
   → Settings:
   - **Bindings → Add → D1 database:** variable name `INTEREST_DB`, database
     `duo-dash-interest`.
   - **Variables and Secrets → Add → Secret:** `INTEREST_ADMIN_TOKEN`, a long random string
     (`openssl rand -hex 32`). Keep it in your password manager.
   - Redeploy (step 2 again) so the binding and secret apply.
4. **Custom domain: the apex `duodash.app`.** Pages project → Custom domains → Set up a
   custom domain → `duodash.app`.
   - Easiest: move the domain's DNS to Cloudflare (Add a site → change the nameservers at
     your registrar). Cloudflare then creates the apex record for you (CNAME flattening).
   - Also add `www.duodash.app` as a custom domain and a redirect rule (Rules → Redirect
     Rules) from `www.duodash.app/*` to `https://duodash.app/${1}`, status 301.
   - `.app` is on the HSTS preload list, so the site only works over HTTPS. Cloudflare issues
     the certificate automatically.
5. **Rate-limit the form before you share the link widely.** Cloudflare dashboard →
   `duodash.app` → Security → WAF → **Rate limiting rules** → match path `/api/interest`,
   method `POST`, 10 requests per minute per IP, action **Block**. (Optionally add Cloudflare
   Turnstile too; you'd then add `challenges.cloudflare.com` to the CSP in `_headers`.)
6. **Test:** open https://duodash.app/mount/, register a test address, export the list
   (below) and check it's there. Check the headers with `curl -sI https://duodash.app/`.

### Export the interest list

```bash
curl -s -H "Authorization: Bearer $INTEREST_ADMIN_TOKEN" https://duodash.app/api/interest > interest.csv
```

Import the CSV into any email service (Buttondown, Mailchimp, Resend…) to send the launch
email, with an unsubscribe link. Delete addresses people ask you to.

### How the form is protected

- Emails are validated and lower-cased; each address is stored once.
- A hidden "website" field catches simple bots; posts from other sites are refused (Origin
  check). Bodies over 2 KB are refused.
- The export needs the admin token (compared in constant time), and cells that could run as
  spreadsheet formulas are defused.
- There's no confirmation email, so someone could add an address that isn't theirs. The
  launch email should say why they're getting it and include an unsubscribe link.
- Campaign tags on a link (`?utm_source=reddit&utm_campaign=launch`) are saved with each
  sign-up as `source`.
- Without JavaScript the form still posts normally and lands on `/mount/?registered=1#register`.

## Deploy on Vercel (alternative)

Vercel serves the static site and applies the same headers from `vercel.json`, but it can't
run the Cloudflare Pages Function, so **the interest form won't store anything on Vercel**
until `functions/api/interest.js` is ported to a Vercel Function with a database (for example
Vercel Postgres or Upstash). Prefer Cloudflare Pages unless you do that port.

1. `cd web/app && npx vercel` (first time: link or create a project; framework "Other", no
   build command, output directory `.`), then `npx vercel --prod`.
2. Project → Settings → Domains → add `duodash.app` (and `www.duodash.app` redirecting to
   it). For the apex, Vercel asks for an `A` record (`76.76.21.21`) at your DNS host, or move
   the nameservers to Vercel.
3. Add a firewall rate limit on `/api/interest` once the form is ported.

## When the app is live on the App Store

- **The link:** search `index.html` for `href="#download"`. Change the App Store button's
  `href` to the app's App Store URL (`https://apps.apple.com/app/id<APP_ID>`), and the
  nav "Download" buttons (`index.html`, `404.html`) to the same URL. Keep the
  `id="download"` on the button row so `/#download` still scrolls there.
- **The badge:** Apple requires its official badge for "Download on the App Store". Download
  the badge (SVG, black, in your locale) from Apple's marketing resources site
  (tools.applemarketingtools.com / developer.apple.com/app-store/marketing/guidelines),
  save it as `assets/app-store-badge.svg`, and replace the contents of the `.btn-store` link
  with `<img src="/assets/app-store-badge.svg" alt="Download on the App Store" width="156" height="52">`.
  Don't recolour or alter it, and give it clear space as Apple's guidelines say. Until then
  the site uses a plain black pill and no Apple artwork.
- Update the Open Graph text if you like, and the `lastmod` dates in `sitemap.xml`.

## Editing

- **Prices:** the mount (A$59 / A$70) is in `index.html` (search `A$59`) and
  `mount/index.html` (search `A$59`, appears in the hero, price card and meta tags). Duo Dash
  Pro prices are in `index.html` (search `A$2.99`).
- **Phone images** (`assets/duo-*.webp`): real app screenshots composited into Apple's
  official iPhone Duo bezels (used under the owner's licence) and flattened by
  `scripts/web-device-images.py`. The hero fold is drawn on a `<canvas>` by `app.js` (no
  CSS 3D, which flattened unreliably in real browsers): the right half flat, the left half
  in 64 perspective-scaled vertical strips, the cover image once it passes 90°. It uses `duo-fold-left-*` / `duo-fold-right-*`
  (the open phone split at the hinge) and `duo-cover-*` (the closed phone, on the back of the
  left half). **Never commit or upload the raw bezel PNGs**; only the composites ship. To
  change a screen, update the screenshot in the assets folder and rerun:
  `/Applications/FreeCAD.app/Contents/Resources/bin/python scripts/web-device-images.py <assets-folder>`.
- **Other images:** the bento screenshots come from `docs/media/` (re-encode with
  `cwebp -q 78 -resize 1600 0 in.jpg -o out-1600.webp` and an `-800` version). The mount
  renders are `assets/mount-problem.webp`, `mount-fixed-front.webp`, `mount-fixed-back.webp`
  and `mount-product.webp` (+ `-640`); replace them with new renders of the same framing
  and file names. The problem/fix animation on `/mount/` rotates `mount-problem.webp` back
  by 24° to show it level first, so a replacement should keep the phone tilted about 24°
  anticlockwise with the phone centred.
- **Assets cache** for a week (`_headers`), so a replaced image can take that long to reach
  returning visitors; rename the file if it must change immediately.
- **Motion:** `app.js` adds `.motion` to `<html>` unless the visitor prefers reduced motion;
  every scroll scene has a static layout without it. Animations change only `transform` and
  `opacity`.
- **CSP:** `_headers` allows only the site itself (`'self'`): no inline scripts or `style=""`
  attributes. Add any new outside service to the CSP deliberately.
