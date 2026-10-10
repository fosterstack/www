#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 5: do the commands and promised outputs of these pages really happen?
#   O  /change-build-cache-logins-without-breaking-ci/   the eleven rows of the page's table on a four-module project, the three orders and
#                                                        their count of jobs that got a 401, the two refusals to start, no password in any output
#   P  /build-cache-server-wont-start-errors/            each startup failure of the page's table, one at a time (exit code 1 and the log's
#                                                        last line), the settings that are ignored or accepted, the root-owned Docker volume
#   S  /build-cache-hit-rate-how-to-measure/             the page's grep recipes on a Gradle and a Maven build log against the server's counters
# Run by the "bench-howto-pages-5" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-5"). Same method as the other
# bench scripts: the page's commands word for word, the server's own counters checked, every output line the page promises asserted, a step that
# fails or prints something else is RECORDED (FAIL) and fails the job at the end; observations that are not failures are OBS lines.
#
# No token and no secret. Gradle, Maven 3.9.9 and cosign are downloaded and checked against pinned checksums; the release binary is verified
# (cosign + sha256) before it runs; the cache image (scenario P) is pinned by digest and verified with cosign by digest before docker runs it.
set -uo pipefail

VER=0.2.2                                    # the release the pages name
LOCAL="${BENCH_LOCAL:-0}"                    # 1 = a developer's dry run with local tools (nothing downloaded or checked: do not quote times)
if [ "$LOCAL" = 1 ]; then PLATFORM="${BENCH_PLATFORM:-darwin_arm64}"; else PLATFORM=linux_amd64; fi
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
MVN399_URL="https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz"
MVN399_SHA512=a555254d6b53d267965a3404ecb14e53c3827c09c3b94b5678835887ab404556bfaf78dcfe03ba76fa2508649dca8531c74bca4d5846513522404d48e8c4ac8b
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
curl -fsSL -o "$W/tools/mvn399.tgz" "$MVN399_URL"; sha512_check "$W/tools/mvn399.tgz" "$MVN399_SHA512"; tar -xzf "$W/tools/mvn399.tgz" -C "$W/tools"; MVN399_HOME="$W/tools/apache-maven-3.9.9"
[ -x "$MVN399_HOME/bin/mvn" ] || { echo "Maven 3.9.9 not usable" >&2; exit 1; }
for t in gh cosign gradle curl python3 tar docker; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
GRADLE_BIN="$(command -v gradle)"

echo "== DISCLOSURE"
echo "runner: $(uname -sr); cpus: $(nproc 2>/dev/null || sysctl -n hw.ncpu); image: ${ImageOS:-?} ${ImageVersion:-?}"
echo "maven 3.9.9: $("$MVN399_HOME/bin/mvn" --version 2>/dev/null | head -1)"
echo "java: $("$JDK21_HOME/bin/java" -version 2>&1 | head -1)   gradle: $(gradle --version 2>/dev/null | grep -E '^Gradle ' | head -1)   cosign: $(cosign version 2>/dev/null | grep -i GitVersion | head -1)   docker: $(docker --version)"
if [ "$LOCAL" = 1 ]; then echo "tools: LOCAL tools in use, nothing checked (a developer's dry run: do not quote these times)"; else
  echo "tools: Gradle ${GR_VER}, Maven 3.9.9 and cosign ${COSIGN_VER} are downloaded and checked against pinned checksums before use; Java 21 and Docker are the runner's own"; fi
