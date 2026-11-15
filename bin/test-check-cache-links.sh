#!/usr/bin/env bash
# Self-test for bin/check-cache-links.py. A local server stands in for GitHub, so nothing leaves this machine.
set -u
cd "$(dirname "$0")/.."
here=$PWD
tmp=$(mktemp -d)
trap 'kill "$server" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0

python3 - "$tmp/port" <<'PY' &
import http.server, sys
class GitHub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if "/dead" in self.path or "x=dead" in self.path:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.end_headers(); self.wfile.write(b'<h2 id="user-content-install" class="anchor">Install</h2>')
server = http.server.HTTPServer(("127.0.0.1", 0), GitHub)
open(sys.argv[1], "w").write(str(server.server_address[1]))
server.serve_forever()
PY
server=$!
for _ in $(seq 20); do [ -s "$tmp/port" ] && break; sleep 0.3; done
github="http://127.0.0.1:$(cat "$tmp/port")"

markup() {   # markup LINK: a link becomes an <a>; an argument that starts with "<" is a whole tag, kept as given
  case "$1" in "<"*) echo "$1" ;; *) echo "<a href=\"$1\">link</a>" ;; esac
}
page() {   # page LINK [LINK2]: a site with one other page, and a home page holding the link(s) under test
  rm -rf "$tmp/site"; mkdir -p "$tmp/site/other"
  echo '<p>other</p>' >"$tmp/site/other/index.html"
  markup "$1" >"$tmp/site/index.html"
  [ -n "${2:-}" ] && markup "$2" >>"$tmp/site/index.html"
}
check() {   # check NAME LINK EXPECTED [LINK2]: EXPECTED is "pass" or the text of the FAIL line
  page "$2" "${4:-}"
  out=$(CACHE_LINKS_RETRY_WAIT=0 python3 "$here/bin/check-cache-links.py" --root "$tmp/site" --github "$github" 2>&1); code=$?
  if [ "$3" = pass ] && [ $code -eq 0 ]; then echo "ok   $1"
  elif [ "$3" != pass ] && [ $code -ne 0 ] && grep -q "$3" <<<"$out"; then echo "ok   $1"
  else echo "FAIL $1 (exit $code)"; sed 's/^/     /' <<<"$out"; fail=1; fi
}

check "a live cache doc link" "https://github.com/fosterstack/cache/blob/main/docs/install.md" pass
check "a cache doc link with its heading" "https://github.com/fosterstack/cache/blob/main/docs/install.md#install" pass
check "an absolute link to a page of the site" "https://fosterstack.com/other/" pass
check "a link to another site is not checked" "https://example.com/dead" pass
check "a dead cache doc link" "https://github.com/fosterstack/cache/blob/main/docs/dead.md" "docs/dead.md, which answered 404"
check "a dead mixed-case cache doc link" "https://github.com/FosterStack/Cache/blob/main/docs/dead.md" "which answered 404"
check "a heading missing from a cache doc" "https://github.com/fosterstack/cache/blob/main/docs/install.md#nope" "#nope, but that heading is not on the page"
check "a dead absolute link to the site" "https://fosterstack.com/new-page/" "https://fosterstack.com/new-page/, which is not a page"
check "a dead canonical link to the site, in a tag other than <a>" '<link rel="canonical" href="https://fosterstack.com/new-page/">' "which is not a page"

# A newline hidden in an href as an entity must not let the link start a workflow command in the output.
page 'https://fosterstack.com/nope&#10;::warning::x'
out=$(CACHE_LINKS_RETRY_WAIT=0 python3 "$here/bin/check-cache-links.py" --root "$tmp/site" --github "$github" 2>&1); code=$?
if [ $code -ne 0 ] && ! grep -q '^::' <<<"$out"; then echo "ok   a newline in a link cannot start a workflow command"
else echo "FAIL a newline in a link cannot start a workflow command (exit $code)"; sed 's/^/     /' <<<"$out"; fail=1; fi

check "an encoded heading that is on the page" "https://github.com/fosterstack/cache/blob/main/docs/install.md#%69nstall" pass
check "an encoded heading missing from the page" "https://github.com/fosterstack/cache/blob/main/docs/install.md#%6eope" "but that heading is not on the page"
check "an encoded fragment that spans two attributes" "https://github.com/fosterstack/cache/blob/main/docs/install.md#install%22%20class=%22anchor" "but that heading is not on the page"
check "a dead query on a live path" "https://github.com/fosterstack/cache/blob/main/docs/install.md?x=dead" "which answered 404"
check "links that differ only by query are both checked" "https://github.com/fosterstack/cache/blob/main/docs/install.md" "which answered 404" "https://github.com/fosterstack/cache/blob/main/docs/install.md?x=dead"
check "a live http cache doc link" "http://github.com/fosterstack/cache/blob/main/docs/install.md" pass
check "a dead http cache doc link" "http://github.com/fosterstack/cache/blob/main/docs/dead.md" "docs/dead.md, which answered 404"
check "a dead protocol-relative cache doc link" "//github.com/fosterstack/cache/blob/main/docs/dead.md" "docs/dead.md, which answered 404"
check "a live http link to the site" "http://fosterstack.com/other/" pass
check "a dead http link to the site" "http://fosterstack.com/new-page/" "//fosterstack.com/new-page/, which is not a page"
check "a dead protocol-relative link to the site" "//fosterstack.com/new-page/" "//fosterstack.com/new-page/, which is not a page"
check "an http link to another site is not checked" "http://example.com/dead" pass
check "a protocol-relative link to another site is not checked" "//example.com/dead" pass

[ $fail -eq 0 ] && echo "cache-links self-test: all passed"
exit $fail
