#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 11: do the commands and promised outputs of two Gradle pages really happen?
#   K  /why-did-this-task-miss-the-build-cache/   the key-diff commands (run twice with --info -Dorg.gradle.caching.debug=true, grep, diff), the six
#                                                 rows of "what each change looked like", a rerun, the reasons a task has no key, the three-module chain
#                                                 (Gradle and Maven 3.9.9) and the Gson bump
#   G  /what-gradle-stores-in-build-cache/        (the Gradle half) `gradle build -i | grep "Stored cache entry"` on a four-module build: what was stored
#                                                 and what was not, and a second run with the same Gradle home against a new empty server
# Run by the "bench-howto-pages-11" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-11"). Same method as the other
# bench scripts. No token and no secret; downloads are checked against pinned checksums (Gradle, cosign, Temurin 27, Maven 3.9.9); the release
# binary is verified (cosign + sha256) before it runs. Servers listen on 127.0.0.1 only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # where bench-proxy.py lives

VER=0.2.2                                    # the release the pages name
LOCAL="${BENCH_LOCAL:-0}"                    # 1 = a developer's dry run with local tools (nothing downloaded or checked: do not quote times)
if [ "$LOCAL" = 1 ]; then PLATFORM="${BENCH_PLATFORM:-darwin_arm64}"; else PLATFORM=linux_amd64; fi
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
EXT_VER=1.2.3
IMG=ghcr.io/fosterstack/cache
IMG_022=sha256:f2b330cf27b3814405230cc001a771909ae5bbf3b1e223a90ee7a9ee5d0e53dd
JDK27_URL="https://github.com/adoptium/temurin27-binaries/releases/download/jdk-27%2B35/OpenJDK27U-jdk_x64_linux_hotspot_27_35.tar.gz"
JDK27_SHA=1cf69a4848ffb728b3b260dfd45206a51566ab571a02a30092271d4c580bccbc
MVN399_URL="https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz"
MVN399_SHA512=a555254d6b53d267965a3404ecb14e53c3827c09c3b94b5678835887ab404556bfaf78dcfe03ba76fa2508649dca8531c74bca4d5846513522404d48e8c4ac8b
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
trap 'stop_server; stop_proxy; stop_tls; cleanup_docker; [ -z "${BENCH_WORK:-}" ] && [ -n "${W:-}" ] && rm -rf "${W:?}"' EXIT



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
curl -fsSL -o "$W/tools/jdk27.tgz" "$JDK27_URL"; sha_check "$W/tools/jdk27.tgz" "$JDK27_SHA"; mkdir -p "$W/tools/jdk27" && tar -xzf "$W/tools/jdk27.tgz" -C "$W/tools/jdk27" --strip-components=1; JDK27_HOME="$W/tools/jdk27"
curl -fsSL -o "$W/tools/mvn399.tgz" "$MVN399_URL"; sha512_check "$W/tools/mvn399.tgz" "$MVN399_SHA512"; tar -xzf "$W/tools/mvn399.tgz" -C "$W/tools"; MVN399_HOME="$W/tools/apache-maven-3.9.9"
[ -x "$JDK27_HOME/bin/java" ] && [ -x "$MVN399_HOME/bin/mvn" ] || { echo "Java 27 or Maven 3.9.9 not usable" >&2; exit 1; }
for t in gh cosign gradle curl python3 tar mvn openssl; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
GRADLE_BIN="$(command -v gradle)"

echo "== DISCLOSURE"
echo "runner: $(uname -sr); cpus: $(nproc 2>/dev/null || sysctl -n hw.ncpu); image: ${ImageOS:-?} ${ImageVersion:-?}"
echo "java: $("$JDK21_HOME/bin/java" -version 2>&1 | head -1)   gradle: $(gradle --version 2>/dev/null | grep -E '^Gradle ' | head -1)   cosign: $(cosign version 2>/dev/null | grep -i GitVersion | head -1)   docker: $(docker --version)"
if [ "$LOCAL" = 1 ]; then echo "tools: LOCAL tools in use, nothing checked (a developer's dry run: do not quote these times)"; else
  echo "tools: Gradle ${GR_VER} and cosign ${COSIGN_VER} are downloaded and checked against pinned checksums before use; Java 21 and Docker are the runner's own"; fi