echo "release under test: FosterStack Cache ${VER}, downloaded with no login and verified (cosign + sha256) before it runs (binary servers); the image is pulled by tag, must equal the pinned digest, and is verified with cosign by digest before docker runs it"
echo "NOT checksum-pinned: the ubuntu:24.04 image (only runs chown and stat on a volume), the Maven build-cache extension 1.2.3 and the Maven plugin jars (their eight versions are pinned in the pom, the files come from Maven Central), JUnit"
echo "invented by this script (the pages show none): the Gradle projects (four modules of 12 small classes for S, four modules for O) and the three-module Maven chain for S, test logins and passwords, the stand-in ports (the pages' own ports 18702 etc. are not all used)"
echo "differences from the pages' own runs: Linux amd64 (the pages: macOS arm64), release ${VER} (the pages: 0.2.1), Gradle ${GR_VER} with the runner's Java 21 and Maven 3.9.9 (as the pages)"
echo "Gradle runs use a new empty Gradle home and a fresh project copy each, no daemon reuse, Gradle's own local cache switched off (as the pages' runs did); startup cases run ./fscache from a clean environment (env -i) with one mistake at a time"
echo "NOT tested here: Docker or Kubernetes starts other than the root-owned-volume case, a very large store, the Prometheus window queries, timings of the starts (reported, not asserted)"
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
# O  /change-build-cache-logins-without-breaking-ci/
# =====================================================================================
OPORT=18151
o_project() { # DIR  (four modules; the address and the login reach the build only as environment variables)
  local d="$1" m cls; rm -rf "${d:?}"; mkdir -p "$d"
  printf 'rootProject.name = "demo"\ninclude("core", "app", "util", "api")\n\n' > "$d/settings.gradle.kts"
  cat >> "$d/settings.gradle.kts" <<'EOF'
buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri(System.getenv("FSCACHE_URL"))
        isAllowInsecureProtocol = true
        isPush = true
        credentials {
            username = System.getenv("FSCACHE_USERNAME")
            password = System.getenv("FSCACHE_PASSWORD")
        }
    }
}
EOF
  printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
  for m in core app util api; do
    cls="$(printf '%s' "${m:0:1}" | tr a-z A-Z)${m:1}"
    mkdir -p "$d/$m/src/main/java/demo"; printf 'plugins { java }\n' > "$d/$m/build.gradle.kts"
    printf 'package demo;\n\npublic class %s {\n    public static String name() { return "%s"; }\n}\n' "$cls" "$m" > "$d/$m/src/main/java/demo/$cls.java"
  done
}
obuild() { # NAME USER PASS   a fresh project copy, a new Gradle home, no daemon, the compile tasks only; sets OFC (tasks from cache), O401 (401 lines), OLAST
  local name="$1" u="$2" p="$3" d="$W/o/$1"
  o_project "$d"; rm -rf "$W/og-$name"; mkdir -p "$W/og-$name"; OLAST="o-$name"
  run "o-$name" "$d" <<EOF
export GRADLE_USER_HOME="$W/og-$name" FSCACHE_URL="http://127.0.0.1:${OPORT}/" FSCACHE_USERNAME='$u' FSCACHE_PASSWORD='$p'
gradle --no-daemon --console=plain :core:compileJava :app:compileJava :util:compileJava :api:compileJava
EOF
  expect "o-$name" "BUILD SUCCESSFUL"
  OFC="$(count "o-$name" 'FROM-CACHE')"; O401="$(count "o-$name" 'response status 401: Unauthorized')"
  rm -rf "$W/og-$name" "$d"
}
owant() { # LABEL WANT_FROM_CACHE WANT_401(yes|no)
  local label="$1" want="$2" w401="$3" ok=1
  [ "$OFC" = "$want" ] || { fail "O $label: the page says $want of 4 restored; the build restored $OFC"; ok=0; }
  if [ "$w401" = yes ]; then
    [ "$O401" -ge 1 ] 2>/dev/null || { fail "O $label: the page says the log has 'response status 401: Unauthorized'; it does not"; ok=0; }
    grep -qF 'The remote build cache was disabled during the build due to errors' "$W/$OLAST.out" || { fail "O $label: the page says Gradle disabled the remote cache for the rest of the build; the line is missing"; ok=0; }
  else
    [ "$O401" = 0 ] || { fail "O $label: the page expects no 401 here; the log has $O401"; ok=0; }
  fi
  [ "$ok" = 1 ] && echo "OBS O $label: restored $OFC of 4$([ "$w401" = yes ] && echo ', the 401 line was printed and the remote cache was disabled for the rest of the build'), as the page says"
  return 0
}
ocode() { # LABEL WANT METHOD USER:PASS KEY   a direct request ("" = no login)
  local label="$1" want="$2" method="$3" up="$4" key="$5"; local -a a
  a=(); [ -n "$up" ] && a=(-u "$up")
  if [ "$method" = PUT ]; then check_code "O $label" "$want" -X PUT --data-binary x ${a[@]+"${a[@]}"} "http://127.0.0.1:${OPORT}/$key"
  else check_code "O $label" "$want" ${a[@]+"${a[@]}"} "http://127.0.0.1:${OPORT}/$key"; fi
}
orestart() { # NAME KEY=VALUE...   stop the server and start it again on the same data folder; the logins come only from the arguments
  local name="$1"; shift; local d="$W/srv-$name"
  stop_server
  ( cd "$d" && exec env FSCACHE_ADDR="127.0.0.1:${OPORT}" "$@" ./fscache ) >> "$d/server.log" 2>&1 &
  SERVER_PID=$!; SERVER_PORT="$OPORT"
  wait_up "$OPORT" || { fail "server $name did not come back on ${OPORT}"; tail -n 5 "$d/server.log" | sed 's/^/    | /'; return 1; }
}
ofill() { # NAME   a fresh server on the old logins and one cold build that fills the cache
  start_server "$1" "$OPORT" ci-old oldrw-secret FSCACHE_RO_USERNAME=dev-old FSCACHE_RO_PASSWORD=oldro-secret || return 1
  obuild "$1-fill" ci-old oldrw-secret; owant "$1: the cold build on the old logins" 0 no
}
scenario_o() {
  echo; echo "== O  (change-build-cache-logins-without-breaking-ci)"
  local D="$W/o" S n; mkdir -p "$D"
  # --- the table's rows 1 and 2: old logins
  ofill o1 || return
  obuild r1b ci-old oldrw-secret; owant "row 1: read-write again, old logins" 4 no
  S="$(statusz "$OPORT" ci-old oldrw-secret)"; echo "OBS O the server after row 1: ${S}"
  [ "$(entries_of "$S")" -ge 4 ] 2>/dev/null || fail "O row 1: the first build should have stored its four results on the server; ${S}"
  obuild r2 dev-old oldro-secret; owant "row 2: read-only, old logins" 4 no
  # --- rows 3 and 4: restart with new passwords
  orestart o1 FSCACHE_USERNAME=ci-old FSCACHE_PASSWORD=newrw-secret FSCACHE_RO_USERNAME=dev-old FSCACHE_RO_PASSWORD=newro-secret || return
  ocode "the old read-write login is refused right after the restart" 401 GET ci-old:oldrw-secret somekey
  obuild r3a ci-old oldrw-secret; owant "row 3: old read-write login after the restart" 0 yes
  obuild r3b dev-old oldro-secret; owant "row 3: old read-only login after the restart" 0 yes
  obuild r4a ci-old newrw-secret; owant "row 4: new read-write login" 4 no
  obuild r4b dev-old newro-secret; owant "row 4: new read-only login" 4 no
  # --- rows 8, 9, 10: direct requests against the new logins (read and write)
  for m in GET PUT; do
    ocode "row 8: right username, wrong password ($m)" 401 $m ci-old:oldrw-secret rowkey
    ocode "row 8: wrong username, right password ($m)" 401 $m ci-other:newrw-secret rowkey
    ocode "row 9: read-only username with the read-write password ($m)" 401 $m dev-old:newrw-secret rowkey
    ocode "row 9: read-write username with the read-only password ($m)" 401 $m ci-old:newro-secret rowkey
    ocode "row 10: no login ($m)" 401 $m "" rowkey
  done
  check_code "O row 10: /healthz without a login" 200 "http://127.0.0.1:${OPORT}/healthz"
  # --- row 11: change only the read-only password
  orestart o1 FSCACHE_USERNAME=ci-old FSCACHE_PASSWORD=newrw-secret FSCACHE_RO_USERNAME=dev-old FSCACHE_RO_PASSWORD=newro2-secret || return
  ocode "row 11: the old read-only password after changing only the read-only pair" 401 GET dev-old:newro-secret rowkey
  ocode "row 11: the new read-only password works" 404 GET dev-old:newro2-secret rowkey
  obuild r11 ci-old newrw-secret; owant "row 11: the read-write build, read-write pair unchanged" 4 no
  S="$(statusz "$OPORT" ci-old newrw-secret)"
  # --- no password in the log, /statusz or /metrics
  curl -s --max-time 30 -u ci-old:newrw-secret "http://127.0.0.1:${OPORT}/statusz" > "$D/statusz.txt"
  curl -s --max-time 30 -u ci-old:newrw-secret "http://127.0.0.1:${OPORT}/metrics" > "$D/metrics.txt"
  grep -ci 'auth\|login\|user' "$D/statusz.txt" | sed 's/^/OBS O lines in /statusz that mention a login: /'
  grep -iE 'auth|login|user' "$D/statusz.txt" | head -n 3 | sed 's/^/OBS O   /'
  stop_server
  # --- the three orders, counting the jobs that got a 401
  local N
  ofill o2 || return; N=0
  orestart o2 FSCACHE_USERNAME=ci-new FSCACHE_PASSWORD=nrw-secret FSCACHE_RO_USERNAME=dev-new FSCACHE_RO_PASSWORD=nro-secret || return
  for n in 1 2 3; do obuild "ord1-$n" ci-old oldrw-secret; owant "order 1, job $n (server first, old login still in CI)" 0 yes; [ "$O401" -ge 1 ] && N=$((N+1)); done
  obuild ord1-after ci-new nrw-secret; owant "order 1, after CI was updated" 4 no
  [ "$N" = 3 ] && echo "OBS O order 1 (server first, CI later): 3 jobs in between, $N got a 401, as the page says" || fail "O order 1: the page says 3 jobs got a 401; $N did"
  stop_server
  ofill o3 || return; N=0
  for n in 1 2; do obuild "ord2-$n" ci-new nrw-secret; owant "order 2, job $n (CI first, the server still on the old login)" 0 yes; [ "$O401" -ge 1 ] && N=$((N+1)); done
  orestart o3 FSCACHE_USERNAME=ci-new FSCACHE_PASSWORD=nrw-secret FSCACHE_RO_USERNAME=dev-new FSCACHE_RO_PASSWORD=nro-secret || return
  obuild ord2-after ci-new nrw-secret; owant "order 2, after the server restart" 4 no
  [ "$N" = 2 ] && echo "OBS O order 2 (CI first, server later): 2 jobs in between, $N got a 401, as the page says" || fail "O order 2: the page says 2 jobs got a 401; $N did"
  stop_server
  # the four steps (rows 5, 6, 7)
  ofill o4 || return; N=0
  orestart o4 FSCACHE_USERNAME=ci-new FSCACHE_PASSWORD=nrw-secret FSCACHE_RO_USERNAME=ci-old FSCACHE_RO_PASSWORD=oldrw-secret || return
  ocode "row 7: the developers' old read-only login, a direct request, at step 2" 401 GET dev-old:oldro-secret rowkey
  obuild ord3-1 ci-old oldrw-secret; owant "row 5: the old read-write login, now the read-only login" 4 no; [ "$O401" -ge 1 ] && N=$((N+1))
  ocode "row 5: a direct write with the old read-write login (now read-only)" 403 PUT ci-old:oldrw-secret writekey
  obuild ord3-2 ci-new nrw-secret; owant "row 6: the new read-write login, job 2" 4 no; [ "$O401" -ge 1 ] && N=$((N+1))
  ocode "row 6: a direct write with the new read-write login" 201 PUT ci-new:nrw-secret writekey
  obuild ord3-3 ci-new nrw-secret; owant "row 6: the new read-write login, job 3" 4 no; [ "$O401" -ge 1 ] && N=$((N+1))
  orestart o4 FSCACHE_USERNAME=ci-new FSCACHE_PASSWORD=nrw-secret FSCACHE_RO_USERNAME=dev-new FSCACHE_RO_PASSWORD=nro-secret || return
  obuild ord3-old ci-old oldrw-secret; owant "the job left on the old login until the end (step 4 done)" 0 yes; [ "$O401" -ge 1 ] && N=$((N+1))
  [ "$N" = 1 ] && echo "OBS O the four steps (3 jobs in between, all restored 4 of 4): $N job got a 401, as the page says" || fail "O the four steps: the page says 1 job got a 401; $N did"
  stop_server
  # --- the two refusals to start
  startcase o-same FSCACHE_USERNAME=aaa FSCACHE_PASSWORD=bbb-secret FSCACHE_RO_USERNAME=aaa FSCACHE_RO_PASSWORD=ccc-secret
  casefail "O identical read-only and read-write usernames" "FSCACHE_RO_USERNAME must differ from FSCACHE_USERNAME"
  startcase o-roonly FSCACHE_RO_USERNAME=rrr FSCACHE_RO_PASSWORD=sss-secret
  casefail "O a read-only login without a read-write login" "FSCACHE_RO_USERNAME and FSCACHE_RO_PASSWORD require FSCACHE_USERNAME and FSCACHE_PASSWORD"
  # --- nowhere did the server print a password
  local leaks; leaks="$(grep -l 'secret' "$W"/srv-o*/server.log "$D/statusz.txt" "$D/metrics.txt" "$W"/p-o-*/log 2>/dev/null | tr '\n' ' ')"
  [ -z "$leaks" ] && echo "OBS O no password in the server logs, /statusz or /metrics (every test password ends in -secret; searched: the logs of every server of this scenario, /statusz, /metrics)" || fail "O a password appeared in: ${leaks}"
}

