#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 10: do the commands and promised outputs of three Maven pages really happen?
#   Y  /maven-build-cache-extension-multi-module/       the six builds of the three-module table (which module was restored, which built)
#   Z  /maven-build-cache-extension-not-restoring/      a healthy first and second build (their log lines, the server's counters), the three symptoms
#                                                       (a misplaced <remote>, no saveToRemote, a 401 from a wrong server id or password), Maven 3.9.9's
#                                                       log line, and the Java 21 / Java 27 series (built or restored, jar checksums, manifest)
#   W  /what-gradle-stores-in-build-cache/ (Maven half) the entries and bytes of a three-module build and of a fully restored second build
# Run by the "bench-howto-pages-10" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-10"). Same method as the other
# bench scripts. No token and no secret; downloads are checked against pinned checksums (Gradle is not used here, only cosign for the release); the
# release binary is verified (cosign + sha256) before it runs. Servers listen on 127.0.0.1 only; made-up passwords.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # where bench-proxy.py lives

VER="${BENCH_VER:-0.2.2}"   # the release the pages name; a scheduled proof run passes the newest release tag (checked by the workflow, and again here)
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad release version: $VER" >&2; exit 2; }
LOCAL="${BENCH_LOCAL:-0}"                    # 1 = a developer's dry run with local tools (nothing downloaded or checked: do not quote times)
if [ "$LOCAL" = 1 ]; then PLATFORM="${BENCH_PLATFORM:-darwin_arm64}"; else PLATFORM=linux_amd64; fi
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
EXT_VER=1.2.3
IMG=ghcr.io/fosterstack/cache
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
echo "invented by this script (the pages show their configuration, not their projects): the Java classes of the one-module and three-module projects, made-up passwords and keys"
echo "differences from the pages' own runs: Linux amd64 (the pages: macOS arm64), release ${VER} (the pages: 0.2.1), Maven 3.10.0 on the runner as on the pages; the page's Java 27 is Temurin 27+35 here (the page: OpenJDK 27 from Homebrew); builds run offline-capable only after the first build has filled the shared Maven repository (the pages: an already-filled local repository)"
echo "Gradle builds use a new empty Gradle home and a fresh project copy each, no daemon, Gradle's own local cache switched off; Maven builds use an emptied ~/.m2/build-cache"
echo "differences from the what-stores page: the Maven half here runs on Java 21 (the page's Maven numbers came from a Mac run; its Java is not the point of that half)"
echo "differences from the not-restoring page: the page ran its symptom runs against a server with a password; here only the 401 symptom uses one (the others use a server without a login); the builds are not offline"
echo "NOT tested here (as on the pages): other Maven or extension versions, other Java vendors, projects whose build settings change with the Java version, Windows, large jars"
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
# Y  /maven-build-cache-extension-multi-module/
# =====================================================================================
scenario_y() {
  echo; echo "== Y  (maven-build-cache-extension-multi-module)"
  local D="$W/y" S; mkdir -p "$D"
  echo "OBS Y Maven: $(mvn --version 2>/dev/null | head -n 1)"
  start_server y "$MPORT" "" "" || return
  local i edit; i=0
  for edit in none none core core app util; do
    i=$((i+1)); mm_project "$D/b$i" "$edit"; mvnrun "y$i" "$D/b$i"; expect "m-y$i" "BUILD SUCCESS"
  done
  want "table, build 1 (first build, as CI would do it): core util app" "$(mstate y1)" "built built built"
  want "table, build 2 (another machine, same code)" "$(mstate y2)" "restored restored restored"
  want "table, build 3 (edit inside a method in core)" "$(mstate y3)" "built built built"
  want "table, build 4 (a teammate makes the same edit)" "$(mstate y4)" "restored restored restored"
  want "table, build 5 (edit only app)" "$(mstate y5)" "restored restored built"
  want "table, build 6 (edit only util)" "$(mstate y6)" "restored built built"
  stop_server
}

