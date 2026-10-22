#!/usr/bin/env bash
# Self-test for bin/live-check.py. Serves a throwaway copy of the site from a local web server (and a second one standing in
# for GitHub), so nothing leaves this machine. Each kind of live problem it promises to catch makes it fail with the matching
# FAIL line; the clean copy passes.
set -u
cd "$(dirname "$0")/.."
here=$PWD
tmp=$(mktemp -d) || { echo "live-check self-test: cannot make a temporary directory"; exit 1; }
[ -n "$tmp" ] && [ -d "$tmp" ] || { echo "live-check self-test: no temporary directory"; exit 1; }
pids=()
cleanup() { for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0

site="$tmp/site"; served="$tmp/served"; gh="$tmp/gh"
fresh() { rm -rf "$site" "$served"; mkdir "$site"; tar --exclude=.git --exclude=.claude -cf - . | tar -xf - -C "$site"; cp -R "$site" "$served"; }
# two throwaway servers: the served copy (live) and a fake GitHub
python3 - "$tmp" <<'PY' &
import http.server, os, socketserver, sys, threading
tmp = sys.argv[1]
class Live(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=os.path.join(tmp, "served"), **k)
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/redir-"):
            self.send_response(301); self.send_header("Location", "/"); self.end_headers(); return
        if self.path.startswith("/slow-"):
            import time; time.sleep(60)
        return super().do_GET()
class GH(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        n = self.path.split("/")[-1]
        if self.path.endswith("/security/advisories/new"):
            self.send_response(302); self.send_header("Location", "/login"); self.end_headers(); return
        if "/dead/" in self.path:
            self.send_response(404); self.end_headers(); return
        for name, code in (("flaky", 503), ("flaky403", 403), ("flaky404", 404), ("flaky302", 302)):
            if "/%s/" % name in self.path:
                flag = os.path.join(tmp, name + "-seen")
                if not os.path.exists(flag):
                    open(flag, "w").close(); self.send_response(code)
                    if code == 302: self.send_header("Location", "/elsewhere")
                    self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
def serve(h, portfile):
    s = socketserver.ThreadingTCPServer(("127.0.0.1", 0), h); s.daemon_threads = True
    open(portfile, "w").write(str(s.server_address[1])); s.serve_forever()
threading.Thread(target=serve, args=(GH, os.path.join(tmp, "gh.port")), daemon=True).start()
serve(Live, os.path.join(tmp, "live.port"))
PY
pids+=($!)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$tmp/live.port" ] && [ -s "$tmp/gh.port" ] && break; sleep 0.3; done
live="http://127.0.0.1:$(cat "$tmp/live.port")"; ghurl="http://127.0.0.1:$(cat "$tmp/gh.port")"

run() { LIVE_CHECK_TIMEOUT=${T:-3} LIVE_CHECK_RETRY_WAIT=0 python3 "$here/bin/live-check.py" --root "$site" --base "$live" --github "$ghurl" "$@" >"$tmp/out" 2>&1; }
expect_pass() { if run; then echo "ok   $1"; else echo "FAIL $1 (expected a pass)"; sed 's/^/     /' "$tmp/out" | head -8; fail=1; fi; }
expect_fail() { if run; then echo "FAIL $1 (expected a failure, got a pass)"; fail=1; elif grep -q "$2" "$tmp/out"; then echo "ok   $1"; else echo "FAIL $1 (failed, but without '$2')"; sed 's/^/     /' "$tmp/out" | head -8; fail=1; fi; }
pages=$(for d in [a-z]*/; do [ -f "$d/index.html" ] && echo "${d%/}"; done)
first=$(echo "$pages" | sed -n 1p)
second=$(echo "$pages" | sed -n 2p)

fresh; expect_pass "a live copy equal to the repository passes"
fresh; rm -rf "$served/$first"
expect_fail "a page in the live sitemap that answers 404 is reported" "FAIL page: .*$first"
fresh; echo "<!-- drift -->" >> "$served/$second/index.html"
expect_fail "a live page that differs from the repository is reported" "FAIL drift: .*$second"
fresh; echo " " >> "$served/sitemap.xml"
expect_fail "a live sitemap that differs from the repository is reported" "FAIL drift: .*sitemap.xml"
fresh; rm "$served/llms.txt"
expect_fail "a missing live llms.txt is reported" "FAIL .*llms.txt"
# the sitemap list comes from the live site, not the repository: a page only the live sitemap names is fetched
fresh; python3 - "$served/sitemap.xml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("</urlset>", "<url><loc>https://fosterstack.com/only-live-xyz/</loc></url></urlset>"))
PY
expect_fail "a page only the live sitemap lists is fetched and reported" "only-live-xyz"
# links on the live pages
fresh; python3 - "$served/$first/index.html" "$site/$first/index.html" <<'PY'
import sys
for p in sys.argv[1:]:
    s = open(p).read(); open(p, "w").write(s.replace("</main>", '<p><a href="https://github.com/fosterstack/dead/x">x</a></p></main>', 1))
PY
expect_fail "a dead GitHub link on a live page is reported" "FAIL link: .*dead"
fresh; python3 - "$served/$first/index.html" "$site/$first/index.html" <<'PY'
import sys
for p in sys.argv[1:]:
    s = open(p).read(); open(p, "w").write(s.replace("</main>", '<p><a href="https://github.com/fosterstack/cache/security/advisories/new">x</a> <a href="https://github.com/fosterstack/flaky/x">y</a></p></main>', 1))
PY
rm -f "$tmp"/flaky*-seen
expect_pass "the advisory form redirect is fine, and one flaky answer is retried once"
fresh; python3 - "$served/$first/index.html" "$site/$first/index.html" <<'PY'
import sys
for p in sys.argv[1:]:
    s = open(p).read(); open(p, "w").write(s.replace("</main>", '<p><a href="/no-such-live-page/">x</a></p></main>', 1))
PY
expect_fail "an internal link that answers 404 on the live site is reported" "FAIL link: .*no-such-live-page"
# a stuck server is cut off by the fixed timeout; the run says so and ends
fresh; python3 - "$served/sitemap.xml" "$site/sitemap.xml" <<'PY'
import sys
for p in sys.argv[1:]:
    s = open(p).read(); open(p, "w").write(s.replace("</urlset>", "<url><loc>https://fosterstack.com/slow-page/</loc></url></urlset>"))
PY
T=1 expect_fail "a page that never answers is cut off by the timeout" "FAIL page: .*slow-page"
# only the site's own host is fetched: a sitemap entry for another host is refused, not fetched
fresh; python3 - "$served/sitemap.xml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("</urlset>", "<url><loc>https://example.org/x/</loc></url></urlset>"))
PY
expect_fail "a live sitemap entry for another host is refused" "FAIL sitemap: .*example.org"
# one retry for EVERY answer that is not acceptable: a flaky 403, 404 or redirect is tried again, a steady one is reported
fresh; python3 - "$served/$first/index.html" "$site/$first/index.html" <<'PY'
import sys
for p in sys.argv[1:]:
    s = open(p).read(); open(p, "w").write(s.replace("</main>", '<p><a href="https://github.com/fosterstack/flaky403/x">a</a> <a href="https://github.com/fosterstack/flaky404/x">b</a> <a href="https://github.com/fosterstack/flaky302/x">c</a></p></main>', 1))
PY
rm -f "$tmp"/flaky*-seen
expect_pass "a 403, a 404 and a redirect that are fine on the second try do not fail the run"
# every way a link is written is read, and links are resolved against their page
for link in "<a href='https://github.com/fosterstack/dead/x'>x</a>" "<a href=https://github.com/fosterstack/dead/x>x</a>" "<A HREF=\"https://github.com/fosterstack/dead/x\">x</A>"; do
  fresh; python3 - "$served/$first/index.html" "$site/$first/index.html" "$link" <<'PY'
import sys
for p in sys.argv[1:3]:
    s = open(p).read(); open(p, "w").write(s.replace("</main>", "<p>" + sys.argv[3] + "</p></main>", 1))
PY
  expect_fail "a link written as $link is checked" "FAIL link: .*dead"
done
fresh; python3 - "$served/$first/index.html" "$site/$first/index.html" <<'PY'
import sys
for p in sys.argv[1:]:
    s = open(p).read(); open(p, "w").write(s.replace("</main>", '<p><a href="../no-such-relative-xyz/">x</a> <a href="https://fosterstack.com/no-such-absolute-xyz/">y</a></p></main>', 1))
PY
expect_fail "a relative link is resolved against its page" "FAIL link: .*no-such-relative-xyz"
expect_fail "an absolute link to the site itself is checked" "FAIL link: .*no-such-absolute-xyz"
# a sitemap entry can never make the check read a file outside the checkout
for loc in "https://fosterstack.com//etc/hosts" "https://fosterstack.com/../../etc/hosts" "https://fosterstack.com/a/../../x/"; do
  fresh; python3 - "$served/sitemap.xml" "$loc" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("</urlset>", "<url><loc>" + sys.argv[2] + "</loc></url></urlset>"))
PY
  expect_fail "a sitemap entry $loc is refused" "FAIL sitemap: .*$(printf '%s' "$loc" | sed 's/[.]/./g' | cut -c1-30)"
done
# a page that redirects, robots.txt that drifts, and control characters never reach the output
fresh; printf 'x' >> "$served/robots.txt"
expect_fail "a live robots.txt that differs from main is reported" "FAIL drift: .*robots.txt"
fresh; python3 - "$served/sitemap.xml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("</urlset>", "<url><loc>https://fosterstack.com/bad\x9b[31mpage/</loc></url></urlset>"))
PY
run || true
python3 -c "import sys; d=open(sys.argv[1],encoding='utf-8',errors='replace').read(); sys.exit(0 if 'FAIL' in d and not any(0x80<=ord(c)<=0x9f or (ord(c)<32 and c!=chr(10)) for c in d) else 1)" "$tmp/out" && echo "ok   control characters from the live site are not printed" || { echo "FAIL control characters reached the output"; fail=1; }
# a page that redirects (a steady 301) is a failure, a link with another scheme, port, credentials or an upper-case host is still read
fresh; python3 - "$served/sitemap.xml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("</urlset>", "<url><loc>https://fosterstack.com/redir-page/</loc></url></urlset>"))
PY
expect_fail "a page that keeps redirecting is reported" "FAIL page: .*redir-page.* 301"
for link in '<a href="http://github.com/fosterstack/dead/x">x</a>' '<a href="https://GITHUB.COM/fosterstack/dead/x">x</a>' '<a href="https://user@github.com/fosterstack/dead/x">x</a>' '<a href="https://github.com:8443/fosterstack/dead/x">x</a>' '<a href="HTTPS://Github.Com/fosterstack/dead/x">x</a>'; do
  fresh; python3 - "$served/$first/index.html" "$site/$first/index.html" "$link" <<'PY'
import sys
for p in sys.argv[1:3]:
    s = open(p).read(); open(p, "w").write(s.replace("</main>", "<p>" + sys.argv[3] + "</p></main>", 1))
PY
  expect_fail "$link is not skipped" "FAIL link: "
done
# a sitemap entry with a trailing control character is refused, not trimmed into a real page
for tail in '&#9;' '&#31;'; do
  fresh; python3 - "$served/sitemap.xml" "$first" "$tail" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("</urlset>", "<url><loc>https://fosterstack.com/" + sys.argv[2] + "/" + sys.argv[3] + "</loc></url></urlset>"))
