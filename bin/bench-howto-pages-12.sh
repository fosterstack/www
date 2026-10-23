#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 12: do the commands and promised outputs of three pages really happen?
#   T  /gradle-test-task-from-cache/                       Gradle runs 1-7 (compileJava / compileTestJava / test, built or from the cache, a failing test) and
#                                                          Maven runs 1-6 (restored or built, Tests run, the skipped plugin executions)
#   S  /several-projects-share-one-build-cache-server/     three projects on one server, direct requests with a read-write and a read-only login, one server for each
#                                                          team, a small size cap shared by all projects
#   A  /air-gapped-build-cache-install/                    the page's verify commands word for word, a tampered archive, the unpacked static binary, the server
#                                                          running with only a loopback interface, the page's docker load and docker run lines
# Run by the "bench-howto-pages-12" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-12"). Same method as the other
# bench scripts. No token and no secret; downloads are checked against pinned checksums (Gradle, cosign); the release binary is verified (cosign +
# sha256) before it runs. Servers listen on 127.0.0.1 only; made-up passwords.
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
for t in gh cosign gradle curl python3 tar mvn openssl; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
GRADLE_BIN="$(command -v gradle)"

echo "== DISCLOSURE"
echo "runner: $(uname -sr); cpus: $(nproc 2>/dev/null || sysctl -n hw.ncpu); image: ${ImageOS:-?} ${ImageVersion:-?}"
echo "java: $("$JDK21_HOME/bin/java" -version 2>&1 | head -1)   gradle: $(gradle --version 2>/dev/null | grep -E '^Gradle ' | head -1)   cosign: $(cosign version 2>/dev/null | grep -i GitVersion | head -1)   docker: $(docker --version)"
if [ "$LOCAL" = 1 ]; then echo "tools: LOCAL tools in use, nothing checked (a developer's dry run: do not quote these times)"; else
  echo "tools: Gradle ${GR_VER} and cosign ${COSIGN_VER} are downloaded and checked against pinned checksums before use; Java 21 and Docker are the runner's own"; fi