# =====================================================================================
# Z  /maven-build-cache-extension-not-restoring/
# =====================================================================================
jarsum() { [ -s "$1/target/demo-1.0.jar" ] && sha256sum "$1/target/demo-1.0.jar" | cut -c1-16 || echo "MISSING-JAR-$RANDOM"; }
scenario_z() {
  echo; echo "== Z  (maven-build-cache-extension-not-restoring)"
  local D="$W/z" S U="http://127.0.0.1:${MPORT}/" b i n
  mkdir -p "$D"
  # --- a healthy first and second build
  start_server z1 "$MPORT" "" "" || return
  m1_project "$D/h" 301 healthy "$U" 0; mvnrun zh1 "$D/h"; expect m-zh1 "BUILD SUCCESS"
  has zh1 "[INFO] Attempting to restore project demo:demo from build cache" && echo "OBS Z the first build logged 'Attempting to restore project demo:demo from build cache'" || fail "Z the first build should log 'Attempting to restore project demo:demo from build cache'"
  hasre zh1 '^\[ERROR\] Error downloading cache item: http://127\.0\.0\.1:18180//v1\.1/demo/demo/[0-9a-f]{16}/buildinfo\.xml' && echo "OBS Z Maven 3.10.0 logged the miss as '[ERROR] Error downloading cache item: ...//v1.1/demo/demo/<id>/buildinfo.xml', as the page shows" || fail "Z the page says Maven 3.10.0 logs the first miss as an [ERROR] 'Error downloading cache item' line"
  hasre zh1 '^\[INFO\] Saved to remote cache http://127\.0\.0\.1:18180//v1\.1/demo/demo/[0-9a-f]{16}/demo\.jar$' && hasre zh1 '^\[INFO\] Saved to remote cache http://127\.0\.0\.1:18180//v1\.1/demo/demo/[0-9a-f]{16}/buildinfo\.xml$' && echo "OBS Z the first build logged both 'Saved to remote cache' lines (demo.jar and buildinfo.xml)" || fail "Z the page says the first build logs 'Saved to remote cache' for demo.jar and buildinfo.xml"
  want "server after the healthy first build: store_entries" "$(sfield $MPORT store_entries)" 3
  rm -rf "$D/h/target"; mvnrun zh2 "$D/h"; expect m-zh2 "BUILD SUCCESS"
  hasre zh2 '^\[INFO\] Found cached build, restoring demo:demo from cache by checksum [0-9a-f]{16}$' && echo "OBS Z the second build (target and the local cache folder deleted): 'Found cached build, restoring demo:demo from cache by checksum <id>'" || fail "Z the page says the second build logs 'Found cached build, restoring demo:demo from cache by checksum <id>'"
  want "server after the restoring build: cache_hits" "$(sfield $MPORT cache_hits)" 2
  # --- Maven 3.9.9 logs the miss differently
  m1_project "$D/h399" 302 healthy "$U" 0; mvnrun zh399 "$D/h399" "$JDK21_HOME" "$MVN399_HOME"; expect m-zh399 "BUILD SUCCESS"
  has zh399 "[INFO] Cache item not found" && ! has zh399 "Error downloading cache item" && echo "OBS Z Maven 3.9.9 logged the miss as '[INFO] Cache item not found', as the page says" || fail "Z the page says Maven 3.9.9 logs a miss as '[INFO] Cache item not found' and not as an [ERROR]"
  stop_server
  # --- symptom 1: the remote element outside configuration
  start_server z2 "$MPORT" "" "" || return
  m1_project "$D/s1" 303 outside "$U" 0; mvnrun zs1 "$D/s1"
  [ "$RC" != 0 ] && echo "OBS Z symptom 1: Maven stopped (exit $RC)" || fail "Z symptom 1: the page says Maven stops; it exited 0"
  has zs1 "Cannot initialize cache because xml config is not valid or not available" && has zs1 "Unable to parse cache xml element: Unrecognised tag: 'remote'" && echo "OBS Z symptom 1: both log lines of the page are there" || fail "Z symptom 1: the page's two log lines ('Cannot initialize cache because xml config is not valid or not available', 'Unable to parse cache xml element: Unrecognised tag: remote') are not both in the log"
  want "symptom 1: 'Compiling' and 'Saved to remote cache' lines (nothing built)" "$(cnt zs1 'Compiling')/$(cnt zs1 'Saved to remote cache')" "0/0"
  want "symptom 1: the server saw nothing (hits+misses+entries)" "$(sfield $MPORT cache_hits)/$(sfield $MPORT cache_misses)/$(sfield $MPORT store_entries)" "0/0/0"
  stop_server
  # --- symptom 2: no saveToRemote="true"
  start_server z3 "$MPORT" "" "" || return
  m1_project "$D/s2" 304 nosave "$U" 0; mvnrun zs2a "$D/s2"; expect m-zs2a "BUILD SUCCESS"
  want "symptom 2: 'Saved to remote cache' lines in the first build" "$(cnt zs2a 'Saved to remote cache')" 0
  rm -rf "$D/s2/target"; mvnrun zs2b "$D/s2"; expect m-zs2b "BUILD SUCCESS"
  has zs2b "Remote cache is incomplete or missing" && echo "OBS Z symptom 2: the second build says 'Remote cache is incomplete or missing'" || fail "Z symptom 2: the page says the second build says 'Remote cache is incomplete or missing'"
  want "symptom 2: the server's store_entries" "$(sfield $MPORT store_entries)" 0
  stop_server
  # --- symptom 3: a 401, from a wrong server id and from a wrong password
  start_server z4 "$MPORT2" maven right-secret || return
  for b in id password; do
    cat > "$MH/.m2/settings.xml" <<EOF
<settings>
  <servers>
    <server>
      <id>$([ "$b" = id ] && echo "some-other-id" || echo "fosterstack-cache")</id>
      <username>maven</username>
      <password>$([ "$b" = id ] && echo "right-secret" || echo "wrong-secret")</password>
    </server>
  </servers>
</settings>
EOF
    m1_project "$D/s3$b" 305 healthy "http://127.0.0.1:${MPORT2}/" 0; mvnrun "zs3$b" "$D/s3$b"; expect "m-zs3$b" "BUILD SUCCESS"
    has "zs3$b" "HTTP Status: 401" && echo "OBS Z symptom 3 ($b mistake): 'HTTP Status: 401' in the log and BUILD SUCCESS" || fail "Z symptom 3 ($b mistake): the page says the log has 'HTTP Status: 401'"
    has "zs3$b" "org.eclipse.aether.spi.connector.transport.http.HttpTransporterException: HTTP Status: 401" && echo "OBS Z   the log has the page's line 'org.eclipse.aether.spi.connector.transport.http.HttpTransporterException: HTTP Status: 401'" || fail "Z symptom 3 ($b mistake): the page quotes 'org.eclipse.aether.spi.connector.transport.http.HttpTransporterException: HTTP Status: 401'; the log has: $(grep -m1 'HTTP Status: 401' "$W/m-zs3$b.out" | cut -c1-200)"
    want "symptom 3 ($b mistake): 'Saved to remote cache' lines" "$(cnt "zs3$b" 'Saved to remote cache')" 0
    want "symptom 3 ($b mistake): the server stays empty (store_entries)" "$(curl -s --max-time 10 -u maven:right-secret "http://127.0.0.1:${MPORT2}/statusz" | python3 -c "import sys,json;print(json.load(sys.stdin)['store_entries'])" 2>/dev/null)" 0
    grep -iE 'credentials|authentication' "$W/m-zs3$b.out" | head -n 2 | cut -c1-200 | sed 's/^/OBS Z   a line about credentials in the log: /'
  done
  rm -f "$MH/.m2/settings.xml"
  stop_server
  # --- Java 21 and Java 27: three series of five builds
  local ser seq rel jh j first sums sumsA mf cls
  for ser in A B C; do
    case "$ser" in A) seq="21 21 27 27 21"; rel=1;; B) seq="21 21 27 27 21"; rel=0;; C) seq="27 27 21 21 27"; rel=0;; esac
    start_server "zj$ser" "$MPORT" "" "" || return
    n=0; sums=""
    for j in $seq; do
      n=$((n+1)); [ "$j" = 21 ] && jh="$JDK21_HOME" || jh="$JDK27_HOME"
      m1_project "$D/j$ser$n" 400 healthy "$U" "$rel"; mvnrun "zj$ser$n" "$D/j$ser$n" "$jh"; expect "m-zj$ser$n" "BUILD SUCCESS"
      if [ "$n" = 1 ]; then has "zj$ser$n" "Found cached build" && fail "Z Java series $ser, build 1 (Java $j): the page says it built, not restored" || echo "OBS Z Java series $ser, build 1 (Java $j): built"
      else has "zj$ser$n" "Found cached build, restoring" && echo "OBS Z Java series $ser, build $n (Java $j): restored" || fail "Z Java series $ser, build $n (Java $j): the page says restored"; fi
      sums="$sums $(jarsum "$D/j$ser$n")"
    done
    [ "$(printf '%s\n' $sums | sort -u | wc -l | tr -d ' ')" = 1 ] && echo "OBS Z Java series $ser: all five jars have one checksum (${sums# })" || fail "Z Java series $ser: the page says all five jars had one checksum; got: $sums"
    first="$(printf '%s' "$seq" | cut -d' ' -f1)"
    for n in 1 2 3 4 5; do
      mf="$(unzip -p "$D/j${ser}${n}/target/demo-1.0.jar" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' | grep -E '^Build-Jdk-Spec')"
      want "Java series $ser, build $n (Java $(printf '%s' "$seq" | cut -d' ' -f$n)): the manifest of the jar it ended with names the first build's Java" "$mf" "Build-Jdk-Spec: $first"
    done
    unzip -p "$D/j${ser}5/target/demo-1.0.jar" demo/App.class > "$W/z/App-$ser.class" 2>/dev/null
    if [ "$ser" = A ]; then has zjA1 "release 17" || has zjA1 "--release 17" && echo "OBS Z series A: the compiler log names release 17" || fail "Z series A: the log should name release 17"
    else has "zj${ser}1" "target 1.8" && echo "OBS Z series $ser: the compiler log says target 1.8, as the page says" || fail "Z series $ser: the page says the log said target 1.8"; fi
    stop_server
  done
  [ -s "$W/z/App-B.class" ] && [ -s "$W/z/App-C.class" ] && cmp -s "$W/z/App-B.class" "$W/z/App-C.class" && echo "OBS Z the compiled class in the Java 21 jar and the Java 27 jar is byte for byte the same (cmp), as the page says" || fail "Z the page says the class was byte for byte the same on both Javas (cmp)"
}

