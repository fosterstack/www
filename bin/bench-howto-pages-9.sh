#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 9: do the commands and promised outputs of this page really happen?
#   X  /gradle-build-cache-corporate-proxy/   the Gradle table (no proxy settings, proxy settings, a loopback cache, nonProxyHosts, an HTTPS cache
#                                             through a CONNECT tunnel, a refusing proxy), the curl check, and Maven (the proxy log of two builds,
#                                             a loopback cache, nonProxyHosts, a refusing proxy, no proxy running)
# Run by the "bench-howto-pages-9" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-9"). Same method as the other
# bench scripts. The proxy is bin/bench-proxy.py: a minimal test proxy written for this (standard library only, 127.0.0.1 only), NOT a production
# proxy such as Squid; it forwards plain HTTP, tunnels CONNECT, can refuse a host with a 403 and logs every request. A small TLS front for the
# HTTPS rows is written by this script into its work folder (standard library only). No token and no secret; the release binary is verified
# (cosign + sha256) before it runs. The cache servers listen on all interfaces of the runner (the page needs a non-loopback address) behind
# made-up passwords where the page uses one; the runner has no inbound traffic and is thrown away after the job.
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
echo "release under test: FosterStack Cache ${VER}, downloaded with no login and verified (cosign + sha256) before it runs; the cache servers listen on all interfaces of the runner (the page needs a non-loopback address), the test proxy on 127.0.0.1 only"
echo "NOT checksum-pinned: the Maven build-cache extension 1.2.3 and the Maven plugin jars (their eight versions are pinned in the pom, the files come from Maven Central); the Maven on the runner is its own (version printed)"
echo "invented by this script (the page shows its settings, not its files): the Gradle and Maven projects (one class), made-up passwords, the test proxy bin/bench-proxy.py, a TLS front and a self-signed certificate for the HTTPS rows, the keystore that makes Java trust it"
echo "differences from the page's own runs: Linux amd64 (the page: macOS arm64), release ${VER} (the page: 0.2.1), Java 21; the proxy and the HTTPS front are ours, as the page says ('we wrote a small proxy'); the page used nginx for HTTPS, this script a TLS front written in Python; the proxy host is 127.0.0.1:18131 (the page: proxy.example.com:3128); the Maven nonProxyHosts line is the page's, except in the row that puts the cache's address in it"
echo "Gradle builds use a new empty Gradle home and a fresh project copy each, no daemon, Gradle's own local cache switched off; Maven builds use an emptied ~/.m2/build-cache"
echo "NOT tested here (as on the page): a real corporate proxy product, a proxy that asks for a password (407), TLS inspection, proxy configuration files, the HTTP_PROXY variables, HTTPS through a proxy for Maven"
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
# X  /gradle-build-cache-corporate-proxy/
# =====================================================================================
XGP=18130; XTP=18443; XPP=18131; XMP=18132
PROXY_PID=""; TLS_PID=""
stop_proxy() { [ -n "$PROXY_PID" ] && { kill "$PROXY_PID" 2>/dev/null; wait "$PROXY_PID" 2>/dev/null; PROXY_PID=""; }; return 0; }
stop_tls() { [ -n "$TLS_PID" ] && { kill "$TLS_PID" 2>/dev/null; wait "$TLS_PID" 2>/dev/null; TLS_PID=""; }; return 0; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
start_proxy() { # LOGFILE [DENIED_HOST ...]
  stop_proxy; : > "$1"; local log="$1"; shift
  python3 "$HERE/bench-proxy.py" "$XPP" "$log" "$@" > /dev/null 2>&1 &
  PROXY_PID=$!
  local i; for i in $(seq 1 50); do port_open "$XPP" && return 0; sleep 0.1; done
  fail "the test proxy did not start on ${XPP}"; return 1
}
plog() { grep -F -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
HOSTIP="$(python3 -c "import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(('10.255.255.255',1));print(s.getsockname()[0])")"
[ -n "$HOSTIP" ] || { echo "no non-loopback address found on this machine" >&2; exit 1; }
g_project() { # DIR N URL PROPS   one class whose content depends on N (a new cache key per row); PROPS are gradle.properties lines
  local d="$1" n="$2" url="$3" props="$4"; rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo"
  cat > "$d/settings.gradle.kts" <<EOF
rootProject.name = "demo"
buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("${url}")
        isPush = true
        isAllowInsecureProtocol = true
    }
}
EOF
  { printf 'org.gradle.caching=true\n'; [ -n "$props" ] && printf '%b\n' "$props"; } > "$d/gradle.properties"
  printf 'plugins { java }\n' > "$d/build.gradle.kts"
  printf 'package demo;\n\npublic class App {\n    public static int f() { return %s; }\n}\n' "$n" > "$d/src/main/java/demo/App.java"
}
grow() { # ID N URL PROPS   two builds (a fresh copy and Gradle home each); the proxy log is in $W/x/proxy-ID.log
  local id="$1" n="$2" url="$3" props="$4"
  g_project "$W/x/$id-1" "$n" "$url" "$props"; qrun "x$id-1" "$W/x/$id-1" "gradle compileJava --console=plain --no-daemon"
  g_project "$W/x/$id-2" "$n" "$url" "$props"; qrun "x$id-2" "$W/x/$id-2" "gradle compileJava --console=plain --no-daemon"
}
scenario_x() {
  echo; echo "== X  (gradle-build-cache-corporate-proxy)"
  local X="$W/x" PROX NPH TRUST id n
  mkdir -p "$X"
  echo "OBS X the runner's non-loopback address: ${HOSTIP}; $(mvn --version 2>/dev/null | head -n 1)"
  PROX="systemProp.http.proxyHost=127.0.0.1\nsystemProp.http.proxyPort=${XPP}\nsystemProp.https.proxyHost=127.0.0.1\nsystemProp.https.proxyPort=${XPP}"
  NPH="systemProp.http.nonProxyHosts=${HOSTIP}|localhost|127.*"
  TRUST="systemProp.javax.net.ssl.trustStore=${X}/trust.jks\nsystemProp.javax.net.ssl.trustStorePassword=changeit"
  # --- the cache for the Gradle rows (no login), and an HTTPS front for it
  start_server xg "$XGP" "" "" FSCACHE_ADDR="0.0.0.0:${XGP}" || return
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$X/key.pem" -out "$X/cert.pem" -days 1 -subj "/CN=${HOSTIP}" -addext "subjectAltName=IP:${HOSTIP}" > /dev/null 2>&1 || { fail "X could not make the self-signed certificate"; return; }
  "$JDK21_HOME/bin/keytool" -importcert -noprompt -alias cache -file "$X/cert.pem" -keystore "$X/trust.jks" -storepass changeit > /dev/null 2>&1 || { fail "X could not make the Java trust store"; return; }
  cat > "$X/tlsfront.py" <<'PYEOF'
import socket, ssl, sys, threading
lport, uport, cert, key = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", lport))
srv.listen(64)
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.close()
            except OSError:
                pass
def handle(c):
    try:
        t = ctx.wrap_socket(c, server_side=True)
        u = socket.create_connection(("127.0.0.1", uport))
        threading.Thread(target=pipe, args=(u, t), daemon=True).start()
        pipe(t, u)
    except Exception:
        try:
            c.close()
        except OSError:
            pass
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PYEOF
  python3 "$X/tlsfront.py" "$XTP" "$XGP" "$X/cert.pem" "$X/key.pem" > /dev/null 2>&1 &
  TLS_PID=$!; local i; for i in $(seq 1 50); do port_open "$XTP" && break; sleep 0.1; done
  [ "$(curl -s --max-time 10 --cacert "$X/cert.pem" "https://${HOSTIP}:${XTP}/healthz")" = ok ] && echo "OBS X the HTTPS front answers /healthz with ok" || { fail "X the HTTPS front does not answer"; return; }
  # --- the Gradle table
  start_proxy "$X/proxy-g1.log"
  grow g1 101 "http://${HOSTIP}:${XGP}/" ""
  qcheck "Gradle, no proxy settings, cache at the non-loopback address: second build" xg1-2 "cache" compileJava
  want "Gradle, no proxy settings: lines in the proxy log" "$(wc -l < "$X/proxy-g1.log" | tr -d ' ')" 0
  start_proxy "$X/proxy-g2.log"
  grow g2 102 "http://${HOSTIP}:${XGP}/" "$PROX"
  qcheck "Gradle, proxy settings, same plain-HTTP URL: second build" xg2-2 "cache" compileJava
  n="$(plog "GET http://${HOSTIP}:${XGP}/" "$X/proxy-g2.log")"; echo "OBS X Gradle, proxy settings: the proxy log has $n GET lines and $(plog "PUT http://${HOSTIP}:${XGP}/" "$X/proxy-g2.log") PUT lines for the cache over the two builds"
  sed -E 's#/[0-9a-f]{32}#/<key>#' "$X/proxy-g2.log" | sort | uniq -c | sed 's/^/OBS X   proxy log (key replaced), count and line: /'
  [ "$n" -ge 2 ] && echo "OBS X Gradle, proxy settings: at least one GET per build reached the proxy ($n GET lines over two builds; the page says one per build)" || fail "X Gradle, proxy settings: the page says the proxy logged a GET per build; it logged $n over two builds"
  grep -E "^GET http://${HOSTIP}:${XGP}/[0-9a-f]{32}$" "$X/proxy-g2.log" > /dev/null && echo "OBS X ...the lines have the form GET http://<cache-ip>:<port>/<32-character key>, as the page shows" || fail "X the proxy log has no line of the form 'GET http://<cache-ip>:<port>/<key>'"
  start_proxy "$X/proxy-g3.log"
  grow g3 103 "http://127.0.0.1:${XGP}/" "$PROX"
  qcheck "Gradle, proxy settings, cache URL 127.0.0.1: second build" xg3-2 "cache" compileJava
  want "Gradle, proxy settings, cache URL 127.0.0.1: lines in the proxy log (Java skips the proxy for loopback)" "$(wc -l < "$X/proxy-g3.log" | tr -d ' ')" 0
  start_proxy "$X/proxy-g4.log"
  grow g4 104 "http://${HOSTIP}:${XGP}/" "${PROX}\n${NPH}"
  qcheck "Gradle, proxy settings, the cache's address in nonProxyHosts: second build" xg4-2 "cache" compileJava
  want "Gradle, nonProxyHosts: lines in the proxy log" "$(wc -l < "$X/proxy-g4.log" | tr -d ' ')" 0
  start_proxy "$X/proxy-g5.log"
  grow g5 105 "https://${HOSTIP}:${XTP}/" "${PROX}\n${TRUST}"
  qcheck "Gradle, proxy settings, HTTPS cache, tunnel allowed: second build" xg5-2 "cache" compileJava
  want "Gradle, HTTPS cache: 'CONNECT <cache-ip>:${XTP}' lines in the proxy log, one per build" "$(plog "CONNECT ${HOSTIP}:${XTP}" "$X/proxy-g5.log")" 2
  want "Gradle, HTTPS cache: the proxy saw nothing else (no GET, no PUT)" "$(grep -cE '^(GET|PUT|HEAD|POST) ' "$X/proxy-g5.log" || true)" 0
  start_proxy "$X/proxy-g6.log" "$HOSTIP"
  grow g6 106 "https://${HOSTIP}:${XTP}/" "${PROX}\n${TRUST}"
  qcheck "Gradle, proxy refuses the cache host: the builds ran without the cache" xg6-2 "ran" compileJava
  for n in 1 2; do expect "q-xg6-$n" "BUILD SUCCESSFUL" "Could not load entry" "response status 403: Forbidden"; done
  grep -qE "^Could not load entry [0-9a-f]{32} from remote build cache: Loading entry from 'https://${HOSTIP}:${XTP}/[0-9a-f]{32}' response status 403: Forbidden$" "$W/q-xg6-1.out" && echo "OBS X the log line has the shape the page shows: Could not load entry <key> from remote build cache: Loading entry from 'https://<cache-ip>:<port>/<key>' response status 403: Forbidden" || fail "X the 403 line does not have the shape the page shows: $(grep -F 'Could not load entry' "$W/q-xg6-1.out" | head -n 1 | cut -c1-260)"
  grep -qF "The remote build cache was disabled during the build due to errors" "$W/q-xg6-1.out" && echo "OBS X ...then the remote cache was disabled for that build" || fail "X the page says the build went on without the cache after the warning"
  want "Gradle, refusing proxy: the proxy answered 403 (CONNECT lines with 403)" "$(plog "CONNECT ${HOSTIP}:${XTP} 403" "$X/proxy-g6.log" | awk '{print ($1>=1)?"yes":"no"}')" yes
  # --- the curl check from the page
  curl -sS -x "http://127.0.0.1:${XPP}" --cacert "$X/cert.pem" "https://${HOSTIP}:${XTP}/healthz" > "$X/curl1.out" 2> "$X/curl1.err"; n=$?
  [ "$(cat "$X/curl1.err")" = "curl: (56) CONNECT tunnel failed, response 403" ] && [ "$n" = 56 ] && echo "OBS X the curl check through the refusing proxy: 'curl: (56) CONNECT tunnel failed, response 403' (exit 56), as the page shows" || fail "X the curl check through the refusing proxy: the page shows 'curl: (56) CONNECT tunnel failed, response 403'; got exit $n and '$(cat "$X/curl1.err")'"
  curl -sS --noproxy '*' --cacert "$X/cert.pem" "https://${HOSTIP}:${XTP}/healthz" > "$X/curl2.out" 2> "$X/curl2.err"; n=$?
  [ "$(cat "$X/curl2.out")" = ok ] && [ "$n" = 0 ] && echo "OBS X the curl check with --noproxy '*': 'ok', as the page shows" || fail "X the curl check with --noproxy: the page shows 'ok'; got exit $n and '$(cat "$X/curl2.out")'"
  stop_proxy; stop_tls; stop_server
  # --- Maven
  local M="$W/x/mvnhome"; mkdir -p "$M/.m2"
  start_server xm "$XMP" maven mvn-secret FSCACHE_ADDR="0.0.0.0:${XMP}" || return
  m_settings() { # NONPROXYHOSTS
    cat > "$M/.m2/settings.xml" <<EOF
<settings>
  <servers>
    <server>
      <id>fosterstack-cache</id>
      <username>maven</username>
      <password>mvn-secret</password>
    </server>
  </servers>
  <proxies>
    <proxy>
      <id>corp</id>
      <active>true</active>
      <protocol>http</protocol>
      <host>127.0.0.1</host>
      <port>${XPP}</port>
      <nonProxyHosts>$1</nonProxyHosts>
    </proxy>
  </proxies>
</settings>
EOF
  }
  m_project() { # DIR N URL
    local d="$1" n="$2" url="$3"; rm -rf "${d:?}"; mkdir -p "$d/.mvn" "$d/src/main/java/demo"
    printf '<extensions>\n  <extension>\n    <groupId>org.apache.maven.extensions</groupId>\n    <artifactId>maven-build-cache-extension</artifactId>\n    <version>%s</version>\n  </extension>\n</extensions>\n' "$EXT_VER" > "$d/.mvn/extensions.xml"
    cat > "$d/.mvn/maven-build-cache-config.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<cache xmlns="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       xsi:schemaLocation="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0 https://maven.apache.org/xsd/build-cache-config-1.2.0.xsd">
  <configuration>
    <enabled>true</enabled>
    <remote enabled="true" saveToRemote="true" id="fosterstack-cache">
      <url>${url}</url>
    </remote>
  </configuration>
</cache>
EOF
    cat > "$d/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>demo</groupId>
  <artifactId>demo</artifactId>
  <version>1.0</version>
  <packaging>jar</packaging>
  <properties>
    <maven.compiler.release>17</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
  <build>
    <pluginManagement><plugins>
      <plugin><artifactId>maven-clean-plugin</artifactId><version>3.4.0</version></plugin>
      <plugin><artifactId>maven-resources-plugin</artifactId><version>3.3.1</version></plugin>
      <plugin><artifactId>maven-compiler-plugin</artifactId><version>3.13.0</version></plugin>
      <plugin><artifactId>maven-surefire-plugin</artifactId><version>3.5.2</version></plugin>
      <plugin><artifactId>maven-jar-plugin</artifactId><version>3.4.2</version></plugin>
      <plugin><artifactId>maven-install-plugin</artifactId><version>3.1.3</version></plugin>
      <plugin><artifactId>maven-deploy-plugin</artifactId><version>3.1.3</version></plugin>
      <plugin><artifactId>maven-site-plugin</artifactId><version>3.12.1</version></plugin>
    </plugins></pluginManagement>
  </build>
</project>
EOF
    printf 'package demo;\n\npublic class App {\n    public static int f() { return %s; }\n}\n' "$n" > "$d/src/main/java/demo/App.java"
  }
  mbuild() { # NAME DIR
    run "x-$1" "$2" <<EOF
export HOME="$M" MAVEN_OPTS="-Duser.home=$M"
rm -rf "\$HOME/.m2/build-cache"
mvn verify
EOF
    expect "x-$1" "BUILD SUCCESS"
  }
  mseq() { # LOGFILE FROMLINE  -> "GET buildinfo.xml,PUT demo.jar,..." for the lines after FROMLINE that name the cache
    tail -n +"$(( $2 + 1 ))" "$1" | grep -E "(${HOSTIP}|127\.0\.0\.1):${XMP}/" | sed -E 's#^(GET|PUT) http://[^/]+/v1\.1/demo/demo/[^/]+/([^ ]+).*$#\1 \2#' | paste -sd, -
  }
  local L1 L2 S0 S1
  # row m1: the proxy used; two builds, the proxy log shows what went through it
  m_settings "cache.internal.example.com|localhost"; start_proxy "$X/proxy-m1.log"
  m_project "$X/m1-1" 201 "http://${HOSTIP}:${XMP}/"; L1=0
  mbuild m1-1 "$X/m1-1"; L1="$(wc -l < "$X/proxy-m1.log" | tr -d ' ')"
  m_project "$X/m1-2" 201 "http://${HOSTIP}:${XMP}/"; mbuild m1-2 "$X/m1-2"
  want "Maven, build 1 (stores): what the proxy logged for the cache" "$(head -n "$L1" "$X/proxy-m1.log" | grep -E "${HOSTIP}:${XMP}/" | sed -E 's#^(GET|PUT) http://[^/]+/v1\.1/demo/demo/[^/]+/([^ ]+).*$#\1 \2#' | paste -sd, -)" "GET buildinfo.xml,GET buildinfo.xml,PUT demo.jar,PUT buildinfo.xml,PUT build-cache-report.xml"
  want "Maven, build 2 (restores): what the proxy logged for the cache" "$(tail -n +"$((L1+1))" "$X/proxy-m1.log" | grep -E "${HOSTIP}:${XMP}/" | sed -E 's#^(GET|PUT) http://[^/]+/v1\.1/demo/demo/[^/]+/([^ ]+).*$#\1 \2#' | paste -sd, -)" "GET buildinfo.xml,GET buildinfo.xml,GET demo.jar,PUT build-cache-report.xml"
  echo "OBS X Maven's own traffic through the proxy (not shown on the page): $(grep -cE 'CONNECT|repo' "$X/proxy-m1.log" || true) lines that do not name the cache"
  grep -qF "Found cached build, restoring demo:demo from cache" "$W/x-m1-2.out" && echo "OBS X Maven, build 2: 'Found cached build, restoring demo:demo from cache'" || fail "X Maven, build 2: the page says it logged 'Found cached build, restoring demo:demo from cache'"
  case "$(mvn --version 2>/dev/null | head -n 1)" in *"Maven 3.10"*) ;; *) echo "OBS X SKIPPED: the page's Maven 3.10.0 note was not checked; the runner's Maven is $(mvn --version 2>/dev/null | head -n 1)";; esac
  case "$(mvn --version 2>/dev/null | head -n 1)" in *"Maven 3.10"*) grep -qF "Error downloading cache item" "$W/x-m1-1.out" && echo "OBS X Maven 3.10: an ordinary first miss also logs 'Error downloading cache item', as the page says" || fail "X the page says Maven 3.10.0 logs 'Error downloading cache item' on an ordinary first miss; build 1 did not";; esac
  # row m2: the cache URL is 127.0.0.1 and the proxy is configured: Maven still uses the proxy
  m_project "$X/m2-1" 202 "http://127.0.0.1:${XMP}/"; mbuild m2-1 "$X/m2-1"; L2="$(wc -l < "$X/proxy-m1.log" | tr -d ' ')"
  m_project "$X/m2-2" 202 "http://127.0.0.1:${XMP}/"; mbuild m2-2 "$X/m2-2"
  want "Maven, cache URL 127.0.0.1 with the proxy configured: requests the proxy logged for the restoring build" "$(tail -n +"$((L2+1))" "$X/proxy-m1.log" | grep -cE "127\.0\.0\.1:${XMP}/")" 4
  grep -qF "Found cached build, restoring" "$W/x-m2-2.out" && echo "OBS X ...and the build restored from the cache" || fail "X Maven, loopback URL through the proxy: the build should still restore"
  # row m3: the cache's address in nonProxyHosts: nothing reaches the proxy, the build still restores
  m_settings "${HOSTIP}|localhost"; L2="$(wc -l < "$X/proxy-m1.log" | tr -d ' ')"
  m_project "$X/m3-1" 203 "http://${HOSTIP}:${XMP}/"; mbuild m3-1 "$X/m3-1"; m_project "$X/m3-2" 203 "http://${HOSTIP}:${XMP}/"; mbuild m3-2 "$X/m3-2"
  want "Maven, the cache's address in nonProxyHosts: requests that reached the proxy for the cache" "$(tail -n +"$((L2+1))" "$X/proxy-m1.log" | grep -cE "(${HOSTIP}|127\.0\.0\.1):${XMP}/")" 0
  grep -qF "Found cached build, restoring" "$W/x-m3-2.out" && echo "OBS X ...and the build still restored from the cache" || fail "X Maven, nonProxyHosts: the page says the build still restored from the cache"
  # row m4: the proxy refuses the cache's host
  m_settings "cache.internal.example.com|localhost"; start_proxy "$X/proxy-m4.log" "$HOSTIP"
  S0="$(statusz "$XMP" maven mvn-secret)"
  m_project "$X/m4-1" 204 "http://${HOSTIP}:${XMP}/"; mbuild m4-1 "$X/m4-1"; m_project "$X/m4-2" 204 "http://${HOSTIP}:${XMP}/"; mbuild m4-2 "$X/m4-2"
  S1="$(statusz "$XMP" maven mvn-secret)"
  want "Maven, the proxy refuses the cache's host: entries on the server (nothing was stored)" "$(entries_of "$S1")" "$(entries_of "$S0")"
  grep -qF "Found cached build" "$W/x-m4-2.out" && fail "X Maven, refusing proxy: the page says nothing was restored" || echo "OBS X Maven, refusing proxy: nothing was restored"
  grep -qF "Error downloading cache item" "$W/x-m4-2.out" && grep -qF "HTTP Status: 403" "$W/x-m4-2.out" && echo "OBS X ...the build logged 'Error downloading cache item' with 'HTTP Status: 403'" || fail "X Maven, refusing proxy: the page says the log has 'Error downloading cache item' with 'HTTP Status: 403'"
  # row m5: no proxy running
  stop_proxy
  S0="$(statusz "$XMP" maven mvn-secret)"
  m_project "$X/m5-1" 205 "http://${HOSTIP}:${XMP}/"; mbuild m5-1 "$X/m5-1"
  S1="$(statusz "$XMP" maven mvn-secret)"
  grep -qF "Connect to 127.0.0.1:${XPP}" "$W/x-m5-1.out" && grep -qF "Connection refused" "$W/x-m5-1.out" && echo "OBS X Maven, no proxy running: the lookup failed with 'Connect to 127.0.0.1:${XPP} ... Connection refused'" || fail "X Maven, no proxy running: the page says the lookup failed with 'Connect to 127.0.0.1:<port> ... Connection refused'"
  want "Maven, no proxy running: entries on the server (nothing was uploaded)" "$(entries_of "$S1")" "$(entries_of "$S0")"
  stop_server
}

# ---------- run ----------
for port in 18130 18131 18132 18443; do
  curl -skf --max-time 3 "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
scenario_x
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
