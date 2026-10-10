#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 4: do the commands and promised outputs of these pages really happen?
#   L  /gradle-build-cache-enable-disable/            the seven on/off runs of the page's table, read-only (isPush = false), and the four-step
#                                                     configuration-cache vs build-cache walk-through with its printed lines
#   M  /gradle-remote-build-cache-authentication/     the fourteen status codes of the page's list, the three ways to supply the password, the
#                                                     401 line, the 413 headers, 429 at the default limit of 32 uploads
#   N  /reset-gradle-build-cache/                     Docker Compose, plain Docker (the page's printed output) and a plain binary
# Run by the "bench-howto-pages-4" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-4"). Same method as
# the other bench scripts: commands word for word, the server's own counters checked, every output line the page promises asserted, a step
# that fails or prints something else is RECORDED (FAIL) and fails the job at the end; observations that are not failures are OBS lines.
#
# No token and no secret. Gradle and cosign are downloaded and checked against pinned sha256 values; the release binary is verified
# (cosign + sha256) before it runs; the cache image is pinned by digest and verified with cosign by digest before docker runs it.
# against pinned checksums; Docker and Compose are the runner's own, and the cache image is verified with cosign before it is run. NOT
# pinned (said again in the output): the Maven build-cache extension, the Maven plugins and JUnit from Maven Central.
set -uo pipefail

VER=0.2.2                                    # the release the pages name
LOCAL="${BENCH_LOCAL:-0}"                    # 1 = a developer's dry run with local tools (nothing downloaded or checked: do not quote times)
if [ "$LOCAL" = 1 ]; then PLATFORM="${BENCH_PLATFORM:-darwin_arm64}"; else PLATFORM=linux_amd64; fi
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
COSIGN_VER=3.1.3
COSIGN_SHA=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
EXT_VER=1.2.3
RW_USER=ci;  RW_PASS='rw-test-secret-not-real'
RO_USER=dev; RO_PASS='ro-test-secret-not-real'
COMPOSE_PASS='change-me'                     # the password the production page's files show

FAILS=0
now() { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }
fail() { FAILS=$((FAILS+1)); printf 'FAIL %s\n' "$*"; }
sha_check() { # file sha256
  if command -v sha256sum >/dev/null 2>&1; then echo "$2  $1" | sha256sum -c - >/dev/null || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }
  else echo "$2  $1" | shasum -a 256 -c - >/dev/null || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }; fi
}
sha512_check() { echo "$2  $1" | { sha512sum -c - 2>/dev/null || shasum -a 512 -c - ; } >/dev/null || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }; }

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
  echo "tools: Gradle ${GR_VER} and cosign ${COSIGN_VER} are downloaded and checked against pinned sha256 values before use; Java 21 and Docker are the runner's own"; fi
echo "release under test: FosterStack Cache ${VER}, downloaded with no login and verified (cosign + sha256) before it runs (binary servers); the image is pulled by tag, must equal the pinned digest, and is verified with cosign by digest before docker runs it"
echo "invented by this script (the pages show none): the Gradle projects (four modules for L, one for M) and their sources, test passwords; the Docker Compose file for N is the quick-start file of /build-cache-docker-compose-production/; the pages' hard-coded ports (18141, 18099) are used as written"
echo "differences from the pages' own runs: Linux amd64 (the pages: macOS arm64), release ${VER} (the pages: 0.2.1), Gradle ${GR_VER} with the runner's Java 21 (the pages: Java 27 for L)"
echo "Gradle runs use a new empty Gradle home and a fresh project copy each, no wrapper; Gradle's own local cache is switched off exactly where the pages switch it off"
echo "NOT tested here: the Kubernetes reset of /reset-gradle-build-cache/ (kubectl scale, delete pvc, apply, scale: covered by a later kind job), Maven, a daemon picking up a changed password (tested in the not-working page's job)"
echo "page commands run with 'bash -o pipefail'; a runner times commands, not people"