PY
  expect_fail "a sitemap entry ending in $tail is refused" "FAIL sitemap: .*not a plain path"
done
# a literal CR or LF around a sitemap entry is refused too (never trimmed into a real page), and neither a fetch nor a file read happens
for tail in $'\n' $'\r'; do
  fresh; python3 - "$served/sitemap.xml" "$first" "$tail" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w", newline="").write(s.replace("</urlset>", "<url><loc>https://fosterstack.com/" + sys.argv[2] + "/" + sys.argv[3] + "</loc></url></urlset>"))
PY
  expect_fail "a sitemap entry with a literal CR or LF at its end is refused" "FAIL sitemap: .*control character"
done
# the bare host only: an explicit :443, an empty user, a bad port and a bad address are failures, and the run goes on to print them
for link in '<a href="https://fosterstack.com:443/x/">x</a>' '<a href="https://@fosterstack.com/x/">x</a>' '<a href="https://github.com:443/fosterstack/cache">x</a>' '<a href="https://@github.com/fosterstack/cache">x</a>' '<a href="https://github.com:bad/fosterstack/cache">x</a>' '<a href="https://github.com:65536/fosterstack/cache">x</a>' '<a href="https://[github.com/fosterstack/cache">x</a>'; do
  fresh; python3 - "$served/$first/index.html" "$site/$first/index.html" "$link" <<'PY'
