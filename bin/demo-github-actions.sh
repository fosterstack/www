#!/usr/bin/env bash
# Proof for the page /github-actions-remote-build-cache/: the Gradle settings that read the cache URL, login and push switch
# from ENVIRONMENT VARIABLES (what GitHub Actions secrets become) work against a FosterStack Cache server.
# Run by the "demo-github-actions" job of .github/workflows/hygiene.yml (manual dispatch only).
#
# IMPORTANT: the cache server is started on the SAME runner, on 127.0.0.1, with FAKE logins made up in this script.
# So this proves the settings and the environment-variable mechanism. It does NOT prove that a GitHub-hosted runner can reach
# your own server: that needs an address the runner can reach.
#
# Steps (each build: a freshly written project, a new empty Gradle home, no daemon):
#   1  CI build, read-write login, push on        -> both compile tasks run and are stored
#   2  CI build again from a fresh checkout       -> both compile tasks come from the cache
#   3  pull-request build, read-only login, push off, app source changed -> lib from the cache, app runs, nothing stored
#   4  fork-style build: the variables exist but are EMPTY, as secrets are on a fork pull request -> builds without the cache, nothing stored
# The script stops with an error if any step does something else.
set -euo pipefail

FS_VER="${BENCH_VER:-0.2.1}"   # the release the page names; a proof run can pass another one
[[ "$FS_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad release version: $FS_VER" >&2; exit 2; }
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf   # services.gradle.org/distributions/gradle-9.8.0-all.zip.sha256
PORT="${DEMO_PORT:-18495}"
CI_USER=ci; CI_PASS=fake-ci-secret; DEV_USER=dev; DEV_PASS=fake-dev-secret   # made up for this run; not real secrets
WORK="$(mktemp -d)"
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"; true' EXIT
cd "$WORK"

sha_check() { # file expected
  local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1)"
  [ "$got" = "$2" ] || { echo "CHECKSUM MISMATCH for $1: $got" >&2; exit 1; }
}

COSIGN_VER=3.1.3
COSIGN_SHA=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71   # cosign-linux-amd64 v3.1.3 (the same pin as the other bench scripts)
fetch_release_tarball() { # the release's own checksums.txt, verified with cosign, gives the tarball's sha256: no per-version checksum is kept in this file
  mkdir -p rel
  ( cd rel
    gh release download "v${FS_VER}" --repo fosterstack/cache -p checksums.txt -p checksums.txt.bundle -p "fscache_${FS_VER}_linux_amd64.tar.gz" || exit 1
    curl -fsSL -o cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VER}/cosign-linux-amd64" || exit 1
    sha_check cosign "$COSIGN_SHA"; chmod +x cosign
    ./cosign verify-blob --bundle checksums.txt.bundle --certificate-identity-regexp='^https://github.com/fosterstack/cache/' --certificate-oidc-issuer='https://token.actions.githubusercontent.com' checksums.txt || exit 1
    want="$(grep -E "^[0-9a-f]{64}  fscache_${FS_VER}_linux_amd64\.tar\.gz\$" checksums.txt | cut -d' ' -f1)"
    [ -n "$want" ] && [ "$(printf '%s\n' "$want" | wc -l | tr -d ' ')" = 1 ] || { echo "no single checksum line for the tarball in checksums.txt" >&2; exit 1; }
    sha_check "fscache_${FS_VER}_linux_amd64.tar.gz" "$want" ) || exit 1
  cp "rel/fscache_${FS_VER}_linux_amd64.tar.gz" fs.tgz
}

# ---- tools (DEMO_FSCACHE_BIN / DEMO_GRADLE_BIN let a developer test the script locally without downloads)
if [ -n "${DEMO_FSCACHE_BIN:-}" ]; then FSCACHE="$DEMO_FSCACHE_BIN"; else
  fetch_release_tarball; mkdir fs && tar -xzf fs.tgz -C fs; FSCACHE="$WORK/fs/fscache"
fi
if [ -n "${DEMO_GRADLE_BIN:-}" ]; then GRADLE="$DEMO_GRADLE_BIN"; else
  curl -fsSL "$GR_URL" -o gr.zip; sha_check gr.zip "$GR_SHA"; unzip -q gr.zip; GRADLE="$WORK/gradle-${GR_VER}/bin/gradle"