export GRADLE_USER_HOME="$W/gradle-home"
mvnhome="$W/mvn-home"; mkdir -p "$mvnhome/.m2"

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
gradle_project() { # DIR URL PUSHEXPR USEREXPR PASSEXPR  (settings as the CI-writes page shows it, plus the line that turns Gradle's own cache off)
  local d="$1"; rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo"
  cat > "$d/settings.gradle.kts" <<EOF
rootProject.name = "demo"

// FosterStack Cache — remote Gradle build cache.
// https://github.com/fosterstack/cache
buildCache {
    local { isEnabled = false } // so a hit can only come from the remote
    remote<HttpBuildCache> {
        url = uri("$2")
        // CI pushes; everyone else only reads
        isPush = $3
        credentials {
            username = $4
            password = $5
        }
    }
}
EOF
  printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
  printf 'plugins { java }\n' > "$d/build.gradle.kts"
  gradle_code "$d" 1
}
gradle_code() { # DIR N  (N changes what is compiled)
  printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println("hello %s");\n    }\n}\n' "$2" > "$1/src/main/java/demo/App.java"
}
mvn_project() { # DIR PIN(0|1) SAVEFILE(0|1) URL CODE
  local d="$1" pin="$2" save="$3" url="$4" code="$5"
  rm -rf "${d:?}"; mkdir -p "$d/.mvn" "$d/src/main/java/demo" "$d/src/test/java/demo"
  cat > "$d/.mvn/extensions.xml" <<EOF
<extensions>
  <extension>
    <groupId>org.apache.maven.extensions</groupId>
    <artifactId>maven-build-cache-extension</artifactId>
    <version>${EXT_VER}</version>
  </extension>
</extensions>
EOF
  local remote='<remote enabled="true" id="fosterstack-cache">'
  [ "$save" = 1 ] && remote='<remote enabled="true" saveToRemote="true" id="fosterstack-cache">'
  cat > "$d/.mvn/maven-build-cache-config.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<cache xmlns="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       xsi:schemaLocation="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0 https://maven.apache.org/xsd/build-cache-config-1.2.0.xsd">
  <configuration>
    <enabled>true</enabled>
    ${remote}
      <url>${url}</url>
    </remote>
  </configuration>
</cache>
EOF
  local mgmt=""
  if [ "$pin" = 1 ]; then mgmt='<pluginManagement><plugins>
      <plugin><artifactId>maven-clean-plugin</artifactId><version>3.4.0</version></plugin>
      <plugin><artifactId>maven-resources-plugin</artifactId><version>3.3.1</version></plugin>
      <plugin><artifactId>maven-compiler-plugin</artifactId><version>3.13.0</version></plugin>
      <plugin><artifactId>maven-surefire-plugin</artifactId><version>3.5.2</version></plugin>
      <plugin><artifactId>maven-jar-plugin</artifactId><version>3.4.2</version></plugin>
      <plugin><artifactId>maven-install-plugin</artifactId><version>3.1.3</version></plugin>
      <plugin><artifactId>maven-deploy-plugin</artifactId><version>3.1.3</version></plugin>
      <plugin><artifactId>maven-site-plugin</artifactId><version>3.12.1</version></plugin>
    </plugins></pluginManagement>'; fi
  cat > "$d/pom.xml" <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>demo</groupId>
  <artifactId>mtest</artifactId>
  <version>1.0</version>
  <packaging>jar</packaging>
  <properties>
    <maven.compiler.release>17</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
  <dependencies>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><version>5.11.4</version><scope>test</scope></dependency>
  </dependencies>
  <build>
    ${mgmt}
  </build>
</project>
EOF
  printf 'package demo;\n\npublic class App {\n    public static String hello() { return "hello %s"; }\n}\n' "$code" > "$d/src/main/java/demo/App.java"
  cat > "$d/src/test/java/demo/AppTest.java" <<'EOF'
package demo;

import static org.junit.jupiter.api.Assertions.assertTrue;
import org.junit.jupiter.api.Test;

class AppTest {
    @Test void startsWithHello() { assertTrue(App.hello().startsWith("hello")); }
    @Test void isNotEmpty() { assertTrue(App.hello().length() > 0); }
}
EOF
}
write_settings() { # SIDE(rw|ro|none)  -> ~/.m2/settings.xml of the isolated home
  case "$1" in
    rw)   printf '<settings>\n  <servers>\n    <server>\n      <id>fosterstack-cache</id>\n      <username>%s</username>\n      <password>%s</password>\n    </server>\n  </servers>\n</settings>\n' "$RW_USER" "$RW_PASS" > "$mvnhome/.m2/settings.xml";;
    ro)   printf '<settings>\n  <servers>\n    <server>\n      <id>fosterstack-cache</id>\n      <username>%s</username>\n      <password>%s</password>\n    </server>\n  </servers>\n</settings>\n' "$RO_USER" "$RO_PASS" > "$mvnhome/.m2/settings.xml";;
    none) printf '<settings>\n</settings>\n' > "$mvnhome/.m2/settings.xml";;
  esac
}
mvn_env() { ORIGHOME="$HOME"; export HOME="$mvnhome"; export MAVEN_OPTS="-Duser.home=${mvnhome}"; }
mvn_env_off() { export HOME="$ORIGHOME"; unset MAVEN_OPTS; }


