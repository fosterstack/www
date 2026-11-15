#!/usr/bin/env bash
# Self-test for bin/check-cache-links.py. A local server stands in for GitHub, so nothing leaves this machine.
# The clean site passes; each kind of dead link it promises to catch makes it fail with the matching FAIL line.
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
        if "/dead" in self.path:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.end_headers(); self.wfile.write(b'<h2 id="user-content-install">Install</h2>')
server = http.server.HTTPServer(("127.0.0.1", 0), GitHub)
open(sys.argv[1], "w").write(str(server.server_address[1]))
server.serve_forever()
PY
server=$!
for _ in $(seq 20); do [ -s "$tmp/port" ] && break; sleep 0.3; done
github="http://127.0.0.1:$(cat "$tmp/port")"

page() {   # page LINK: a site with one other page, and a home page holding the one link under test
  rm -rf "$tmp/site"; mkdir -p "$tmp/site/other"
  echo '<p>other</p>' >"$tmp/site/other/index.html"
  echo "<a href=\"$1\">link</a>" >"$tmp/site/index.html"
}
check() {   # check NAME LINK EXPECTED: EXPECTED is "pass" or the text of the FAIL line
  page "$2"
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
check "a heading missing from a cache doc" "https://github.com/fosterstack/cache/blob/main/docs/install.md#nope" "#nope, but that heading is not on the page"
check "a dead absolute link to the site" "https://fosterstack.com/new-page/" "https://fosterstack.com/new-page/, which is not a page"

[ $fail -eq 0 ] && echo "cache-links self-test: all passed"
exit $fail