echo "release under test: FosterStack Cache ${VER}, downloaded with no login and verified (cosign + sha256) before it runs; every server listens on 127.0.0.1 only"
echo "NOT checksum-pinned: the Maven build-cache extension 1.2.3, the Maven plugin jars (their eight versions are pinned in the poms, the files come from Maven Central), the JUnit 5.11.0 libraries (Maven Central), and the container image ghcr.io/fosterstack/cache:${VER} (pulled by tag; the page verifies it with cosign, which this job does not do); the runner's own Maven (version printed) is used"
echo "invented by this script (the pages show their build files only in part): the one-class Calc project and its JUnit tests, the three small Gradle projects A, B and C, made-up logins"
echo "differences from the pages' own runs: Linux amd64 (the pages: macOS arm64), release ${VER} (the pages: 0.2.1), Gradle ${GR_VER}, Java 21 (the test-task page: Java 27); the air-gapped page's crane pull is replaced by docker pull and docker save, and its docker run line gets a --name so the container can be removed; the no-route test uses a network namespace with only a loopback interface"
echo "Gradle builds in scenario S use a new empty Gradle home and a fresh project copy each, no daemon, Gradle's own local cache off; scenario T shares one Gradle home between its runs (the test libraries are downloaded once, as on the page); every Maven build uses a fresh copy and an emptied ~/.m2/build-cache"
echo "NOT tested here (as on the pages): tests that read the clock or the network, several modules, many projects at once, real project sizes, Maven in the several-projects page, verifying the container image with cosign, a machine with no network at all (only a network namespace with a loopback interface)"
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
sfield() { # PORT FIELD  one field of /statusz; the login (USER:PASS) is read from the variable SFA_<port> when the server has one
  local v="SFA_$1" auth=""; auth="${!v:-}"
  curl -s --max-time 30 ${auth:+-u "$auth"} "http://127.0.0.1:$1/statusz" | python3 -c "import sys,json;print(json.load(sys.stdin)['$2'])" 2>/dev/null || echo unreadable
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



stop_proxy() { :; }; stop_tls() { :; }   # the exit trap of the shared base calls these two; this job starts neither

# =====================================================================================
# Maven helpers
# =====================================================================================
MPORT=18180; MPORT2=18181
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
# T  /gradle-test-task-from-cache/   (Gradle runs 1-7, Maven runs 1-6)
# =====================================================================================
TPORT=18150
tg_project() { # DIR VARIANT   (base | main3 | test4 | comment | failing)   one class, two JUnit tests; each variant starts from the base project
  local d="$1" v="$2" body="return a + b;" after="" extra="" two="assertEquals(4, Calc.add(2, 2));"
  case "$v" in main3) body="return a + b + 0;";; comment) after=" // sums";; test4) extra='    @Test void addsZero() { assertEquals(0, Calc.add(0, 0)); }';; failing) two="assertEquals(5, Calc.add(2, 2));";; esac
  rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo" "$d/src/test/java/demo"
  printf 'package demo;\n\npublic class Calc {\n    public static int add(int a, int b) { %s }%s\n}\n' "$body" "$after" > "$d/src/main/java/demo/Calc.java"
  printf 'package demo;\n\nimport org.junit.jupiter.api.Test;\nimport static org.junit.jupiter.api.Assertions.assertEquals;\n\nclass CalcTest {\n    @Test void addsOne() { assertEquals(3, Calc.add(1, 2)); }\n    @Test void addsTwo() { %s }\n%s\n}\n' "$two" "$extra" > "$d/src/test/java/demo/CalcTest.java"
}
tg_gradle_files() { # DIR PORT
  local d="$1" port="$2"
  cat > "$d/build.gradle.kts" <<'KTS'
plugins { java }
repositories { mavenCentral() }
dependencies {
    testImplementation(platform("org.junit:junit-bom:5.11.0"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}
tasks.test { useJUnitPlatform() }
KTS
  printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
  printf 'rootProject.name = "gtest"\n\nbuildCache {\n    local { isEnabled = false }\n    remote<HttpBuildCache> {\n        url = uri("http://127.0.0.1:%s/")\n        isPush = true\n        isAllowInsecureProtocol = true\n    }\n}\n' "$port" > "$d/settings.gradle.kts"
}
tg_state() { # NAME TASK  -> ran | cache | failed | missing   (exact task lines)
  local f="$W/$1.out"
  if grep -qxF "> Task :$2 FROM-CACHE" "$f"; then echo cache; elif grep -qxF "> Task :$2 FAILED" "$f"; then echo failed; elif grep -qxF "> Task :$2" "$f"; then echo ran; else echo missing; fi
}
tg_run() { # NAME VARIANT OUTCOME(ok|fail)   a fresh copy of the project, one shared Gradle home (the test libraries are downloaded once)
  local name="$1" v="$2" outcome="$3" d="$W/t/$1"
  tg_project "$d" "$v"; tg_gradle_files "$d" "$TPORT"
  run "$name" "$d" <<EOF
export GRADLE_USER_HOME="$W/tg-home" JAVA_HOME="$JDK21_HOME" PATH="$JDK21_HOME/bin:\$PATH"
gradle test --console=plain --no-daemon
EOF
  if [ "$outcome" = ok ]; then expect "$name" "BUILD SUCCESSFUL"; else NOZERO=1 expect "$name" "BUILD FAILED"; [ "$RC" != 0 ] || fail "$name: a failing test should end the build with a non-zero exit"; fi
  rm -rf "$d"
}
tg_check() { # LABEL NAME "want: compileJava compileTestJava test"
  local got; got="$(tg_state "$2" compileJava) $(tg_state "$2" compileTestJava) $(tg_state "$2" test)"
  if [ "$got" = "$3" ]; then echo "OBS T $1: compileJava / compileTestJava / test = $got, as the page says"; else fail "T $1: the page says '$3'; the build did '$got'"; fi
}
tm_project() { # DIR VARIANT   one module demo:mtest, one class, two JUnit tests, Surefire 3.5.2
  local d="$1" v="$2"; tg_project "$d" "$v"; mkdir -p "$d/src/main/java/demo"
  m_cfg "$d" healthy "http://127.0.0.1:${TPORT}/"
  { printf '<project xmlns="http://maven.apache.org/POM/4.0.0">\n  <modelVersion>4.0.0</modelVersion>\n  <groupId>demo</groupId>\n  <artifactId>mtest</artifactId>\n  <version>1.0</version>\n  <packaging>jar</packaging>\n  <properties>\n    <maven.compiler.release>17</maven.compiler.release>\n    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>\n  </properties>\n  <dependencies>\n    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><version>5.11.0</version><scope>test</scope></dependency>\n  </dependencies>\n  <build>\n    <pluginManagement><plugins>\n%s\n    </plugins></pluginManagement>\n  </build>\n</project>\n' "$PLUGINS"; } > "$d/pom.xml"
}
tm_run() { # NAME VARIANT   a fresh copy, an emptied local build cache
  local name="$1" v="$2" d="$W/t/$1"
  tm_project "$d" "$v"; mvnrun "$name" "$d"; rm -rf "$d"
}

scenario_t() {
  echo; echo "== T  (gradle-test-task-from-cache)"
  mkdir -p "$W/t"; rm -rf "$W/tg-home"; mkdir -p "$W/tg-home"
  start_server t "$TPORT" "" "" || return
  tg_run tg1 base ok;     tg_check "run 1 (first build, as CI would do it)" tg1 "ran ran ran"
  tg_run tg2 base ok;     tg_check "run 2 (fresh copy, same code)" tg2 "cache cache cache"
  grep -qxF "> Task :test FROM-CACHE" "$W/tg2.out" && echo "OBS T run 2 printed the page's line '> Task :test FROM-CACHE'" || fail "T run 2 did not print '> Task :test FROM-CACHE'"
  tg_run tg3 main3 ok;    tg_check "run 3 (change the main code)" tg3 "ran cache ran"
  tg_run tg4 test4 ok;    tg_check "run 4 (add a test)" tg4 "cache ran ran"
  tg_run tg5 comment ok;  tg_check "run 5 (a comment on the same line in the main code)" tg5 "ran cache cache"
  tg_run tg6 failing fail; tg_check "run 6 (a test that fails)" tg6 "cache ran failed"
  tg_run tg7 failing fail; tg_check "run 7 (the same failing test, fresh copy)" tg7 "cache cache failed"
  grep -qF "2 tests completed, 1 failed" "$W/tg7.out" && echo "OBS T run 7 reported '2 tests completed, 1 failed', as the page says" || fail "T run 7: the page says '2 tests completed, 1 failed'"
  # --- Maven
  tm_run tm1 base;    expect "m-tm1" "BUILD SUCCESS"
  want "Maven run 1: built (no restore line)" "$(has tm1 'Found cached build' && echo restored || echo built)" built
  hasre tm1 '\] Tests run: 2, Failures: 0, Errors: 0' && echo "OBS T Maven run 1: 'Tests run: 2'" || fail "T Maven run 1: the page says 2 tests ran"
  tm_run tm2 base;    expect "m-tm2" "BUILD SUCCESS"
  hasre tm2 'Found cached build, restoring demo:mtest from cache by checksum' && echo "OBS T Maven run 2: restored (Found cached build, restoring demo:mtest from cache by checksum)" || fail "T Maven run 2: the page says it restored the module"
  want "Maven run 2: 'Tests run:' lines" "$(cnt tm2 'Tests run:')" 0
  for st in resources:resources compiler:compile resources:testResources compiler:testCompile surefire:test jar:jar; do
    has tm2 "[INFO] Skipping plugin execution (cached): $st" || fail "T Maven run 2: the page lists 'Skipping plugin execution (cached): $st'; not in the log"
  done
  echo "OBS T Maven run 2: the six 'Skipping plugin execution (cached)' lines of the page were checked"
  tm_run tm3 main3;   expect "m-tm3" "BUILD SUCCESS"
  has tm3 "Found cached build" && fail "T Maven run 3 (change the main code): the page says it built" || echo "OBS T Maven run 3: built"
  hasre tm3 '\] Tests run: 2, Failures: 0' && echo "OBS T Maven run 3: 'Tests run: 2'" || fail "T Maven run 3: the page says 2 tests ran"
  tm_run tm4 test4;   expect "m-tm4" "BUILD SUCCESS"
  has tm4 "Found cached build" && fail "T Maven run 4 (add a test): the page says it built" || echo "OBS T Maven run 4: built"
  hasre tm4 '\] Tests run: 3, Failures: 0' && echo "OBS T Maven run 4: 'Tests run: 3'" || fail "T Maven run 4: the page says 3 tests ran"
  tm_run tm5 failing; NOZERO=1 expect "m-tm5" "BUILD FAILURE"
  hasre tm5 '\] Tests run: 2, Failures: 1' && echo "OBS T Maven run 5: 'Tests run: 2, Failures: 1', BUILD FAILURE" || fail "T Maven run 5: the page says 2 tests with 1 failure"
  tm_run tm6 failing; NOZERO=1 expect "m-tm6" "BUILD FAILURE"
  has tm6 "Found cached build" && fail "T Maven run 6: the page says a failing build was not restored" || echo "OBS T Maven run 6: built again, not restored"
  hasre tm6 '\] Tests run: 2, Failures: 1' && echo "OBS T Maven run 6: 'Tests run: 2, Failures: 1', BUILD FAILURE" || fail "T Maven run 6: the page says 2 tests with 1 failure"
  stop_server
}

# =====================================================================================
# S  /several-projects-share-one-build-cache-server/
# =====================================================================================
SPORT=18160; SPORT2=18161
RWU=ci; RWP=rw-secret-1; ROU=dev; ROP=ro-secret-1
T1U=team1; T1P=t1-secret; T2U=team2; T2P=t2-secret
sproj() { # DIR WHICH(A|B)   three classes (A) or four different ones (B)
  local d="$1" w="$2" n i; rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo"
  printf 'rootProject.name = "demo"\n\nbuildCache {\n    local { isEnabled = false }\n    remote<HttpBuildCache> {\n        url = uri(System.getenv("CACHE_URL"))\n        credentials {\n            username = System.getenv("CACHE_USER")\n            password = System.getenv("CACHE_PASS")\n        }\n        isPush = System.getenv("CACHE_PUSH") != "false"\n        isAllowInsecureProtocol = true\n    }\n}\n' > "$d/settings.gradle.kts"
  printf 'plugins { java }\n' > "$d/build.gradle.kts"; printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
  if [ "$w" = A ]; then n=3; else n=4; fi
  for i in $(seq 1 $n); do printf 'package demo;\n\npublic class %s%s {\n    public int f() { return %s; }\n}\n' "$w" "$i" "$((i*7))" > "$d/src/main/java/demo/$w$i.java"; done
}
sbuild() { # NAME DIR URL USER PASS [PUSH=false]   compileJava and jar, a new Gradle home, no daemon, the cache address and login only as environment variables
  local name="$1" dir="$2" url="$3" u="$4" p="$5" push="${6:-true}"
  rm -rf "$W/sg-$name"; mkdir -p "$W/sg-$name"
  run "s-$name" "$dir" <<EOF
export GRADLE_USER_HOME="$W/sg-$name" JAVA_HOME="$JDK21_HOME" PATH="$JDK21_HOME/bin:\$PATH" CACHE_URL="$url" CACHE_USER="$u" CACHE_PASS="$p" CACHE_PUSH="$push"
gradle compileJava jar -i --console=plain --no-daemon
EOF
  rm -rf "$W/sg-$name"
}
sstate() { local f="$W/s-$1.out"; if grep -qxF "> Task :compileJava FROM-CACHE" "$f"; then echo cache; elif grep -qxF "> Task :compileJava" "$f"; then echo ran; else echo missing; fi; }
skey() { grep -m1 -o "Stored cache entry for task ':compileJava' with cache key [0-9a-f]*" "$W/s-$1.out" | awk '{print $NF}'; }
scode() { curl -s --max-time 30 -o /dev/null -w '%{http_code}' "$@"; }

scenario_s() {
  echo; echo "== S  (several-projects-share-one-build-cache-server)"
  local D="$W/s" U1="http://127.0.0.1:${SPORT}/" U2="http://127.0.0.1:${SPORT2}/" ka kb h0 h1 h2 e
  mkdir -p "$D"
  # --- one server, no size cap, one read-write login (and a read-only one)
  SFA_18160="$RWU:$RWP"
  start_server s1 "$SPORT" "$RWU" "$RWP" FSCACHE_RO_USERNAME="$ROU" FSCACHE_RO_PASSWORD="$ROP" || return
  sproj "$D/a" A; sbuild sa "$D/a" "$U1" "$RWU" "$RWP"; expect s-sa "BUILD SUCCESSFUL"
  want "A: compile task" "$(sstate sa)" ran
  want "A: entries on the server afterwards" "$(sfield $SPORT store_entries)" 2
  h0="$(sfield $SPORT cache_hits)"; case "$h0" in ''|*[!0-9]*) fail "S the server's /statusz could not be read with the login (got '$h0')"; stop_server; return;; esac; want "A: restored from the server (cache hits)" "$h0" 0
  sproj "$D/b" B; sbuild sb "$D/b" "$U1" "$RWU" "$RWP"; expect s-sb "BUILD SUCCESSFUL"
  want "B, different code: compile task" "$(sstate sb)" ran
  want "B: entries on the server afterwards" "$(sfield $SPORT store_entries)" 3
  h1="$(sfield $SPORT cache_hits)"; case "$h1" in ''|*[!0-9]*) h1=0;; esac; want "B: restored from the server (the compiled build script)" "$((h1-h0))" 1
  sproj "$D/c" A; sbuild sc "$D/c" "$U1" "$RWU" "$RWP"; expect s-sc "BUILD SUCCESSFUL"
  want "C, a copy of A in another folder: compile task" "$(sstate sc)" cache
  want "C: entries on the server afterwards" "$(sfield $SPORT store_entries)" 3
  h2="$(sfield $SPORT cache_hits)"; case "$h2" in ''|*[!0-9]*) h2=0;; esac; want "C: restored from the server (A's compile result and the build script)" "$((h2-h1))" 2
  ka="$(skey sa)"; kb="$(skey sb)"
  [ -n "$ka" ] && [ -n "$kb" ] && [ "$ka" != "$kb" ] && echo "OBS S the compile keys of A and B differ; A's key in the copy C: same as A's (C restored it)" || fail "S could not read two different compile keys from the logs of A and B"
  # --- direct requests: the key is the request path
  want "A's key, read-write login" "$(scode -u "$RWU:$RWP" "${U1}${ka}")" 200
  want "B's key, the same login" "$(scode -u "$RWU:$RWP" "${U1}${kb}")" 200
  echo "OBS S sizes: A's compile entry $(curl -s --max-time 30 -u "$RWU:$RWP" "${U1}${ka}" | wc -c | tr -d ' ') bytes, B's $(curl -s --max-time 30 -u "$RWU:$RWP" "${U1}${kb}" | wc -c | tr -d ' ') bytes (the page: 1,659 and 1,803)"
  want "both keys with the read-only login (A)" "$(scode -u "$ROU:$ROP" "${U1}${ka}")" 200
  want "both keys with the read-only login (B)" "$(scode -u "$ROU:$ROP" "${U1}${kb}")" 200
  want "a write with the read-only login" "$(scode -X PUT --data-binary x -u "$ROU:$ROP" "${U1}0123456789abcdef0123456789abcdef")" 403
  want "...entries stayed at" "$(sfield $SPORT store_entries)" 3
  want "A's key with no login" "$(scode "${U1}${ka}")" 401
  want "A's key with a wrong password" "$(scode -u "$RWU:wrong" "${U1}${ka}")" 401
  want "a project name in front of A's key" "$(scode -u "$RWU:$RWP" "${U1}demo/${ka}")" 404
  want "a project name in front of B's key" "$(scode -u "$RWU:$RWP" "${U1}demo/${kb}")" 404
  sproj "$D/ra" A; sbuild sra "$D/ra" "$U1" "$ROU" "$ROP" false; expect s-sra "BUILD SUCCESSFUL"
  want "A with the read-only login and pushing off: compile task" "$(sstate sra)" cache
  sproj "$D/rb" B; sbuild srb "$D/rb" "$U1" "$ROU" "$ROP" false; expect s-srb "BUILD SUCCESSFUL"
  want "B with the read-only login and pushing off: compile task" "$(sstate srb)" cache
  stop_server
  # --- two servers, one for each team
  SFA_18160="$T1U:$T1P"; SFA_18161="$T2U:$T2P"
  start_server s2 "$SPORT" "$T1U" "$T1P" || return; local PID1="$SERVER_PID"
  sproj "$D/ta" A; sbuild ta "$D/ta" "$U1" "$T1U" "$T1P"; expect s-ta "BUILD SUCCESSFUL"
  want "A on team 1's server: compile task" "$(sstate ta)" ran
  want "...entries stored" "$(sfield $SPORT store_entries)" 2
  local KT1; KT1="$(skey ta)"
  sproj "$D/tc" A; sbuild tc "$D/tc" "$U1" "$T1U" "$T1P"; expect s-tc "BUILD SUCCESSFUL"
  want "C on team 1's server: compile task" "$(sstate tc)" cache
  # second server on another port (start_server keeps one server pid: keep team 1's alive by hand)
  local SAVE_PID="$SERVER_PID"
  start_server s3 "$SPORT2" "$T2U" "$T2P" || { SERVER_PID="$SAVE_PID"; SERVER_PORT="$SPORT"; stop_server; return; }
  local PID2="$SERVER_PID"
  sproj "$D/td" A; sbuild td "$D/td" "$U2" "$T1U" "$T1P"; expect s-td "BUILD SUCCESSFUL"
  want "C on team 2's server, sending team 1's login: compile task" "$(sstate td)" ran
  want "...nothing was stored on team 2's server (entries) and nothing restored (hits)" "$(sfield $SPORT2 store_entries)/$(sfield $SPORT2 cache_hits)" "0/0"
  has_s() { grep -qF -- "$2" "$W/s-$1.out"; }
  has_s td "401" && echo "OBS S the build log names a 401" || fail "S the page says team 1's login got a 401 on team 2's server; no 401 in the log"
  has_s td "remote build cache" && echo "OBS S the build warned about the remote build cache (log: $(grep -m2 -iE 'disabled|warn' "$W/s-td.out" | tr '\n' ' ' | cut -c1-260))" || fail "S the page says the build warned and switched the remote cache off"
  sproj "$D/te" A; sbuild te "$D/te" "$U2" "$T2U" "$T2P"; expect s-te "BUILD SUCCESSFUL"
  want "C on team 2's server, with team 2's login: compile task (nothing restored)" "$(sstate te)" ran
  want "...entries stored on team 2's server" "$(sfield $SPORT2 store_entries)" 2
  want "...and nothing restored from it (hits)" "$(sfield $SPORT2 cache_hits)" 0
  sproj "$D/tf" A; sbuild tf "$D/tf" "$U2" "$T2U" "$T2P"; expect s-tf "BUILD SUCCESSFUL"
  want "the same build again on team 2's server: compile task" "$(sstate tf)" cache
  want "team 1's login on team 2's server, A's key" "$(scode -u "$T1U:$T1P" "${U2}${KT1}")" 401
  want "team 2's login on team 1's server, A's key" "$(scode -u "$T2U:$T2P" "${U1}${KT1}")" 401
  kill "$PID2" 2>/dev/null; wait "$PID2" 2>/dev/null; SERVER_PID="$PID1"; SERVER_PORT="$SPORT"; stop_server
  # --- one small size cap
  SFA_18160="$RWU:$RWP"
  start_server s4 "$SPORT" "$RWU" "$RWP" FSCACHE_MAX_BYTES=5000 || return
  sproj "$D/ca" A; sbuild ca "$D/ca" "$U1" "$RWU" "$RWP"; expect s-ca "BUILD SUCCESSFUL"
  echo "OBS S cap run: A's entries take $(sfield $SPORT store_bytes) bytes (the page: 4,472 with a 5,000-byte cap)"
  want "A: compile task / evicted so far / entries" "$(sstate ca) $(sfield $SPORT evicted_entries) $(sfield $SPORT store_entries)" "ran 0 2"
  sproj "$D/cb" B; sbuild cb "$D/cb" "$U1" "$RWU" "$RWP"; expect s-cb "BUILD SUCCESSFUL"
  want "B: compile task / evicted so far / entries" "$(sstate cb) $(sfield $SPORT evicted_entries) $(sfield $SPORT store_entries)" "ran 1 2"
  want "...B's compile result is on the server, A's is not" "$(scode -u "$RWU:$RWP" "${U1}$(skey cb)") $(scode -u "$RWU:$RWP" "${U1}$(skey ca)")" "200 404"
  sproj "$D/cc" A; sbuild cc "$D/cc" "$U1" "$RWU" "$RWP"; expect s-cc "BUILD SUCCESSFUL"
  want "C, a copy of A: compile task / evicted so far / entries" "$(sstate cc) $(sfield $SPORT evicted_entries) $(sfield $SPORT store_entries)" "ran 2 2"
  want "...A's compile result is on the server again, B's is not" "$(scode -u "$RWU:$RWP" "${U1}$(skey ca)") $(scode -u "$RWU:$RWP" "${U1}$(skey cb)")" "200 404"
  sproj "$D/cd" B; sbuild cd "$D/cd" "$U1" "$RWU" "$RWP"; expect s-cd "BUILD SUCCESSFUL"
  want "B again: compile task / evicted so far / entries" "$(sstate cd) $(sfield $SPORT evicted_entries) $(sfield $SPORT store_entries)" "ran 3 2"
  want "...B's compile result is on the server, A's is not" "$(scode -u "$RWU:$RWP" "${U1}$(skey cd)") $(scode -u "$RWU:$RWP" "${U1}$(skey ca)")" "200 404"
  stop_server
}