# images (scenario N): the pinned digest of the release under test
IMG=ghcr.io/fosterstack/cache
IMG_022=sha256:f2b330cf27b3814405230cc001a771909ae5bbf3b1e223a90ee7a9ee5d0e53dd

# =====================================================================================
# SCENARIO L: /gradle-build-cache-enable-disable/
# =====================================================================================
l_project() { # DIR  (four modules, the page's settings block verbatim except the port)
  local d="$1" m; rm -rf "${d:?}"; mkdir -p "$d"
  printf 'rootProject.name = "demo"\ninclude("core", "app", "util", "api")\n\n' > "$d/settings.gradle.kts"
  cat >> "$d/settings.gradle.kts" <<EOF
buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:${LP}/")
        isPush = ${LPUSH}
        isAllowInsecureProtocol = true
    }
}
EOF
  local cls
  for m in core app util api; do
    cls="$(printf '%s' "${m:0:1}" | tr a-z A-Z)${m:1}"
    mkdir -p "$d/$m/src/main/java/demo"; printf 'plugins { java }\n' > "$d/$m/build.gradle.kts"
    printf 'package demo;\n\npublic class %s {\n    public static String name() { return "%s"; }\n}\n' "$cls" "$m" > "$d/$m/src/main/java/demo/$cls.java"
  done
}
lgradle() { # NAME DIR GRADLEPROPS(0|1) args...   (a new empty Gradle home for every run, as the page's runs had)
  local name="$1" dir="$2" prop="$3"; shift 3
  rm -rf "$W/lg-$name"; mkdir -p "$W/lg-$name"
  [ "$prop" = 1 ] && printf 'org.gradle.caching=true\n' > "$dir/gradle.properties" || rm -f "$dir/gradle.properties"
  run "l-$name" "$dir" <<EOF
export GRADLE_USER_HOME="$W/lg-$name"
gradle $@
EOF
}