fi
JAVA_HOME="${DEMO_JAVA_HOME:-${JAVA_HOME_21_X64:-${JAVA_HOME:-}}}"; export JAVA_HOME
[ -x "$JAVA_HOME/bin/java" ] || { echo "no usable Java (JAVA_HOME=$JAVA_HOME)" >&2; exit 1; }

# ---- disclosure
echo "== runner"; uname -sr; echo "cpus (nproc): $(nproc 2>/dev/null || sysctl -n hw.ncpu)"
echo "image: ${ImageOS:-?} ${ImageVersion:-?}   runner: ${RUNNER_NAME:-?} (${RUNNER_ENVIRONMENT:-?})"
echo "java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
if [ -n "${DEMO_FSCACHE_BIN:-}${DEMO_GRADLE_BIN:-}" ]; then echo "tools: LOCAL OVERRIDES in use, downloads not checked"; else echo "gradle: ${GR_VER} (distribution checked against pinned sha256)   fscache: v${FS_VER} (checked against checksums.txt value)"; fi
echo "server: FosterStack Cache on 127.0.0.1:${PORT} on THIS machine, with made-up logins (not a test that a hosted runner can reach your server)"

# ---- the project: the settings.gradle.kts below is the same text as on the page
mkproj() { # dir variant(base|changed)
  mkdir -p "$1/lib/src/main/java/demo/lib" "$1/app/src/main/java/demo/app"
  cat > "$1/settings.gradle.kts" <<'EOT'
rootProject.name = "demo"
include(":lib", ":app")

buildCache {
    remote<HttpBuildCache> {
        val cacheUrl = providers.environmentVariable("CACHE_URL").orNull
        isEnabled = !cacheUrl.isNullOrBlank()
        if (!cacheUrl.isNullOrBlank()) {
            url = uri(cacheUrl)
        }
        isPush = providers.environmentVariable("CACHE_PUSH").orNull == "true"
        credentials {
            username = providers.environmentVariable("CACHE_USER").orNull
            password = providers.environmentVariable("CACHE_PASSWORD").orNull
        }
    }
}
EOT
  echo 'org.gradle.caching=true' > "$1/gradle.properties"
  : > "$1/build.gradle.kts"
  printf 'plugins { `java-library` }\n' > "$1/lib/build.gradle.kts"
  printf 'plugins { `java-library` }\n\ndependencies {\n    implementation(project(":lib"))\n}\n' > "$1/app/build.gradle.kts"
  printf 'package demo.lib;\n\npublic class Lib {\n    public String name() { return "lib"; }\n}\n' > "$1/lib/src/main/java/demo/lib/Lib.java"
  local greeting="hello "; [ "$2" = changed ] && greeting="hello again "
  printf 'package demo.app;\n\nimport demo.lib.Lib;\n\npublic class App {\n    public String hello() { return "%s" + new Lib().name(); }\n}\n' "$greeting" > "$1/app/src/main/java/demo/app/App.java"
}

entries() { find "$WORK/data/blobs" -type f 2>/dev/null | wc -l | tr -d ' '; }
task_state() { # logfile task -> FROM-CACHE | ran | not-run
  local l; l="$(grep -F "> Task $2" "$1" | head -1 || true)"
  case "$l" in *FROM-CACHE*) echo FROM-CACHE;; "") echo not-run;; *) echo ran;; esac
}

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "| step | build | :lib:compileJava | :app:compileJava | entries on the server before -> after |" >> "$SUMMARY"
echo "|---|---|---|---|---|" >> "$SUMMARY"