# =====================================================================================
# P  /build-cache-server-wont-start-errors/
# =====================================================================================
scenario_p() {
  echo; echo "== P  (build-cache-server-wont-start-errors)"
  local D="$W/p" PA=18161 v i n S k
  mkdir -p "$D"
  # --- a second server on an address in use; the first keeps serving
  start_server p0 "$PA" "" "" || return
  curl -s --max-time 30 -X PUT --data-binary x "http://127.0.0.1:${PA}/held" >/dev/null
  CASE_PORT=$PA startcase p-inuse
  casefail "P an address already in use" "listen tcp 127.0.0.1:${PA}: bind: address already in use"
  [ "$(http_code "http://127.0.0.1:${PA}/healthz")" = 200 ] && echo "OBS P the first server still answers /healthz" || fail "P the first server stopped answering after the second one failed"
  stop_server
  # --- invalid FSCACHE_ADDR values (six); the first column of the page's table has three phrasings
  i=0
  for v in garbage 127.0.0.1 18702 :99999 :-1 127.0.0.1:abc; do
    i=$((i+1)); startcase "p-addr$i" "FSCACHE_ADDR=$v"
    if [ "$CASE_RC" = 1 ] && { grep -qF "missing port in address" "$CASE_LOG" || grep -qF "invalid port" "$CASE_LOG" || grep -qF "unknown port" "$CASE_LOG"; }; then
      echo "OBS P FSCACHE_ADDR=$v: exit code 1 after ${CASE_SECS} s; last line: ${CASE_LAST}"
    else fail "P FSCACHE_ADDR=$v: the page says exit code 1 with 'missing port in address', 'invalid port' or 'unknown port'; got exit '${CASE_RC}', last line: ${CASE_LAST}"; fi
    if [ -e "$W/p-p-addr$i/data/meta.db" ] && [ -e "$W/p-p-addr$i/data/blobs" ]; then echo "OBS P FSCACHE_ADDR=$v still left meta.db and blobs behind"; else fail "P the page says a bad address leaves meta.db and blobs in the data folder; for $v they are not there"; fi
  done
  grep -qF "listen tcp: address garbage: missing port in address" "$W/p-p-addr1/log" && echo "OBS P FSCACHE_ADDR=garbage printed the line shown in the table" || fail "P the table's line 'listen tcp: address VALUE: missing port in address' did not appear for garbage: $(tail -n 1 "$W/p-p-addr1/log" | cut -c1-200)"
  # --- the data folder
  CASE_PRE='touch "$dir/afile"' startcase p-file "FSCACHE_DATA_DIR=$W/p-p-file/afile"
  casefail "P the data path is a file" "check shutdown marker: stat $W/p-p-file/afile/.unclean-shutdown: not a directory"
  CASE_PRE='mkdir "$dir/ro"; chmod 555 "$dir/ro"' startcase p-ro "FSCACHE_DATA_DIR=$W/p-p-ro/ro"
  casefail "P a data folder the server cannot write to" "write shutdown marker: open $W/p-p-ro/ro/.unclean-shutdown: permission denied"
  CASE_PRE='mkdir "$dir/rop"; chmod 555 "$dir/rop"' startcase p-rop "FSCACHE_DATA_DIR=$W/p-p-rop/rop/child"
  casefail "P a data folder inside a read-only parent" "write shutdown marker: mkdir $W/p-p-rop/rop/child: permission denied"
  CASE_NODATA=1 CASE_PRE='mkdir "$dir/rocwd"; chmod 555 "$dir/rocwd"' CASE_CWD="$W/p-p-rocwd/rocwd" startcase p-rocwd
  casefail "P no data setting, started in a read-only folder" "mkdir data: permission denied"
  # --- the index file meta.db: four 100-byte entries first
  start_server p1 18162 "" "" || return
  for k in k1 k2 k3 k4; do head -c 100 /dev/zero | curl -s --max-time 30 -o /dev/null -X PUT --data-binary @- "http://127.0.0.1:18162/$k"; done
  S="$(statusz 18162 x y)"; check_entries "P before the meta.db cases" "$S" 4
  stop_server
  local BASE="$W/srv-p1/data"
  [ -f "$BASE/meta.db" ] || { fail "P the data folder has no meta.db at $BASE"; return; }
  for v in empty deleted; do
    rm -rf "$W/mcopy-$v"; cp -R "$BASE" "$W/mcopy-$v"
    if [ "$v" = empty ]; then : > "$W/mcopy-$v/meta.db"; else rm -f "$W/mcopy-$v/meta.db"; fi
    CASE_KEEP=1 CASE_PORT=18163 startcase "p-meta-$v" "FSCACHE_DATA_DIR=$W/mcopy-$v"
    casestarts "P meta.db $v"
    if [ "$CASE_RC" = running ]; then
      wait_up 18163 || fail "P meta.db $v: nothing answered"
      check_code "P meta.db $v: an old entry is still served" 200 "http://127.0.0.1:18163/k1"
      head -c 100 /dev/zero | curl -s --max-time 30 -o /dev/null -X PUT --data-binary @- "http://127.0.0.1:18163/newkey"
      S="$(statusz 18163 x y)"; echo "OBS P meta.db $v: /statusz after one new 100-byte upload: ${S}; store_bytes=$(sfield 18163 store_bytes)"
      [ "$(entries_of "$S")" = 1 ] || fail "P meta.db $v: the page says /statusz counts only the entry stored afterwards (1 entry); the server says ${S}"
      [ "$(sfield 18163 store_bytes)" = 100 ] || fail "P meta.db $v: the page says 100 bytes; the server says $(sfield 18163 store_bytes)"
      casestop
    fi
  done
  rm -rf "$W/mcopy-random"; cp -R "$BASE" "$W/mcopy-random"; head -c "$(wc -c < "$BASE/meta.db")" /dev/urandom > "$W/mcopy-random/meta.db"
  CASE_PORT=18163 startcase p-meta-random "FSCACHE_DATA_DIR=$W/mcopy-random"
  casefail "P meta.db overwritten with random bytes" "open metadata store: metadata: open: invalid database"
  rm -rf "$W/mcopy-ro"; cp -R "$BASE" "$W/mcopy-ro"; chmod 444 "$W/mcopy-ro/meta.db"
  CASE_PORT=18163 startcase p-meta-ro "FSCACHE_DATA_DIR=$W/mcopy-ro"
  casefail "P meta.db read-only" "open metadata store: metadata: open: open $W/mcopy-ro/meta.db: permission denied"
  # --- a second server on a data folder held by a running server
  start_server p2 18164 "" "" || return
  curl -s --max-time 30 -o /dev/null -X PUT --data-binary x "http://127.0.0.1:18164/held"
  CASE_TICKS=48 CASE_PORT=18165 startcase p-held "FSCACHE_DATA_DIR=$W/srv-p2/data"
  casefail "P a second server on a data folder held by a running server" "open metadata store: metadata: open: timeout"
  awk -v s="$CASE_SECS" 'BEGIN { exit !(s >= 4 && s <= 8) }' && echo "OBS P the second server gave up after ${CASE_SECS} s, as the page says (about 5 seconds)" || fail "P the page says about 5 seconds; the second server took ${CASE_SECS} s"
  [ "$(http_code "http://127.0.0.1:18164/healthz")" = 200 ] && [ "$(http_code "http://127.0.0.1:18164/held")" = 200 ] && echo "OBS P the first server answers /healthz and kept its entry" || fail "P the first server did not keep serving"
  stop_server
  # --- size settings
  i=0
  for v in -1 abc 10GB 10G 1.5 12abc 1e6 " 100"; do
    i=$((i+1)); startcase "p-size$i" "FSCACHE_MAX_BYTES=$v"
    casefail "P FSCACHE_MAX_BYTES=\"$v\"" "FSCACHE_MAX_BYTES="
    [ ! -e "$W/p-p-size$i/data" ] || fail "P FSCACHE_MAX_BYTES=\"$v\": the page says no data folder was created; there is one"
  done
  grep -qF 'FSCACHE_MAX_BYTES=\"10GB\" is not a valid byte count (whole non-negative decimal number)' "$W/p-p-size3/log" && echo "OBS P the 10GB line is the one the table shows" || fail "P the table's 10GB line is not in the log: $(tail -n 1 "$W/p-p-size3/log" | cut -c1-220)"
  grep -qF 'FSCACHE_MAX_BYTES=\"-1\" is negative; a byte count cannot be' "$W/p-p-size1/log" && echo "OBS P the -1 line is the one the table shows" || fail "P the table's -1 line is not in the log: $(tail -n 1 "$W/p-p-size1/log" | cut -c1-220)"
  startcase p-size0 FSCACHE_MAX_BYTES=0;    casestarts "P FSCACHE_MAX_BYTES=0" '"max_bytes":0'
  [ "$CASE_STOP_RC" = 0 ] || fail "P a normal stop should exit with code 0; it exited ${CASE_STOP_RC}"
  startcase p-size5000 FSCACHE_MAX_BYTES=5000; casestarts "P FSCACHE_MAX_BYTES=5000" '"max_bytes":5000'
  # --- upload and body limits
  startcase p-up1 FSCACHE_MAX_CONCURRENT_UPLOADS=abc;  casefail "P FSCACHE_MAX_CONCURRENT_UPLOADS=abc" 'FSCACHE_MAX_CONCURRENT_UPLOADS=\"abc\" is not a valid byte count'
  startcase p-up2 FSCACHE_MAX_CONCURRENT_UPLOADS=-1;   casefail "P FSCACHE_MAX_CONCURRENT_UPLOADS=-1" 'FSCACHE_MAX_CONCURRENT_UPLOADS=\"-1\" is negative; a byte count cannot be'
  startcase p-body FSCACHE_MAX_BODY_BYTES=big;         casefail "P FSCACHE_MAX_BODY_BYTES=big" 'FSCACHE_MAX_BODY_BYTES=\"big\" is not a valid byte count'
  startcase p-up0 FSCACHE_MAX_CONCURRENT_UPLOADS=0;    casestarts "P FSCACHE_MAX_CONCURRENT_UPLOADS=0"
  startcase p-up32 FSCACHE_MAX_CONCURRENT_UPLOADS=32;  casestarts "P FSCACHE_MAX_CONCURRENT_UPLOADS=32"
  # --- logins
  startcase p-l1 FSCACHE_USERNAME=aaa;                 casefail "P one half of the read-write pair" "FSCACHE_USERNAME and FSCACHE_PASSWORD must both be set or both be empty"
  startcase p-l2 FSCACHE_RO_USERNAME=rrr;              casefail "P one half of the read-only pair" "FSCACHE_RO_USERNAME and FSCACHE_RO_PASSWORD must both be set or both be empty"
  startcase p-l3 FSCACHE_RO_USERNAME=rrr FSCACHE_RO_PASSWORD=sss; casefail "P a read-only pair without the read-write pair" "FSCACHE_RO_USERNAME and FSCACHE_RO_PASSWORD require FSCACHE_USERNAME and FSCACHE_PASSWORD"
  startcase p-l4 FSCACHE_USERNAME=aaa FSCACHE_PASSWORD=bbb FSCACHE_RO_USERNAME=aaa FSCACHE_RO_PASSWORD=ccc; casefail "P the same username twice" "FSCACHE_RO_USERNAME must differ from FSCACHE_USERNAME"
  for n in up1 up2 body l1 l2 l3 l4; do [ ! -e "$W/p-p-$n/data" ] || fail "P a rejected setting ($n): the page says no data folder was created; there is one"; done
  echo "OBS P a rejected login, upload-limit or body-limit setting created no data folder"
  # --- starts, but not the way you meant: a misspelled name; the right name
  CASE_KEEP=1 CASE_PORT=18166 startcase p-typo FSCACHE_MAXBYTES=1500
  casestarts "P FSCACHE_MAXBYTES=1500 (misspelled)" '"max_bytes":0'
  if [ "$CASE_RC" = running ]; then
    wait_up 18166 || fail "P the misspelled-name server did not answer"
    for k in a b c d; do head -c 1000 /dev/zero | curl -s --max-time 30 -o /dev/null -X PUT --data-binary @- "http://127.0.0.1:18166/$k"; done
    S="$(statusz 18166 x y)"; check_entries "P misspelled name: four 1,000-byte uploads" "$S" 4
    # HTTPS to the plain HTTP port: the server logs nothing
    n="$(wc -l < "$CASE_LOG")"; curl -sk --max-time 10 -o /dev/null "https://127.0.0.1:18166/healthz"; v=$?
    [ "$v" = 35 ] && echo "OBS P curl with https:// to the plain HTTP port: exit code 35" || fail "P the page says curl exit code 35 for https:// to the server's port; curl exited $v"
    [ "$(wc -l < "$CASE_LOG")" = "$n" ] && echo "OBS P the server logged nothing for the https:// request" || fail "P the page says the server logged nothing for the https:// request; it logged $(( $(wc -l < "$CASE_LOG") - n )) line(s)"
    check_code "P /healthz over http://" 200 "http://127.0.0.1:18166/healthz"
    casestop
  fi
  CASE_KEEP=1 CASE_PORT=18166 startcase p-right FSCACHE_MAX_BYTES=1500
  casestarts "P FSCACHE_MAX_BYTES=1500 (right name)" '"max_bytes":1500'
  if [ "$CASE_RC" = running ]; then
    wait_up 18166 || fail "P the right-name server did not answer"
    for k in a b c d; do head -c 1000 /dev/zero | curl -s --max-time 30 -o /dev/null -X PUT --data-binary @- "http://127.0.0.1:18166/$k"; done
    S="$(statusz 18166 x y)"; check_entries "P right name: one entry left after four uploads" "$S" 1
    [ "$(sfield 18166 evicted_entries)" = 3 ] && echo "OBS P right name: 3 entries evicted, as the page says" || fail "P the page says 3 evicted; the server says $(sfield 18166 evicted_entries)"
    casestop
  fi
  # --- the container image on a volume that belongs to root
  local got; for n in 1 2 3; do docker pull -q "$IMG:${VER}" >/dev/null 2>&1 && break; sleep 5; done
  got="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMG:${VER}" 2>/dev/null)"
  [ "${got#*@}" = "$IMG_022" ] || { fail "P: $IMG:${VER} is '${got#*@}', not the pinned ${IMG_022}: no image is run"; return; }
  run p-cosign "$D" <<EOF
cosign verify ${IMG}@${IMG_022} --certificate-identity-regexp="^https://github.com/fosterstack/cache/.github/workflows/stage-promote.yml@refs/tags/v${VER}\$" --certificate-oidc-issuer='https://token.actions.githubusercontent.com'
EOF
  expect p-cosign "${IMG_022}"; [ "$RC" = 0 ] || { fail "P: the image signature did not verify: no image is run"; return; }
  docker rm -f fscache >/dev/null 2>&1; docker volume rm fscache-data >/dev/null 2>&1; CONTAINERS="$CONTAINERS fscache"
  run p-vol "$D" <<'EOF'
docker volume create fscache-data
docker run --rm -v fscache-data:/d ubuntu:24.04 sh -c 'mkdir -p /d/data && chown 0:0 /d /d/data && chmod 755 /d /d/data && stat -c "%n %u:%g %A" /d /d/data'
EOF
  expect p-vol "/d 0:0 drwxr-xr-x" "/d/data 0:0 drwxr-xr-x"
  docker run -d --name fscache -p 127.0.0.1:18167:8080 -v fscache-data:/home/nonroot "${IMG}:${VER}" >/dev/null
  for i in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Status}}' fscache 2>/dev/null)" = exited ] && break; sleep 0.5; done
  S="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' fscache 2>/dev/null)"
  [ "$S" = "exited 1" ] && echo "OBS P the container on a root-owned volume exited with status 1" || fail "P the page says the container exits with status 1; it says '${S}'"
  docker logs fscache 2>&1 | tail -n 1 | cut -c1-260 | sed 's/^/OBS P the log: /'
  docker logs fscache 2>&1 | grep -qF '"error":"write shutdown marker: open data/.unclean-shutdown: permission denied"' && echo "OBS P the log ends with the line the page shows" || fail "P the log does not hold the line the page shows"
  run p-chown "$D" <<'EOF'
