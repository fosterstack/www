#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 8: do the commands and promised outputs of this page really happen?
#   U  /restart-build-cache-server-while-builds-run/   a build that keeps four 8-second cacheable tasks running while the server is stopped
#                                                      (normal stop and kill -9; back after 2 s and after 14 s), a build started while the server is
#                                                      down, how long the server is unreachable, an upload in progress when the server stops, and
#                                                      what survives a restart (clean stop, kill, a different data folder)
# Run by the "bench-howto-pages-8" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-8"). Same method as the other
# bench scripts: the page's commands word for word, every output line the page promises asserted; a step that fails or prints something else is
# RECORDED (FAIL) and fails the job at the end; the rest are OBS lines. No token and no secret; the release binary is verified (cosign + sha256)
# before it runs; every server listens on 127.0.0.1 only. Times are measured on a runner and reported, not promised.
set -uo pipefail

VER=0.2.2                                    # the release the pages name
LOCAL="${BENCH_LOCAL:-0}"                    # 1 = a developer's dry run with local tools (nothing downloaded or checked: do not quote times)
if [ "$LOCAL" = 1 ]; then PLATFORM="${BENCH_PLATFORM:-darwin_arm64}"; else PLATFORM=linux_amd64; fi
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
EXT_VER=1.2.3
IMG=ghcr.io/fosterstack/cache
IMG_022=sha256:f2b330cf27b3814405230cc001a771909ae5bbf3b1e223a90ee7a9ee5d0e53dd
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
echo "NOT checksum-pinned: nothing else is downloaded"
echo "invented by this script (the page shows its settings, not its build files): the four-module projects, the four cacheable tasks that sleep 8 seconds (a Gradle task class written in each module build file), made-up keys and file contents"
echo "differences from the page's own runs: Linux amd64 (the page: macOS arm64), release ${VER} (the page: 0.2.1), Java 21; the stop is sent 2 s after the build has printed the header of its second slow task, i.e. while the third task runs (the page does not say when it stopped the server); the page's 20 MiB and 40 MiB uploads are sent with curl --limit-rate 2M"
echo "Gradle runs use a new empty Gradle home and a fresh project copy each, no daemon, Gradle's own local cache switched off (as the pages' runs did)"
echo "NOT tested here: Docker, Kubernetes or Compose rollouts, Maven builds, more than one build at once"
echo "page commands run with 'bash -o pipefail'; a runner times commands, not people"

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

# ---------- helpers carried over from the batch 7 script ----------
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

# =====================================================================================
# U  /restart-build-cache-server-while-builds-run/
# =====================================================================================
UPORT=18201
u_project() { # DIR   four modules, each with a cacheable task "slow" that sleeps 8 seconds; no parallel build (as one build at a time, in order)
  local d="$1" m; rm -rf "${d:?}"; mkdir -p "$d"
  printf 'rootProject.name = "demo"\ninclude("core", "util", "api", "app")\n\n' > "$d/settings.gradle.kts"
  cat >> "$d/settings.gradle.kts" <<EOF
buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:${UPORT}/")
        isPush = true
        isAllowInsecureProtocol = true
    }
}
EOF
  printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
  for m in core util api app; do
    mkdir -p "$d/$m"
    cat > "$d/$m/build.gradle.kts" <<EOF
import org.gradle.api.DefaultTask
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.TaskAction

@CacheableTask
abstract class SlowTask : DefaultTask() {
    @get:Input abstract val tag: Property<String>
    @get:OutputFile abstract val out: RegularFileProperty
    @TaskAction fun run() { Thread.sleep(8000); out.get().asFile.writeText(tag.get()) }
}