echo "release under test: FosterStack Cache ${VER}, downloaded with no login and verified (cosign + sha256) before it runs; every server listens on 127.0.0.1 only"
echo "NOT checksum-pinned: the Maven build-cache extension 1.2.3 and the Maven plugin jars (their eight versions are pinned in the pom, the files come from Maven Central); the runner's own Maven (version printed) is used except for one 3.9.9 build, whose archive is checked"
echo "invented by this script (the pages show commands and results, not the projects): the key-diff project (one class, notes.txt and five small cacheable tasks written in its build file), the failing-to-cache tasks, the three-module chain, the lib/app Gson project, the four-module project of the Gradle half"
echo "differences from the pages' own runs: Linux amd64 (the pages: macOS arm64), release ${VER} (the pages: 0.2.1), Gradle ${GR_VER}; Java 27 is Temurin 27+35 (the page: Homebrew OpenJDK 27); the Maven chain uses Maven 3.9.9 as the page does, the other Maven helpers use the runner's 3.10.0"
echo "Gradle builds use a new empty Gradle home and a fresh project copy each, no daemon, Gradle's own local cache switched off; Maven builds use an emptied ~/.m2/build-cache"
echo "NOT covered by this job: the three-module chain table (Gradle and Maven) and the Gson bump of the why-did-this-task-miss page (their projects differ from the ones built here); the Maven half of the what-stores page (batch 10)"
echo "NOT tested here (as on the pages): other Gradle or Maven versions, Kotlin or Android builds, a second machine, annotation processors, bigger projects, build times"
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

