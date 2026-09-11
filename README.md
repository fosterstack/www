# fosterstack/www — marketing site

Static landing page for fosterstack.com. No forms, no email capture, no cookies, no
analytics, and no third-party requests of any kind
service, no analytics (add privacy-respecting analytics later if wanted).

**One-time setup after cloning:** `git config core.hooksPath .githooks` — enables the
public-repo hygiene pre-commit hook (see below). CI enforces the same check as a backstop
either way, but the hook catches it before a push, not after.

## Layout

```
index.html                    the page (inline CSS/JS, system fonts, zero external assets)
.drafts/bcn-removed/index.html  pre-positioned migration page (see below) — UNPUBLISHED draft
_redirects                    /bcn-removed/* -> / until the draft publishes
_headers                      security headers incl. CSP
.githooks/pre-commit          public-repo hygiene hook (see below)
bin/check-file-allowlist.sh   the allowlist itself — shared by the hook and CI
```

## Public-repo hygiene

Everything in this repo is served verbatim by Cloudflare Pages (output directory `/`, no
build step) — anything committed here is one push away from being live on the internet.
`bin/check-file-allowlist.sh` rejects any file that isn't on an explicit allowlist (fails
closed on anything unrecognized, rather than trying to enumerate bad patterns), run both as
a local pre-commit hook and as a CI backstop (`.github/workflows/hygiene.yml`) for commits
made without the hook enabled. Legitimately adding a new file type is a one-line change to
the `ALLOW_PATTERNS` array in that script.

## Pre-positioned page: `bcn-removed/`

Addendum §2 (DECIDED): built ahead of any trigger so FosterStack is in front of
panic-searches within hours of Gradle actually removing `gradle/build-cache-node` from
Docker Hub, not days. REVISED Sep 11, 2026: it used to deploy at an unlisted URL behind
a `noindex` tag; the Sep 10 review pointed out that noindex is a request, not a gate —
the page claimed a removal that had not happened, at a live URL. It now lives in
`.drafts/` (dot-prefixed paths are excluded from the Pages upload, so it does not
deploy), and `/bcn-removed/*` 302s to the homepage in the meantime.

The trigger source is `fosterstack/ops`'s daily Docker Hub watcher
(`bin/docker-hub-watch.sh`, private repo) — it files a tracking issue when it detects the
repo being deleted or its tag count dropping. **Publishing this page for real is an owner
action, not automatic**: verify the finding directly at
[hub.docker.com/r/gradle/build-cache-node](https://hub.docker.com/r/gradle/build-cache-node)
first (the watcher is tuned to alert fast, which means it can also alert on a transient API
hiccup), then remove the `noindex` tag and add a prominent, dated link from `index.html`.
Full instructions are in an HTML comment at the top of `bcn-removed/index.html`.

## Deploy checklist (owner, ~15 min, one-time)

1. Create the GitHub repo `fosterstack/www` (public is fine — nothing secret here).
   Tier 1 credentials cannot create repos; do this in the web UI or with Tier 0.
   Then from this directory: `git remote add origin git@github.com:fosterstack/www.git`
   and `git push -u origin main` (identity/signing auto-applies via includeIf).
2. Cloudflare dashboard → Workers & Pages → Create → Pages → connect to git →
   select `fosterstack/www`. Framework preset: None. Build command: (empty).
   Output directory: `/`. Deploy.
3. Custom domain: Pages project → Custom domains → add `fosterstack.com` and
   `www.fosterstack.com`. (Requires fosterstack.com DNS on Cloudflare; if the domain is
   registered elsewhere, add the site to Cloudflare DNS first.)
4. Test: load the page and confirm the links resolve. There is nothing to submit.

## No data collection

This site has no forms, no inputs, and no server-side functions. It collects no email
addresses, sets no cookies, loads no third-party scripts, and makes no external
requests. The CSP in `_headers` enforces that: `connect-src 'self'` and no `form-action`
target, so a form or a beacon added by accident fails in the browser rather than
shipping quietly.

Do not reintroduce an email field. "Stay in touch" is GitHub star and
Watch → Releases, which is a subscription the reader controls and can revoke without
asking us.

## Copy constraints (do not undo)

- Trademark hygiene: "Gradle"/"Develocity" appear only for compatibility identification;
  the footer disclaimer stays. No Gradle code claims, no affiliation implications.
- The trust pitch (MIT core, one public image, identical bytes free/paid, license-key
  unlock, security patches never withheld from free tier) is brief §0.2 policy, not
  marketing filler. Changes to it are an owner decision.
- No fabricated testimonials, logos, or usage numbers — FTC posture per brief §4.
- No calendar commitments. No launch dates, no "beta in <month>", no phase language.
  The dateless roadmap and the honest maturity label (v0.1, early) stay; a schedule
  we might miss does not go on a public page.
- No email capture, ever. See "No data collection" above.