docker run --rm -v fscache-data:/d ubuntu:24.04 chown -R 65532:65532 /d
EOF
  expect p-chown
  docker rm -f fscache >/dev/null 2>&1
  docker run -d --name fscache -p 127.0.0.1:18167:8080 -v fscache-data:/home/nonroot "${IMG}:${VER}" >/dev/null
  wait_up 18167 && echo "OBS P after the chown the same image started" || fail "P after the chown the image did not start: $(docker logs fscache 2>&1 | tail -n 2 | cut -c1-200)"
  [ "$(curl -s --max-time 10 http://127.0.0.1:18167/healthz)" = ok ] && echo "OBS P /healthz answered ok" || fail "P /healthz did not answer ok"
  check_code "P an upload after the chown" 201 -X PUT --data-binary x "http://127.0.0.1:18167/afterchown"
  docker rm -f fscache >/dev/null 2>&1; docker volume rm fscache-data >/dev/null 2>&1
  # a new empty volume; one whose top folder was set to root: both start, and the folder belongs to 65532 afterwards
  for v in plain toproot; do
    docker rm -f fscache >/dev/null 2>&1; docker volume rm fscache-v-$v >/dev/null 2>&1; docker volume create fscache-v-$v >/dev/null
    [ "$v" = toproot ] && docker run --rm -v fscache-v-$v:/d ubuntu:24.04 chown 0:0 /d
    docker run -d --name fscache -p 127.0.0.1:18167:8080 -v fscache-v-$v:/home/nonroot "${IMG}:${VER}" >/dev/null
    if wait_up 18167; then
      S="$(docker run --rm -v fscache-v-$v:/d ubuntu:24.04 stat -c '%u:%g' /d | tr -d '\n')"
      [ "$S" = 65532:65532 ] && echo "OBS P a new empty volume ($v): started, and its folder belongs to 65532:65532 afterwards" || fail "P a new empty volume ($v): the page says its folder belongs to 65532 afterwards; stat says ${S}"
    else fail "P a new empty volume ($v) did not start: $(docker logs fscache 2>&1 | tail -n 2 | cut -c1-200)"; fi
    docker rm -f fscache >/dev/null 2>&1; docker volume rm fscache-v-$v >/dev/null 2>&1
  done
}

