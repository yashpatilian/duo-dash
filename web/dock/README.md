# Duo Dock website (`doc.yashyp.com`)

A static product and pre-order page for **Duo Dock**, the all-in-one car mount for iPhone Duo.
Plain HTML, CSS and JS. No build step, no framework, no trackers. The only external request is
Google Fonts (Inter).

| File | What |
|---|---|
| `index.html` | The page: hero, how it works, vent vs windscreen, Duo Dash, specs, pre-order, FAQ. All product imagery is inline SVG. |
| `styles.css` | Styles. Light and dark follow the visitor's system setting. Phone-first, no horizontal scroll at 320 px. |
| `app.js` | Mount-option tabs, the pre-order form, UTM pass-through, and the `STRIPE_LINKS` config. |
| `_headers` | Cloudflare Pages security headers (CSP etc.). |

**Status: demo.** The pre-order form validates the email, then shows a thank-you that says
plainly it's a demo. It sends and stores nothing. Prices shown: **A$69 launch price (first 50),
then A$79, shipped in Australia; US$49 + US$12 shipping to the US.** These come from the mount
costing (`Duo Holder/v2/Duo_Mount_v2_Costing.xlsx`); see `docs/business/PRICING_AND_COSTS.md`.

## Preview locally

```sh
cd web/dock
python3 -m http.server 8080
# open http://localhost:8080
```

Test the phone layout in Chrome DevTools' device toolbar (iPhone widths 375–430 px), and both
colour schemes (DevTools → Rendering → "Emulate CSS prefers-color-scheme").

## Before going live: things to change

1. **Contact email.** The footer uses `hello@yashyp.com`. Create it (Cloudflare Email Routing
   can forward it to your inbox for free: dashboard → yashyp.com → Email → Email Routing) or
   change the address.
2. **Policies you're committing to.** The page promises a **30-day change-of-mind return** and a
   **12-month warranty** on top of Australian Consumer Law. Keep, change or remove them in both
   the Specs, Pre-order and FAQ sections before launch.
3. **Ship date wording.** "We'll email you before anything is charged" is only true while the
   form collects emails. When you switch to Stripe, change that line to the real dispatch time.
4. **Road-test claims.** The FAQ says a summer heat test is part of road testing. Publish the
   result (README v2 tests T1–T9) or soften the line.
5. **Photos.** Replace or add to the SVG illustrations with real photos once the first kits are
   printed. Don't use Apple's product imagery.

## Deploy on Cloudflare Pages at `doc.yashyp.com`

Do these yourself. Nothing here has been set up.

### Option A: direct upload (simplest, no Git connection)

1. Make a clean copy without this README (Pages would otherwise publish it at `/README.md`):
   ```sh
   rm -rf /tmp/duo-dock-dist && rsync -a --exclude README.md web/dock/ /tmp/duo-dock-dist/
   ```
2. Deploy with Wrangler (it opens a browser to log in the first time):
   ```sh
   npx wrangler@latest pages project create duo-dock --production-branch main
   npx wrangler@latest pages deploy /tmp/duo-dock-dist --project-name duo-dock --branch main
   ```
   Or in the dashboard: **Workers & Pages → Create → Pages → Upload assets**, name it
   `duo-dock`, and drag in the `/tmp/duo-dock-dist` folder.
3. Check it at `https://duo-dock.pages.dev`.

### Option B: connect the Git repo (redeploys on every push)

1. **Workers & Pages → Create → Pages → Connect to Git**, pick this repo and the branch.
2. Build settings: **Framework preset: None**, **Build command:** *(leave empty)*,
   **Build output directory:** `web/dock`.