start_server() { # NAME PORT USER PASS [KEY=VALUE ...]   (each server in its own empty folder; 127.0.0.1 unless the caller passes FSCACHE_ADDR)
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
# Maven helpers
# =====================================================================================
MPORT=18180; MPORT2=18181
stop_proxy() { :; }; stop_tls() { :; }   # the exit trap of the shared base calls these two; this job starts neither
MH="$W/mvnhome"; mkdir -p "$MH/.m2"
PLUGINS='      <plugin><artifactId>maven-clean-plugin</artifactId><version>3.4.0</version></plugin>
      <plugin><artifactId>maven-resources-plugin</artifactId><version>3.3.1</version></plugin>
      <plugin><artifactId>maven-compiler-plugin</artifactId><version>3.13.0</version></plugin>
      <plugin><artifactId>maven-surefire-plugin</artifactId><version>3.5.2</version></plugin>
      <plugin><artifactId>maven-jar-plugin</artifactId><version>3.4.2</version></plugin>
      <plugin><artifactId>maven-install-plugin</artifactId><version>3.1.3</version></plugin>
      <plugin><artifactId>maven-deploy-plugin</artifactId><version>3.1.3</version></plugin>
      <plugin><artifactId>maven-site-plugin</artifactId><version>3.12.1</version></plugin>'
m_cfg() { # DIR MODE URL   MODE: healthy | nosave | outside   (the extension and its config at the project root)
  local d="$1" mode="$2" url="$3"; mkdir -p "$d/.mvn"
  printf '<extensions>\n  <extension>\n    <groupId>org.apache.maven.extensions</groupId>\n    <artifactId>maven-build-cache-extension</artifactId>\n    <version>%s</version>\n  </extension>\n</extensions>\n' "$EXT_VER" > "$d/.mvn/extensions.xml"
  local head='<?xml version="1.0" encoding="UTF-8"?>
<cache xmlns="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       xsi:schemaLocation="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0 https://maven.apache.org/xsd/build-cache-config-1.2.0.xsd">'
  case "$mode" in
    healthy) printf '%s\n  <configuration>\n    <enabled>true</enabled>\n    <remote enabled="true" saveToRemote="true" id="fosterstack-cache">\n      <url>%s</url>\n    </remote>\n  </configuration>\n</cache>\n' "$head" "$url" > "$d/.mvn/maven-build-cache-config.xml";;
    nosave)  printf '%s\n  <configuration>\n    <enabled>true</enabled>\n    <remote enabled="true" id="fosterstack-cache">\n      <url>%s</url>\n    </remote>\n  </configuration>\n</cache>\n' "$head" "$url" > "$d/.mvn/maven-build-cache-config.xml";;
    outside) printf '%s\n  <configuration>\n    <enabled>true</enabled>\n  </configuration>\n  <remote enabled="true" saveToRemote="true" id="fosterstack-cache">\n    <url>%s</url>\n  </remote>\n</cache>\n' "$head" "$url" > "$d/.mvn/maven-build-cache-config.xml";;
  esac
}
m1_project() { # DIR N MODE URL RELEASE17(0|1)   one module demo:demo; the class depends on N (a new cache key)
  local d="$1" n="$2" mode="$3" url="$4" rel="$5"; rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo"
  m_cfg "$d" "$mode" "$url"
  { printf '<project xmlns="http://maven.apache.org/POM/4.0.0">\n  <modelVersion>4.0.0</modelVersion>\n  <groupId>demo</groupId>\n  <artifactId>demo</artifactId>\n  <version>1.0</version>\n  <packaging>jar</packaging>\n  <properties>\n'
    [ "$rel" = 1 ] && printf '    <maven.compiler.release>17</maven.compiler.release>\n'
    printf '    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>\n  </properties>\n  <build>\n    <pluginManagement><plugins>\n%s\n    </plugins></pluginManagement>\n  </build>\n</project>\n' "$PLUGINS"; } > "$d/pom.xml"
  printf 'package demo;\n\npublic class App {\n    public static int f() { return %s; }\n}\n' "$n" > "$d/src/main/java/demo/App.java"
}
mm_project() { # DIR EDIT(none|core|util|app)   three modules: core <- util <- app, six classes each; EDIT changes a number in one method body of that module
  local d="$1" edit="$2" m i body; rm -rf "${d:?}"; mkdir -p "$d"
  m_cfg "$d" healthy "http://127.0.0.1:${MPORT}/"
  { printf '<project xmlns="http://maven.apache.org/POM/4.0.0">\n  <modelVersion>4.0.0</modelVersion>\n  <groupId>demo</groupId>\n  <artifactId>parent</artifactId>\n  <version>1.0</version>\n  <packaging>pom</packaging>\n  <modules><module>core</module><module>util</module><module>app</module></modules>\n  <properties>\n    <maven.compiler.release>17</maven.compiler.release>\n    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>\n  </properties>\n  <build>\n    <pluginManagement><plugins>\n%s\n    </plugins></pluginManagement>\n  </build>\n</project>\n' "$PLUGINS"; } > "$d/pom.xml"
  local dep=""
  for m in core util app; do
    mkdir -p "$d/$m/src/main/java/demo/$m"
    { printf '<project xmlns="http://maven.apache.org/POM/4.0.0">\n  <modelVersion>4.0.0</modelVersion>\n  <parent><groupId>demo</groupId><artifactId>parent</artifactId><version>1.0</version></parent>\n  <artifactId>%s</artifactId>\n  <packaging>jar</packaging>\n' "$m"
      [ -n "$dep" ] && printf '  <dependencies>\n    <dependency><groupId>demo</groupId><artifactId>%s</artifactId><version>1.0</version></dependency>\n  </dependencies>\n' "$dep"
      printf '</project>\n'; } > "$d/$m/pom.xml"
    for i in 1 2 3 4 5 6; do
      body="$i"; [ "$edit" = "$m" ] && [ "$i" = 1 ] && body="101"
      printf 'package demo.%s;\n\npublic class C%s {\n    public int f() { return %s; }\n}\n' "$m" "$i" "$body" > "$d/$m/src/main/java/demo/$m/C$i.java"
    done
    dep="$m"
  done
}
mvnrun() { # NAME DIR [JAVA_HOME] [MVN_HOME]   mvn verify with an emptied local build cache; output in $W/m-NAME.out
  local name="$1" dir="$2" jh="${3:-$JDK21_HOME}" mh="${4:-}"
  run "m-$name" "$dir" <<EOF
export HOME="$MH" MAVEN_OPTS="-Duser.home=$MH" JAVA_HOME="$jh" PATH="$jh/bin:${mh:+$mh/bin:}\$PATH"
rm -rf "\$HOME/.m2/build-cache"
mvn verify
EOF
}
has() { grep -qF -- "$2" "$W/m-$1.out"; }
hasre() { grep -qE -- "$2" "$W/m-$1.out"; }
cnt() { local n; n="$(grep -cF -- "$2" "$W/m-$1.out" 2>/dev/null)"; printf '%s' "${n:-0}"; }
mstate() { # NAME  -> "restored|built restored|built ..." for core util app
  local o="" m; for m in core util app; do if has "$1" "Found cached build, restoring demo:$m from cache"; then o="$o restored"; else o="$o built"; fi; done; printf '%s' "${o# }"
}
want() { if [ "$2" = "$3" ]; then echo "OBS $1: $2, as the page says"; else fail "$1: the page says $3; got $2"; fi; }