# =====================================================================================
# A  /air-gapped-build-cache-install/
# =====================================================================================
scenario_a() {
  echo; echo "== A  (air-gapped-build-cache-install)"
  local D="$W/a"; rm -rf "$D"; mkdir -p "$D/connected" "$D/isolated"
  # the connected side: the page's list and its verify commands, word for word (X.Y.Z is the release)
  run a-fetch "$D/connected" <<EOF
VER=${VER}
gh release download v\${VER} --repo fosterstack/cache -p checksums.txt -p checksums.txt.bundle -p "fscache_\${VER}_linux_amd64.tar.gz"
# 1. Prove the checksums file is ours
cosign verify-blob \\
  --bundle checksums.txt.bundle \\
  --certificate-identity-regexp='^https://github.com/fosterstack/cache/' \\
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \\
  checksums.txt
# 2. Prove your archive matches it
sha256sum -c <(grep "fscache_\${VER}_linux_amd64.tar.gz" checksums.txt | grep -v sbom)
EOF
  expect a-fetch "Verified OK" "fscache_${VER}_linux_amd64.tar.gz: OK"
  # the command as the page published it (without the grep -v sbom): what does it do?
  ( cd "$D/connected" && sha256sum -c <(grep "fscache_${VER}_linux_amd64.tar.gz" checksums.txt) ) > "$W/a-asis.out" 2>&1; local asis=$?
  echo "OBS A the page's verify line as first published (no 'grep -v sbom') exited $asis; its output: $(tr '\n' ' ' < "$W/a-asis.out" | cut -c1-260)"
  cp "$D/connected/fscache_${VER}_linux_amd64.tar.gz" "$D/isolated/"
  # a wrong archive must fail the second step
  printf 'tampered' >> "$D/connected/fscache_${VER}_linux_amd64.tar.gz"
  ( cd "$D/connected" && sha256sum -c <(grep "fscache_${VER}_linux_amd64.tar.gz" checksums.txt | grep -v sbom) ) > "$W/a-tamper.out" 2>&1 && fail "A a tampered archive passed the checksum step" || { grep -qF "tar.gz: FAILED" "$W/a-tamper.out" && echo "OBS A a tampered archive fails 'sha256sum -c' with '...tar.gz: FAILED', so the checksum step does catch it" || fail "A the tampered archive did not fail with 'tar.gz: FAILED' (output: $(tr '\n' ' ' < "$W/a-tamper.out" | cut -c1-200))"; }
  # the isolated side: unpack and look at it
  run a-unpack "$D/isolated" <<EOF
tar -xzf "fscache_${VER}_linux_amd64.tar.gz"
ls
file fscache
EOF
  expect a-unpack "fscache"
  grep -qi "statically linked" "$W/a-unpack.out" && echo "OBS A the server binary is statically linked ('one static program')" || fail "A the page says the server is one static program; file says: $(grep -m1 'fscache:' "$W/a-unpack.out" | cut -c1-200)"
  # it starts and works with no route to anywhere: a network namespace holding only the loopback interface
  cat > "$D/isolated/nonet.sh" <<'NONET'
set -u
ip link set lo up || exit 90
cd "$1"
FSCACHE_ADDR=127.0.0.1:18150 FSCACHE_DATA_DIR="$1/data" ./fscache > server.log 2>&1 &
pid=$!
for i in $(seq 1 100); do curl -sf --max-time 2 http://127.0.0.1:18150/healthz >/dev/null 2>&1 && break; sleep 0.1; done
echo "healthz: $(curl -s --max-time 5 http://127.0.0.1:18150/healthz)"
echo "put: $(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X PUT --data-binary hello http://127.0.0.1:18150/0123456789abcdef0123456789abcdef)"
echo "get: $(curl -s --max-time 5 http://127.0.0.1:18150/0123456789abcdef0123456789abcdef)"
echo "interfaces: $(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')"
kill $pid 2>/dev/null; wait $pid 2>/dev/null
NONET
  run a-nonet "$D/isolated" <<EOF
sudo -n unshare -n bash "$D/isolated/nonet.sh" "$D/isolated"; sudo -n chown -R "\$(id -u):\$(id -g)" "$D/isolated"
EOF
  if grep -qxE "interfaces: lo ?" "$W/a-nonet.out" && grep -qE "^healthz: ok" "$W/a-nonet.out" && grep -qxF "get: hello" "$W/a-nonet.out"; then
    echo "OBS A with only a loopback interface (no route anywhere) the server started, answered /healthz, stored and returned an entry: no outbound call was needed"
  else fail "A the server did not work in a network namespace with only a loopback interface (log: $(tr '\n' ' ' < "$W/a-nonet.out" | cut -c1-300))"; fi
  # containers: the page's load and run (crane pull is replaced by docker pull and docker save)
  docker pull -q "ghcr.io/fosterstack/cache:${VER}" >/dev/null 2>&1 && docker save -o "$D/isolated/fscache-${VER}.tar" "ghcr.io/fosterstack/cache:${VER}" && docker rmi -f "ghcr.io/fosterstack/cache:${VER}" >/dev/null 2>&1
  if [ -s "$D/isolated/fscache-${VER}.tar" ]; then
    curl -sf --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1 && { fail "A something already answers on port 8080: the container step is not run"; return; }
    CONTAINERS="air-gapped-test"
    run a-docker "$D/isolated" <<EOF
docker load -i fscache-${VER}.tar
docker run -d --name air-gapped-test -p 127.0.0.1:8080:8080 -v fscache-data:/home/nonroot ghcr.io/fosterstack/cache:${VER}
EOF
    expect a-docker "Loaded image"
    wait_up 8080 && echo "OBS A the container from the loaded image answers /healthz on 127.0.0.1:8080 (the page's docker run line, as written)" || fail "A the page's docker run line did not give a server answering on 127.0.0.1:8080 (logs: $(docker logs air-gapped-test 2>&1 | tail -n 3 | tr '\n' ' ' | cut -c1-300))"
    docker rm -f air-gapped-test >/dev/null 2>&1; docker volume rm fscache-data >/dev/null 2>&1; docker rmi -f "ghcr.io/fosterstack/cache:${VER}" >/dev/null 2>&1
  else fail "A could not pull and save the container image ghcr.io/fosterstack/cache:${VER}: the container step was not run"; fi
}

# ---------- run ----------
for port in 18150 18160 18161 8080; do
  curl -skf --max-time 3 "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
scenario_s
scenario_t
scenario_a
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