# =====================================================================================
# S  /build-cache-hit-rate-how-to-measure/
# =====================================================================================
SPORT=18171
s_gproject() { # DIR  (four modules in a chain, 12 small classes each, the remote cache on the server, Gradle's own local cache off)
  local d="$1" m prev="" i; rm -rf "${d:?}"; mkdir -p "$d"
  printf 'rootProject.name = "demo"\ninclude("core", "util", "api", "app")\n\n' > "$d/settings.gradle.kts"
  cat >> "$d/settings.gradle.kts" <<EOF
buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:${SPORT}/")
        isAllowInsecureProtocol = true
        isPush = true
    }
}
EOF
  printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
  for m in core util api app; do
    mkdir -p "$d/$m/src/main/java/demo/$m"
    if [ -n "$prev" ]; then printf 'plugins { java }\n\ndependencies {\n    implementation(project(":%s"))\n}\n' "$prev" > "$d/$m/build.gradle.kts"; else printf 'plugins { java }\n' > "$d/$m/build.gradle.kts"; fi
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      printf 'package demo.%s;\n\npublic class C%s {\n    public int f() { return %s; }\n}\n' "$m" "$i" "$i" > "$d/$m/src/main/java/demo/$m/C$i.java"
    done
    prev="$m"
  done
}
sgbuild() { # NAME CHANGE(0|1)  a fresh copy, a new Gradle home; the page's three commands word for word
  local name="$1" change="$2" d="$W/s/g-$1"
  s_gproject "$d"
  [ "$change" = 1 ] && printf 'package demo.core;\n\npublic class C1 {\n    public int f() { return 101; }\n}\n' > "$d/core/src/main/java/demo/core/C1.java"
  rm -rf "$W/sg-$name"; mkdir -p "$W/sg-$name"
  run "s-g-$name" "$d" <<EOF
export GRADLE_USER_HOME="$W/sg-$name"
gradle assemble --info --console=plain > build.log
grep -c 'Build cache key for task' build.log     # tasks that can be cached
grep -c '^> Task .* FROM-CACHE\$' build.log      # of those, taken from the cache
grep -F 'BUILD SUCCESSFUL' build.log
grep -F 'actionable tasks' build.log
gradle --stop >/dev/null 2>&1
true
EOF
  expect "s-g-$name" "BUILD SUCCESSFUL"
  SKEYS="$(grep -E '^[0-9]+$' "$W/s-g-$name.out" | sed -n 1p)"; SFC="$(grep -E '^[0-9]+$' "$W/s-g-$name.out" | sed -n 2p)"; SSUM="$(grep -F 'actionable tasks' "$W/s-g-$name.out" | head -n 1)"
  rm -rf "$W/sg-$name" "$d"
}
s_mproject() { # DIR CHANGE(0|1)  (a three-module chain a <- b <- c under a parent pom, the eight plugin versions pinned)
  local d="$1" change="$2" m dep=""; rm -rf "${d:?}"; mkdir -p "$d/.mvn"
  cat > "$d/.mvn/extensions.xml" <<EOF
<extensions>
  <extension>
    <groupId>org.apache.maven.extensions</groupId>
    <artifactId>maven-build-cache-extension</artifactId>
    <version>${EXT_VER}</version>
  </extension>
</extensions>
EOF
  cat > "$d/.mvn/maven-build-cache-config.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<cache xmlns="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       xsi:schemaLocation="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0 https://maven.apache.org/xsd/build-cache-config-1.2.0.xsd">
  <configuration>
    <enabled>true</enabled>
    <remote enabled="true" saveToRemote="true" id="fosterstack-cache">
      <url>http://127.0.0.1:${SPORT}/</url>
    </remote>
  </configuration>
</cache>
EOF
  cat > "$d/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>demo</groupId>
  <artifactId>parent</artifactId>
  <version>1.0</version>
  <packaging>pom</packaging>
  <modules><module>a</module><module>b</module><module>c</module></modules>
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
  for m in a b c; do
    mkdir -p "$d/$m/src/main/java/demo"
    {
      printf '<project xmlns="http://maven.apache.org/POM/4.0.0">\n  <modelVersion>4.0.0</modelVersion>\n  <parent><groupId>demo</groupId><artifactId>parent</artifactId><version>1.0</version></parent>\n  <artifactId>%s</artifactId>\n  <packaging>jar</packaging>\n' "$m"
      [ -n "$dep" ] && printf '  <dependencies>\n    <dependency><groupId>demo</groupId><artifactId>%s</artifactId><version>1.0</version></dependency>\n  </dependencies>\n' "$dep"
      printf '</project>\n'
    } > "$d/$m/pom.xml"
    dep="$m"
  done
  printf 'package demo;\n\npublic class A {\n    public static String name() { return "%s"; }\n}\n' "$([ "$change" = 1 ] && echo a2 || echo a)" > "$d/a/src/main/java/demo/A.java"
  printf 'package demo;\n\npublic class B {\n    public static String name() { return A.name() + "b"; }\n}\n' > "$d/b/src/main/java/demo/B.java"
  printf 'package demo;\n\npublic class C {\n    public static String name() { return B.name() + "c"; }\n}\n' > "$d/c/src/main/java/demo/C.java"
}
smbuild() { # NAME CHANGE(0|1)  a fresh copy, an empty local build cache; the page's two commands word for word
  local name="$1" change="$2" d="$W/s/m-$1"
  s_mproject "$d" "$change"
  run "s-m-$name" "$d" <<EOF
export HOME="$W/mvn-home" MAVEN_OPTS="-Duser.home=$W/mvn-home" PATH="$MVN399_HOME/bin:\$PATH"
rm -rf "\$HOME/.m2/build-cache"
mvn verify > build.log
grep -c 'Found cached build, restoring' build.log
grep -F 'BUILD SUCCESS' build.log
true
EOF
  expect "s-m-$name" "BUILD SUCCESS"
  SMFC="$(grep -E '^[0-9]+$' "$W/s-m-$name.out" | sed -n 1p)"; rm -rf "$d"
}
sline() { # LABEL GOT WANT
  if [ "$2" = "$3" ]; then echo "OBS S $1: $2, as the page says"; else fail "S $1: the page says $3; got $2"; fi
}
scenario_s() {
  echo; echo "== S  (build-cache-hit-rate-how-to-measure)"
  mkdir -p "$W/s" "$W/mvn-home/.m2"
  local B A b hd ms want
  # --- Gradle: a new empty server, three builds
  start_server s1 "$SPORT" "" "" || return
  for b in cold:0:0:13:0:4:0 repeat:0:4:0:13:4:4 change:1:3:1:12:4:3; do
    IFS=: read -r name ch _ w_miss w_hit w_keys w_fc <<<"$b"
    # fields: name change(0|1) <unused> misses hits keys fromcache  (see the list above)
    B="$(statusz "$SPORT" x y)"; sgbuild "$name" "$ch"; A="$(statusz "$SPORT" x y)"
    case "$(hits_of "$A")$(misses_of "$A")$(hits_of "$B")$(misses_of "$B")" in *unreadable*) fail "S Gradle $name: /statusz was unreadable"; continue;; esac
    hd=$(( $(hits_of "$A") - $(hits_of "$B") )); ms=$(( $(misses_of "$A") - $(misses_of "$B") ))
    sline "Gradle $name: tasks that can be cached ('Build cache key for task')" "$SKEYS" "4"
    sline "Gradle $name: taken from the cache (FROM-CACHE lines)" "$SFC" "$w_fc"
    # the page's 13 requests include the lookups of the project's own compiled build scripts, which depend on the project: here only the shape is asserted
    echo "OBS S Gradle $name: the server counted $hd hits and $ms misses ($((hd+ms)) requests for 4 cacheable tasks; the rest are Gradle's compiled build scripts)"
    case "$name" in
      cold)   [ "$hd" = 0 ] && [ "$ms" -gt 4 ] || fail "S Gradle cold: the page says no hits and more requests than tasks; got $hd hits, $ms misses";;
      repeat) [ "$ms" = 0 ] && [ "$hd" -gt 4 ] || fail "S Gradle repeat: the page says no misses and more requests than tasks; got $hd hits, $ms misses";;
      change) [ "$ms" = 1 ] && [ "$hd" -gt 3 ] || fail "S Gradle change: the page says one miss; got $hd hits, $ms misses";;
    esac
    echo "OBS S Gradle $name: summary line: ${SSUM}"
    [ "$name" = repeat ] && { case "$SSUM" in *"8 actionable tasks: 4 executed, 4 from cache"*) echo "OBS S the repeat build said '8 actionable tasks: 4 executed, 4 from cache', as the page says";; *) fail "S the page says the repeat build printed '8 actionable tasks: 4 executed, 4 from cache'; it printed '${SSUM}'";; esac; }
  done
  run s-metrics "$W" <<EOF
