#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 7: do the commands and promised outputs of these pages really happen?
#   V  /is-the-build-cache-server-healthy-what-to-alert-on/   the rows of the page's "How we checked" table: a healthy server, a stopped one, a
#                                                             restart on the same data, a read-only or deleted data folder (while running and at
#                                                             start), a tiny size cap, logins on; the metric names; the two rules checked on live /metrics values
#   T  /build-cache-eviction-size-limit/                      a 3,500-byte cap with five 1,000-byte entries, an entry bigger than the cap, and a
#                                                             real full disk (an 8 MiB tmpfs volume): uploads, builds, recovery, starts, caps
# Run by the "bench-howto-pages-7" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-7"). Same method as the other
# bench scripts: the page's commands word for word, every output line the page promises asserted; a step that fails or prints something else is
# RECORDED (FAIL) and fails the job at the end; the rest are OBS lines. The full-disk volume is a tmpfs mounted with sudo (a runner has
# passwordless sudo); where that is not possible the full-disk part is skipped and said so.
#
# No token and no secret. Gradle and cosign are downloaded and checked against pinned checksums; the release binary is verified (cosign + sha256)
# before it runs.
set -uo pipefail

VER="${BENCH_VER:-0.2.2}"   # the release the pages name; a scheduled proof run passes the newest release tag (checked by the workflow, and again here)
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad release version: $VER" >&2; exit 2; }
LOCAL="${BENCH_LOCAL:-0}"                    # 1 = a developer's dry run with local tools (nothing downloaded or checked: do not quote times)
if [ "$LOCAL" = 1 ]; then PLATFORM="${BENCH_PLATFORM:-darwin_arm64}"; else PLATFORM=linux_amd64; fi
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
EXT_VER=1.2.3
IMG=ghcr.io/fosterstack/cache
COSIGN_VER=3.1.3
COSIGN_SHA=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71

FAILS=0
now() { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }
fail() { FAILS=$((FAILS+1)); printf 'FAIL %s\n' "$*"; }
sha512_check() { echo "$2  $1" | { sha512sum -c - 2>/dev/null || shasum -a 512 -c - ; } >/dev/null || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }; }
sha_check() { # file sha256
  if command -v sha256sum >/dev/null 2>&1; then echo "$2  $1" | sha256sum -c - >/dev/null || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }
  else echo "$2  $1" | shasum -a 256 -c - >/dev/null || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }; fi
}

if [ -n "${BENCH_WORK:-}" ]; then W="$BENCH_WORK"; mkdir -p "$W"; else W="$(mktemp -d)"; fi
: "${W:?}"
SERVER_PID=""; SERVER_PORT=""
stop_server() {
  local i
  if [ -n "$SERVER_PID" ]; then
    pkill -P "$SERVER_PID" 2>/dev/null; kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
    for i in $(seq 1 100); do curl -sf --max-time 5 "localhost:${SERVER_PORT}/healthz" >/dev/null 2>&1 || break; sleep 0.1; done
    curl -sf --max-time 5 "localhost:${SERVER_PORT}/healthz" >/dev/null 2>&1 && fail "the server on port ${SERVER_PORT} did not stop"
  fi
}
COMPOSE_PROJECTS=""; CONTAINERS=""
cleanup_docker() {
  local p c
  for p in $COMPOSE_PROJECTS; do docker compose -p "$p" down -v >/dev/null 2>&1 || true; done
  for c in $CONTAINERS; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  docker volume rm fscache-data >/dev/null 2>&1 || true
}
trap 'stop_server; cleanup_docker; [ -z "${BENCH_WORK:-}" ] && [ -n "${W:-}" ] && rm -rf "${W:?}"' EXIT



# ---------- tools (not timed) ----------
mkdir -p "$W/tools/bin"; cd "$W/tools"
if [ "$LOCAL" = 1 ]; then
  export GH_CONFIG_DIR="$W/gh-empty-config"; mkdir -p "$GH_CONFIG_DIR"; unset GH_TOKEN GITHUB_TOKEN
  command -v sha256sum >/dev/null 2>&1 || { printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > bin/sha256sum; chmod +x bin/sha256sum; export PATH="$W/tools/bin:$PATH"; }
  JDK21_HOME="${BENCH_JAVA_HOME:-$(/usr/libexec/java_home -v 21 2>/dev/null || echo "${JAVA_HOME:-}")}"
else
  unset GH_TOKEN GITHUB_TOKEN; export GH_CONFIG_DIR="$W/gh-empty-config"; mkdir -p "$GH_CONFIG_DIR"
  curl -fsSL -o cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VER}/cosign-linux-amd64"; sha_check cosign "$COSIGN_SHA"; install -m 0755 cosign bin/cosign
  curl -fsSL -o gr.zip "$GR_URL"; sha_check gr.zip "$GR_SHA"; unzip -q gr.zip; ln -s "$W/tools/gradle-${GR_VER}/bin/gradle" bin/gradle
  JDK21_HOME="${BENCH_JAVA_HOME:-${JAVA_HOME_21_X64:-${JAVA_HOME:-}}}"
  export PATH="$W/tools/bin:$PATH"
fi
"$JDK21_HOME/bin/java" -version 2>&1 | head -1 | grep -q '"21\.' || { echo "JAVA_HOME for Java 21 is not Java 21: $("$JDK21_HOME/bin/java" -version 2>&1 | head -1)" >&2; exit 1; }
export JAVA_HOME="$JDK21_HOME"; export PATH="$JDK21_HOME/bin:$PATH"
for t in gh cosign gradle curl python3 tar docker; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
GRADLE_BIN="$(command -v gradle)"

echo "== DISCLOSURE"
echo "runner: $(uname -sr); cpus: $(nproc 2>/dev/null || sysctl -n hw.ncpu); image: ${ImageOS:-?} ${ImageVersion:-?}"
echo "java: $("$JDK21_HOME/bin/java" -version 2>&1 | head -1)   gradle: $(gradle --version 2>/dev/null | grep -E '^Gradle ' | head -1)   cosign: $(cosign version 2>/dev/null | grep -i GitVersion | head -1)   docker: $(docker --version)"
if [ "$LOCAL" = 1 ]; then echo "tools: LOCAL tools in use, nothing checked (a developer's dry run: do not quote these times)"; else
  echo "tools: Gradle ${GR_VER} and cosign ${COSIGN_VER} are downloaded and checked against pinned checksums before use; Java 21 and Docker are the runner's own"; fi
