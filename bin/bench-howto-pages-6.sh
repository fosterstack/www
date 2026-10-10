#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 6: do the commands and promised outputs of these pages really happen?
#   Q  /gradle-build-cache-monorepo/                    the six runs of the four-module table and the six runs of the buildSrc + included build table:
#                                                       for each module/part, did compileJava run or come FROM-CACHE; the jar steps
#   R  /gradle-build-cache-docker-ci-fresh-container/   the page's docker run command (five runs, a mount at another path, no password) and the
#                                                       daemon case (a password set after Gradle's background process had started)
# Run by the "bench-howto-pages-6" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-6"). Same method as the other
# bench scripts: the page's commands word for word (differences are said in the output), the server's own counters checked, every output line the
# page promises asserted; a step that fails or prints something else is RECORDED (FAIL) and fails the job at the end; the rest are OBS lines.
#
# No token and no secret. Gradle and cosign are downloaded and checked against pinned checksums; the release binary is verified (cosign + sha256)
# before it runs; the Gradle container image is resolved to a digest at run time and that digest is used and printed (it is not signed with cosign).
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
  echo "tools: Gradle ${GR_VER}, Maven 3.9.9 and cosign ${COSIGN_VER} are downloaded and checked against pinned checksums before use; Java 21 and Docker are the runner's own"; fi
echo "release under test: FosterStack Cache ${VER}, downloaded with no login and verified (cosign + sha256) before it runs (binary servers); the gradle container image is pulled by tag, resolved to a digest at run time, and that digest is used for every container (it is not cosign-verified)"
echo "NOT checksum-pinned beforehand: the gradle:9.8.0-jdk21 image (digest printed at run time), the ubuntu:24.04 image (only used to remove files the container created)"
echo "invented by this script (the pages show their settings and one sentence on their build files, not the files): the Java classes (12 per module), the build.gradle.kts files of the modules, buildSrc and the included build; made-up password and username"
echo "differences from the pages' own runs: Linux amd64 (Q: the page ran on macOS arm64 with Java 27; R: Linux aarch64 under Docker Desktop), release ${VER} (the pages: 0.2.1), Java 21 for Q; R adds --add-host=host.docker.internal:host-gateway to the docker run (a Linux Docker engine does not define that name by itself); the cache server for R listens on all interfaces of this runner so a container can reach it (password set; the runner is thrown away)"
echo "Q runs use a new empty Gradle home and a fresh project copy each, no daemon (as the page), the local cache switched off; R runs use a new container each (no volumes for the Gradle home)"
echo "NOT tested here: a buildSrc with plugins or other languages, an included build that is itself large, other CI products, x86 versus aarch64 differences, HTTPS, Windows, a cache on another host"
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