scenario_l() {
  echo; echo "== L  (gradle-build-cache-enable-disable)"
  LP=18141; LPUSH=true; local D="$W/l" S H0 H1 M0 M1 E0 E1
  mkdir -p "$D"
  start_server l "$LP" "" "" || return
  statusn() { statusz "$LP" x y; }
  # --- the page's table of seven runs
  l_project "$D/p1"
  lgradle flag1 "$D/p1" 0 ':core:compileJava --build-cache'
  expect l-flag1 "BUILD SUCCESSFUL" "> Task :core:compileJava"; absent l-flag1 "FROM-CACHE"
  S="$(statusn)"; [ "$(entries_of "$S")" -gt 0 ] 2>/dev/null && echo "OBS L row 1 (flag, first build): ran and saved the result to the server (${S})" || fail "L row 1: nothing was saved to the server (${S})"
  l_project "$D/p2"; S="$(statusn)"
  lgradle nothing "$D/p2" 0 ':core:compileJava'
  expect l-nothing "BUILD SUCCESSFUL" "> Task :core:compileJava"; absent l-nothing "FROM-CACHE"
  [ "$(statusn)" = "$S" ] && echo "OBS L row 2 (nothing set): ran, the cache was not used (the server's counters did not move)" || fail "L row 2: with nothing set the server saw requests ($S -> $(statusn))"
  l_project "$D/p3"; lgradle flag2 "$D/p3" 0 ':core:compileJava --build-cache'
  expect l-flag2 "BUILD SUCCESSFUL" "> Task :core:compileJava FROM-CACHE"
  l_project "$D/p4"; lgradle prop "$D/p4" 1 ':core:compileJava'
  expect l-prop "BUILD SUCCESSFUL" "> Task :core:compileJava FROM-CACHE"
  l_project "$D/p5"; lgradle noflag "$D/p5" 1 ':core:compileJava --no-build-cache'
  expect l-noflag "BUILD SUCCESSFUL" "> Task :core:compileJava"; absent l-noflag "FROM-CACHE"
  echo "OBS L row 5 (property on, --no-build-cache): ran, the flag won"
  l_project "$D/p6"; lgradle sysprop "$D/p6" 0 ':core:compileJava -Dorg.gradle.caching=true'
  expect l-sysprop "BUILD SUCCESSFUL" "> Task :core:compileJava FROM-CACHE"
  l_project "$D/p7"; lgradle rerun "$D/p7" 0 ':core:compileJava --build-cache --rerun-tasks'
  expect l-rerun "BUILD SUCCESSFUL" "> Task :core:compileJava"; absent l-rerun "FROM-CACHE"
  echo "OBS L row 7 (--build-cache --rerun-tasks): ran, even though a result was stored"
  stop_server
  # --- read-only: isPush = false against an empty server
  LPUSH=false; start_server l2 "$LP" "" "" || return
  l_project "$D/ro1"; lgradle ro1 "$D/ro1" 0 ':core:compileJava --build-cache'
  expect l-ro1 "BUILD SUCCESSFUL" "> Task :core:compileJava"; absent l-ro1 "FROM-CACHE"
  S="$(statusn)"; [ "$(entries_of "$S")" = 0 ] && echo "OBS L isPush = false: the build ran and the server still held 0 entries (${S})" || fail "L isPush = false: the server holds entries (${S}), but the page says 0"
  l_project "$D/ro2"; lgradle ro2 "$D/ro2" 0 ':core:compileJava --build-cache'
  expect l-ro2 "BUILD SUCCESSFUL" "> Task :core:compileJava"; absent l-ro2 "FROM-CACHE"
  echo "OBS L isPush = false: a second build also ran the task, because nothing had ever been stored, as the page says"
  stop_server; LPUSH=true
  # --- configuration cache and build cache together (a one-module project; the page's settings block)
  start_server l3 "$LP" "" "" || return
  local C="$W/l/cc"; rm -rf "$C"; mkdir -p "$C/src/main/java/demo"
  cat > "$C/settings.gradle.kts" <<EOF
rootProject.name = "demo"

buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:${LP}/")
        isPush = true
        isAllowInsecureProtocol = true
    }
}
EOF
  printf 'plugins { java }\n' > "$C/build.gradle.kts"; printf 'package demo;\n\npublic class App {\n    public static String name() { return "app"; }\n}\n' > "$C/src/main/java/demo/App.java"
  rm -rf "$W/lg-cc"; mkdir -p "$W/lg-cc"
  local CC="export GRADLE_USER_HOME=\"$W/lg-cc\""
  run l-cc1 "$C" <<EOF
${CC}
gradle build --configuration-cache --build-cache
EOF
  expect l-cc1 "Calculating task graph as no cached configuration is available for tasks: build" "> Task :compileJava" "BUILD SUCCESSFUL" "Configuration cache entry stored."; absent l-cc1 "FROM-CACHE"
  run l-cc2 "$C" <<EOF
${CC}
gradle build --configuration-cache --build-cache
EOF
  expect l-cc2 "Reusing configuration cache." "> Task :compileJava UP-TO-DATE" "BUILD SUCCESSFUL" "Configuration cache entry reused."
  H0="$(hits_of "$(statusn)")"
  run l-cc3 "$C" <<EOF
${CC}
gradle clean
gradle build --configuration-cache --build-cache
EOF
  expect l-cc3 "Reusing configuration cache." "> Task :compileJava FROM-CACHE" "BUILD SUCCESSFUL" "Configuration cache entry reused."
  H1="$(hits_of "$(statusn)")"; [ "$H1" = "$((H0+1))" ] && echo "OBS L step 3: the server's status page counted one hit for the FROM-CACHE (hits ${H0} -> ${H1}), as the page says" || fail "L step 3: the page says the status page counted one hit; hits went ${H0} -> ${H1}"
  printf '\n// a comment, so that the build file changes\n' >> "$C/build.gradle.kts"
  run l-cc4 "$C" <<EOF