echo "release under test: FosterStack Cache ${VER}, downloaded with no login and verified (cosign + sha256) before it runs; every server listens on 127.0.0.1 only"
echo "NOT checksum-pinned: nothing else is downloaded; the full-disk part mounts a tmpfs volume with sudo (the runner's own tools)"
echo "invented by this script (the pages show their settings, not their build files): the four-module Java project (12 small classes per module), made-up logins and passwords, the stand-in ports, the files and key names of the upload tests"
echo "differences from the pages' own runs: Linux amd64 (the pages: macOS arm64, Java 21.0.12.1 or 27), release ${VER} (the pages: 0.2.1); V: this project asks the server for a different number of things per build than the page's project (the page: 13 = four tasks and nine compiled build scripts), so the script compares the numbers with each other, not with the page's 13; T: the full disk is an 8 MiB tmpfs, the page used an 8 MiB APFS image, so counts of accepted uploads can differ"
echo "Gradle runs use a new empty Gradle home and a fresh project copy each, no daemon, Gradle's own local cache switched off (as the pages' runs did)"
echo "NOT tested here: Docker or Kubernetes volumes, file systems other than tmpfs, Maven, a full inode table, a disk quota, a very large single upload, Prometheus itself (the two rules are checked on live /metrics values with the script's own arithmetic, not on saved scrapes)"
echo "page commands run with 'bash -o pipefail'; a runner times commands, not people"
echo "full-disk start: two states are tried, with not one free byte (the server stops at its shutdown marker) and with 16 KiB free (the page's APFS volume still had room for small files); the page says which of the two it saw only in the words 'a full volume'"
echo "replaced by helper functions: the eviction page's put()/get() block (tput_code, tget_code, treadback); the healthy page's curl of /statusz is parsed with python; two filler files outside the data folder (1 MiB and 512 KiB) imitate the page's free-space step on the tmpfs"

export GRADLE_USER_HOME="$W/gradle-home"

# ---------- helpers ----------
run() { # NAME DIR  (command text on stdin)
  local name="$1" dir="$2" t0 t1
  cat > "$W/$name.sh"
  t0=$(now); ( cd "$dir" && bash -o pipefail "$W/$name.sh" ) > "$W/$name.out" 2>&1; RC=$?; t1=$(now); EL=$(secs "$t0" "$t1")
}
expect() { # NAME text...  (RC must be 0 unless NOZERO=1; every text must be in the output)
  local name="$1"; shift; local ok=yes w
  [ "${NOZERO:-0}" = 1 ] || [ "$RC" = 0 ] || ok="NO(exit $RC)"
  for w in "$@"; do grep -qF -- "$w" "$W/$name.out" || ok="${ok}; missing: ${w}"; done
  printf 'STEP %-40s %7s s  exit=%s  expected=%s\n' "$name" "$EL" "$RC" "$ok"
  case "$ok" in yes) ;; *) FAILS=$((FAILS+1)); sed 's/^/    | /' "$W/$name.out" | tail -14 ;; esac
}
absent() { # NAME text...  (none of the texts may be in the output)
  local name="$1"; shift; local w
  for w in "$@"; do grep -qF -- "$w" "$W/$name.out" && fail "$name: the output contains '${w}', which the page says it does not"; done
  return 0
}
count() { grep -cF -- "$2" "$W/$1.out" || true; }
statusz() { # port user pass [curl options...] -> entries/hits/misses
  local port="$1" u="$2" p="$3"; shift 3
  curl -s --max-time 30 "$@" -u "$u:$p" "${SCHEME:-http}://localhost:$port/statusz" | python3 -c "import sys,json;d=json.load(sys.stdin);print('entries=%s hits=%s misses=%s' % (d['store_entries'],d['cache_hits'],d['cache_misses']))" 2>/dev/null || echo "statusz-unreadable"
}
entries_of() { case "$1" in *entries=*) printf '%s' "$1" | sed -E 's/.*entries=([0-9]+).*/\1/';; *) printf 'unreadable';; esac; }
hits_of() { case "$1" in *hits=*) printf '%s' "$1" | sed -E 's/.*hits=([0-9]+).*/\1/';; *) printf 'unreadable';; esac; }
wait_up() { local i; for i in $(seq 1 400); do curl -sf --max-time 5 "localhost:$1/healthz" >/dev/null 2>&1 && return 0; sleep 0.05; done; return 1; }
check_entries() { # LABEL STATUSZ-TEXT WANT
  local got; got="$(entries_of "$2")"
  if [ "$got" = "$3" ]; then echo "OBS $1: server has $got entries, as the page says"; else fail "$1: the page says $3 entries on the server; the server says '$2'"; fi
}
http_code() { curl -s --max-time 120 -o /dev/null -w '%{http_code}' "$@"; }
check_code() { # LABEL WANT curl-args...
  local label="$1" want="$2"; shift 2; local got; got="$(http_code "$@")"
  if [ "$got" = "$want" ]; then echo "OBS $label: HTTP $got, as the page says"; else fail "$label: the page says HTTP $want; the server answered $got"; fi
}

# the release: downloaded and verified once (first-15 step 2, word for word), then unpacked for every server below
REL="$W/rel"; mkdir -p "$REL"
run release-download-verify "$REL" <<EOF
VER=${VER}
PLATFORM=${PLATFORM}
gh release download v\${VER} --repo fosterstack/cache \\
  -p checksums.txt -p checksums.txt.bundle -p "fscache_\${VER}_\${PLATFORM}.tar.gz"
cosign verify-blob --bundle checksums.txt.bundle \\
  --certificate-identity-regexp='^https://github.com/fosterstack/cache/' \\
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' checksums.txt
sha256sum -c <(grep "fscache_\${VER}_\${PLATFORM}.tar.gz" checksums.txt | grep -v sbom)
EOF
expect release-download-verify "Verified OK" "fscache_${VER}_${PLATFORM}.tar.gz: OK"
if [ "$RC" != 0 ] || ! grep -qF "Verified OK" "$W/release-download-verify.out"; then fail "the release did not verify: no server is started"; echo "FAILURES $FAILS"; exit 1; fi
tar -xzf "$REL/fscache_${VER}_${PLATFORM}.tar.gz" -C "$REL" || { echo "could not unpack the verified release" >&2; exit 1; }

