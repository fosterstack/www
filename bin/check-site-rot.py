#!/usr/bin/env python3
"""Keep the public site from rotting. Standard library only; reads files, runs nothing from them.

Fails (exit 1, one line per problem) on:
  1. a broken internal link: an href or src to a page or file that does not exist
  2. a broken #anchor: a link whose #fragment is not an id on the target page
  3. a removed page without its two 301 lines (with and without the trailing slash), or a
     redirect whose target page or #anchor does not exist, or a redirect whose source is a live page
  4. a mismatch between the sitemap, llms.txt and the home page's links to pages
  5. a <title> longer than 60 characters (or a page with none)
  6. hidden pages (owner ratified Oct 22 2026): a page hidden from search (a robots or googlebot noindex tag, or an
     X-Robots-Tag noindex rule in _headers) that is listed in the sitemap; and, for the live site only, any hidden
     page except 404.html. The second applies with --live, and by itself when GitHub says this run is for a pull
     request whose base is main (GITHUB_BASE_REF) or for main itself (GITHUB_REF), so a draft branch stays testable.

Usage: check-site-rot.py [--root DIR] [--base REF] [--removed FILE...] [--live]
  --base REF asks git which pages were removed since REF (the workflow passes HEAD^1) and requires each to
  have its two redirect lines; it fails if REF cannot be found, so a shallow checkout cannot hide a removal.
  --removed takes page paths directly (for example "old-page/index.html"), for tests.
  Limit: --base looks at one commit back, so if several commits are pushed to main in one go, only the last
  commit's removals are seen (pull requests are always covered: their HEAD^1 is the base branch).
"""
import argparse
import html
from html.parser import HTMLParser
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
    # an id attribute, not data-id or aria-id (the lookbehind), double or single quoted
    return set(a or b for a, b in re.findall(r'(?<![\w-])id\s*=\s*(?:"([^"]+)"|\'([^\']+)\')', text, re.I))


VALUE_DIRECTIVES = {"max-snippet", "max-image-preview", "max-video-preview", "unavailable_after"}


