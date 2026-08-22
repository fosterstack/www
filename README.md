# fosterstack/www — marketing site + waitlist

Static landing page for fosterstack.com with a Cloudflare Pages Function waitlist
(`/api/waitlist`) backed by a KV namespace. No external requests, no third-party form
service, no analytics (add privacy-respecting analytics later if wanted).

**One-time setup after cloning:** `git config core.hooksPath .githooks` — enables the
public-repo hygiene pre-commit hook (see below). CI enforces the same check as a backstop
either way, but the hook catches it before a push, not after.

## Layout

```
index.html                    the page (inline CSS/JS, system fonts, zero external assets)
bcn-removed/index.html        pre-positioned migration page (see below) — NOT linked from nav
functions/api/waitlist.js     Pages Function: POST /api/waitlist -> KV
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
Docker Hub, not days. It deploys automatically like any other file here (Cloudflare Pages
has no concept of "build but don't ship") but is deliberately **not linked from `index.html`**
and carries `<meta name="robots" content="noindex">`, so it sits at a real, working URL
that isn't discoverable until someone links to it.

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