${CC}
gradle clean
gradle build --configuration-cache --build-cache
EOF
  expect l-cc4 "Calculating task graph as configuration cache cannot be reused because file 'build.gradle.kts' has changed." "> Task :compileJava FROM-CACHE" "BUILD SUCCESSFUL" "Configuration cache entry stored."
  "$GRADLE_BIN" --stop >/dev/null 2>&1; for g in "$W"/lg-*; do GRADLE_USER_HOME="$g" "$GRADLE_BIN" --stop >/dev/null 2>&1; done
  stop_server
}

# =====================================================================================
# SCENARIO M: /gradle-remote-build-cache-authentication/
# =====================================================================================
scenario_m() {
  echo; echo "== M  (gradle-remote-build-cache-authentication)"
  local D="$W/m" P=18099 B="http://127.0.0.1:18099" S k RWP='m-rw-secret-not-real' ROP='m-ro-secret-not-real'
  mkdir -p "$D"
  # the page's list of fourteen results: a server with a read-write login, a read-only login and the body limit set to 1024 bytes
  start_server m "$P" gradle "$RWP" FSCACHE_RO_USERNAME=reader FSCACHE_RO_PASSWORD="$ROP" FSCACHE_MAX_BODY_BYTES=1024 || return
  check_code "M GET /healthz (no credentials)" 200 "$B/healthz"
  check_code "M GET /metrics (no credentials)" 200 "$B/metrics"
  check_code "M GET key, no credentials" 401 "$B/somekey"
  check_code "M GET key, wrong password" 401 -u gradle:wrong-password "$B/somekey"
  check_code "M GET missing key, read-write login" 404 -u "gradle:$RWP" "$B/missingkey"
  check_code "M PUT 5 bytes, read-write login" 201 -X PUT --data-binary 'hello' -u "gradle:$RWP" "$B/storedkey"
  check_code "M GET stored key, read-write login" 200 -u "gradle:$RWP" "$B/storedkey"
  check_code "M GET stored key, read-only login" 200 -u "reader:$ROP" "$B/storedkey"
  check_code "M HEAD stored key, read-only login" 200 -I -u "reader:$ROP" "$B/storedkey"
  check_code "M PUT, no credentials" 401 -X PUT --data-binary 'hello' "$B/nocredkey"
  check_code "M PUT, read-only login" 403 -X PUT --data-binary 'hello' -u "reader:$ROP" "$B/rokey"
  head -c 2048 /dev/zero > "$D/two-kb"
  check_code "M PUT 2048 bytes (limit set to 1024), read-write login" 413 -X PUT --data-binary @"$D/two-kb" -u "gradle:$RWP" "$B/toolarge"
  check_code "M GET the too-large key afterwards" 404 -u "gradle:$RWP" "$B/toolarge"
  check_code "M /statusz, no credentials" 401 "$B/statusz"
  # 413 for a per-entry limit has no X-FSCache-Reject header
  k="$(curl -s --max-time 20 -D - -o /dev/null -X PUT --data-binary @"$D/two-kb" -u "gradle:$RWP" "$B/toolarge2" | tr -d '\r')"
  case "$(printf '%s' "$k" | tr 'A-Z' 'a-z')" in *"x-fscache-reject"*) fail "M 413 over the per-entry limit: the page says no X-FSCache-Reject header, but the response has one ($k)";; *) echo "OBS M 413 over the per-entry limit: no X-FSCache-Reject header, as the page says";; esac
  stop_server
  start_server m1 "$P" gradle "$RWP" FSCACHE_RO_USERNAME=reader FSCACHE_RO_PASSWORD="$ROP" || return   # no body limit of 1024 bytes now: Gradle's entries are bigger
  # --- the Gradle side: the page's settings block, three ways to supply the password, the 401 line
  m_project() { # DIR PASSWORD-EXPRESSION   (the page's block, the address replaced, Gradle's own cache switched off)
    local d="$1" pe="$2"; rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo"
    cat > "$d/settings.gradle.kts" <<EOF
rootProject.name = "demo"

// FosterStack Cache — remote Gradle build cache.
// https://github.com/fosterstack/cache
buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("${B}/")
        isAllowInsecureProtocol = true
        isPush = true
        credentials {
            username = "gradle"
            password = ${pe}
        }
    }
}
EOF
    printf 'plugins { java }\n' > "$d/build.gradle.kts"; printf 'org.gradle.caching=true\n' > "$d/gradle.properties"; gradle_code "$d" 1
  }
  m_run() { # NAME DIR HOME-PROPS(none|prop) PASSENV EXTRA...
    local name="$1" dir="$2" mode="$3" pw="$4"; shift 4
    rm -rf "$W/mg-$name"; mkdir -p "$W/mg-$name"
    [ "$mode" = prop ] && printf 'fscachePassword=%s\n' "$RWP" > "$W/mg-$name/gradle.properties"
    run "m-$name" "$dir" <<EOF
export GRADLE_USER_HOME="$W/mg-$name"
$( [ -n "$pw" ] && echo "export FSCACHE_PASSWORD='$pw'" )
gradle compileJava $@
EOF
  }
  m_project "$D/g1" 'System.getenv("FSCACHE_PASSWORD")'
  m_run way1a "$D/g1" none "$RWP"
  expect m-way1a "BUILD SUCCESSFUL" "> Task :compileJava"; absent m-way1a "FROM-CACHE"
  m_project "$D/g2" 'System.getenv("FSCACHE_PASSWORD")'; m_run way1b "$D/g2" none "$RWP"
  expect m-way1b "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
  echo "OBS M way 1 (an environment variable): :compileJava FROM-CACHE"
  m_project "$D/g3" 'providers.gradleProperty("fscachePassword").orNull'; m_run way2 "$D/g3" prop ""
  expect m-way2 "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
  echo "OBS M way 2 (the user's gradle.properties): :compileJava FROM-CACHE"
  m_project "$D/g4" 'providers.gradleProperty("fscachePassword").orNull'; m_run way3 "$D/g4" none "" "-PfscachePassword=$RWP"
  expect m-way3 "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
  echo "OBS M way 3 (the command line, -P): :compileJava FROM-CACHE"
  # the 401 line at the default log level, with a wrong password and with none
  m_project "$D/g5" 'System.getenv("FSCACHE_PASSWORD")'; m_run wrong "$D/g5" none "wrong-password"
  expect m-wrong "BUILD SUCCESSFUL" "response status 401: Unauthorized" "Could not load entry"
  m_project "$D/g6" 'System.getenv("FSCACHE_PASSWORD")'; m_run none "$D/g6" none ""
  expect m-none "BUILD SUCCESSFUL" "response status 401: Unauthorized" "Could not load entry"
  echo "OBS M 401: with a wrong password and with none, the default log level printed 'Could not load entry ... response status 401: Unauthorized' and the build succeeded"
  for g in "$W"/mg-*; do GRADLE_USER_HOME="$g" "$GRADLE_BIN" --stop >/dev/null 2>&1; done
  stop_server
  # --- 413 with X-FSCache-Reject: an entry bigger than the whole cache size cap
  start_server m2 "$P" gradle "$RWP" FSCACHE_MAX_BYTES=4096 || return
  head -c 8192 /dev/zero > "$D/eight-kb"
  k="$(curl -s --max-time 20 -D - -o /dev/null -X PUT --data-binary @"$D/eight-kb" -u "gradle:$RWP" "$B/biggerthancap" | tr -d '\r')"
  case "$k" in *" 413"*) echo "OBS M 413 over FSCACHE_MAX_BYTES: HTTP 413";; *) fail "M an entry bigger than FSCACHE_MAX_BYTES should get 413, got: $(printf '%s' "$k" | head -1)";; esac
  case "$(printf '%s' "$k" | tr 'A-Z' 'a-z')" in *"x-fscache-reject: entry-exceeds-cache-cap"*) echo "OBS M 413 over FSCACHE_MAX_BYTES carries the header X-FSCache-Reject: entry-exceeds-cache-cap, as the page says (sent as '$(printf '%s' "$k" | grep -i '^x-fscache-reject' | tr -d '\n')': header names are case-insensitive)";; *) fail "M 413 over FSCACHE_MAX_BYTES: no 'X-FSCache-Reject: entry-exceeds-cache-cap' header ($(printf '%s' "$k" | tr '\n' '|'))";; esac
  stop_server
  # --- 429 at the default limit of 32 uploads in progress (40 slow uploads at once)
  start_server m3 "$P" gradle "$RWP" || return
  python3 - "$P" "$RWP" > "$W/m-429.out" 2>&1 <<'PYEOF'