# =====================================================================================
# W  /what-gradle-stores-in-build-cache/  (the Maven half)
# =====================================================================================
scenario_w() {
  echo; echo "== W  (what-gradle-stores-in-build-cache: Maven)"
  local D="$W/w" S1 S2 u sz sj sb srep tot k info; mkdir -p "$D"
  start_server w "$MPORT" "" "" || return
  want "empty server: entries" "$(sfield $MPORT store_entries)" 0
  mm_project "$D/m1" none; mvnrun w1 "$D/m1"; expect m-w1 "BUILD SUCCESS"
  want "after the first build (all three modules built): entries" "$(sfield $MPORT store_entries)" 7
  S1="$(sfield $MPORT store_bytes)"
  want "first build: 'Saved to remote cache' lines for jars" "$(grep -c 'Saved to remote cache.*\.jar$' "$W/m-w1.out")" 3
  want "first build: 'Saved to remote cache' lines for buildinfo.xml" "$(grep -c 'Saved to remote cache.*buildinfo\.xml$' "$W/m-w1.out")" 3
  want "first build: 'Saved to remote cache' lines for build-cache-report.xml" "$(grep -c 'Saved to remote cache.*build-cache-report\.xml$' "$W/m-w1.out")" 1
  want "first build: '[ERROR] Error downloading cache item ... buildinfo.xml' lines (Maven 3.10.0 logs the misses so)" "$(grep -c '^\[ERROR\] Error downloading cache item.*buildinfo\.xml' "$W/m-w1.out")" 3
  tot=0; sj=0; sb=0
  for u in $(grep -oE 'Saved to remote cache [^ ]+' "$W/m-w1.out" | awk '{print $5}'); do
    u="$(printf '%s' "$u" | sed -E 's#([^:])//+#\1/#g')"   # the log prints a doubled slash after the host; the server refuses an empty path segment (400 'invalid key'), so ask for the single-slash form
    info="$(curl -s --max-time 30 -o /dev/null -w '%{http_code} %{size_download}' "$u")"; sz="${info#* }"; tot=$((tot+sz))
    [ "${info%% *}" = 200 ] || fail "W fetching a saved entry ($u) answered ${info%% *}, not 200"
    case "$u" in *.jar) sj=$((sj+sz));; *buildinfo.xml) sb=$((sb+sz));; esac
  done
  echo "OBS W the seven entries: jars $sj bytes in all, buildinfo.xml files $sb bytes in all, together with the report $tot bytes; the server says $S1 bytes"
  want "the sizes of the seven entries add up to the server's store_bytes" "$tot" "$S1"
  [ "$sb" -gt "$sj" ] && echo "OBS W the buildinfo.xml files ($sb bytes) are bigger than the jars ($sj bytes) in this small project, as the page says" || fail "W the page says the buildinfo.xml files were bigger than the jars in its small project; here $sb against $sj"
  mm_project "$D/m2" none; mvnrun w2 "$D/m2"; expect m-w2 "BUILD SUCCESS"
  want "second build from a fresh copy: all three restored" "$(mstate w2)" "restored restored restored"
  want "...it added one entry (entries)" "$(sfield $MPORT store_entries)" 8
  want "...and it uploaded one file: 'Saved to remote cache' lines" "$(cnt w2 'Saved to remote cache')" 1
  want "...and that Saved line is the build-cache-report.xml" "$(grep -c 'Saved to remote cache.*build-cache-report\.xml$' "$W/m-w2.out")" 1
  S2="$(sfield $MPORT store_bytes)"; echo "OBS W the restored build added $((S2-S1)) bytes (the page: 1,318)"
  stop_server
}

# ---------- run ----------
for port in 18180 18181; do
  curl -skf --max-time 3 "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
scenario_y
scenario_z
scenario_w
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
