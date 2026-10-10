#!/usr/bin/env bash
# Self-test for bin/check-site-rot.py: the clean site passes, and each kind of rot it promises to catch
# makes it fail with the matching message. Works on a throwaway copy; touches nothing in the repo.
set -u
cd "$(dirname "$0")/.."
here=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
site="$tmp/site"
fail=0

fresh() { rm -rf "$site"; mkdir "$site"; tar --exclude=.git --exclude=.claude -cf - . | tar -xf - -C "$site"; }

# edit FILE OLD NEW  (first occurrence; OLD and NEW are plain text; "REGEX:" prefix on OLD means regex)
edit() {
  python3 - "$@" <<'EOF'
import re, sys
path, old, new = sys.argv[1:4]
s = open(path).read()
if old.startswith("REGEX:"):
    s2, n = re.subn(old[6:], lambda m: new, s, count=1, flags=re.S)
else:
    s2, n = s.replace(old, new, 1), s.count(old) and 1
if not n:
    sys.exit("test setup: pattern not found in " + path)
open(path, "w").write(s2)
EOF
}
append() { printf '%s\n' "$2" >>"$1"; }

expect_pass() {
  if python3 "$here/bin/check-site-rot.py" --root "$site" "${@:2}" >"$tmp/out" 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1 (expected a pass)"; sed 's/^/     /' "$tmp/out"; fail=1
  fi
}
expect_fail() { # name, pattern, [args]
  if python3 "$here/bin/check-site-rot.py" --root "$site" "${@:3}" >"$tmp/out" 2>&1; then
    echo "FAIL $1 (expected a failure, got a pass)"; fail=1
  elif grep -q "$2" "$tmp/out"; then
    echo "ok   $1"
  else
    echo "FAIL $1 (failed, but without '$2')"; sed 's/^/     /' "$tmp/out"; fail=1
  fi
}

pages=$(for d in [a-z]*/; do [ -f "$d/index.html" ] && echo "${d%/}"; done)
first=$(echo "$pages" | sed -n 1p)
second=$(echo "$pages" | sed -n 2p)

fresh; expect_pass "the clean site passes"

fresh; edit "$site/$first/index.html" "</main>" '<p><a href="/no-such-page-here/">x</a></p></main>'
expect_fail "a link to a page that does not exist" "does not exist"

fresh; edit "$site/$first/index.html" "</main>" "<p><a href=\"/$second/#no-such-id\">x</a></p></main>"
expect_fail "an #anchor that is not on the page" "id is not on the page"

fresh; append "$site/_redirects" "/old-gone-page/ /$first/ 301"
expect_fail "a redirect line without its no-slash twin" "no matching"

fresh; append "$site/_redirects" "/old-gone-page/ /$first/#no-such-id 301"; append "$site/_redirects" "/old-gone-page /$first/#no-such-id 301"
expect_fail "a redirect to an id that is not there" "is not on the page"

fresh; append "$site/_redirects" "/$second/ /$first/ 301"; append "$site/_redirects" "/$second /$first/ 301"
expect_fail "a redirect whose source is a live page" "still exists"

fresh
expect_fail "a removed page with no 301 lines" "was removed but has no 301" --removed "gone-page-xyz/index.html"

fresh; append "$site/_redirects" "/gone-page-xyz/ /$first/ 301"; append "$site/_redirects" "/gone-page-xyz /$first/ 301"
expect_pass "a removed page with both 301 lines passes" --removed "gone-page-xyz/index.html"

fresh; edit "$site/sitemap.xml" "REGEX:<url>\s*<loc>https://fosterstack\.com/$first/</loc>.*?</url>" ""
expect_fail "a page missing from the sitemap" "sitemap: is missing"

fresh; edit "$site/llms.txt" "REGEX:[^\n]*\(https://fosterstack\.com/$first/\)[^\n]*\n" ""
expect_fail "a page missing from llms.txt" "llms.txt: does not list"

fresh; python3 - "$site/index.html" "$first" <<'EOF'
import sys
p, slug = sys.argv[1:3]
s = open(p).read().replace('href="/%s/"' % slug, 'href="/"')
open(p, "w").write(s)
EOF
expect_fail "a page the home page no longer links" "home: does not link"

fresh; edit "$site/$first/index.html" "REGEX:<title>.*?</title>" "<title>This title is deliberately far too long to be a good page title for a search result</title>"
expect_fail "a title over 60 characters" "characters (max 60)"

# text from a pull request must not be able to print a line that starts with "::" (a GitHub Actions workflow command)
fresh; edit "$site/$first/index.html" "REGEX:<title>.*?</title>" "<title>padding padding padding padding padding padding padding
::error::injected line</title>"
python3 "$here/bin/check-site-rot.py" --root "$site" >"$tmp/out" 2>&1
if grep -q '^::' "$tmp/out"; then echo "FAIL output has a line starting with ::"; fail=1; else echo "ok   no output line can start with ::"; fi

# --base: removed pages are found through git, and a missing parent fails closed instead of meaning "nothing removed"
gitc() { git -C "$site" -c user.name=selftest -c user.email=selftest@example.invalid -c commit.gpgsign=false "$@"; }
fresh; git -C "$site" init -q; mkdir "$site/gone-page-xyz"; cp "$site/$first/index.html" "$site/gone-page-xyz/index.html"
gitc add -A; gitc commit -q -m "with the extra page"; rm -rf "$site/gone-page-xyz"; gitc add -A; gitc commit -q -m "page removed"
expect_fail "--base finds a removed page that has no 301 lines" "was removed but has no 301" --base HEAD^1
append "$site/_redirects" "/gone-page-xyz/ /$first/ 301"; append "$site/_redirects" "/gone-page-xyz /$first/ 301"
expect_pass "--base accepts the removed page once both 301 lines exist" --base HEAD^1
fresh; git -C "$site" init -q; gitc add -A; gitc commit -q -m "only commit"
expect_fail "--base fails closed when the parent commit is missing" "cannot find HEAD^1" --base HEAD^1
expect_fail "--base fails closed on a ref that does not exist" "cannot find no-such-ref" --base no-such-ref

[ "$fail" = 0 ] && echo "all site-rot self-tests passed" || { echo "site-rot self-test FAILED"; exit 1; }