start_server() { # NAME PORT USER PASS [KEY=VALUE ...]   (127.0.0.1 only; each server in its own empty folder)
  local name="$1" port="$2" user="$3" pass="$4"; shift 4
  local d="$W/srv-$name"; rm -rf "${d:?}"; mkdir -p "$d"; cp "$REL/fscache" "$d/fscache"
  ( cd "$d" && exec env FSCACHE_ADDR="127.0.0.1:${port}" FSCACHE_USERNAME="$user" FSCACHE_PASSWORD="$pass" "$@" ./fscache ) > "$d/server.log" 2>&1 &
  SERVER_PID=$!; SERVER_PORT="$port"
  wait_up "$port" || { fail "server $name did not answer on ${port}"; sed 's/^/    | /' "$d/server.log" | tail -5; stop_server; return 1; }
}

# ---------- project writers ----------
gradle_code() { # DIR N  (N changes what is compiled)
  printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println("hello %s");\n    }\n}\n' "$2" > "$1/src/main/java/demo/App.java"
}
# =====================================================================================

# ---------- one start from a clean environment (scenarios O and P) ----------
CASE_KEEP=0; CASE_PID=""
startcase() { # NAME KEY=VALUE...   one start of ./fscache from `env -i`; watched in quarter-seconds (CASE_TICKS, default 12 = 3 s)
  # sets CASE_RC (the exit code, or "running"), CASE_STOP_RC (the exit code after a normal stop), CASE_LOG, CASE_LAST, CASE_SECS
  # optional: CASE_PORT, CASE_NODATA=1 (no FSCACHE_DATA_DIR), CASE_CWD, CASE_PRE (shell text run first, $dir is the case folder), CASE_KEEP=1 (leave it running)
  local name="$1"; shift; local dir="$W/p-$name" i t0 t1; local -a envs
  chmod -R u+w "$dir" 2>/dev/null; rm -rf "${dir:?}"; mkdir -p "$dir/work"; cp "$REL/fscache" "$dir/work/fscache"
  [ -n "${CASE_PRE:-}" ] && eval "$CASE_PRE"
  CASE_LOG="$dir/log"; CASE_STOP_RC=""; CASE_PID=""
  envs=(PATH="$PATH" HOME="$dir" FSCACHE_ADDR="127.0.0.1:${CASE_PORT:-18161}")
  [ "${CASE_NODATA:-0}" = 1 ] || envs+=(FSCACHE_DATA_DIR="$dir/data")
  t0=$(now)
  ( cd "${CASE_CWD:-$dir/work}" && exec env -i "${envs[@]}" "$@" "$dir/work/fscache" ) > "$CASE_LOG" 2>&1 &
  local pid=$!
  for i in $(seq 1 "${CASE_TICKS:-12}"); do sleep 0.25; kill -0 "$pid" 2>/dev/null || break; done
  if kill -0 "$pid" 2>/dev/null; then
    CASE_RC=running; t1=$(now); CASE_SECS="$(secs "$t0" "$t1")"
    if [ "${CASE_KEEP:-0}" = 1 ]; then CASE_PID="$pid"; else kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; CASE_STOP_RC=$?; fi
  else
    wait "$pid" 2>/dev/null; CASE_RC=$?; t1=$(now); CASE_SECS="$(secs "$t0" "$t1")"
  fi
  CASE_LAST="$(tail -n 1 "$CASE_LOG" | cut -c1-260)"
  CASE_PRE=""; CASE_PORT=""; CASE_NODATA=0; CASE_CWD=""; CASE_TICKS=12; CASE_KEEP=0
}
casestop() { [ -n "$CASE_PID" ] && { kill "$CASE_PID" 2>/dev/null; wait "$CASE_PID" 2>/dev/null; CASE_STOP_RC=$?; CASE_PID=""; }; return 0; }
casefail() { # LABEL TEXT...  the start must fail with exit code 1 and the log must hold every TEXT
  local label="$1" w ok=1; shift
  [ "$CASE_RC" = 1 ] || ok=0
  for w in "$@"; do grep -qF -- "$w" "$CASE_LOG" || ok=0; done
  case "$(tail -n 1 "$CASE_LOG")" in *'"msg":"fscache: fatal"'*) ;; *) ok=0;; esac   # the last line is the fatal line
  if [ "$ok" = 1 ]; then echo "OBS $label: exit code 1 after ${CASE_SECS} s; last line: ${CASE_LAST}"
  else fail "$label: the page says exit code 1 and a log holding '$*'; got exit '${CASE_RC}', last line: ${CASE_LAST}"; fi
}
casestarts() { # LABEL [TEXT]  the start must have worked (still running after the watch) and a normal stop must exit 0
  local label="$1" ok=1
  [ "$CASE_RC" = running ] || ok=0
  [ -n "${2:-}" ] && { grep -qF -- "$2" "$CASE_LOG" || ok=0; }
  if [ "$ok" = 1 ]; then echo "OBS $label: started${CASE_STOP_RC:+; a normal stop exited with code ${CASE_STOP_RC}}"
  else fail "$label: the page says it starts${2:+ with '$2' in the start line}; got exit '${CASE_RC}', last line: ${CASE_LAST}"; fi
}
sfield() { # PORT FIELD  one field of /statusz (no login)
  curl -s --max-time 30 "http://127.0.0.1:$1/statusz" | python3 -c "import sys,json;print(json.load(sys.stdin)['$2'])" 2>/dev/null || echo unreadable
}
misses_of() { case "$1" in *misses=*) printf '%s' "$1" | sed -E 's/.*misses=([0-9]+).*/\1/';; *) printf 'unreadable';; esac; }

