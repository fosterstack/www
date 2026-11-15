#!/usr/bin/env python3
"""Check, on every pull request, the links a page makes that check-site-rot.py does not read. Standard library only.

  1. a link to https://fosterstack.com/<path> must name a page or file in this checkout
  2. a link to https://github.com/fosterstack/cache... must answer 200 (the private-advisory form may redirect to a login),
     and when it has a #fragment, the page it answers with must carry that heading id
Links to any other site are not checked: they flake.

Usage: check-cache-links.py [--root DIR] [--github URL]   (default: the checkout, https://github.com)
"""
import argparse
import os
import sys
import time
import urllib.error
import urllib.request
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit

SITE = "fosterstack.com"
CACHE = "/fosterstack/cache"
RETRY_WAIT = float(os.environ.get("CACHE_LINKS_RETRY_WAIT", "5"))


class Hrefs(HTMLParser):
    def __init__(self):
        super().__init__()
        self.found = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.found += [v for k, v in attrs if k == "href" and v]


def fetch(url):
    """(status, body); a failure is tried once more, since GitHub answers wrongly now and then. Status 0: no answer."""
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            status = e.code
        except OSError:
            status = 0
        time.sleep(RETRY_WAIT)
    return status, ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--github", default="https://github.com")
    args = ap.parse_args()
    problems = []
    cache_links = {}
    for folder, dirs, files in os.walk(args.root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if not name.endswith(".html"):
                continue
            page = os.path.join(folder, name)
            parser = Hrefs()
            with open(page, encoding="utf-8") as f:
                parser.feed(f.read())
            for href in parser.found:
                parts = urlsplit(href)
                if parts.scheme == "https" and parts.hostname == SITE:
                    target = os.path.join(args.root, unquote(parts.path).strip("/"))
                    if not (os.path.isfile(os.path.join(target, "index.html")) or os.path.isfile(target)):
                        problems.append("%s links %s, which is not a page or file here" % (page, href))
                elif parts.scheme == "https" and parts.hostname == "github.com" and (
                        parts.path == CACHE or parts.path.startswith(CACHE + "/")):
                    cache_links.setdefault((parts.path, parts.fragment), page)
    for (path, fragment), page in sorted(cache_links.items()):
        status, body = fetch(args.github + path)
        if status != 200:
            problems.append("%s links github.com%s, which answered %s" % (page, path, status or "nothing"))
        elif fragment and 'id="user-content-%s"' % fragment not in body:
            problems.append("%s links github.com%s#%s, but that heading is not on the page" % (page, path, fragment))
    for line in problems:
        print("FAIL " + line)
    print("%d cache links checked, %d problem%s" % (len(cache_links), len(problems), "" if len(problems) == 1 else "s"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