import socket, sys, base64, time
port, pw = int(sys.argv[1]), sys.argv[2]
auth = base64.b64encode(("gradle:" + pw).encode()).decode()
socks = []
for i in range(40):
    s = socket.create_connection(("127.0.0.1", port), timeout=20)
    s.sendall(("PUT /slow%d HTTP/1.1\r\nHost: x\r\nAuthorization: Basic %s\r\nContent-Length: 1000000\r\n\r\n" % (i, auth)).encode() + b"x" * 1000)
    socks.append(s)
time.sleep(3)
codes = []
for s in socks:
    s.settimeout(0.5)
    try:
        data = s.recv(200)
        codes.append(data.split(b" ")[1].decode() if data.startswith(b"HTTP/") else "?")
    except socket.timeout:
        codes.append("waiting")
print("429:", codes.count("429"), "waiting:", codes.count("waiting"), "other:", sorted(set(c for c in codes if c not in ("429", "waiting"))))
for s in socks: s.close()
PYEOF
  cat "$W/m-429.out"
  grep -q "^429: 8 " "$W/m-429.out" && echo "OBS M 429: 40 uploads started at once, 32 were accepted and 8 got 429, as the page says (the server allows 32 by default)" || fail "M 429: expected 8 of 40 simultaneous uploads to get 429 at the default limit of 32 ($(cat "$W/m-429.out"))"
  S="$(statusz "$P" gradle "$RWP")"; echo "OBS M after the 429 test the server holds: ${S} (a refused upload stores nothing)"
  stop_server
}