3. Save and deploy. (README.md will be served too; that's harmless, or use Option A.)

Cloudflare is steering new projects towards Workers with static assets. Pages still works for
this. If you'd rather use Workers: `npx wrangler@latest deploy --assets /tmp/duo-dock-dist
--name duo-dock --compatibility-date 2026-11-01`, then add the custom domain under the Worker's
**Settings → Domains & Routes**.

### Custom domain and DNS

1. In the Pages project: **Custom domains → Set up a custom domain →** `doc.yashyp.com` → Continue.
2. DNS:
   - **If `yashyp.com` is already a zone in your Cloudflare account**, Cloudflare offers to add
     the record for you: a proxied `CNAME doc → duo-dock.pages.dev`. Accept it.
   - **If the domain's DNS is elsewhere** (your registrar), add at the registrar:
     `CNAME  doc  duo-dock.pages.dev` (TTL auto/300). Then wait for Pages to show **Active**.
     Don't point the record at Pages before adding the custom domain in step 1, or it will
     return a 522 error.
3. TLS certificates are issued automatically; it usually takes a few minutes, up to a day.
4. Optional: **Rules → Redirect Rules** to send `www.doc.yashyp.com` or `dock.yashyp.com` to
   `doc.yashyp.com`.

## Add Stripe Payment Links

Recommended order: collect emails first (see "Email capture" below), then switch the form to
Stripe once a batch is printed and you can ship within a few days. Taking money for stock that
doesn't exist yet makes Australian Consumer Law delivery and refund obligations harder.

1. Stripe account (Australia), verified, with your ABN and bank account. Payouts in AUD.
2. **Product catalogue → Add product:** "Duo Dock", one-off prices:
   - A$69.00 AUD ("Launch, first 50")
   - A$79.00 AUD ("Standard, AU shipped")
   - US$49.00 USD ("US")
3. **Shipping rate** (Product catalogue → Shipping rates): "US standard, tracked" US$12.00.
4. **Payment Links → New**, one per region:
   - **AU launch link:** A$69 price, quantity fixed at 1 (or adjustable up to 3), **Collect
     customers' addresses → Shipping, Australia only**, **Limit the number of payments → 50**
     (under Advanced options), confirmation page or redirect to
     `https://doc.yashyp.com/?ordered=1`.
   - **AU standard link:** same with A$79 and no limit. Swap it in when the launch link sells out.
   - **US link:** US$49 price + the US$12 shipping rate, shipping address United States only.
   - Turn on **Apple Pay / Google Pay** (Settings → Payment methods). Leave **Collect tax off**
     until you're GST-registered.
5. Paste the URLs into `STRIPE_LINKS` in `app.js`:
   ```js
   var STRIPE_LINKS = { AU: "https://buy.stripe.com/…", US: "https://buy.stripe.com/…" };
   ```
   The form then redirects to Stripe with the email prefilled (`prefilled_email`) and the
   visitor's UTM tags in `client_reference_id`, which shows on each payment in the dashboard.
6. Update the page copy: the button text ("Reserve, no charge yet" → "Buy now"), the demo note
   under the button, the thank-you text, and the "We'll email you before anything is charged"
   line.
7. Test with Stripe **test mode** links and card `4242 4242 4242 4242` before swapping in live
   links.

### Later: Shopify Buy Button

When you outgrow Payment Links (inventory, discount codes, abandoned-cart emails), create a
Shopify store, then **Sales channels → Buy Button → Create** and paste the embed into
`<div id="shopify-buy-button">` in `index.html`, removing the form. Add Shopify's script and
frame domains to the CSP in `_headers` or the button won't load.

## Email capture (until checkout is live)

The form stores nothing. To actually keep the list, either:
- point the form at a hosted signup endpoint from an email tool (MailerLite, Buttondown or
  similar, all have free tiers): set `action` and `method="post"` on `<form>`, rename the email
  field to what the tool expects, and remove the demo branch in `app.js`; or
- add a Cloudflare Pages Function (`functions/api/reserve.js`) that writes to a D1 table or KV.

Add a one-line privacy note under the form when you do ("We'll only email you about Duo Dock.
Unsubscribe any time.") and a short privacy policy page.

## Links into the site from the app

Use UTM tags so you can see which placement sells:

| Placement | URL |
|---|---|
| Duo Dash onboarding promo | `https://doc.yashyp.com/?utm_source=duodash&utm_medium=app&utm_campaign=onboarding` |
| Duo Dash Settings → Duo Dock | `https://doc.yashyp.com/?utm_source=duodash&utm_medium=app&utm_campaign=settings` |
| Reddit launch post | `https://doc.yashyp.com/?utm_source=reddit&utm_medium=social&utm_campaign=launch` |
| GitHub README | `https://doc.yashyp.com/?utm_source=github&utm_medium=readme&utm_campaign=app` |

Cloudflare Web Analytics (free, cookie-less) can be switched on for the Pages project if you
want page-view counts; it adds a Cloudflare beacon script, so add
`https://static.cloudflareinsights.com` to `script-src` in `_headers`.

## Preview screenshots

`web/dock-preview/` has full-page captures (desktop 1440 px and phone 390 px, light and dark)
taken with headless Chrome on 2026-11-17. They sit outside `web/dock/` so they are not deployed.