# ---------- shared project writers (from the batch 6 script) ----------
q_cls() { # DIR MODULE EXTRA  (twelve small classes per module; EXTRA is "method" (a body edit of C1) or "public" (a new public method on C1) or "")
  local d="$1" m="$2" extra="$3" i body="return 1;" more=""
  [ "$extra" = method ] && body="return 101;"
  [ "$extra" = public ] && more="    public int added() { return 7; }"
  mkdir -p "$d/$m/src/main/java/demo/$m"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [ "$i" = 1 ]; then printf 'package demo.%s;\n\npublic class C1 {\n    public int f() { %s }\n%s\n}\n' "$m" "$body" "$more" > "$d/$m/src/main/java/demo/$m/C1.java"
    else printf 'package demo.%s;\n\npublic class C%s {\n    public int f() { return %s; }\n}\n' "$m" "$i" "$i" > "$d/$m/src/main/java/demo/$m/C$i.java"; fi
  done
}
q_project() { # DIR EDIT(none|core-method|core-public|app-method)   (core; util and api use core; app uses util and api)
  local d="$1" edit="$2" m; rm -rf "${d:?}"; mkdir -p "$d"
  printf 'rootProject.name = "demo"\ninclude("core", "util", "api", "app")\n\n' > "$d/settings.gradle.kts"
  cat >> "$d/settings.gradle.kts" <<EOF
buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:${QPORT}/")
        isPush = true
        isAllowInsecureProtocol = true
    }
}
EOF
  printf 'org.gradle.caching=true\norg.gradle.parallel=true\n' > "$d/gradle.properties"
  mkdir -p "$d/core"; printf 'plugins { `java-library` }\n' > "$d/core/build.gradle.kts"
  for m in util api; do mkdir -p "$d/$m"; printf 'plugins { `java-library` }\n\ndependencies {\n    api(project(":core"))\n}\n' > "$d/$m/build.gradle.kts"; done
  mkdir -p "$d/app"; printf 'plugins { java }\n\ndependencies {\n    implementation(project(":util"))\n    implementation(project(":api"))\n}\n' > "$d/app/build.gradle.kts"
  for m in core util api app; do
    case "$edit:$m" in
      core-method:core) q_cls "$d" "$m" method;; core-public:core) q_cls "$d" "$m" public;; app-method:app) q_cls "$d" "$m" method;; *) q_cls "$d" "$m" "";;
    esac
  done
}
qrun() { # NAME DIR COMMAND...   (a new empty Gradle home; the page's command)
  local name="$1" dir="$2"; shift 2
  rm -rf "$W/qg-$name"; mkdir -p "$W/qg-$name"
  run "q-$name" "$dir" <<EOF
export GRADLE_USER_HOME="$W/qg-$name"
$*
EOF
  expect "q-$name" "BUILD SUCCESSFUL"
  rm -rf "$W/qg-$name"
}
qstate() { # NAME TASKPATH  -> ran | cache | missing   (the exact line of the compile task)
  local f="$W/q-$1.out"
  if grep -qxF "> Task :$2 FROM-CACHE" "$f"; then echo cache; elif grep -qxF "> Task :$2" "$f"; then echo ran; else echo missing; fi
}

