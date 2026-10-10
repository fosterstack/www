#!/usr/bin/env python3
"""Keep the public site from rotting. Standard library only; reads files, runs nothing from them.

Fails (exit 1, one line per problem) on:
  1. a broken internal link: an href or src to a page or file that does not exist
  2. a broken #anchor: a link whose #fragment is not an id on the target page
  3. a removed page without its two 301 lines (with and without the trailing slash), or a
     redirect whose target page or #anchor does not exist, or a redirect whose source is a live page
  4. a mismatch between the sitemap, llms.txt and the home page's links to pages
  5. a <title> longer than 60 characters (or a page with none)

Usage: check-site-rot.py [--root DIR] [--base REF] [--removed FILE...]
  --base REF asks git which pages were removed since REF (the workflow passes HEAD^1) and requires each to
  have its two redirect lines; it fails if REF cannot be found, so a shallow checkout cannot hide a removal.
  --removed takes page paths directly (for example "old-page/index.html"), for tests.
"""
import argparse
import html
import os
import re
import subprocess
import sys
from urllib.parse import unquote

TITLE_MAX = 60
SITE = "https://fosterstack.com/"


def page_dirs(root):
    out = []
    for name in sorted(os.listdir(root)):
        if name.startswith("."):
            continue
        if os.path.isfile(os.path.join(root, name, "index.html")):
            out.append(name)
    return out


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def ids_of(text):
    return set(re.findall(r'\bid="([^"]+)"', text))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--removed", nargs="*", default=[])
    ap.add_argument("--base", help="git ref of the parent commit (for example HEAD^1): pages removed since then "
                                   "must have their two 301 lines. Fails if the ref cannot be found.")
    args = ap.parse_args()
    root = args.root
    problems = []
    removed_from_git = []
    if args.base:
        # fail closed: a missing parent must never quietly turn into "nothing was removed"
        shown = re.sub(r"[\x00-\x1f\x7f]", " ", args.base)
        ref = subprocess.run(["git", "-C", root, "rev-parse", "--verify", "--quiet", args.base + "^{commit}"],
                             capture_output=True, text=True)
        if ref.returncode != 0:
            print("FAIL base: cannot find %s, so removed pages cannot be checked "
                  "(is the checkout too shallow? it needs two commits)" % shown)
            return 1
        diff = subprocess.run(["git", "-C", root, "diff", "--diff-filter=D", "--name-only", args.base, "HEAD",
                               "--", "*/index.html"], capture_output=True, text=True)
        if diff.returncode != 0:
            print("FAIL base: git diff against %s failed, so removed pages cannot be checked" % shown)
            return 1
        removed_from_git = diff.stdout.splitlines()

    def bad(msg):
        # one printable line per problem: text from a pull request must never start a line with "::"
        # (GitHub Actions reads such a line as a workflow command) or smuggle in a newline
        problems.append(re.sub(r"[\x00-\x1f\x7f]", " ", msg))

    pages = page_dirs(root)
    page_set = set(pages)
    files = {"": os.path.join(root, "index.html")}
    for p in pages:
        files[p] = os.path.join(root, p, "index.html")
    if os.path.isfile(os.path.join(root, "404.html")):
        files["404.html"] = os.path.join(root, "404.html")
    texts = {k: read(v) for k, v in files.items()}
    ids = {k: ids_of(t) for k, t in texts.items()}

    # 5. titles
    for key, t in texts.items():
        m = re.search(r"<title>(.*?)</title>", t, re.S)
        label = key or "/"
        if not m:
            bad("title: %s has no <title>" % label)
            continue
        title = html.unescape(m.group(1).strip())
        if len(title) > TITLE_MAX:
            bad("title: %s is %d characters (max %d): %s" % (label, len(title), TITLE_MAX, title))

    # 1 and 2. internal links and anchors
    def resolve(path):
        """Return the key of the page a site path points at, 'FILE' for a real file, or None."""
        path = unquote(path)
        if path in ("", "/"):
            return ""
        key = path.strip("/")
        if "/" not in key and key in page_set:
            return key
        if os.path.isfile(os.path.join(root, key)):
            return "FILE"
        return None

    for key, t in texts.items():
        label = key or "/"
        for attr, val in re.findall(r'\b(href|src)="([^"]*)"', t):
            val = html.unescape(val)
            if not val or val.startswith(("http://", "https://", "mailto:", "tel:", "//", "data:", "javascript:")):
                continue
            frag = ""
            if "#" in val:
                val, frag = val.split("#", 1)
            val = val.split("?", 1)[0]
            if val == "":
                target = key
            elif val.startswith("/"):
                target = resolve(val)
            else:
                bad("link: %s has a relative %s=%r (use a path from the site root)" % (label, attr, val))
                continue
            if target is None:
                bad("link: %s points at %s which does not exist" % (label, val))
                continue
            if frag and target != "FILE" and frag not in ids.get(target, set()):
                bad("anchor: %s links to %s#%s but that id is not on the page" % (label, val or label, frag))

    # 3. redirects
    redirects = []
    rpath = os.path.join(root, "_redirects")
    if os.path.isfile(rpath):
        for n, line in enumerate(read(rpath).splitlines(), 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            parts = s.split()
            if len(parts) != 3:
                bad("redirects: line %d does not have three fields: %s" % (n, s))
                continue
            redirects.append((n, parts[0], parts[1], parts[2]))
    sources = {src for _, src, _, _ in redirects}
    for n, src, tgt, code in redirects:
        if "*" in src:
            continue
        if code == "301":
            base = src.strip("/")
            if "/" not in base and base in page_set:
                bad("redirects: line %d redirects %s but that page still exists" % (n, src))
            if tgt.startswith("/"):
                path, _, frag = tgt.partition("#")
                target = resolve(path)
                if target is None:
                    bad("redirects: line %d target %s does not exist" % (n, tgt))
                elif frag and target != "FILE" and frag not in ids.get(target, set()):
                    bad("redirects: line %d target %s: the id #%s is not on the page" % (n, tgt, frag))
            pair = "/" + base if src.endswith("/") else "/" + base + "/"
            if pair not in sources:
                bad("redirects: line %d %s has no matching %s line (a rule with a trailing slash does not match the URL without one)" % (n, src, pair))
    removed = list(removed_from_git)
    for item in args.removed:
        removed.extend(x for x in item.split("\n") if x.strip())
    for path in removed:
        m = re.match(r"^([^/]+)/index\.html$", path.strip())
        if not m:
            continue
        slug = m.group(1)
        if slug in page_set:
            continue  # still there (renamed in place): nothing to redirect
        for form in ("/%s/" % slug, "/%s" % slug):
            line = [r for r in redirects if r[1] == form and r[3] == "301"]
            if not line:
                bad("removed: page %s was removed but has no 301 line for %s in _redirects" % (slug, form))

    # 4. sitemap, llms.txt and the home page's links to pages
    smp = os.path.join(root, "sitemap.xml")
    if os.path.isfile(smp):
        locs = re.findall(r"<loc>([^<]*)</loc>", read(smp))
        want = {SITE} | {SITE + p + "/" for p in pages}
        got = set(locs)
        if len(locs) != len(got):
            bad("sitemap: has a duplicate <loc>")
        for u in sorted(got - want):
            bad("sitemap: lists %s but no such page exists" % u)
        for u in sorted(want - got):
            bad("sitemap: is missing %s" % u)
    lp = os.path.join(root, "llms.txt")
    if os.path.isfile(lp):
        urls = set(re.findall(r"\((https://fosterstack\.com/[^)\s]*)\)", read(lp)))
        want = {SITE + p + "/" for p in pages}
        for u in sorted(urls - want - {SITE}):
            bad("llms.txt: links %s but no such page exists" % u)
        for u in sorted(want - urls):
            bad("llms.txt: does not list %s" % u)
    homelinks = {m for m in re.findall(r'href="/([a-z0-9-]+)/"', texts[""])}
    for p in sorted(homelinks - page_set):
        bad("home: links /%s/ which is not a page" % p)
    for p in sorted(page_set - homelinks):
        bad("home: does not link /%s/ (the Guides list or another section should)" % p)

    for line in problems:
        print("FAIL " + line)
    print("%d pages checked, %d problem%s" % (len(pages) + 1, len(problems), "" if len(problems) == 1 else "s"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