# run NAME VARIANT VAR=value ...   (the variables are passed exactly as a workflow `env:` block passes them)
run() {
  local n="$1" variant="$2"; shift 2
  mkproj "$WORK/p-$n" "$variant"
  local before; before="$(entries)"
  ( cd "$WORK/p-$n" && env "$@" GRADLE_USER_HOME="$WORK/gh-$n" "$GRADLE" :lib:compileJava :app:compileJava --console=plain --no-daemon > "$WORK/log-$n.txt" 2>&1 ) || { cat "$WORK/log-$n.txt"; echo "step $n: BUILD FAILED" >&2; exit 1; }
  grep -q 'BUILD SUCCESSFUL' "$WORK/log-$n.txt" || { cat "$WORK/log-$n.txt"; exit 1; }
  RES_LIB="$(task_state "$WORK/log-$n.txt" :lib:compileJava)"; RES_APP="$(task_state "$WORK/log-$n.txt" :app:compileJava)"; RES_BEFORE="$before"; RES_AFTER="$(entries)"
  printf '%-34s lib: %-11s app: %-11s entries %s -> %s\n' "$n" "$RES_LIB" "$RES_APP" "$RES_BEFORE" "$RES_AFTER"
  echo "| $n | BUILD SUCCESSFUL | $RES_LIB | $RES_APP | $RES_BEFORE -> $RES_AFTER |" >> "$SUMMARY"
  rm -rf "$WORK/gh-$n"
}
expect() { # description condition...
  local d="$1"; shift
  "$@" || { echo "UNEXPECTED: $d" >&2; echo "**UNEXPECTED: $d**" >> "$SUMMARY"; exit 1; }
}

# ---- server
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/healthz" || true)" = "200" ] && { echo "port $PORT is already in use" >&2; exit 1; }
FSCACHE_ADDR="127.0.0.1:$PORT" FSCACHE_DATA_DIR="$WORK/data" FSCACHE_USERNAME="$CI_USER" FSCACHE_PASSWORD="$CI_PASS" \
  FSCACHE_RO_USERNAME="$DEV_USER" FSCACHE_RO_PASSWORD="$DEV_PASS" "$FSCACHE" > "$WORK/server.log" 2>&1 & SRV_PID=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null || { echo "server did not start" >&2; exit 1; }
kill -0 "$SRV_PID" 2>/dev/null || { echo "the server we started has exited; something else is answering on port $PORT" >&2; exit 1; }
URL="http://127.0.0.1:$PORT/"

echo "== steps"
run 1-ci-push base CACHE_URL="$URL" CACHE_USER="$CI_USER" CACHE_PASSWORD="$CI_PASS" CACHE_PUSH=true
expect "step 1 should run both tasks and store entries" test "$RES_LIB" = ran -a "$RES_APP" = ran -a "$RES_AFTER" -gt "$RES_BEFORE"
run 2-ci-fresh-checkout base CACHE_URL="$URL" CACHE_USER="$CI_USER" CACHE_PASSWORD="$CI_PASS" CACHE_PUSH=true
expect "step 2 should restore both tasks" test "$RES_LIB" = FROM-CACHE -a "$RES_APP" = FROM-CACHE
run 3-pull-request-read-only changed CACHE_URL="$URL" CACHE_USER="$DEV_USER" CACHE_PASSWORD="$DEV_PASS" CACHE_PUSH=false
expect "step 3 should restore lib, run app, store nothing" test "$RES_LIB" = FROM-CACHE -a "$RES_APP" = ran -a "$RES_AFTER" = "$RES_BEFORE"
# the read-only login really cannot write: a direct write with it is refused (403), and a wrong password is refused (401)
RO_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data x -u "$DEV_USER:$DEV_PASS" "${URL}cache/probe" || true)"
BAD_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data x -u "$DEV_USER:wrong-password" "${URL}cache/probe" || true)"
expect "a direct write with the read-only login should be refused (403), got $RO_CODE" test "$RO_CODE" = 403
expect "a direct write with a wrong password should be refused (401), got $BAD_CODE" test "$BAD_CODE" = 401
echo "| 3b | direct write with the read-only login: HTTP $RO_CODE; with a wrong password: HTTP $BAD_CODE | | | |" >> "$SUMMARY"
run 4-fork-style-empty-variables changed CACHE_URL= CACHE_USER= CACHE_PASSWORD= CACHE_PUSH=
expect "step 4 should build without the cache and store nothing" test "$RES_LIB" = ran -a "$RES_APP" = ran -a "$RES_AFTER" = "$RES_BEFORE"

{
  echo
  echo "The server ran on the same runner with made-up logins. This shows the settings and the environment variables work; it does not show that a GitHub-hosted runner can reach your own server."
} >> "$SUMMARY"
echo "all four steps behaved as expected"
