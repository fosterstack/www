# fosterstack/www — marketing site + waitlist

Static landing page for fosterstack.com with a Cloudflare Pages Function waitlist
(`/api/waitlist`) backed by a KV namespace. No external requests, no third-party form
service, no analytics (add privacy-respecting analytics later if wanted).

## Layout

```
index.html                 the page (inline CSS/JS, system fonts, zero external assets)
functions/api/waitlist.js  Pages Function: POST /api/waitlist -> KV
_headers                   security headers incl. CSP
```

## Deploy checklist (owner, ~15 min, one-time)

1. Create the GitHub repo `fosterstack/www` (public is fine — nothing secret here).
   Tier 1 credentials cannot create repos; do this in the web UI or with Tier 0.
   Then from this directory: `git remote add origin git@github.com:fosterstack/www.git`
   and `git push -u origin main` (identity/signing auto-applies via includeIf).
2. Cloudflare dashboard → Workers & Pages → Create → Pages → connect to git →
   select `fosterstack/www`. Framework preset: None. Build command: (empty).
   Output directory: `/`. Deploy.
3. KV: Workers & Pages → KV → Create namespace `waitlist`. Then in the Pages project →
   Settings → Bindings → add KV binding, variable name `WAITLIST` (exact, uppercase),
   pointing at that namespace. Redeploy so the binding takes effect.
4. Custom domain: Pages project → Custom domains → add `fosterstack.com` and
   `www.fosterstack.com`. (Requires fosterstack.com DNS on Cloudflare; if the domain is
   registered elsewhere, add the site to Cloudflare DNS first.)
5. Test: submit a real email on the live page, then check KV entries in the dashboard,
   or `wrangler kv key list --namespace-id=<id>`.

## Reading the waitlist

Each signup is a KV entry: key `email:<address>`, value JSON `{email, ts, country}`.
Idempotent — duplicate signups don't error and don't overwrite the original timestamp.
Honeypot field (`website`) silently drops bots.

## Copy constraints (do not undo)

- Trademark hygiene: "Gradle"/"Develocity" appear only for compatibility identification;
  the footer disclaimer stays. No Gradle code claims, no affiliation implications.
- The trust pitch (MIT core, one public image, identical bytes free/paid, license-key
  unlock, security patches never withheld from free tier) is brief §0.2 policy, not
  marketing filler. Changes to it are an owner decision.
- No fabricated testimonials, logos, or usage numbers — FTC posture per brief §4.