# =====================================================================================
# Key-diff project for /why-did-this-task-miss-the-build-cache/
# =====================================================================================
QPORT=18170
kd_project() { # DIR SRC NOTES   (SRC changes what compileJava sees; NOTES is the content of notes.txt)
  local d="$1" src="$2" notes="$3"; rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo"
  printf 'rootProject.name = "demo"\n\nbuildCache {\n    local { isEnabled = false }\n    remote<HttpBuildCache> {\n        url = uri("http://127.0.0.1:%s/")\n        isPush = true\n        isAllowInsecureProtocol = true\n    }\n}\n' "$QPORT" > "$d/settings.gradle.kts"
  printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
  printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println("hello %s");\n    }\n}\n' "$src" > "$d/src/main/java/demo/App.java"
  printf '%s\n' "$notes" > "$d/notes.txt"
  cat > "$d/build.gradle.kts" <<'KTS'
plugins { java }

@CacheableTask
abstract class Greet : DefaultTask() {
    @get:Input abstract val label: Property<String>
    @get:OutputFile abstract val out: RegularFileProperty
    @TaskAction fun go() { out.get().asFile.writeText(label.get()) }
}

@CacheableTask
abstract class CopyNotes : DefaultTask() {
    @get:InputFile @get:PathSensitive(PathSensitivity.RELATIVE) abstract val src: RegularFileProperty
    @get:OutputFile abstract val out: RegularFileProperty
    @TaskAction fun go() { src.get().asFile.copyTo(out.get().asFile, true) }
}

abstract class Plain : DefaultTask() {
    @get:Input abstract val label: Property<String>
    @get:OutputFile abstract val out: RegularFileProperty
    @TaskAction fun go() { out.get().asFile.writeText(label.get()) }
}

fun TaskContainer.greet(name: String, value: Provider<String>, file: String = name + ".txt") =
    register<Greet>(name) { label.set(value); out.set(layout.buildDirectory.file(file)) }

tasks.greet("greetEnv", providers.environmentVariable("GREET_LABEL").orElse("none"))
tasks.greet("greetProp", providers.gradleProperty("greetLabel").orElse("none"))
tasks.greet("greetAbs", provider { layout.projectDirectory.asFile.absolutePath })
tasks.greet("greetStable", provider { "stable" })
tasks.register<CopyNotes>("copyNotes") {
    src.set(layout.projectDirectory.file("notes.txt")); out.set(layout.buildDirectory.file("notes-copy.txt"))
}