class _RobotsMeta(HTMLParser):
    """Finds robots and googlebot meta tags the way a browser reads the page: comments, script and style text are not tags,
    and a quoted '>' does not end a tag."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hidden = False

    def handle_starttag(self, tag, attrs):
        if tag != "meta":
            return
        a = {k.lower(): (v or "").strip().lower() for k, v in attrs}
        if a.get("name") in ("robots", "googlebot") and {x.strip() for x in a.get("content", "").split(",")} & {"noindex", "none"}:
            self.hidden = True

    handle_startendtag = handle_starttag


def hidden_by_meta(text):
    """True if a robots or googlebot meta tag in the page carries noindex (or none, which means noindex and nofollow)."""
    parser = _RobotsMeta()
    parser.feed(text)
    parser.close()
    return parser.hidden


def header_hides(value):
    """True if an X-Robots-Tag value carries noindex or none as a directive, alone or for one named bot ("googlebot: noindex").
    A directive that only has the word as its value, such as "max-image-preview: none", hides nothing."""
    for part in value.split(","):
        m = re.fullmatch(r"\s*(?:([A-Za-z0-9_-]+)\s*:\s*)?(noindex|none)\s*", part, re.I)
        if m and (m.group(1) or "").lower() not in VALUE_DIRECTIVES:
            return True
    return False


def hidden_by_headers(headers_text):
    """Path patterns of the _headers blocks that send an X-Robots-Tag with noindex (or none)."""
    patterns, cur, hit = [], None, False
    for line in headers_text.splitlines() + ["/end-of-file"]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            if cur is not None and hit:
                patterns.append(cur)
            cur, hit = line.strip(), False
        elif re.match(r"\s*x-robots-tag\s*:", line, re.I):
            hit = hit or header_hides(line.split(":", 1)[1])
    return patterns


def pattern_regex(pat):
    """A _headers path pattern as a regex over the URL path: * matches anything, :name matches one path segment; an absolute
    URL on this site is read as its path, one on another host matches nothing here."""
    m = re.match(r"https?://([^/]+)(/.*)?$", pat)
    if m:
        if m.group(1) not in ("fosterstack.com", "www.fosterstack.com"):
            return None
        pat = m.group(2) or "/"
    out = ""
    for tok in re.split(r"(\*|:[A-Za-z][A-Za-z0-9_]*)", pat):
        out += ".*" if tok == "*" else "[^/]+" if re.fullmatch(r":[A-Za-z][A-Za-z0-9_]*", tok) else re.escape(tok)
    return re.compile(out)


# href="..." / src='...' / href=bare, any case: every way a link can be written
LINK_RE = re.compile(r'(?<![\w-])(href|src)\s*=\s*(?:"([^"]*)"|\'([^\']*)\'|([^\s"\'>]+))', re.I)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--removed", nargs="*", default=[])
    ap.add_argument("--live", action="store_true",
                    help="the live-site rule: no page except 404.html may be hidden from search (turned on by itself for a "
                         "pull request based on main and for main)")
    ap.add_argument("--base", help="git ref of the parent commit (for example HEAD^1): pages removed since then "
                                   "must have their two 301 lines. Fails if the ref cannot be found.")
    args = ap.parse_args()
    root = args.root
    live = args.live or os.environ.get("GITHUB_BASE_REF") == "main" or os.environ.get("GITHUB_REF") == "refs/heads/main"
    problems = []
    removed_from_git = []
    if args.base:
        # fail closed: a missing parent must never quietly turn into "nothing was removed"
        shown = re.sub(r"[\x00-\x1f\x7f]", " ", args.base)
        if not re.fullmatch(r"[A-Za-z0-9_./~^@{}][A-Za-z0-9_./~^@{}-]*", args.base):
            print("FAIL base: %s is not a plain git ref" % shown)
            return 1
        ref = subprocess.run(["git", "-C", root, "rev-parse", "--verify", "--quiet", args.base + "^{commit}"],
                             capture_output=True, text=True)
        if ref.returncode != 0:
            print("FAIL base: cannot find %s, so removed pages cannot be checked "
                  "(is the checkout too shallow? it needs two commits)" % shown)
            return 1
        # --no-renames: a renamed page must show up as removed (git would call it "R"), or a rename
        # without redirects would pass
        # -z: names come back NUL-separated and unquoted (git would otherwise C-quote a name like café)
        diff = subprocess.run(["git", "-C", root, "diff", "-z", "--no-renames", "--diff-filter=D", "--name-only",
                               args.base, "HEAD", "--", "*/index.html"], capture_output=True, text=True)
        if diff.returncode != 0:
            print("FAIL base: git diff against %s failed, so removed pages cannot be checked" % shown)
            return 1
        removed_from_git = [x for x in diff.stdout.split("\0") if x]

    def bad(msg):
        # one printable line per problem: text from a pull request must never start a line with "::"
        # (GitHub Actions reads such a line as a workflow command) or smuggle in a newline
        problems.append(re.sub(r"[\x00-\x1f\x7f]", " ", msg))

    # a symlink could point a page (or its title) at a file outside the site: refuse them
    for name in sorted(os.listdir(root)):
        if name == ".git":
            continue
        for path in (os.path.join(root, name), os.path.join(root, name, "index.html")):
            if os.path.islink(path):
                bad("symlink: %s is a symbolic link (not allowed in the site)" % os.path.relpath(path, root))
    pages = [p for p in page_dirs(root)
             if not os.path.islink(os.path.join(root, p)) and not os.path.islink(os.path.join(root, p, "index.html"))]
    page_set = set(pages)
    files = {"": os.path.join(root, "index.html")}
    for p in pages:
        files[p] = os.path.join(root, p, "index.html")
    if os.path.isfile(os.path.join(root, "404.html")):
        files["404.html"] = os.path.join(root, "404.html")
    texts = {k: read(v) for k, v in files.items() if not os.path.islink(v)}
    for k, v in files.items():
        if k not in texts:
            texts[k] = ""  # a symlink was reported above; do not read through it
    ids = {k: ids_of(t) for k, t in texts.items()}

    # 6. hidden pages: found by a meta tag in the page or an X-Robots-Tag rule in _headers
    hp = os.path.join(root, "_headers")
    header_res = [r for r in (pattern_regex(x) for x in (hidden_by_headers(read(hp)) if os.path.isfile(hp) else [])) if r]
    hidden = set()
    for key, t in texts.items():
        url_path = "/" if key == "" else "/404" if key == "404.html" else "/%s/" % key
        if hidden_by_meta(t) or any(r.fullmatch(url_path) or r.fullmatch(url_path.rstrip("/") or "/") for r in header_res):
            hidden.add(key)

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
        for attr, v1, v2, v3 in LINK_RE.findall(t):
            attr = attr.lower()
            val = html.unescape(v1 or v2 or v3)
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
    sources = {src for _, src, _, code in redirects if code == "301"}
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
        want = ({SITE} if "" not in hidden else set()) | {SITE + p + "/" for p in pages if p not in hidden}
        got = set(locs)
        if len(locs) != len(got):
            bad("sitemap: has a duplicate <loc>")
        for key in sorted(hidden):
            url = SITE if key == "" else SITE + key + "/"
            if key != "404.html" and url in got:
                bad("hidden: %s is hidden from search but listed in the sitemap" % (key or "/"))
                got.discard(url)
        for u in sorted(got - want):
            bad("sitemap: lists %s but no such page exists" % u)
        for u in sorted(want - got):
            bad("sitemap: is missing %s" % u)
    if live:
        for key in sorted(hidden - {"404.html"}):
            bad("live: %s is hidden from search; on the live site only the 404 page may be" % (key or "/"))
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
    # The home page links a few guides and /guides/, which lists every guide: a page linked from /guides/ counts as linked from home.
    reachable = set(homelinks)
    if "guides" in page_set:
        if "guides" in homelinks:
            reachable |= {m for m in re.findall(r'href="/([a-z0-9-]+)/"', texts.get("guides", ""))}
        else:
            bad("home: does not link /guides/ (the page that lists every guide)")
    for p in sorted(page_set - reachable):
        bad("home: does not link /%s/ (the Guides list or another section should)" % p)

    for line in problems:
        print("FAIL " + line)
    print("%d pages checked, %d problem%s" % (len(pages) + 1, len(problems), "" if len(problems) == 1 else "s"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