# =====================================================================================
# V  /is-the-build-cache-server-healthy-what-to-alert-on/
# =====================================================================================
VPORT=18181
mval() { # PORT SERIES  -> one value of /metrics (0 when the series has not been seen yet)
  local v; v="$(curl -s --max-time 10 "http://127.0.0.1:$1/metrics" | awk -v k="$2" '$1==k {print $2; exit}')"; printf '%s' "${v:-0}"
}
put5xx() { curl -s --max-time 10 "http://127.0.0.1:$1/metrics" | awk '$1 ~ /^fscache_http_requests_total\{method="PUT",status="5/ {s+=$2} END {print s+0}'; }
reqsum() { curl -s --max-time 10 "$@" | awk '$1 ~ /^fscache_http_requests_total\{/ {s+=$2} END {print s+0}'; }
want() { # LABEL GOT WANT
  if [ "$2" = "$3" ]; then echo "OBS $1: $2, as the page says"; else fail "$1: the page says $3; got $2"; fi
}
want_gt() { # LABEL GOT THAN
  if awk -v a="$2" -v b="$3" 'BEGIN { exit !(a+0 > b+0) }'; then echo "OBS $1: $2 (more than $3), as the page says"; else fail "$1: the page says it goes up from $3; got $2"; fi
}
probe_rc() { curl -sf --max-time 3 "$1" >/dev/null 2>&1; echo $?; }
vrestart() { # NAME PORT KEY=VALUE...   same data folder
  local name="$1" port="$2"; shift 2; local d="$W/srv-$name"
  stop_server
  ( cd "$d" && exec env FSCACHE_ADDR="127.0.0.1:${port}" "$@" ./fscache ) >> "$d/server.log" 2>&1 &
  SERVER_PID=$!; SERVER_PORT="$port"
  wait_up "$port" || { fail "server $name did not come back on ${port}"; return 1; }
}
vbuild() { # NAME EDIT   (the four compile tasks, a fresh copy, a new Gradle home)
  q_project "$W/v/$1" "$2"; qrun "$1" "$W/v/$1" "gradle compileJava --console=plain --no-daemon"; rm -rf "$W/v/$1"
}
qcheck() { # LABEL NAME "want per task" tasks...   (ran | cache for each compile task)
  local label="$1" name="$2" want="$3"; shift 3; local got="" t
  for t in "$@"; do got="$got $(qstate "$name" "$t")"; done; got="${got# }"
  if [ "$got" = "$want" ]; then echo "OBS V/T $label: $got, as the page says"; else fail "$label: the page says '$want'; the build did '$got'"; fi
}
scenario_v() {
  echo; echo "== V  (is-the-build-cache-server-healthy-what-to-alert-on)"
  mkdir -p "$W/v"; QPORT=$VPORT; local P=$VPORT S M h0 h1 m0 e0 b0 bw br st0 pt0 B
  start_server v1 "$P" "" "" || return
  # --- healthy server, cold build
  vbuild vb1 none; qcheck "cold build: the four compile tasks" vb1 "ran ran ran ran" core:compileJava util:compileJava api:compileJava app:compileJava
  want "healthy server: /healthz" "$(http_code "http://127.0.0.1:$P/healthz")" 200
  want "healthy server: /statusz" "$(http_code "http://127.0.0.1:$P/statusz")" 200
  M="$(mval $P fscache_cache_misses_total)"; bw="$(mval $P fscache_bytes_written_total)"
  want "cold build: hits" "$(mval $P fscache_cache_hits_total)" 0
  want "cold build: PUT 201 equals the misses ($M)" "$(mval $P 'fscache_http_requests_total{method="PUT",status="201"}')" "$M"
  want_gt "cold build: bytes written" "$bw" 0
  want "cold build: entries equal the misses" "$(sfield $P store_entries)" "$M"
  want "cold build: evictions" "$(mval $P fscache_evicted_entries_total)" 0
  want "cold build: no PUT with a 5xx status (rule 1 stays quiet)" "$(put5xx $P)" 0
  # --- same project again, new Gradle home
  vbuild vb2 none; qcheck "same project again: the four compile tasks" vb2 "cache cache cache cache" core:compileJava util:compileJava api:compileJava app:compileJava
  want "same project again: hits equal the earlier misses" "$(mval $P fscache_cache_hits_total)" "$M"
  want "same project again: bytes read equal the bytes written" "$(mval $P fscache_bytes_read_total)" "$bw"
  want "same project again: no PUT with a 5xx status and no evictions (the two rules stay quiet)" "$(put5xx $P)/$(mval $P fscache_evicted_entries_total)" "0/0"
  # --- one method changed in one module
  h0="$(mval $P fscache_cache_hits_total)"; m0="$M"
  vbuild vb3 core-method; qcheck "one method changed: the four compile tasks" vb3 "ran cache cache cache" core:compileJava util:compileJava api:compileJava app:compileJava
  want "one method changed: one more miss" "$(mval $P fscache_cache_misses_total)" "$((m0+1))"
  want "one method changed: the other lookups are hits" "$(( $(mval $P fscache_cache_hits_total) - h0 ))" "$((M-1))"
  want "one method changed: one more entry" "$(sfield $P store_entries)" "$((M+1))"
  want "one method changed: no PUT with a 5xx status and no evictions (the two rules stay quiet)" "$(put5xx $P)/$(mval $P fscache_evicted_entries_total)" "0/0"
  # --- the status page and the metric names
  curl -s "http://127.0.0.1:$P/statusz" | python3 -c "
import sys,json
d=json.load(sys.stdin)
want=['version','revision','fips140','fips140_note','uptime_seconds','uptime','store_bytes','max_bytes','store_entries','cache_hits','cache_misses','hit_ratio','evicted_entries','auth_enabled']
missing=[k for k in want if k not in d]
print('statusz keys: ' + ('all 14 of the page are there' if not missing else 'MISSING ' + ','.join(missing)))
" | sed 's/^/OBS V /' | tee "$W/v/statusz-keys.txt"; grep -q MISSING "$W/v/statusz-keys.txt" && fail "V /statusz is missing a key the page shows"
  for n in fscache_cache_hits_total fscache_cache_misses_total fscache_store_bytes fscache_store_entries fscache_evicted_entries_total fscache_http_requests_total fscache_http_request_duration_seconds fscache_bytes_read_total fscache_bytes_written_total process_start_time_seconds; do
    curl -s "http://127.0.0.1:$P/metrics" | grep -q "^$n" || fail "V /metrics has no '$n', which the page lists"
  done
  echo "OBS V /metrics holds every metric name the page lists (and process_start_time_seconds)"
  # --- the other URLs the page says are not health URLs
  m0="$(mval $P fscache_cache_misses_total)"
  want "/readyz" "$(http_code "http://127.0.0.1:$P/readyz")" 404
  want "/livez" "$(http_code "http://127.0.0.1:$P/livez")" 404
  want "the two 404s were counted as cache misses" "$(( $(mval $P fscache_cache_misses_total) - m0 ))" 2
  # --- server stopped; the probe
  st0="$(mval $P process_start_time_seconds)"; S="$(statusz $P x y)"; B="$(sfield $P store_bytes)"; e0="$(sfield $P store_entries)"
  stop_server
  want "server stopped: curl -sf --max-time 3 /healthz exits" "$(probe_rc "http://127.0.0.1:$P/healthz")" 7
  want "server stopped: the same for /metrics" "$(probe_rc "http://127.0.0.1:$P/metrics")" 7
  # --- started again on the same data
  vrestart v1 "$P" FSCACHE_DATA_DIR="$W/srv-v1/data" || return
  want "restart: /healthz" "$(http_code "http://127.0.0.1:$P/healthz")" 200
  want "restart: /statusz still shows the stored bytes" "$(sfield $P store_bytes)" "$B"
  want "restart: /statusz still shows the entries" "$(sfield $P store_entries)" "$e0"
  want "restart: the hit counter is back to 0" "$(sfield $P cache_hits)" 0
  want "restart: the miss counter is back to 0" "$(sfield $P cache_misses)" 0
  want "restart: the eviction counter is back to 0" "$(sfield $P evicted_entries)" 0
  awk -v u="$(sfield $P uptime_seconds)" 'BEGIN { exit !(u < 10) }' && echo "OBS V restart: uptime is back to $(sfield $P uptime_seconds) s" || fail "V restart: the page says uptime is back to 0; it is $(sfield $P uptime_seconds)"
  want "restart: /metrics store_bytes reads 0 until an upload" "$(mval $P fscache_store_bytes)" 0
  want "restart: /metrics store_entries reads 0 until an upload" "$(mval $P fscache_store_entries)" 0
  curl -s --max-time 30 -o /dev/null -X PUT --data-binary 0123456789 "http://127.0.0.1:$P/afterrestart"
  want "after one upload: /metrics store_bytes is the stored bytes plus the upload" "$(mval $P fscache_store_bytes)" "$((B+10))"
  want "after one upload: /metrics store_entries" "$(mval $P fscache_store_entries)" "$((e0+1))"
  [ "$(mval $P process_start_time_seconds)" != "$st0" ] && echo "OBS V process_start_time_seconds changed when the server restarted" || fail "V process_start_time_seconds did not change on restart"
  stop_server
  # --- a read-only data folder at start; a data path that cannot be created
  rm -rf "$W/vro"; cp -R "$W/srv-v1/data" "$W/vro"; chmod -R a-w "$W/vro"
  CASE_PORT=18182 startcase v-ro "FSCACHE_DATA_DIR=$W/vro"
  casefail "V start with a read-only data folder" "write shutdown marker" "permission denied"
  want "read-only data folder at start: the probe exits" "$(probe_rc "http://127.0.0.1:18182/healthz")" 7
  chmod -R u+w "$W/vro"
  CASE_PRE='touch "$dir/afile"' CASE_PORT=18182 startcase v-file "FSCACHE_DATA_DIR=$W/p-v-file/afile"
  casefail "V start where the data folder cannot be created" "check shutdown marker" "not a directory"
  want "data folder cannot be created: the probe exits" "$(probe_rc "http://127.0.0.1:18182/healthz")" 7
  # --- the data folder made read-only while running; deleted while running
  local K1=seedkey
  for B in readonly deleted; do
    start_server "v-$B" "$P" "" "" || return
    curl -s --max-time 30 -o /dev/null -X PUT --data-binary 0123456789 "http://127.0.0.1:$P/$K1"
    vbuild "vb-$B-0" none
    S="$(sfield $P store_bytes)"
    if [ "$B" = readonly ]; then chmod -R a-w "$W/srv-v-$B/data"; else rm -rf "$W/srv-v-$B/data"; fi
    want "data folder $B while running: /healthz" "$(http_code "http://127.0.0.1:$P/healthz")" 200
    want "data folder $B while running: /statusz" "$(http_code "http://127.0.0.1:$P/statusz")" 200
    if [ "$B" = readonly ]; then want "read-only while running: an existing entry" "$(http_code "http://127.0.0.1:$P/$K1")" 200
    else want "deleted while running: /statusz still shows the old size" "$(sfield $P store_bytes)" "$S"; want "deleted while running: the stored key" "$(http_code "http://127.0.0.1:$P/$K1")" 404; fi
    pt0="$(put5xx $P)"
    want "data folder $B while running: a new upload" "$(http_code -X PUT --data-binary x "http://127.0.0.1:$P/newkey")" 500
    want "data folder $B while running: counted as PUT 500" "$(( $(put5xx $P) - pt0 ))" 1
    [ "$B" = readonly ] && { grep -q 'store error' "$W/srv-v-$B/server.log" && grep -q 'permission denied' "$W/srv-v-$B/server.log" && echo "OBS V the log holds 'store error' and 'permission denied'" || fail "V read-only while running: the log should hold 'store error ... permission denied'"; }
    vbuild "vb-$B-1" core-method
    expect "q-vb-$B-1" "BUILD SUCCESSFUL" "Could not store entry" "response status 500" "The remote build cache was disabled during the build due to errors."
    echo "OBS V Gradle with the data folder $B: Could not store entry ... response status 500, the remote cache disabled, BUILD SUCCESSFUL"
    chmod -R u+w "$W/srv-v-$B" 2>/dev/null; stop_server
  done
  # --- a tiny size cap, three builds; an upload larger than the whole cap
  start_server v-cap "$P" "" "" FSCACHE_MAX_BYTES=20000 || return
  local ev_prev=0 ev
  for n in 1 2 3; do
    vbuild "vb-cap-$n" none
    ev="$(mval $P fscache_evicted_entries_total)"
    want_gt "size cap 20,000, build $n: evictions so far (rule 2 fires)" "$ev" "$ev_prev"; ev_prev="$ev"
    want "size cap 20,000, build $n: hits so far" "$(mval $P fscache_cache_hits_total)" 0
    S="$(sfield $P store_bytes)"; awk -v s="$S" 'BEGIN { exit !(s <= 20000) }' && echo "OBS V size cap 20,000, build $n: stored size $S of 20,000" || fail "V the stored size $S is over the cap"
  done
  head -c 25000 /dev/zero > "$W/v/big"
  want "an upload larger than the whole cap" "$(http_code -X PUT --data-binary @"$W/v/big" "http://127.0.0.1:$P/toobig")" 413
  want "...counted as PUT 413" "$(mval $P 'fscache_http_requests_total{method="PUT",status="413"}')" 1
  want "...and /healthz" "$(http_code "http://127.0.0.1:$P/healthz")" 200
  stop_server
  # --- logins on
  start_server v-auth "$P" rw rwsecret FSCACHE_RO_USERNAME=ro FSCACHE_RO_PASSWORD=rosecret || return
  curl -s --max-time 30 -o /dev/null -u rw:rwsecret -X PUT --data-binary x "http://127.0.0.1:$P/k"
  local R0 R1 R2
  R0="$(reqsum -u rw:rwsecret "http://127.0.0.1:$P/metrics")"
  want "logins on, no login: /healthz" "$(http_code "http://127.0.0.1:$P/healthz")" 200
  want "logins on, no login: /metrics" "$(http_code "http://127.0.0.1:$P/metrics")" 200
  want "logins on, no login: /statusz" "$(http_code "http://127.0.0.1:$P/statusz")" 401
  want "logins on, wrong login: /statusz" "$(http_code -u rw:wrong "http://127.0.0.1:$P/statusz")" 401
  want "logins on, no login: reading an entry" "$(http_code "http://127.0.0.1:$P/k")" 401
  want "logins on, wrong login: reading an entry" "$(http_code -u rw:wrong "http://127.0.0.1:$P/k")" 401
  R1="$(reqsum -u rw:rwsecret "http://127.0.0.1:$P/metrics")"
  want "refused reads added nothing to fscache_http_requests_total" "$R1" "$R0"
  want "the read-only login uploads" "$(http_code -u ro:rosecret -X PUT --data-binary x "http://127.0.0.1:$P/k2")" 403
  R2="$(reqsum -u rw:rwsecret "http://127.0.0.1:$P/metrics")"
  want "the refused upload added nothing to fscache_http_requests_total" "$R2" "$R1"
  grep -E 'status.{0,4}(401|403)|[Uu]nauthorized|[Ff]orbidden' "$W/srv-v-auth/server.log" | head -n 1 | grep -q . && fail "V the page says refused logins did not appear in the server log; they did" || echo "OBS V refused logins did not appear in the server log, as the page says"
  # --- Gradle with a wrong password
  local d="$W/v/vb-wrong"; q_project "$d" none
  cat > "$d/settings.gradle.kts" <<EOF
rootProject.name = "demo"
include("core", "util", "api", "app")

buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:${P}/")
        isPush = true
        isAllowInsecureProtocol = true
        credentials { username = "rw"; password = "wrong" }
    }
}
EOF
  local H0; H0="$(sfield $P cache_hits)"
  qrun vb-wrong "$d" "gradle compileJava --console=plain --no-daemon"
  want "Gradle with a wrong password: the build got no hits from the server" "$(sfield $P cache_hits)" "$H0"
  expect q-vb-wrong "BUILD SUCCESSFUL" "Could not load entry" "response status 401: Unauthorized" "The remote build cache was disabled during the build due to errors."
  echo "OBS V Gradle with a wrong password: the 401 line, the remote cache disabled, BUILD SUCCESSFUL"
  stop_server
}