tasks.register<SlowTask>("slow") {
    tag.set("${m}")
    out.set(layout.buildDirectory.file("slow.txt"))
}
EOF
  done
}
ubuild_start() { # NAME DIR   a build in the background; output in $W/u-NAME.out, exit code in $W/u-NAME.rc
  local name="$1" dir="$2"
  rm -rf "$W/ug-$name"; mkdir -p "$W/ug-$name"; rm -f "$W/u-$name.rc"
  ( cd "$dir" && GRADLE_USER_HOME="$W/ug-$name" gradle slow --console=plain --no-daemon > "$W/u-$name.out" 2>&1; echo $? > "$W/u-$name.rc" ) &
  UBUILD_PID=$!
}
ubuild_wait() { # NAME   -> waits for the build to end
  local name="$1" i; for i in $(seq 1 600); do [ -f "$W/u-$name.rc" ] && break; sleep 0.5; done
  [ -f "$W/u-$name.rc" ] || { fail "U build $name did not end in 5 minutes"; return 1; }
  rm -rf "$W/ug-$name"
}
ubuild() { # NAME DIR  -> runs the build and waits
  ubuild_start "$1" "$2"; ubuild_wait "$1"
}
uheaders() { grep -cE '^> Task :[a-z]+:slow$' "$W/u-$1.out" 2>/dev/null || true; }
ufc() { grep -cE '^> Task :[a-z]+:slow FROM-CACHE$' "$W/u-$1.out" 2>/dev/null || true; }
uok() { grep -qF "BUILD SUCCESSFUL" "$W/u-$1.out" && [ "$(cat "$W/u-$1.rc")" = 0 ]; }
tget_code() { curl -s --max-time 30 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/$2"; }
scenario_u() {
  echo; echo "== U  (restart-build-cache-server-while-builds-run)"
  local D="$W/u" P=$UPORT row mode down i n t0 t1 stored
  mkdir -p "$D"; QPORT=$P
  # --- four rows: the server is stopped while the build's third slow task runs, and comes back after 2 s or 14 s
  for row in ${UROWS-normal:2 kill:2 normal:14 kill:14}; do
    mode="${row%%:*}"; down="${row##*:}"
    start_server "u-$mode-$down" "$P" "" "" || return
    u_project "$D/b-$mode-$down"
    t0=$(now); ubuild_start "r-$mode-$down" "$D/b-$mode-$down"
    for i in $(seq 1 800); do [ "$(uheaders "r-$mode-$down")" -ge 2 ] && break; sleep 0.25; done
    sleep 2   # Gradle prints a task's header when the task has finished, so two headers = two tasks done and stored; the third task has just started (8 s)
    echo "OBS U row $mode / ${down} s: the server is stopped $(secs "$t0" "$(now)") s after the build started, with $(uheaders "r-$mode-$down") slow tasks finished"
    if [ "$mode" = normal ]; then stop_server; else kill -9 "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""; fi
    sleep "$down"
    ( cd "$W/srv-u-$mode-$down" && exec env FSCACHE_ADDR="127.0.0.1:${P}" FSCACHE_DATA_DIR="$W/srv-u-$mode-$down/data" ./fscache ) >> "$W/srv-u-$mode-$down/server.log" 2>&1 &
    SERVER_PID=$!; SERVER_PORT=$P
    wait_up "$P" || fail "U the server did not come back after the $mode / ${down} s row"
    ubuild_wait "r-$mode-$down"
    uok "r-$mode-$down" && echo "OBS U row $mode stop, back after ${down} s: BUILD SUCCESSFUL" || fail "U row $mode / ${down} s: the page says the build still ended with BUILD SUCCESSFUL"
    if [ "$down" = 2 ]; then
      for t in "Could not store entry" "Could not load entry" "The remote build cache was disabled"; do grep -qF "$t" "$W/u-r-$mode-$down.out" && fail "U row $mode / 2 s: the page says the build printed nothing about the cache; it printed '$t'"; done
      echo "OBS U row $mode stop, back after 2 s: nothing about the cache was printed, as the page says"
    else
      want "row $mode stop, back after 14 s: 'Could not store entry' lines" "$(grep -cF 'Could not store entry' "$W/u-r-$mode-$down.out")" 1
      grep -qF "The remote build cache was disabled during the build due to errors" "$W/u-r-$mode-$down.out" && echo "OBS U row $mode stop, back after 14 s: then the remote cache was disabled" || fail "U row $mode / 14 s: the page says the remote cache was disabled after the warning"
    fi
    u_project "$D/n-$mode-$down"; ubuild "n-$mode-$down" "$D/n-$mode-$down"
    if [ "$down" = 2 ]; then want "row $mode stop, back after 2 s: next build, tasks from cache" "$(ufc "n-$mode-$down")" 4; else want "row $mode stop, back after 14 s: next build, tasks from cache" "$(ufc "n-$mode-$down")" 2; fi
    stop_server
  done
  # --- a build started while the server is stopped, then the server comes up
  start_server u-down "$P" "" "" || return
  stop_server
  u_project "$D/d1"; ubuild d1 "$D/d1"
  want "a build while the server is stopped: 'Could not load entry' lines" "$(grep -cF 'Could not load entry' "$W/u-d1.out")" 1
  want "...and it built all four modules locally (tasks from cache)" "$(ufc d1)" 0
  [ "$(uheaders d1)" = 4 ] || fail "U the page says it built all four modules; $(uheaders d1) slow tasks ran"
  ( cd "$W/srv-u-down" && exec env FSCACHE_ADDR="127.0.0.1:${P}" FSCACHE_DATA_DIR="$W/srv-u-down/data" ./fscache ) >> "$W/srv-u-down/server.log" 2>&1 &
  SERVER_PID=$!; SERVER_PORT=$P; wait_up "$P" || { fail "U the server did not start"; return; }
  u_project "$D/d2"; ubuild d2 "$D/d2"; want "after the server was started: the next build ran all four" "$(uheaders d2)/$(ufc d2)" "4/0"
  u_project "$D/d3"; ubuild d3 "$D/d3"; want "the one after that took all four from the cache" "$(ufc d3)" 4
  stop_server
  # --- how long the server is unreachable: five stops and starts in a row for each case
  local entries
  for entries in 20 5000; do
    start_server u-time "$P" "" "" || return
    python3 - "$P" "$entries" <<'PYEOF'
import sys, http.client
port, n = int(sys.argv[1]), int(sys.argv[2])
size = 100 if n == 20 else 10000
c = http.client.HTTPConnection("127.0.0.1", port)
body = b"x" * size
for i in range(n):
    c.request("PUT", "/key%d" % i, body); r = c.getresponse(); r.read()
    if r.status != 201:
        print("PUT %d got %d" % (i, r.status)); sys.exit(1)
PYEOF
    echo "OBS U $entries entries in the cache: $(statusz $P x y), $(sfield $P store_bytes) bytes"
    for mode in normal kill; do
      local worst=0 best=999 el
      for i in 1 2 3 4 5; do
        if [ "$mode" = normal ]; then stop_server; else kill -9 "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""; for n in $(seq 1 50); do curl -sf --max-time 1 "http://127.0.0.1:$P/healthz" >/dev/null 2>&1 || break; sleep 0.1; done; fi
        t0=$(now)
        ( cd "$W/srv-u-time" && exec env FSCACHE_ADDR="127.0.0.1:${P}" FSCACHE_DATA_DIR="$W/srv-u-time/data" ./fscache ) >> "$W/srv-u-time/server.log" 2>&1 &
        SERVER_PID=$!; SERVER_PORT=$P
        wait_up "$P" || fail "U restart timing: the server did not come back"
        t1=$(now); el="$(secs "$t0" "$t1")"
        awk -v e="$el" -v w="$worst" 'BEGIN { exit !(e+0 > w+0) }' && worst="$el"; awk -v e="$el" -v b="$best" 'BEGIN { exit !(e+0 < b+0) }' && best="$el"
      done
      echo "OBS U $entries entries, $mode stop then start, five times: back after $best to $worst s (polled /healthz; includes the poll interval)"
      awk -v w="$worst" 'BEGIN { exit !(w < 2.0) }' || fail "U the page says the server was back in well under a second (0.03 to 0.15 s on its Mac); the slowest of five took $worst s here"
    done
    if [ "$entries" = 5000 ]; then
      grep -q "unclean shutdown detected, reconciling stores before serving" "$W/srv-u-time/server.log" && echo "OBS U after a kill the log says 'unclean shutdown detected, reconciling stores before serving'" || fail "U the page says the log holds 'unclean shutdown detected, reconciling stores before serving' after a kill"
      [ "$(sfield $P store_entries)" -ge "$entries" ] && echo "OBS U ...and no entries were lost: $(sfield $P store_entries) entries after the restarts (before: $entries)" || fail "U the page says no entries were lost after a kill; $(sfield $P store_entries) of $entries are left"
    fi
    stop_server
  done
  # --- an upload in progress when the server stops
  head -c 20971520 /dev/zero > "$W/u/f20"; head -c 41943040 /dev/zero > "$W/u/f40"
  local up rc el_stop exit_rc tmpsz
  for row in 20:normal 20:kill 40:normal; do
    n="${row%%:*}"; mode="${row##*:}"
    start_server u-up "$P" "" "" || return
    curl -s -o /dev/null -X PUT --data-binary x "http://127.0.0.1:$P/earlier"
    ( curl -s --max-time 120 --limit-rate 2M -o /dev/null -w '%{http_code}' -X PUT --data-binary @"$W/u/f$n" "http://127.0.0.1:$P/bigone" > "$W/u/up.code" 2>/dev/null; echo $? > "$W/u/up.rc" ) &
    UPLOAD_PID=$!
    sleep 3
    t0=$(now)
    if [ "$mode" = normal ]; then kill "$SERVER_PID"; else kill -9 "$SERVER_PID"; fi
    wait "$SERVER_PID" 2>/dev/null; exit_rc=$?; t1=$(now); el_stop="$(secs "$t0" "$t1")"; SERVER_PID=""
    wait "$UPLOAD_PID" 2>/dev/null
    up="$(cat "$W/u/up.code" 2>/dev/null)"; rc="$(cat "$W/u/up.rc" 2>/dev/null)"
    tmpsz="$(find "$W/srv-u-up/data" -type f -size +1M -exec ls -l {} \; 2>/dev/null | awk '{print int($5/1048576)" MiB"}' | tr '\n' ' ')"
    echo "OBS U ${n} MiB upload at 2 MiB/s, $mode stop after 3 s: the server exited after ${el_stop} s with code ${exit_rc}; the upload ended with HTTP '${up}' (curl exit ${rc}); files over 1 MiB left in the data folder: ${tmpsz:-none}"
    ( cd "$W/srv-u-up" && exec env FSCACHE_ADDR="127.0.0.1:${P}" FSCACHE_DATA_DIR="$W/srv-u-up/data" ./fscache ) >> "$W/srv-u-up/server.log" 2>&1 &
    SERVER_PID=$!; SERVER_PORT=$P; wait_up "$P" || fail "U the server did not restart after the upload row $row"
    case "$row" in
      20:normal) want "20 MiB, normal stop: the upload finished with" "$up" 201; want "...the server exited cleanly (code)" "$exit_rc" 0
                 awk -v e="$el_stop" 'BEGIN { exit !(e >= 5 && e <= 10) }' && echo "OBS U ...after ${el_stop} s (the page: 7.4 s)" || fail "U 20 MiB normal stop: the page says the server exited cleanly after 7.4 s; it took ${el_stop} s"
                 want "...the entry afterwards" "$(tget_code "$P" bigone)" 200;;
      20:kill)   [ "$up" != 201 ] || fail "U 20 MiB kill: the page says the upload broke; it finished with 201"
                 want "20 MiB, kill: the entry afterwards" "$(tget_code "$P" bigone)" 404
                 [ -z "$(find "$W/srv-u-up/data" -type f -size +1M 2>/dev/null)" ] && echo "OBS U ...the next start removed the temporary file" || fail "U 20 MiB kill: the page says the next start removed the temporary file; a file over 1 MiB is still in the data folder";;
      40:normal) [ "$up" != 201 ] || fail "U 40 MiB normal stop: the page says the upload broke; it finished with 201"
                 awk -v e="$el_stop" 'BEGIN { exit !(e >= 9 && e <= 12) }' && echo "OBS U 40 MiB, normal stop: the server gave up after ${el_stop} s (the page: 10.0 s)" || fail "U 40 MiB normal stop: the page says the server gave up after 10.0 s; it took ${el_stop} s"
                 [ "$exit_rc" != 0 ] && echo "OBS U ...and exited with an error (code ${exit_rc})" || fail "U 40 MiB normal stop: the page says the server exited with an error; the exit code was 0"
                 want "...the entry afterwards" "$(tget_code "$P" bigone)" 404;;
    esac
    want "$row: the entry stored earlier stays readable" "$(tget_code "$P" earlier)" 200
    stop_server
  done
  # --- what survives a restart: clean stop, kill, a different data folder
  q_project "$D/s1" none
  start_server u-surv "$P" "" "" || return
  S="$(statusz $P x y)"; want "survival, step 1: entries before the first build" "$(entries_of "$S")" 0
  qrun us1 "$D/s1" "gradle compileJava --console=plain --no-daemon"; qcheck "survival, step 1: first build" us1 "ran ran ran ran" core:compileJava util:compileJava api:compileJava app:compileJava
  E1="$(sfield $P store_entries)"; B1="$(sfield $P store_bytes)"; [ "$E1" -gt 0 ] && echo "OBS U survival: $E1 entries and $B1 bytes after the first build" || fail "U survival: nothing stored"
  stop_server
  vrestart u-surv "$P" FSCACHE_DATA_DIR="$W/srv-u-surv/data" || return
  want "survival, step 2 (clean restart): entries right after the restart" "$(sfield $P store_entries)" "$E1"; want "...bytes" "$(sfield $P store_bytes)" "$B1"
  q_project "$D/s2" none; qrun us2 "$D/s2" "gradle compileJava --console=plain --no-daemon"; qcheck "survival, step 2: build after a clean restart" us2 "cache cache cache cache" core:compileJava util:compileJava api:compileJava app:compileJava
  kill -9 "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""; sleep 1
  vrestart u-surv "$P" FSCACHE_DATA_DIR="$W/srv-u-surv/data" || return
  want "survival, step 3 (kill -9): entries right after the restart" "$(sfield $P store_entries)" "$E1"; want "...bytes" "$(sfield $P store_bytes)" "$B1"
  q_project "$D/s3" none; qrun us3 "$D/s3" "gradle compileJava --console=plain --no-daemon"; qcheck "survival, step 3: build after the kill" us3 "cache cache cache cache" core:compileJava util:compileJava api:compileJava app:compileJava
  stop_server
  vrestart u-surv "$P" FSCACHE_DATA_DIR="$W/other-folder" || return
  want "survival, step 4 (a different, empty folder): entries" "$(sfield $P store_entries)" 0
  q_project "$D/s4" none; qrun us4 "$D/s4" "gradle compileJava --console=plain --no-daemon"; qcheck "survival, step 4: build against the empty folder" us4 "ran ran ran ran" core:compileJava util:compileJava api:compileJava app:compileJava
  stop_server
}

# ---------- run ----------
for port in 18201; do
  curl -skf --max-time 3 "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
scenario_u
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