import sys
for p in sys.argv[1:3]:
    s = open(p).read(); open(p, "w").write(s.replace("</main>", "<p>" + sys.argv[3] + "</p></main>", 1))
PY
  expect_fail "$link is a plain-link failure, not a crash" "FAIL link: "
  grep -q "live pages checked" "$tmp/out" || { echo "FAIL the run ended without its summary line for $link"; fail=1; }
done
# an empty live sitemap is a failure, not a green run over nothing
fresh; : > "$served/sitemap.xml"
expect_fail "an empty live sitemap is refused" "FAIL sitemap: .*no page"

# proof-report, with a stand-in gh that records what it is asked to do (no network)
mkdir "$tmp/fakebin"
cat >"$tmp/fakebin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_LOG"
case "$*" in
  *"/jobs?"*) cat "$FAKE_JOBS" ;;
  *"/logs"*) echo "2026-10-22T05:00:00Z FAIL live: https://fosterstack.com/x/ answered 404" ;;
  "issue list"*) printf '%s' "${FAKE_OPEN:-}" ;;
  *) : ;;
esac
exit 0
GH
chmod +x "$tmp/fakebin/gh"
report() { # name, jobs-json, open-issue, TAG, WATCH_RUN
  rm -f "$tmp/proven.txt" "$tmp/fake.log"; printf '%s' "$2" >"$tmp/jobs.json"
  PATH="$tmp/fakebin:$PATH" FAKE_LOG="$tmp/fake.log" FAKE_JOBS="$tmp/jobs.json" FAKE_OPEN="$3" GH_TOKEN=x GITHUB_REPOSITORY=o/r RUN_ID=1 RUN_URL=http://x \
    TAG="$4" WATCH_RUN="$5" WATCH_REASON="" MODE=schedule OUT_FILE="$tmp/proven.txt" bash bin/proof-report.sh >"$tmp/rep.out" 2>&1
}
okrun='{"jobs":[{"id":1,"name":"proof-watch","conclusion":"success","status":"completed","steps":[]},{"id":3,"name":"bench-miss-cost","conclusion":"success","status":"completed","steps":[]}]}'
ok='{"jobs":[{"id":1,"name":"proof-watch","conclusion":"success","status":"completed","steps":[]},{"id":2,"name":"live-check","conclusion":"success","status":"completed","steps":[]},{"id":3,"name":"bench-miss-cost","conclusion":"skipped","status":"completed","steps":[]}]}'
bad='{"jobs":[{"id":2,"name":"live-check","conclusion":"failure","status":"completed","steps":[{"name":"the live site against main, and every link on it","conclusion":"failure"}]},{"id":3,"name":"bench-miss-cost","conclusion":"skipped","status":"completed","steps":[]}]}'
chk2() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; sed 's/^/     /' "$tmp/rep.out" "$tmp/fake.log" 2>/dev/null | head -6; fail=1; fi; }
report a "$ok" "" "" false
chk2 "report: a day with only the live check, all green, opens nothing and writes no proven-release file" "[ ! -e $tmp/proven.txt ] && ! grep -q 'issue create' $tmp/fake.log"
report b "$bad" "" "" false
chk2 "report: a failed live-check opens the one issue, naming the job, and writes no proven-release file" "grep -q 'issue create' $tmp/fake.log && grep -q 'live-check' $tmp/fake.log && [ ! -e $tmp/proven.txt ]"
report c "$bad" "7" "" false
chk2 "report: a failed live-check with an open issue comments on it, no second issue" "grep -q 'issue comment 7' $tmp/fake.log && ! grep -q 'issue create' $tmp/fake.log"
report d "$ok" "7" "" false
chk2 "report: a green day closes the open issue" "grep -q 'issue close 7' $tmp/fake.log"
report e "$okrun" "" "v0.2.2" true
chk2 "report: a green proof run with a release writes the proven-release file" "[ -s $tmp/proven.txt ]"
report f "$ok" "" "" true
chk2 "report: a proof run that skipped a bench job proved nothing for it" "grep -q 'issue create' $tmp/fake.log && [ ! -e $tmp/proven.txt ]"