# =====================================================================================
# T  /build-cache-eviction-size-limit/
# =====================================================================================
TPORT=18191
VOLMOUNT=""
cleanup_docker() { [ -n "$VOLMOUNT" ] && { sudo -n umount "$VOLMOUNT" >/dev/null 2>&1 || true; }; }
tput_code() { # PORT KEY FILE   -> HTTP status of a PUT of FILE
  curl -s --max-time 60 -o /dev/null -w '%{http_code}' -X PUT --data-binary @"$3" "http://127.0.0.1:$1/$2"
}
tget_code() { curl -s --max-time 30 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/$2"; }
treadback() { # PORT KEY...   in the order given -> "k1:200 k2:404 ..."
  local port="$1" k out=""; shift
  for k in "$@"; do out="$out $k:$(tget_code "$port" "$k")"; done; printf '%s' "${out# }"
}
scenario_t() {
  echo; echo "== T  (build-cache-eviction-size-limit)"
  mkdir -p "$W/t"; local P=$TPORT S ev i code
  head -c 1000 /dev/zero > "$W/t/k1000"; head -c 4000 /dev/zero > "$W/t/k4000"
  # --- a deliberately tiny cap: 3,500 bytes, five 1,000-byte entries
  start_server t1 "$P" "" "" FSCACHE_MAX_BYTES=3500 || return
  for k in k1 k2 k3; do tput_code "$P" $k "$W/t/k1000" >/dev/null; done
  S="$(sfield $P store_bytes)/$(sfield $P store_entries)/$(sfield $P evicted_entries)"
  want "step 1, store k1 k2 k3: bytes/entries/evicted" "$S" "3000/3/0"
  want "step 1: which keys could be read" "$(treadback $P k1 k2 k3)" "k1:200 k2:200 k3:200"
  tget_code "$P" k1 >/dev/null
  S="$(sfield $P store_bytes)/$(sfield $P store_entries)/$(sfield $P evicted_entries)"
  want "step 2, read k1: unchanged" "$S" "3000/3/0"
  tput_code "$P" k4 "$W/t/k1000" >/dev/null
  S="$(sfield $P store_bytes)/$(sfield $P store_entries)/$(sfield $P evicted_entries)"
  want "step 3, store k4 (would go over 3,500): bytes/entries/evicted" "$S" "3000/3/1"
  want "step 3: which keys could be read (k2 is gone)" "$(treadback $P k1 k2 k3 k4)" "k1:200 k2:404 k3:200 k4:200"
  tput_code "$P" k5 "$W/t/k1000" >/dev/null
  S="$(sfield $P store_bytes)/$(sfield $P store_entries)/$(sfield $P evicted_entries)"
  want "step 4, store k5: bytes/entries/evicted" "$S" "3000/3/2"
  want "step 4: which keys could be read (k1 is gone)" "$(treadback $P k1 k2 k3 k4 k5)" "k1:404 k2:404 k3:200 k4:200 k5:200"
  want "an entry of 4,000 bytes against the 3,500 cap" "$(tput_code "$P" toobig "$W/t/k4000")" 413
  S="$(sfield $P store_bytes)/$(sfield $P store_entries)/$(sfield $P evicted_entries)"
  want "...stored nothing and evicted nothing else" "$S" "3000/3/2"
  stop_server
  # --- a real full disk: an 8 MiB tmpfs volume
  if [ "$LOCAL" = 1 ] || ! sudo -n true 2>/dev/null; then echo "OBS T the full-disk part was skipped: it needs Linux and passwordless sudo for a tmpfs mount"; return; fi
  local VOL="$W/vol" N G
  mkdir -p "$VOL"; sudo -n mount -t tmpfs -o size=8m,mode=0777 tmpfs "$VOL" || { fail "T could not mount the 8 MiB tmpfs volume"; return; }
  VOLMOUNT="$VOL"; QPORT=$P
  head -c 262144 /dev/zero > "$W/t/k256k"; head -c 4096 /dev/zero > "$W/t/k4k"; head -c 1024 /dev/zero > "$W/t/k1k"
  start_server t2 "$P" "" "" FSCACHE_DATA_DIR="$VOL/data" || return
  q_project "$W/t/b1" none; qrun tb1 "$W/t/b1" "gradle compileJava --console=plain --no-daemon"; qcheck "full disk, cold build (the disk has room)" tb1 "ran ran ran ran" core:compileJava util:compileJava api:compileJava app:compileJava
  echo "OBS T cold build with room: $(sfield $P store_entries) entries, $(sfield $P store_bytes) bytes"
  dd if=/dev/zero of="$VOL/filler" bs=1048576 count=1 2>/dev/null; dd if=/dev/zero of="$VOL/filler_b" bs=1024 count=512 2>/dev/null   # two files outside the data folder: 1 MiB to free in the page's step, 512 KiB more so the last build has room
  # 256 KiB uploads until one fails
  N=0; for i in $(seq 1 60); do code="$(tput_code "$P" "big$i" "$W/t/k256k")"; [ "$code" = 201 ] && N=$((N+1)) || break; done
  curl -s --max-time 30 -X PUT --data-binary @"$W/t/k256k" "http://127.0.0.1:$P/bigfail" > "$W/t/body.txt" 2>/dev/null
  want "256 KiB uploads: the one that failed" "$code" 500; echo "OBS T 256 KiB uploads: $N accepted, then a 500 with the body '$(cat "$W/t/body.txt")'"
  [ "$(cat "$W/t/body.txt")" = "internal error" ] || fail "T the page says the 500 body is 'internal error'; it is '$(cat "$W/t/body.txt")'"
  # then 4 KiB uploads
  N=0; for i in $(seq 1 400); do code="$(tput_code "$P" "small$i" "$W/t/k4k")"; [ "$code" = 201 ] && N=$((N+1)) || break; done
  want "4 KiB uploads: the one that failed" "$code" 500; echo "OBS T 4 KiB uploads: $N accepted, then a 500"
  want "...then a 1 KiB upload also" "$(tput_code "$P" onek "$W/t/k1k")" 500
  # looking at the full server
  want "full disk: /healthz still answers" "$(curl -s --max-time 10 "http://127.0.0.1:$P/healthz")" ok
  echo "OBS T full disk: /statusz $(statusz $P x y), bytes $(sfield $P store_bytes); PUT 500 counted: $(put5xx $P)"
  want "full disk: a stored entry reads" "$(tget_code "$P" big1)" 200
  want "full disk: a stored entry reads (second)" "$(tget_code "$P" small1)" 200
  want "full disk: a key never stored" "$(tget_code "$P" neverstored)" 404
  q_project "$W/t/b2" none; qrun tb2 "$W/t/b2" "gradle compileJava --console=plain --no-daemon"; qcheck "full disk, same build again" tb2 "cache cache cache cache" core:compileJava util:compileJava api:compileJava app:compileJava
  q_project "$W/t/b3" core-method; qrun tb3 "$W/t/b3" "gradle compileJava --console=plain --no-daemon"
  expect q-tb3 "BUILD SUCCESSFUL" "response status 500: Internal Server Error" "The remote build cache was disabled during the build due to errors."
  want "full disk, changed build: 'Could not store entry' lines" "$(count q-tb3 'Could not store entry')" 1
  # free 1 MiB outside the data folder
  rm -f "$VOL/filler"
  want "1 MiB freed: a 1 KiB upload" "$(tput_code "$P" after1k "$W/t/k1k")" 201
  N=0; for i in 1 2 3; do code="$(tput_code "$P" "after$i" "$W/t/k256k")"; [ "$code" = 201 ] && N=$((N+1)); done; want "1 MiB freed: three 256 KiB uploads accepted" "$N" 3
  N=0; for i in 4 5; do code="$(tput_code "$P" "after$i" "$W/t/k256k")"; [ "$code" = 500 ] && N=$((N+1)); done; want "...the next two get 500, no restart" "$N" 2
  rm -f "$VOL/filler_b"
  q_project "$W/t/b4" core-public; qrun tb4 "$W/t/b4" "gradle compileJava --console=plain --no-daemon"
  absent q-tb4 "Could not store entry" "The remote build cache was disabled"
  echo "OBS T a changed build with room (512 KiB more freed first): BUILD SUCCESSFUL and no warning"
  # a start on a full volume. First with NO free byte at all, then with 16 KiB free (the page's volume still had room for small files)
  stop_server
  dd if=/dev/zero of="$VOL/filler2" bs=1024 2>/dev/null
  CASE_PORT=$P startcase t-full0-old "FSCACHE_DATA_DIR=$VOL/data"
  casefail "T a start with not one free byte, with the old data" "write shutdown marker" "no space left on device"
  CASE_PORT=$P startcase t-full0-new "FSCACHE_DATA_DIR=$VOL/newdata0"
  casefail "T a start with not one free byte, with a new empty data folder" "no space left on device"
  truncate -s "$(( $(stat -c %s "$VOL/filler2") - 16384 ))" "$VOL/filler2"
  ( cd "$W/srv-t2" && exec env FSCACHE_ADDR="127.0.0.1:${P}" FSCACHE_DATA_DIR="$VOL/data" ./fscache ) > "$W/srv-t2/again.log" 2>&1 &
  SERVER_PID=$!; SERVER_PORT=$P
  if wait_up "$P"; then
    echo "OBS T started on a full volume (16 KiB free) with its old data: /healthz ok, /statusz $(statusz $P x y)"
    want "...a stored entry reads" "$(tget_code "$P" big1)" 200
    want "...a new 256 KiB upload" "$(tput_code "$P" newfull "$W/t/k256k")" 500
  else fail "T the page says the server starts on a full volume with its old data; it did not answer: $(tail -n 2 "$W/srv-t2/again.log" | cut -c1-200)"; fi
  stop_server
  CASE_PORT=$P startcase t-newfolder "FSCACHE_DATA_DIR=$VOL/newdata" FSCACHE_MAX_BYTES=4194304
  casefail "T a new, empty data folder on a full volume (16 KiB free)" "open metadata store" "no space left on device"
  want "...and it never answered" "$(probe_rc "http://127.0.0.1:$P/healthz")" 7
  # the size cap against a small volume: 40 uploads of 256 KiB (10 MiB in all)
  for G in 4194304 20971520; do
    rm -rf "${VOL:?}"/* "${VOL:?}"/.[!.]* 2>/dev/null
    start_server t3 "$P" "" "" FSCACHE_DATA_DIR="$VOL/data" FSCACHE_MAX_BYTES=$G || return
    N=0; for i in $(seq 1 40); do code="$(tput_code "$P" "cap$i" "$W/t/k256k")"; [ "$code" = 201 ] && N=$((N+1)); done
    ev="$(sfield $P evicted_entries)"; S="$(sfield $P store_bytes)"
    echo "OBS T size cap $G, 40 uploads of 256 KiB: $N accepted, $((40-N)) refused, $ev entries removed, stored size $S"
    if [ "$G" = 4194304 ]; then want "cap 4 MiB: all accepted" "$N" 40; want "cap 4 MiB: entries removed" "$ev" 24; want "cap 4 MiB: stored size" "$S" 4194304
    else [ "$N" -gt 0 ] && [ "$N" -lt 40 ] || fail "T cap 20 MiB: the page says some uploads were accepted and the rest got 500; $N of 40 were accepted"; want "cap 20 MiB: nothing removed" "$ev" 0; fi
    stop_server
  done
  sudo -n umount "$VOL" && VOLMOUNT=""
}

# ---------- run ----------
for port in 18181 18182 18191; do
  curl -skf --max-time 3 "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
scenario_v
scenario_t
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
