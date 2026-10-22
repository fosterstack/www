#!/usr/bin/env python3
"""Check the LIVE site once a day (launch week and after). Standard library only; reads the network and the checkout, writes nothing.

What it does, in order (a problem is one line starting with "FAIL", which is what the tracking issue quotes):
  1. fetch /sitemap.xml from the live site and take the page list FROM IT (not from the repository); every entry must be
     on the site's own host (https://fosterstack.com/), or the entry is refused and never fetched;
  2. fetch every listed page: it must answer 200 (a redirect is a failure) and be byte for byte the file in the checkout of main;
     sitemap.xml, llms.txt and robots.txt the same (so "the live site" and "what main says" cannot drift apart unseen);
  3. from the live pages take every internal link (a path from the site root) and every github.com/fosterstack link; each must
     answer 200 (the private-advisory form may redirect to a login).
Every request has one fixed timeout (LIVE_CHECK_TIMEOUT, default 20 seconds) and ONE retry after a short wait
(LIVE_CHECK_RETRY_WAIT, default 5 seconds), so a flaky answer does not raise an issue by itself.

Usage: live-check.py [--root DIR] [--base URL] [--github URL]   (defaults: the checkout, https://fosterstack.com, https://github.com)
"""
import argparse
import hashlib
import html
import os
import re
import sys
import time
import urllib.error
import urllib.request

SITE = "https://fosterstack.com/"
TIMEOUT = float(os.environ.get("LIVE_CHECK_TIMEOUT", "20"))
RETRY_WAIT = float(os.environ.get("LIVE_CHECK_RETRY_WAIT", "5"))
MAX_BYTES = 8 * 1024 * 1024


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


OPENER = urllib.request.build_opener(_NoRedirect)


def fetch(url):
    """(status, body) with one retry; status 0 means no answer. Never raises."""
    last = (0, b"")
    for attempt in (1, 2):
        try:
            with OPENER.open(urllib.request.Request(url, headers={"User-Agent": "fosterstack-live-check"}), timeout=TIMEOUT) as r:
                body = r.read(MAX_BYTES + 1)
                last = (r.status, body[:MAX_BYTES])
        except urllib.error.HTTPError as e:
            last = (e.code, b"")
        except Exception:
            last = (0, b"")
        # a good answer, or a plain "no such thing", is final; a timeout, a refusal and a 5xx are tried once more
        if last[0] in (200, 301, 302, 303, 307, 308, 400, 401, 403, 404, 410) :
            break
        if attempt == 1:
            time.sleep(RETRY_WAIT)
    return last


def clean(text):
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", text)[:300]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--base", default=SITE.rstrip("/"))
    ap.add_argument("--github", default="https://github.com")
    args = ap.parse_args()
    base = args.base.rstrip("/")
    problems = []

    def bad(kind, msg):
        problems.append("FAIL %s: %s" % (kind, clean(msg)))

    def live_url(site_url):
        return base + "/" + site_url[len(SITE):]

    def repo_bytes(site_url):
        rel = site_url[len(SITE):]
        path = os.path.join(args.root, rel + ("index.html" if rel.endswith("/") or rel == "" else ""))
        try:
            with open(path, "rb") as f:
                return f.read()
        except OSError:
            return None

    # 1. the page list, from the live sitemap
    status, body = fetch(base + "/sitemap.xml")
    if status != 200:
        bad("sitemap", "sitemap.xml answered %s" % (status or "nothing"))
        locs = []
    else:
        locs = [html.unescape(x).strip() for x in re.findall(r"<loc>([^<]*)</loc>", body.decode("utf-8", "replace"))]
    pages = []
    for u in locs:
        if not u.startswith(SITE):
            bad("sitemap", "the live sitemap lists %s, which is not on %s" % (u, SITE))
        else:
            pages.append(u)

    # 2. every listed page, and the three files, against main
    texts = {}
    for u in dict.fromkeys(pages + [SITE + "llms.txt", SITE + "robots.txt", SITE + "sitemap.xml"]):
        status, got = fetch(live_url(u))
        label = u[len(SITE):] or "/"
        kind = "page" if u in pages else "drift"
        if status != 200:
            bad("page" if u in pages else "file", "%s answered %s" % (u, status or "nothing"))
            continue
        texts[u] = got
        want = repo_bytes(u)
        if want is None:
            bad("drift", "%s is live but main has no such file" % u)
        elif hashlib.sha256(want).digest() != hashlib.sha256(got).digest():
            bad("drift", "%s is live but differs from the file on main" % u)

    # 3. links on the live pages
    internal, external = {}, {}
    for u, got in texts.items():
        if not u.endswith("/"):
            continue
        for m in re.finditer(r'(?<![\w-])href\s*=\s*"([^"]*)"', got.decode("utf-8", "replace"), re.I):
            v = html.unescape(m.group(1)).split("#", 1)[0].split("?", 1)[0]
            if v.startswith("/") and not v.startswith("//") and v:
                internal.setdefault(v, u)
            elif v.startswith("https://github.com/fosterstack/"):
                external.setdefault(v, u)
    for v, src in sorted(internal.items()):
        if SITE.rstrip("/") + v in pages or v == "/":
            continue
        status, _ = fetch(base + v)
        if status != 200:
            bad("link", "%s links %s, which answered %s" % (src, v, status or "nothing"))
    for v, src in sorted(external.items()):
        target = args.github.rstrip("/") + v[len("https://github.com"):]
        status, _ = fetch(target)
        if status == 200 or (status in (301, 302, 303, 307, 308) and v.endswith("/security/advisories/new")):
            continue
        bad("link", "%s links %s, which answered %s" % (src, v, status or "nothing"))

    for line in problems:
        print(line)
    print("%d live pages checked, %d problem%s" % (len(pages), len(problems), "" if len(problems) == 1 else "s"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