# =====================================================================================
# SCENARIO N: /reset-gradle-build-cache/
# =====================================================================================
scenario_n() {
  echo; echo "== N  (reset-gradle-build-cache)"
  local D="$W/n" S got
  mkdir -p "$D"
  # the image: pinned digest, cosign by digest, then docker
  local n; for n in 1 2 3; do docker pull -q "$IMG:${VER}" >/dev/null 2>&1 && break; sleep 5; done
  got="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMG:${VER}" 2>/dev/null)"
  [ "${got#*@}" = "$IMG_022" ] || { fail "N: $IMG:${VER} is '${got#*@}', not the pinned ${IMG_022}: no image is run"; return; }
  run n-cosign "$D" <<EOF
cosign verify ${IMG}@${IMG_022} --certificate-identity-regexp="^https://github.com/fosterstack/cache/.github/workflows/stage-promote.yml@refs/tags/v${VER}\$" --certificate-oidc-issuer='https://token.actions.githubusercontent.com'
EOF
  expect n-cosign "${IMG_022}"; [ "$RC" = 0 ] || { fail "N: the image signature did not verify: no image is run"; return; }
  docker rm -f fscache >/dev/null 2>&1; docker volume rm fscache-data >/dev/null 2>&1
  # --- plain Docker: the page's original docker run, one stored entry, the reset block, the printed output
  CONTAINERS="$CONTAINERS fscache"
  run n-dockerrun "$D" <<EOF
docker run -d --name fscache -p 127.0.0.1:8080:8080 -v fscache-data:/home/nonroot ${IMG}:${VER}
EOF
  expect n-dockerrun; wait_up 8080 || { fail "N: nothing answered on 8080"; return; }
  check_code "N plain Docker: store one entry" 201 -X PUT --data-binary 'x' localhost:8080/testkey
  S="$(statusz 8080 x y)"; [ "$(entries_of "$S")" = 1 ] && echo "OBS N plain Docker, before the reset: /statusz shows one stored entry (${S}), as the page says" || fail "N plain Docker: before the reset the page says one stored entry; the server says ${S}"
  run n-reset-docker "$D" <<'EOF'