curl -s localhost:${SPORT}/metrics | grep -E 'fscache_cache_(hits|misses)_total'
curl -s localhost:${SPORT}/statusz            # add -u user:password if login is on
EOF
  expect s-metrics "fscache_cache_hits_total" "fscache_cache_misses_total" '"cache_hits"' '"cache_misses"'
  stop_server
  # --- Maven: a new empty server, three builds
  start_server s2 "$SPORT" "" "" || return
  for b in cold:0:0:3:0:0 repeat:0:0:0:6:3 change:1:0:3:0:0; do
    IFS=: read -r name ch _ w_miss w_hit w_fc <<<"$b"
    B="$(statusz "$SPORT" x y)"; smbuild "$name" "$ch"; A="$(statusz "$SPORT" x y)"
    case "$(hits_of "$A")$(misses_of "$A")$(hits_of "$B")$(misses_of "$B")" in *unreadable*) fail "S Maven $name: /statusz was unreadable"; continue;; esac
    hd=$(( $(hits_of "$A") - $(hits_of "$B") )); ms=$(( $(misses_of "$A") - $(misses_of "$B") ))
    sline "Maven $name: modules restored ('Found cached build, restoring')" "$SMFC" "$w_fc"
    sline "Maven $name: the server's hits in this build" "$hd" "$w_hit"
    sline "Maven $name: the server's misses in this build" "$ms" "$w_miss"
  done
  stop_server
}

# ---------- run ----------
for port in 18151 18161 18162 18163 18164 18165 18166 18167 18171; do
  curl -skf --max-time 3 "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
scenario_o
scenario_p
scenario_s
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