# =====================================================================================
# Q  /gradle-build-cache-monorepo/
# =====================================================================================
QPORT=18140
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
c_project() { # DIR EDIT(none|buildsrc|lib-method|lib-public|app-method)   buildSrc, an included build "lib", and app
  local d="$1" edit="$2" v="v1" body="return 1;" more="" abody="return 1;"
  rm -rf "${d:?}"; mkdir -p "$d/buildSrc/src/main/java/demo" "$d/lib/src/main/java/demo" "$d/app/src/main/java/demo"
  [ "$edit" = buildsrc ] && v="v2"
  [ "$edit" = lib-method ] && body="return 101;"
  [ "$edit" = lib-public ] && more="    public static int added() { return 7; }"
  [ "$edit" = app-method ] && abody="return 101;"
  cat > "$d/settings.gradle.kts" <<EOF
rootProject.name = "composite"
includeBuild("lib")
include(":app")
buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:${CPORT}/")
        isPush = true
        isAllowInsecureProtocol = true
    }
}
EOF
  printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
  printf 'println("info " + demo.Info.value())\n' > "$d/build.gradle.kts"
  printf 'plugins { java }\n' > "$d/buildSrc/build.gradle.kts"
  printf 'package demo;\n\npublic class Info {\n    public static String value() { return "%s"; }\n}\n' "$v" > "$d/buildSrc/src/main/java/demo/Info.java"
  printf 'rootProject.name = "lib"\n' > "$d/lib/settings.gradle.kts"
  printf 'plugins { `java-library` }\n\ngroup = "demo"\n' > "$d/lib/build.gradle.kts"
  printf 'package demo;\n\npublic class Lib {\n    public static int f() { %s }\n%s\n}\n' "$body" "$more" > "$d/lib/src/main/java/demo/Lib.java"
  printf 'plugins { java }\n\ndependencies {\n    implementation("demo:lib")\n}\n' > "$d/app/build.gradle.kts"
  printf 'package demo;\n\npublic class App {\n    public static int f() { %s }\n    public static int g() { return Lib.f(); }\n}\n' "$abody" > "$d/app/src/main/java/demo/App.java"
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
qcheck() { # LABEL NAME "want per task" tasks...
  local label="$1" name="$2" want="$3"; shift 3; local got="" t
  for t in "$@"; do got="$got $(qstate "$name" "$t")"; done; got="${got# }"
  if [ "$got" = "$want" ]; then echo "OBS Q $label: $got, as the page says"; else fail "Q $label: the page says '$want'; the build did '$got'"; fi
}
CPORT=18220
scenario_q() {
  echo; echo "== Q  (gradle-build-cache-monorepo)"
  local D="$W/q" t; mkdir -p "$D"
  local CMD="gradle build --console=plain --no-daemon"
  start_server q1 "$QPORT" "" "" || return
  local -a T=(core:compileJava util:compileJava api:compileJava app:compileJava)
  q_project "$D/r1" none;        qrun r1 "$D/r1" "$CMD";  qcheck "table 1, run 1 (first build, as CI would do it)" r1 "ran ran ran ran" "${T[@]}"
  q_project "$D/r2" none;        qrun r2 "$D/r2" "$CMD";  qcheck "table 1, run 2 (another machine, same code)" r2 "cache cache cache cache" "${T[@]}"
  q_project "$D/r3" core-method; qrun r3 "$D/r3" "$CMD";  qcheck "table 1, run 3 (edit inside a method in core)" r3 "ran cache cache cache" "${T[@]}"
  q_project "$D/r4" core-method; qrun r4 "$D/r4" "$CMD";  qcheck "table 1, run 4 (a teammate makes the same edit)" r4 "cache cache cache cache" "${T[@]}"
  q_project "$D/r5" core-public; qrun r5 "$D/r5" "$CMD";  qcheck "table 1, run 5 (add a public method to core)" r5 "ran ran ran ran" "${T[@]}"
  q_project "$D/r6" app-method;  qrun r6 "$D/r6" "$CMD";  qcheck "table 1, run 6 (edit only app)" r6 "cache cache cache ran" "${T[@]}"
  for t in r1 r2 r3 r4 r5 r6; do grep -qxF "> Task :core:jar FROM-CACHE" "$W/q-$t.out" && fail "Q the page says the jar steps are not cacheable by default and ran every time; :core:jar came from the cache in $t"; done
  echo "OBS Q the jar steps were never taken from the cache in the six runs, as the page says"
  grep -xF -e "> Task :core:compileJava" -e "> Task :util:compileJava FROM-CACHE" -e "> Task :api:compileJava FROM-CACHE" -e "> Task :app:compileJava FROM-CACHE" "$W/q-r3.out" | sed 's/^/OBS Q run 3 printed: /'
  stop_server
  # --- buildSrc and an included build
  start_server q2 "$CPORT" "" "" || return
  local -a C=(buildSrc:compileJava lib:compileJava app:compileJava)
  local CC="gradle :app:build --console=plain --no-daemon"
  c_project "$D/c1" none;        qrun c1 "$D/c1" "$CC"; qcheck "table 2, run 1 (first build)" c1 "ran ran ran" "${C[@]}"
  c_project "$D/c2" none;        qrun c2 "$D/c2" "$CC"; qcheck "table 2, run 2 (fresh copy, same code)" c2 "cache cache cache" "${C[@]}"
  c_project "$D/c3" buildsrc;    qrun c3 "$D/c3" "$CC"; qcheck "table 2, run 3 (edit buildSrc)" c3 "ran cache cache" "${C[@]}"
  c_project "$D/c4" lib-method;  qrun c4 "$D/c4" "$CC"; qcheck "table 2, run 4 (edit inside a method in lib)" c4 "cache ran cache" "${C[@]}"
  c_project "$D/c5" lib-public;  qrun c5 "$D/c5" "$CC"; qcheck "table 2, run 5 (add a public method to lib)" c5 "cache ran ran" "${C[@]}"
  c_project "$D/c6" app-method;  qrun c6 "$D/c6" "$CC"; qcheck "table 2, run 6 (edit only app)" c6 "cache cache ran" "${C[@]}"
  grep -xF -e "> Task :buildSrc:compileJava FROM-CACHE" -e "> Task :lib:compileJava FROM-CACHE" -e "> Task :app:compileJava FROM-CACHE" "$W/q-c2.out" | sed 's/^/OBS Q run 2 printed: /'
  stop_server
}