tasks.greet("onlyOnCi", provider { "x" }).configure { outputs.cacheIf("only on CI") { false } }
tasks.greet("noCacheDev", provider { "x" }).configure { outputs.doNotCacheIf("a developer asked for no caching") { true } }
tasks.register<Plain>("notCacheable") { label.set("x"); out.set(layout.buildDirectory.file("notCacheable.txt")) }
tasks.register("noOutputs") { doLast { println("ran with no declared outputs") } }
tasks.greet("overlapA", provider { "a" }, "overlap.txt")
tasks.greet("overlapB", provider { "b" }, "overlap.txt").configure { mustRunAfter("overlapA") }
KTS
}
SIX="compileJava greetEnv greetProp copyNotes greetAbs greetStable"
kdrun() { # NAME DIR [ENV=value ...] [JAVA=path] [PROP=-Dx=y]   the page's command with the six tasks; the whole log is q-NAME.out
  local name="$1" dir="$2"; shift 2; local envs="" jh="${JDK21_HOME}" props="" e
  for e in "$@"; do case "$e" in JAVA=*) jh="${e#JAVA=}";; PROP=*) props="$props ${e#PROP=}";; *) envs="$envs $e";; esac; done
  qrun "$name" "$dir" "export JAVA_HOME='$jh' PATH=\"$jh/bin:\$PATH\"; env$envs gradle $SIX$props --info -Dorg.gradle.caching.debug=true --console=plain --no-daemon"
  grep -E '^(Appending|Build cache key for task)' "$W/q-$name.out" > "$W/$name.keys"
}
ranset() { # NAME -> the tasks of the six that were not taken from the cache
  local t o=""; for t in $SIX; do [ "$(qstate "$1" "$t")" = cache ] || o="$o $t"; done; printf '%s' "${o# }"
}
kdiff() { diff "$W/$1.keys" "$W/$2.keys"; }