# the workflow is wired as promised (static reads of .github/workflows/hygiene.yml)
wf=.github/workflows/hygiene.yml
chk() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
chk "the live-check job checks out main, whatever branch a manual run starts on" "awk '/^  live-check:/{f=1} f&&/ref: main/{r=1} /^  # Timed runs/{f=0} END{exit !r}' $wf"
chk "issues: write is on exactly one job (proof-report)" "[ \$(grep -v '^\\s*#' $wf | grep -c 'issues: write') = 1 ] && awk '/^  proof-report:/{f=1} f&&/issues: write/{r=1} END{exit !r}' $wf"
chk "the live-check job has exactly contents: read, and no write permission" "awk '/^  live-check:/{f=1} f&&/^    permissions:/{p=1;next} f&&p&&/^      [a-z-]+:/{n++; if (\$0 !~ /contents: read/) bad=1} f&&p&&!/^      /{p=0} /^  # Timed runs/{f=0} END{exit (bad||n!=1)}' $wf"
chk "the live-check job runs only on the schedule or a manual which=live-check" "awk '/^  live-check:/{f=1;next} f&&/^    if:/{print; exit}' $wf | grep -q \"github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && inputs.which == 'live-check')\$\""
chk "a manual live-check run is reported under the schedule mode, not the self-test mode" "grep -q \"MODE: \\\${{ (github.event_name == 'schedule' || inputs.which == 'live-check') && 'schedule' || 'selftest' }}\" $wf"
chk "every uses: line is a full commit digest with a tag comment" "! grep -E '^\s*-?\s*uses:' $wf | grep -v -E 'uses: [^ ]+@[0-9a-f]{40} # v?[0-9]' | grep -q ."
chk "a manual live-check run is reported (the report job's condition names it)" "awk '/^  proof-report:/{f=1} f&&/which == .live-check./{r=1} END{exit !r}' $wf"
chk "the report's TAG is empty unless the proof watch decided to run" "grep -q \"TAG: \\\${{ needs.proof-watch.outputs.run == 'true' && needs.proof-watch.outputs.tag || '' }}\" $wf"
chk "the sitemap is fetched once: the page list and the comparison with main use the same answer" "[ \$(grep -c 'fetch(base + \"/sitemap.xml\")' bin/live-check.py) = 1 ] && grep -q 'sitemap_body' bin/live-check.py"
chk "no new workflow file: hygiene.yml is the only one" "[ \"\$(ls .github/workflows)\" = hygiene.yml ]"

[ "$fail" = 0 ] && echo "all live-check self-tests passed" || { echo "live-check self-test FAILED"; exit 1; }