docker rm -f fscache
docker volume rm fscache-data
# then run your original docker run command again
EOF
  expect n-reset-docker
  run n-dockerrun2 "$D" <<EOF
docker run -d --name fscache -p 127.0.0.1:8080:8080 -v fscache-data:/home/nonroot ${IMG}:${VER}
EOF
  expect n-dockerrun2; wait_up 8080 || { fail "N: nothing answered on 8080 after the reset"; return; }
  run n-check "$D" <<'EOF'
curl -s localhost:8080/statusz | grep -E '"store_entries"|"store_bytes"'
curl -s localhost:8080/testkey -o /dev/null -w 'GET testkey %{http_code}\n'
EOF
  expect n-check '"store_bytes": 0,' '"store_entries": 0,' "GET testkey 404"
  docker rm -f fscache >/dev/null 2>&1; docker volume rm fscache-data >/dev/null 2>&1
  # --- Docker Compose: the page's one line, with the quick-start Compose file of the Docker page
  mkdir -p "$D/compose"
  cat > "$D/compose/compose.yaml" <<'EOF'
services:
  fscache:
    image: ghcr.io/fosterstack/cache:latest   # pin a version tag
    restart: unless-stopped
    ports:
      - "8080:8080"                    # all interfaces, so auth is on
    volumes:
      - fscache-data:/home/nonroot
    environment:
      FSCACHE_MAX_BYTES: "53687091200"   # 50 GiB, size to your CI volume
      FSCACHE_USERNAME: gradle
      FSCACHE_PASSWORD: change-me        # generate one: openssl rand -base64 24
volumes:
  fscache-data:
EOF
  docker pull -q "$IMG:latest" >/dev/null 2>&1; got="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMG:latest" 2>/dev/null)"
  [ "${got#*@}" = "$IMG_022" ] || { fail "N Compose: $IMG:latest is '${got#*@}', not the verified ${IMG_022}: it is not run"; return; }
  COMPOSE_PROJECTS="$COMPOSE_PROJECTS compose"
  run n-compose-up "$D/compose" <<'EOF'
docker compose up -d
EOF
  expect n-compose-up; wait_up 8080 || { fail "N Compose: nothing answered on 8080"; return; }
  check_code "N Compose: store one entry" 201 -X PUT --data-binary 'x' -u gradle:change-me localhost:8080/testkey
  run n-compose-reset "$D/compose" <<'EOF'
docker compose down -v && docker compose up -d
EOF
  expect n-compose-reset; wait_up 8080 || { fail "N Compose: nothing answered on 8080 after the reset"; return; }
  S="$(statusz 8080 gradle change-me)"; [ "$(entries_of "$S")" = 0 ] && echo "OBS N Compose: after docker compose down -v && docker compose up -d the server holds 0 entries (${S})" || fail "N Compose: after the reset the server should hold 0 entries (${S})"
  check_code "N Compose: the stored key after the reset" 404 -u gradle:change-me localhost:8080/testkey
  docker compose down -v >/dev/null 2>&1
  # --- a plain binary: stop the process, delete the data directory, start it again
  start_server n-bin 8081 "" "" || return
  check_code "N binary: store one entry" 201 -X PUT --data-binary 'x' localhost:8081/testkey
  stop_server; rm -rf "${W:?}/srv-n-bin/data"
  ( cd "$W/srv-n-bin" && exec env FSCACHE_ADDR="127.0.0.1:8081" ./fscache ) > "$W/srv-n-bin/again.log" 2>&1 &
  SERVER_PID=$!; SERVER_PORT=8081; wait_up 8081 || { fail "N binary: the server did not start after its data directory was deleted"; stop_server; return; }
  S="$(statusz 8081 x y)"; [ "$(entries_of "$S")" = 0 ] && echo "OBS N binary: stop, delete the data directory, start: the server holds 0 entries (${S}), as the page says" || fail "N binary: after deleting the data directory the server should hold 0 entries (${S})"
  check_code "N binary: the stored key after the reset" 404 localhost:8081/testkey
  stop_server
}

# ---------- run ----------
for port in 8080 8081 18099 18141; do
  curl -skf --max-time 3 "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
scenario_l
scenario_m
scenario_n
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