scenario_k() {
  echo; echo "== K  (why-did-this-task-miss-the-build-cache)"
  local D="$W/k" w; mkdir -p "$D"
  start_server k "$QPORT" "" "" || return
  kd_project "$D/b1" 1 "notes one"; kdrun kb1 "$D/b1"
  want "build 1 on an empty server: tasks that ran" "$(ranset kb1)" "$SIX"
  kd_project "$D/b2" 1 "notes one"; kdrun kb2 "$D/b2"
  want "an unchanged repeat from a fresh copy: tasks that ran" "$(ranset kb2)" ""
  cmp -s "$W/kb1.keys" "$W/kb2.keys" && echo "OBS K the two key files are identical for the unchanged repeat" || fail "K the key files of an unchanged repeat differ"
  # the page's own commands, as written
  cp "$W/q-kb1.out" "$W/run1.log"; cp "$W/q-kb2.out" "$W/run2.log"
  ( cd "$W" && grep -E '^(Appending|Build cache key for task)' run1.log > run1.keys && grep -E '^(Appending|Build cache key for task)' run2.log > run2.keys && diff run1.keys run2.keys >/dev/null ) && echo "OBS K the page's grep and diff commands ran; the unchanged repeat gives no diff (exit 0)" || fail "K the page's grep/diff commands on two unchanged builds did not give an empty diff"
  # --- one change at a time, each against the unchanged repeat
  kd_project "$D/c1" 2 "notes one"; kdrun kc1 "$D/c1"
  want "row 'A Java source file': tasks that ran" "$(ranset kc1)" "compileJava"
  kdiff kb2 kc1 | grep -q "stableSources" && echo "OBS K the lines that differed include the stableSources fingerprint" || fail "K row 'A Java source file': the page says the stableSources fingerprint differed"
  kd_project "$D/c2" 1 "notes one"; kdrun kc2 "$D/c2" GREET_LABEL=changed
  want "row 'An environment variable the task reads': tasks that ran" "$(ranset kc2)" "greetEnv"
  kdiff kb2 kc2 | grep -q "Appending input value fingerprint for 'label' to build cache key" && echo "OBS K the differing line is the 'label' value fingerprint, as the page shows" || fail "K row 'environment variable': the page says the 'label' value fingerprint differed"
  kd_project "$D/c3" 1 "notes one"; kdrun kc3 "$D/c3" PROP=-PgreetLabel=changed
  want "row 'A Gradle property, on the command line': tasks that ran" "$(ranset kc3)" "greetProp"
  kd_project "$D/c3b" 1 "notes one"; printf 'greetLabel=changed\n' >> "$D/c3b/gradle.properties"; kdrun kc3b "$D/c3b"
  want "row 'A Gradle property, in gradle.properties': tasks that ran" "$(ranset kc3b)" "greetProp"
  kd_project "$D/c4" 1 "notes two"; kdrun kc4 "$D/c4"
  want "row 'The contents of an input file': tasks that ran" "$(ranset kc4)" "copyNotes"
  kdiff kb2 kc4 | grep -q "'src'" && echo "OBS K the differing line names the 'src' file fingerprint" || fail "K row 'input file': the page says the 'src' file fingerprint differed"
  kd_project "$D/moved/inner" 1 "notes one"; kdrun kc5 "$D/moved/inner"
  want "row 'The project moved to another folder': tasks that ran" "$(ranset kc5)" "greetAbs"
  kd_project "$D/c6" 1 "notes one"; kdrun kc6 "$D/c6" "JAVA=$JDK27_HOME"
  want "row 'Gradle run on Java 27 instead of Java 21': tasks that ran" "$(ranset kc6)" "$SIX"
  for w in jvmTarget javaVersion sourceCompatibility targetCompatibility; do
    kdiff kb2 kc6 | grep -qi "$w" && echo "OBS K the Java 27 run differed in: $w" || fail "K Java 27 row: the page lists $w among the differing lines; it did not differ"
  done
  kdiff kb2 kc6 | grep -q "implementation" && echo "OBS K the custom tasks showed a different 'implementation' line" || fail "K Java 27 row: the page says every custom task showed a different implementation line"
  # --- a rerun is not a miss
  kd_project "$D/r" 1 "notes one"
  qrun kr "$D/r" "export JAVA_HOME='$JDK21_HOME' PATH=\"$JDK21_HOME/bin:\$PATH\"; gradle $SIX --rerun-tasks --info -Dorg.gradle.caching.debug=true --console=plain --no-daemon"
  grep -E '^(Appending|Build cache key for task)' "$W/q-kr.out" > "$W/kr.keys"
  want "--rerun-tasks: tasks that ran" "$(ranset kr)" "$SIX"
  cmp -s "$W/kb2.keys" "$W/kr.keys" && echo "OBS K with --rerun-tasks the keys were identical to the unchanged repeat" || fail "K the page says the --rerun-tasks keys were identical to the unchanged repeat"
  grep -qF "Executed with '--rerun-tasks'." "$W/q-kr.out" && grep -qE "^Stored cache entry for task ':greetStable' with cache key [0-9a-f]+" "$W/q-kr.out" && echo "OBS K the log says why (Executed with '--rerun-tasks'.) and the result is stored again" || fail "K the page's two --rerun-tasks log lines were not both there"
  # --- tasks with no key at all
  kd_project "$D/n" 1 "notes one"
  qrun kn "$D/n" "export JAVA_HOME='$JDK21_HOME' PATH=\"$JDK21_HOME/bin:\$PATH\"; gradle onlyOnCi noCacheDev notCacheable noOutputs overlapA overlapB --info --console=plain --no-daemon"
  local t
  for t in onlyOnCi noCacheDev notCacheable noOutputs overlapB; do
    grep -qF "Caching disabled for task ':$t' because:" "$W/q-kn.out" && echo "OBS K ':$t': 'Caching disabled for task ... because:' is printed" || fail "K ':$t': the page says Gradle prints 'Caching disabled for task ... because:'"
    grep -qF "Build cache key for task ':$t'" "$W/q-kn.out" && fail "K ':$t' printed a 'Build cache key' line; the page says none of these did" || true
  done
  grep -qF "'only on CI' not satisfied" "$W/q-kn.out" && echo "OBS K cacheIf reason printed as the page shows" || fail "K the page's reason 'only on CI' not satisfied is missing"
  grep -qF "'a developer asked for no caching' satisfied" "$W/q-kn.out" && echo "OBS K doNotCacheIf reason printed as the page shows" || fail "K the page's reason 'a developer asked for no caching' satisfied is missing"
  grep -qF "Caching has not been enabled for the task" "$W/q-kn.out" && echo "OBS K 'Caching has not been enabled for the task' printed" || fail "K the page's reason 'Caching has not been enabled for the task' is missing"
  grep -qF "Gradle would require more information to cache this task" "$W/q-kn.out" && echo "OBS K 'Gradle would require more information to cache this task' printed" || fail "K the page's reason 'Gradle would require more information to cache this task' is missing (log has: $(grep -A1 "Caching disabled for task ':noOutputs'" "$W/q-kn.out" | tr '\n' ' ' | cut -c1-200))"
  grep -qF "Gradle does not know how file 'build/overlap.txt' was created" "$W/q-kn.out" && echo "OBS K the overlapping-output reason printed as the page shows" || fail "K the page's 'Gradle does not know how file build/overlap.txt was created' is missing (log has: $(grep -m2 -i 'overlap' "$W/q-kn.out" | tr '\n' ' ' | cut -c1-300))"
  grep -qF "Stored cache entry for task ':overlapA'" "$W/q-kn.out" && echo "OBS K the first of the two overlapping tasks was cached" || fail "K the page says the first overlapping task was cached"
  stop_server
}

