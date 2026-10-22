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
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

SITE = "https://fosterstack.com/"
TIMEOUT = float(os.environ.get("LIVE_CHECK_TIMEOUT", "20"))
RETRY_WAIT = float(os.environ.get("LIVE_CHECK_RETRY_WAIT", "5"))
MAX_BYTES = 8 * 1024 * 1024


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


OPENER = urllib.request.build_opener(_NoRedirect)


def fetch(url, accept=(200,)):
    """(status, body). ONE retry for any answer not in accept (a timeout, a refusal, a 5xx, a 403, a 404, a redirect: all may be a
    flaky moment), so only a failure seen twice is reported; status 0 means no answer. Never raises."""
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
        if last[0] in accept:
            break
        if attempt == 1:
            time.sleep(RETRY_WAIT)
    return last


class _Links(HTMLParser):
    """Every href of every a and link tag, read the way a browser reads the page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hrefs = []

    def handle_starttag(self, tag, attrs):
        if tag in ("a", "link", "area"):
            for k, v in attrs:
                if k.lower() == "href" and v:
                    self.hrefs.append(v.strip())

    handle_startendtag = handle_starttag


def links_of(text):
    parser = _Links()
    parser.feed(text)
    parser.close()
    return parser.hrefs


def has_control(raw):
    """A control character written out, or as a numeric reference (&#9; &#x1f;), which the decoder would otherwise drop."""
    if re.search(r"[\x00-\x1f\x7f-\x9f]", raw):
        return True
    for m in re.finditer(r"&#(?:[xX]([0-9a-fA-F]+)|([0-9]+));", raw):
        n = int(m.group(1), 16) if m.group(1) else int(m.group(2))
        if n < 0x20 or 0x7f <= n <= 0x9f:
            return True
    return False


def safe_suffix(suffix):
    """The part of a sitemap URL after the site root, if it is a plain relative path (no leading slash, no '..', no
    backslash, no query or fragment, no control characters); None otherwise."""
    if suffix.startswith("/") or "\\" in suffix or "?" in suffix or "#" in suffix or re.search(r"[\x00-\x1f\x7f-\x9f]", suffix):
        return None
    if any(part in ("..", ".") for part in suffix.split("/")):
        return None
    return suffix


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
        rel = safe_suffix(site_url[len(SITE):])
        if rel is None:
            return None
        path = os.path.realpath(os.path.join(args.root, rel + ("index.html" if rel.endswith("/") or rel == "" else "")))
        if not path.startswith(os.path.realpath(args.root) + os.sep):
            return None
        try:
            with open(path, "rb") as f:
                return f.read()
        except OSError:
            return None

    # 1. the page list, from the live sitemap
    status, body = fetch(base + "/sitemap.xml")
    sitemap_body = body
    status_sitemap_ok = status == 200
    if status != 200:
        bad("sitemap", "sitemap.xml answered %s" % (status or "nothing"))
        locs = []
    else:
        # only plain spaces and line breaks around an entry are ignored; any other control character (a tab, U+001F, ...)
        # is looked at after the text is decoded, and the entry is refused, so it is never fetched and no file is read for it
        locs = [x.strip(" \r\n") for x in re.findall(r"<loc>([^<]*)</loc>", body.decode("utf-8", "replace"))]
    pages = []
    for raw in locs:
        u = html.unescape(raw)
        if has_control(raw):
            bad("sitemap", "the live sitemap lists %s, which is not a plain path on the site (it holds a control character)" % raw)
        elif not u.startswith(SITE):
            bad("sitemap", "the live sitemap lists %s, which is not on %s" % (u, SITE))
        elif safe_suffix(u[len(SITE):]) is None:
            bad("sitemap", "the live sitemap lists %s, which is not a plain path on the site" % u)
        else:
            pages.append(u)
    if status == 200 and not pages:
        bad("sitemap", "the live sitemap lists no page")

    # 2. every listed page, and the three files, against main
    texts = {}
    for u in dict.fromkeys(pages + [SITE + "llms.txt", SITE + "robots.txt", SITE + "sitemap.xml"]):
        if u == SITE + "sitemap.xml":
            status, got = (200, sitemap_body) if sitemap_body is not None and status_sitemap_ok else (0, b"")   # the same answer the page list came from
        else:
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
        for href in links_of(got.decode("utf-8", "replace")):
            full = urljoin(u, href)               # resolved against its own page, so relative and absolute links are both read
            parts = urlsplit(full)
            host = (parts.hostname or "").lower()
            if parts.scheme not in ("http", "https") or host not in ("fosterstack.com", "github.com"):
                continue
            if host == "github.com" and not parts.path.startswith("/fosterstack/"):
                continue
            if parts.scheme != "https" or parts.username or parts.password or parts.port not in (None, 443):
                bad("link", "%s links %s, which is not a plain https link (http, a port or credentials)" % (u, full))
                continue
            clean_url = "https://%s%s" % (host, parts.path)
            (internal if host == "fosterstack.com" else external).setdefault(clean_url, u)
    for v, src in sorted(internal.items()):
        if v in pages or v == SITE:
            continue
        status, _ = fetch(live_url(v))
        if status != 200:
            bad("link", "%s links %s, which answered %s" % (src, v, status or "nothing"))
    for v, src in sorted(external.items()):
        advisory = v.endswith("/security/advisories/new")
        status, _ = fetch(args.github.rstrip("/") + v[len("https://github.com"):],
                          accept=(200, 301, 302, 303, 307, 308) if advisory else (200,))
        if status in (200, 301, 302, 303, 307, 308) and (status == 200 or advisory):
            continue
        bad("link", "%s links %s, which answered %s" % (src, v, status or "nothing"))

    for line in problems:
        print(line)
    print("%d live pages checked, %d problem%s" % (len(pages), len(problems), "" if len(problems) == 1 else "s"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