# =====================================================================================
# R  /gradle-build-cache-docker-ci-fresh-container/
# =====================================================================================
RPORT=18250
RPW=ci-test-password
rmproj() { sudo -n rm -rf "$@" 2>/dev/null || rm -rf "$@"; }
r_project() { # DIR  (the four-module build of the monorepo page; the settings file is the page's)
  q_project "$1" none
  cat > "$1/settings.gradle.kts" <<EOF
rootProject.name = "demo"
include("core", "util", "api", "app")

buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("http://host.docker.internal:${RPORT}/")
        isPush = true
        isAllowInsecureProtocol = true
        credentials { username = "ci"; password = System.getenv("FSCACHE_PASSWORD") }
    }
}
EOF
}
rdocker() { # NAME MOUNTPATH WITHPASSWORD(1|0)   the page's docker run command; run from the folder that holds ./project
  local name="$1" mp="$2" pw="$3"
  [ "$LOCAL" = 1 ] && sleep 4   # a developer's Mac: Docker Desktop needs a moment to see a folder written just now (not needed on the runner)
  run "r-$name" "$W/r/$name" <<EOF
docker run --rm $([ "$pw" = 1 ] && echo "-e FSCACHE_PASSWORD=${RPW}") --add-host=host.docker.internal:host-gateway \\
  -v "\$PWD/project:${mp}" -w ${mp} \\
  ${RIMG} gradle :core:compileJava --console=plain --no-daemon
EOF
}
scenario_r() {
  echo; echo "== R  (gradle-build-cache-docker-ci-fresh-container)"
  local D="$W/r" n got; mkdir -p "$D"
  for n in 1 2 3; do docker pull -q gradle:9.8.0-jdk21 >/dev/null 2>&1 && break; sleep 5; done
  got="$(docker inspect --format '{{index .RepoDigests 0}}' gradle:9.8.0-jdk21 2>/dev/null)"
  [ -n "$got" ] || { fail "R: could not pull gradle:9.8.0-jdk21"; return; }
  RIMG="$got"; echo "OBS R image gradle:9.8.0-jdk21 resolved at run time to ${RIMG} (used for every container); platform: $(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$RIMG")"
  start_server r1 "$RPORT" ci "$RPW" FSCACHE_ADDR="0.0.0.0:${RPORT}" || return
  local t=":core:compileJava"
  # run 1: first container
  r_project "$D/run1/project"; rdocker run1 /work/one 1
  expect r-run1 "BUILD SUCCESSFUL" "> Task ${t}"; absent r-run1 "FROM-CACHE" "response status 401"
  echo "OBS R run 1 (first container): :core:compileJava ran, no 401 line, BUILD SUCCESSFUL"
  # a note on the folder: the same folder again, no clean
  mkdir -p "$D/run1b"; cp -R "$D/run1/project" "$D/run1b/project"; rdocker run1b /work/one 1
  grep -qF "> Task ${t} UP-TO-DATE" "$W/r-run1b.out" && echo "OBS R the page's command run again on the SAME project folder (build output left in it) printed ':core:compileJava UP-TO-DATE', not FROM-CACHE" || echo "OBS R the same folder again printed: $(grep -F "> Task ${t}" "$W/r-run1b.out" | head -n 1)"
  rmproj "$D/run1b/project"
  # run 2: new container, same code, same mount path (a fresh copy of the project)
  r_project "$D/run2/project"; rdocker run2 /work/one 1
  expect r-run2 "BUILD SUCCESSFUL" "> Task ${t} FROM-CACHE"; absent r-run2 "response status 401"; rmproj "$D/run2/project"
  # run 3: mounted at a different path
  r_project "$D/run3/project"; rdocker run3 /work/two 1
  expect r-run3 "BUILD SUCCESSFUL" "> Task ${t} FROM-CACHE"; absent r-run3 "response status 401"; rmproj "$D/run3/project"
  # run 4: a line of main code edited
  r_project "$D/run4/project"; q_cls "$D/run4/project" core method; rdocker run4 /work/one 1
  expect r-run4 "BUILD SUCCESSFUL" "> Task ${t}"; absent r-run4 "FROM-CACHE" "response status 401"; rmproj "$D/run4/project"
  # run 5: no password passed (the edited code, which the cache now holds)
  r_project "$D/run5/project"; q_cls "$D/run5/project" core method; rdocker run5 /work/one 0
  expect r-run5 "BUILD SUCCESSFUL" "> Task ${t}" "response status 401: Unauthorized" "The remote build cache was disabled during the build due to errors."; absent r-run5 "FROM-CACHE"
  grep -F "Could not load entry" "$W/r-run5.out" | head -n 1 | cut -c1-200 | sed 's/^/OBS R run 5: /'; rmproj "$D/run5/project"
  # the daemon: two builds in one container with Gradle's background process on
  r_project "$D/daemon/project"
  run r-daemon "$D/daemon" <<EOF
docker run --rm --add-host=host.docker.internal:host-gateway -v "\$PWD/project:/work/one" -w /work/one ${RIMG} sh -c 'gradle :core:compileJava --console=plain; echo ==== SECOND; export FSCACHE_PASSWORD=${RPW}; rm -rf core/build; gradle :core:compileJava --console=plain'
EOF
  expect r-daemon "response status 401: Unauthorized" "==== SECOND"
  awk '/==== SECOND/{f=1} f' "$W/r-daemon.out" | grep -qxF "> Task ${t} FROM-CACHE" && echo "OBS R the daemon picked up the password set later in the same shell: :core:compileJava FROM-CACHE in the second build, as the page says" || fail "R the page says the second build printed :core:compileJava FROM-CACHE after the password was set in the same shell"
  rmproj "$D/daemon/project"
  stop_server
}

# ---------- run ----------
for port in 18140 18220 18250; do
  curl -skf --max-time 3 "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
scenario_q
scenario_r
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