# =====================================================================================
# G  /what-gradle-stores-in-build-cache/  (the Gradle half)
# =====================================================================================
scenario_g() {
  echo; echo "== G  (what-gradle-stores-in-build-cache: Gradle)"
  local D="$W/g" GH="$W/g-home" m t; mkdir -p "$D"; rm -rf "$GH"; mkdir -p "$GH"
  start_server g1 "$QPORT" "" "" || return
  q_project "$D/p1" none
  run g1 "$D/p1" <<EOF
export GRADLE_USER_HOME="$GH" JAVA_HOME="$JDK21_HOME" PATH="$JDK21_HOME/bin:\$PATH"
gradle build -i --console=plain --no-daemon
EOF
  expect g1 "BUILD SUCCESSFUL"
  grep "Stored cache entry" "$W/g1.out" > "$W/g1.stored"
  want "gradle build -i | grep 'Stored cache entry': lines" "$(wc -l < "$W/g1.stored" | tr -d ' ')" 13
  for m in core util api app; do want ":$m:compileJava stored" "$(grep -c "Stored cache entry for task ':$m:compileJava'" "$W/g1.stored")" 1; done
  want "Kotlin build script compilation, first stage" "$(grep -c 'Stored cache entry for Kotlin DSL script compilation (Project/TopLevel/stage1)' "$W/g1.stored")" 5
  want "Kotlin build script compilation, second stage" "$(grep -c 'Stored cache entry for Kotlin DSL script compilation (Project/TopLevel/stage2)' "$W/g1.stored")" 4
  want "the server's entries after the build" "$(sfield $QPORT store_entries)" 13
  echo "OBS G the server holds $(sfield $QPORT store_bytes) bytes (the page: about 36 KB, 36,054 to 36,103 bytes)"
  for m in core util api app; do for t in classes jar assemble build; do
    grep -q "Stored cache entry for task ':$m:$t'" "$W/g1.out" && fail "G ':$m:$t' stored an entry; the page says classes, jar, assemble and build stored nothing"
    grep -qxF "> Task :$m:$t FROM-CACHE" "$W/g1.out" && fail "G ':$m:$t' came FROM-CACHE; the page says the jar tasks never did"
  done; done
  echo "OBS G classes, jar, assemble and build of the four modules were not stored and not taken from the cache"
  stop_server
  # a second run with the same Gradle home against a new empty server: the script entries are not stored again
  start_server g2 "$QPORT" "" "" || return
  q_project "$D/p2" none
  run g2 "$D/p2" <<EOF
export GRADLE_USER_HOME="$GH" JAVA_HOME="$JDK21_HOME" PATH="$JDK21_HOME/bin:\$PATH"
gradle build -i --console=plain --no-daemon
EOF
  expect g2 "BUILD SUCCESSFUL"
  want "same Gradle home, new empty server: 'Stored cache entry' lines" "$(grep -c 'Stored cache entry' "$W/g2.out")" 4
  want "...of which compileJava" "$(grep -c "Stored cache entry for task ':[a-z]*:compileJava'" "$W/g2.out")" 4
  want "...the server's entries" "$(sfield $QPORT store_entries)" 4
  echo "OBS G ...and its bytes: $(sfield $QPORT store_bytes) (the page: 11,425)"
  stop_server
}

# ---------- run ----------
curl -skf --max-time 3 "localhost:${QPORT}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${QPORT}: not starting" >&2; exit 1; }
scenario_k
scenario_g
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
