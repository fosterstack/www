#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner: do the commands and promised outputs of three how-to pages really happen?
#   C  /laptop-builds-reuse-ci-build-cache/        the claims that can be tested on one Linux machine: a different Java version (Gradle) or
#                                                  Maven version (Maven, plugins unpinned) changes the cache key
#   D  /gradle-build-cache-ci-writes-developers-read/  two logins, the page's Gradle settings, the 403 line, the Maven table of eight cases
#   E  /build-cache-docker-compose-production/     docker run, the quick-start Compose file, the production Compose file behind nginx and TLS
# Run by the "bench-howto-pages" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages"). Same method as
# bin/bench-setup-pages.sh: commands word for word, the server's own counters checked, every output line the page promises asserted, a
# step that fails or prints something else is RECORDED (FAIL) and fails the job at the end, and observations that are not failures are
# printed as OBS lines. The Mac/Linux claim of the laptop page needs a Mac: it is tested by a separate job.
#
# No token and no secret: the release downloads without a login. Tools (Gradle, Maven 3.10.0 and 3.9.9, JDK 27, cosign) are downloaded and
# checked against pinned checksums; Docker and Compose are the runner's own. NOT pinned (said again in the output): the Maven build-cache
# extension and the Maven plugins from Maven Central, and the page's nginx tag, which is resolved ONCE at the start to a digest that is
# then used for the whole run (both are logged).
set -uo pipefail

VER="${BENCH_VER:-0.2.2}"   # the release the pages name; a scheduled proof run passes the newest release tag (checked by the workflow, and again here)
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad release version: $VER" >&2; exit 2; }
LOCAL="${BENCH_LOCAL:-0}"                    # 1 = a developer's dry run with local tools (nothing downloaded or checked: do not quote times)
if [ "$LOCAL" = 1 ]; then PLATFORM="${BENCH_PLATFORM:-darwin_arm64}"; else PLATFORM=linux_amd64; fi
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
MVN310_URL="https://archive.apache.org/dist/maven/maven-3/3.10.0/binaries/apache-maven-3.10.0-bin.tar.gz"
MVN310_SHA512=908b1501bfb420bf7c8affb855534a9c407fd6099367bfb9f2f2dcb8e9799102bffb84518cde74c679bd76870247c6528683abdd620581bffa90f95d92d175aa
MVN399_URL="https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz"
MVN399_SHA512=a555254d6b53d267965a3404ecb14e53c3827c09c3b94b5678835887ab404556bfaf78dcfe03ba76fa2508649dca8531c74bca4d5846513522404d48e8c4ac8b
JDK27_URL="https://github.com/adoptium/temurin27-binaries/releases/download/jdk-27%2B35/OpenJDK27U-jdk_x64_linux_hotspot_27_35.tar.gz"
JDK27_SHA=1cf69a4848ffb728b3b260dfd45206a51566ab571a02a30092271d4c580bccbc
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
  MVN310_HOME="${BENCH_MVN310_HOME:-$(mvn --version 2>/dev/null | sed -n "s/^Maven home: //p")}"; MVN399_HOME="${BENCH_MVN399_HOME:?set BENCH_MVN399_HOME for a dry run}"
  JDK27_HOME="${BENCH_JDK27_HOME:?set BENCH_JDK27_HOME for a dry run}"
  JDK21_HOME="${BENCH_JAVA_HOME:-$(/usr/libexec/java_home -v 21 2>/dev/null || echo "${JAVA_HOME:-}")}"
else
  curl -fsSL -o cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VER}/cosign-linux-amd64"; sha_check cosign "$COSIGN_SHA"; install -m 0755 cosign bin/cosign
  curl -fsSL -o gr.zip "$GR_URL"; sha_check gr.zip "$GR_SHA"; unzip -q gr.zip; ln -s "$W/tools/gradle-${GR_VER}/bin/gradle" bin/gradle
  curl -fsSL -o mvn310.tgz "$MVN310_URL"; sha512_check mvn310.tgz "$MVN310_SHA512"; tar -xzf mvn310.tgz; MVN310_HOME="$W/tools/apache-maven-3.10.0"
  curl -fsSL -o mvn399.tgz "$MVN399_URL"; sha512_check mvn399.tgz "$MVN399_SHA512"; tar -xzf mvn399.tgz; MVN399_HOME="$W/tools/apache-maven-3.9.9"
  curl -fsSL -o jdk27.tgz "$JDK27_URL"; sha_check jdk27.tgz "$JDK27_SHA"; mkdir jdk27 && tar -xzf jdk27.tgz -C jdk27 --strip-components=1; JDK27_HOME="$W/tools/jdk27"
  JDK21_HOME="${BENCH_JAVA_HOME:-${JAVA_HOME_21_X64:-${JAVA_HOME:-}}}"
  export PATH="$W/tools/bin:$PATH"
fi
for h in "$JDK21_HOME" "$JDK27_HOME"; do [ -x "$h/bin/java" ] || { echo "no usable Java at $h" >&2; exit 1; }; done
[ -x "$MVN399_HOME/bin/mvn" ] && [ -x "$MVN310_HOME/bin/mvn" ] || { echo "Maven homes not usable" >&2; exit 1; }
export JAVA_HOME="$JDK21_HOME"; export PATH="$JDK21_HOME/bin:$PATH"
for t in gh cosign gradle curl python3 tar docker openssl keytool; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
GRADLE_BIN="$(command -v gradle)"

# ---------- disclosure ----------
echo "== DISCLOSURE"
echo "runner: $(uname -sr); cpus: $(nproc 2>/dev/null || sysctl -n hw.ncpu); image: ${ImageOS:-?} ${ImageVersion:-?}"
echo "java 21: $("$JDK21_HOME/bin/java" -version 2>&1 | head -1)   java 27: $("$JDK27_HOME/bin/java" -version 2>&1 | head -1)"
echo "gradle: $(gradle --version 2>/dev/null | grep -E '^Gradle ' | head -1)   maven 3.9.9: $("$MVN399_HOME/bin/mvn" --version 2>/dev/null | head -1)   maven 3.10.0: $("$MVN310_HOME/bin/mvn" --version 2>/dev/null | head -1)"
echo "cosign: $(cosign version 2>/dev/null | grep -i GitVersion | head -1)   docker: $(docker --version)   compose: $(docker compose version | head -1)"
if [ "$LOCAL" = 1 ]; then echo "tools: LOCAL tools in use, nothing checked (a developer's dry run: do not quote these times)"; else
  echo "tools: Gradle ${GR_VER}, Maven 3.10.0 and 3.9.9, JDK 27 (Temurin 27+35) and cosign ${COSIGN_VER} are downloaded and checked against pinned checksums before use; Java 21, Docker and Compose are the runner's own"; fi
echo "NOT pinned: the Maven build-cache extension ${EXT_VER} and the Maven plugins and JUnit come from Maven Central at run time; the page's nginx tag is resolved once below to a digest and that digest is used for the whole run"
echo "release under test: FosterStack Cache ${VER}, downloaded from its GitHub release with no login (binary for scenarios C and D) and from ghcr.io (images for E, verified with cosign)"
echo "invented by this script (the pages show none): the Gradle project's rootProject.name, build.gradle.kts (plugins { java }) and a small App.java; the Maven pom (junit-jupiter 5.11.4, two tests, plugin versions pinned or not as each scenario says), App.java and tests; the self-signed certificate for localhost (the production page does not show how it is made); test passwords"
echo "values replaced in the pages' files: the example host https://cache.example.com/ by 127.0.0.1 or localhost URLs, <a long secret> by test passwords, /path/to/trust.jks by the real path; for scenario E the page's own port mappings and password change-me are used as written, so the quick-start stack listens on all interfaces of this runner for a few minutes behind that password"
echo "also invented or added by this script: the random upload files of 1.1, 2.1 and 20 MB; the page's nginx.conf is first run WITHOUT its client_max_body_size line (nginx's own default, to see the 413) and then replaced in place by the page's file and reloaded; the Gradle commands are 'gradle compileJava --build-cache' (the pages' tables are about compileJava); the cache servers of scenarios C and D are started with the page's login variables plus FSCACHE_ADDR=127.0.0.1:PORT, so the page's own server block is not run as written; scenario D first builds a warm-up project so that the Gradle home already holds the compiled build script (the page's tables count only the task's entry)"
echo "NOT tested here (the pages promise them): that a different Gradle version changes the key, that the server accepts an entry up to 1 GiB, that Gradle stops reading from the remote cache for the rest of a build after a refused store, and the Mac/Linux claim (a separate job)"
echo "Gradle's own local cache is switched off in the Gradle runs (local { isEnabled = false }), as the page's own run did, so that a hit can only come from the server; the runner sets CI=true, so developer builds run with CI unset"
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

# =====================================================================================
# SCENARIO C: /laptop-builds-reuse-ci-build-cache/  (what has to match)
# =====================================================================================
scenario_c() {
  echo; echo "== C  (laptop-builds-reuse-ci-build-cache: what has to match)"
  local D="$W/c" P=8082 S
  mkdir -p "$D"
  # --- Gradle: a different Java version changes the cache key (the page tested Java 21 against 27)
  start_server c-gradle "$P" "$RW_USER" "$RW_PASS" || return
  gradle_project "$D/g1" "http://127.0.0.1:${P}/" 'true' "\"$RW_USER\"" "\"$RW_PASS\""
  run c-gradle-j21-first "$D/g1" <<EOF
export JAVA_HOME="$JDK21_HOME"
gradle compileJava --build-cache
EOF
  expect c-gradle-j21-first "BUILD SUCCESSFUL" "> Task :compileJava"; absent c-gradle-j21-first "> Task :compileJava FROM-CACHE"
  S="$(statusz $P $RW_USER $RW_PASS)"; local E21; E21="$(entries_of "$S")"
  echo "OBS C Gradle, Java 21 builds and stores: server $S (a first build on a new Gradle home also stores the build script's compiled form, so this can be more than 1)"
  case "$E21" in 0|unreadable) fail "C Gradle: the Java 21 build stored nothing on the server ($S)";; esac
  gradle_project "$D/g2" "http://127.0.0.1:${P}/" 'true' "\"$RW_USER\"" "\"$RW_PASS\""
  run c-gradle-j21-again "$D/g2" <<EOF
export JAVA_HOME="$JDK21_HOME"
gradle compileJava --build-cache
EOF
  expect c-gradle-j21-again "> Task :compileJava FROM-CACHE"
  S="$(statusz $P $RW_USER $RW_PASS)"; echo "OBS C Gradle control (same Java 21, new project copy): server $S"
  [ "$(hits_of "$S")" = 1 ] || fail "C Gradle control: the second Java 21 build was not a server hit ($S)"
  gradle_project "$D/g3" "http://127.0.0.1:${P}/" 'true' "\"$RW_USER\"" "\"$RW_PASS\""
  run c-gradle-j27 "$D/g3" <<EOF
export JAVA_HOME="$JDK27_HOME"
gradle compileJava --build-cache
EOF
  expect c-gradle-j27 "BUILD SUCCESSFUL" "> Task :compileJava"
  if grep -qF "> Task :compileJava FROM-CACHE" "$W/c-gradle-j27.out"; then fail "C Gradle: with Java 27 the build restored the Java 21 result, but the page says a different Java version changes the cache key"; else echo "OBS C Gradle: with Java 27 the same code was not restored from the Java 21 entry, as the page says"; fi
  S="$(statusz $P $RW_USER $RW_PASS)"; echo "OBS C Gradle after the Java 27 build: server $S"
  [ "$(entries_of "$S")" -gt "$E21" ] 2>/dev/null || fail "C Gradle: the Java 27 build should have stored new entries beside the Java 21 ones ($E21); the server says $S"
  "$GRADLE_BIN" --stop >/dev/null 2>&1 || true
  stop_server
  # --- Maven: a different Maven version changes the key when plugin versions are left unpinned; pinned, it does not
  mvn_env
  local pinned
  for pinned in 0 1; do
    start_server c-maven-$pinned "$P" "$RW_USER" "$RW_PASS" || { mvn_env_off; return; }
    write_settings rw
    local tag="unpinned"; [ "$pinned" = 1 ] && tag="pinned"
    local V1 V2
    mvn_project "$D/m${pinned}a" "$pinned" 1 "http://127.0.0.1:${P}/" 1
    run c-maven-$tag-399-first "$D/m${pinned}a" <<EOF
export PATH="${MVN399_HOME}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
mvn verify
EOF
    expect c-maven-$tag-399-first "Saved to remote cache" "BUILD SUCCESS"
    check_entries "C Maven ${tag}, Maven 3.9.9 builds and stores" "$(statusz $P $RW_USER $RW_PASS)" 3
    mvn_project "$D/m${pinned}b" "$pinned" 1 "http://127.0.0.1:${P}/" 1
    run c-maven-$tag-399-again "$D/m${pinned}b" <<EOF
export PATH="${MVN399_HOME}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
mvn verify
EOF
    expect c-maven-$tag-399-again "Found cached build, restoring demo:mtest from cache by checksum" "BUILD SUCCESS"
    S="$(statusz $P $RW_USER $RW_PASS)"; echo "OBS C Maven ${tag} control (same Maven 3.9.9, new project copy): server $S"
    mvn_project "$D/m${pinned}c" "$pinned" 1 "http://127.0.0.1:${P}/" 1
    run c-maven-$tag-310 "$D/m${pinned}c" <<EOF
export PATH="${MVN310_HOME}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
mvn verify
EOF
    expect c-maven-$tag-310 "BUILD SUCCESS"
    S="$(statusz $P $RW_USER $RW_PASS)"; echo "OBS C Maven ${tag}, Maven 3.10.0 on the same code: server $S"
    if [ "$pinned" = 0 ]; then
      if grep -qF "Found cached build, restoring demo:mtest" "$W/c-maven-$tag-310.out"; then fail "C Maven: with unpinned plugins Maven 3.10.0 restored Maven 3.9.9's result, but the page says a different Maven version changes the key"; else echo "OBS C Maven unpinned: Maven 3.10.0 did not restore Maven 3.9.9's result, as the page says"; fi
    else
      if grep -qF "Found cached build, restoring demo:mtest" "$W/c-maven-$tag-310.out"; then echo "OBS C Maven pinned: Maven 3.10.0 restored Maven 3.9.9's result, as the page's advice to pin implies"; else fail "C Maven: with every plugin version pinned a different Maven version still did not restore the result, which the page's advice (pin them, or keep the Maven version) does not say"; fi
    fi
    stop_server
  done
  mvn_env_off
}

# =====================================================================================
# SCENARIO D: /gradle-build-cache-ci-writes-developers-read/
# =====================================================================================
scenario_d() {
  echo; echo "== D  (gradle-build-cache-ci-writes-developers-read)"
  local D="$W/d" P=8083 S
  mkdir -p "$D/warm/src/main/java/demo"
  printf 'rootProject.name = "demo"\n' > "$D/warm/settings.gradle.kts"; printf 'plugins { java }\n' > "$D/warm/build.gradle.kts"; gradle_code "$D/warm" 0
  run d-gradle-warmup "$D/warm" <<'WARMEOF'
gradle compileJava --no-build-cache
WARMEOF
  expect d-gradle-warmup "BUILD SUCCESSFUL"
  # --- the server with two logins, as the page starts it (read-only login optional)
  start_server d-gradle "$P" "$RW_USER" "$RW_PASS" FSCACHE_RO_USERNAME="$RO_USER" FSCACHE_RO_PASSWORD="$RO_PASS" || return
  echo "OBS the server was started with FSCACHE_USERNAME/PASSWORD and FSCACHE_RO_USERNAME/PASSWORD as the page's block shows (plus FSCACHE_ADDR=127.0.0.1:${P} so it listens on this machine only)"
  # --- curl facts from the end of the page
  local base="http://127.0.0.1:${P}"
  check_code "D curl: PUT with the read-write login" 201 -X PUT --data-binary 'x' -u "$RW_USER:$RW_PASS" "$base/curlkey1"
  check_code "D curl: PUT with the read-only login" 403 -X PUT --data-binary 'x' -u "$RO_USER:$RO_PASS" "$base/curlkey2"
  check_code "D curl: GET with the read-only login" 200 -u "$RO_USER:$RO_PASS" "$base/curlkey1"
  check_code "D curl: GET with no login" 401 "$base/curlkey1"
  check_code "D curl: PUT with no login" 401 -X PUT --data-binary 'x' "$base/curlkey3"
  stop_server
  # --- Gradle table
  start_server d-gradle2 "$P" "$RW_USER" "$RW_PASS" FSCACHE_RO_USERNAME="$RO_USER" FSCACHE_RO_PASSWORD="$RO_PASS" || return
  local U='System.getenv("FSCACHE_USERNAME")' PW='System.getenv("FSCACHE_PASSWORD")' URL="http://127.0.0.1:${P}/" PUSH='System.getenv("CI") != null'
  gradle_project "$D/g1" "$URL" "$PUSH" "$U" "$PW"
  run d-gradle-dev-first "$D/g1" <<EOF
unset CI
export FSCACHE_USERNAME=${RO_USER} FSCACHE_PASSWORD=${RO_PASS}
gradle compileJava --build-cache
EOF
  expect d-gradle-dev-first "BUILD SUCCESSFUL" "> Task :compileJava"; absent d-gradle-dev-first "FROM-CACHE" "Forbidden"
  check_entries "D Gradle row 1 (developer first, read-only login, CI unset)" "$(statusz $P $RW_USER $RW_PASS)" 0
  gradle_project "$D/g2" "$URL" "$PUSH" "$U" "$PW"
  run d-gradle-ci "$D/g2" <<EOF
export CI=true
export FSCACHE_USERNAME=${RW_USER} FSCACHE_PASSWORD=${RW_PASS}
gradle compileJava --build-cache
EOF
  expect d-gradle-ci "BUILD SUCCESSFUL" "> Task :compileJava"; absent d-gradle-ci "FROM-CACHE"
  check_entries "D Gradle row 2 (CI, read-write login, CI=true)" "$(statusz $P $RW_USER $RW_PASS)" 1
  gradle_project "$D/g3" "$URL" "$PUSH" "$U" "$PW"
  run d-gradle-dev-again "$D/g3" <<EOF
unset CI
export FSCACHE_USERNAME=${RO_USER} FSCACHE_PASSWORD=${RO_PASS}
gradle compileJava --build-cache
EOF
  expect d-gradle-dev-again "> Task :compileJava FROM-CACHE" "1 from cache"
  S="$(statusz $P $RW_USER $RW_PASS)"; echo "OBS D Gradle row 3 (developer again): server $S"
  [ "$(entries_of "$S")" = 1 ] && [ "$(hits_of "$S")" = 1 ] || fail "D Gradle row 3: the page says 1 entry, 1 hit; the server says $S"
  # --- a laptop set up to push anyway: CI=true but only the read-only login, new code
  gradle_project "$D/g4" "$URL" "$PUSH" "$U" "$PW"; gradle_code "$D/g4" 2
  run d-gradle-403 "$D/g4" <<EOF
export CI=true
export FSCACHE_USERNAME=${RO_USER} FSCACHE_PASSWORD=${RO_PASS}
gradle compileJava --build-cache -i
EOF
  expect d-gradle-403 "BUILD SUCCESSFUL" "Could not store entry" "response status 403: Forbidden" "The remote build cache was disabled during the build due to errors."
  check_entries "D Gradle 403 case (the laptop pushed with the read-only login)" "$(statusz $P $RW_USER $RW_PASS)" 1
  gradle_project "$D/g5" "$URL" "$PUSH" "$U" "$PW"; gradle_code "$D/g5" 2
  run d-gradle-ci-newcode "$D/g5" <<EOF
export CI=true
export FSCACHE_USERNAME=${RW_USER} FSCACHE_PASSWORD=${RW_PASS}
gradle compileJava --build-cache
EOF
  expect d-gradle-ci-newcode "BUILD SUCCESSFUL" "> Task :compileJava"
  check_entries "D Gradle, the same change built by CI with the read-write login" "$(statusz $P $RW_USER $RW_PASS)" 2
  "$GRADLE_BIN" --stop >/dev/null 2>&1 || true
  stop_server

  # --- Maven: the table of eight cases (Maven 3.9.9, extension 1.2.3, all plugin versions pinned, two tests)
  mvn_env
  local MURL="http://127.0.0.1:${P}/"
  mvn_case() { # LABEL SIDE(rw|ro|none) FLAG("" | on | false) CODE(1|2) SAVEFILE(0|1)
    local label="$1" side="$2" flag="$3" code="$4" savefile="$5" cmd="mvn verify"
    case "$flag" in on) cmd="mvn -Dmaven.build.cache.remote.save.enabled=true verify";; false) cmd="mvn -Dmaven.build.cache.remote.save.enabled=false verify";; esac
    mvn_project "$D/mcase-$label" 1 "$savefile" "$MURL" "$code"; write_settings "$side"
    run "d-maven-$label" "$D/mcase-$label" <<EOF
export PATH="${MVN399_HOME}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
$cmd
EOF
    MS="$(statusz $P $RW_USER $RW_PASS)"
  }
  # group 1: a fresh server; rows 1 to 3
  start_server d-maven1 "$P" "$RW_USER" "$RW_PASS" FSCACHE_RO_USERNAME="$RO_USER" FSCACHE_RO_PASSWORD="$RO_PASS" || { mvn_env_off; return; }
  mvn_case r1 rw "" 1 0
  expect d-maven-r1 "BUILD SUCCESS"; absent d-maven-r1 "Saved to remote cache"; check_entries "D Maven row 1 (CI, read-write, saving not turned on)" "$MS" 0
  echo "OBS D Maven row 1 on Maven 3.9.9 with a valid login: 'Error downloading cache item' lines in the output: $(count d-maven-r1 'Error downloading cache item')"
  mvn_case r2 rw on 1 0
  expect d-maven-r2 "BUILD SUCCESS"; check_entries "D Maven row 2 (CI, read-write, saving on)" "$MS" 3
  mvn_case r3 ro "" 1 0
  expect d-maven-r3 "Found cached build, restoring demo:mtest from cache by checksum" "BUILD SUCCESS"; check_entries "D Maven row 3 (developer, read-only, same code, restored)" "$MS" 3
  stop_server
  # group 2: a CI build of the original code first (3 entries), then rows 4 and 5
  start_server d-maven2 "$P" "$RW_USER" "$RW_PASS" FSCACHE_RO_USERNAME="$RO_USER" FSCACHE_RO_PASSWORD="$RO_PASS" || { mvn_env_off; return; }
  mvn_case g2setup rw on 1 0; expect d-maven-g2setup "BUILD SUCCESS"; check_entries "D Maven rows 4 to 5, setup (CI build of the original code)" "$MS" 3
  mvn_case r4 ro on 2 0
  expect d-maven-r4 "BUILD SUCCESS" "Unable to save to remote cache"
  [ "$(count d-maven-r4 'Unable to save to remote cache')" = 3 ] || fail "D Maven row 4: the page says 3 saves refused; the output has $(count d-maven-r4 'Unable to save to remote cache') 'Unable to save to remote cache' lines"
  grep -qE "status code: 403, reason phrase: Forbidden \(403\)" "$W/d-maven-r4.out" || fail "D Maven row 4: the page's 'status code: 403, reason phrase: Forbidden (403)' line is not in the output"
  grep -qE "Unable to save to remote cache .*mtest.*\.jar" "$W/d-maven-r4.out" || fail "D Maven row 4: no 'Unable to save to remote cache ...mtest...jar' line, as the page shows"
  check_entries "D Maven row 4 (developer, read-only, new code, saving on: refused)" "$MS" 3
  mvn_case r5 rw on 2 0; expect d-maven-r5 "BUILD SUCCESS"; check_entries "D Maven row 5 (CI, same new code, saving on)" "$MS" 6
  stop_server
  # group 3: row 6, a developer with no login
  start_server d-maven3 "$P" "$RW_USER" "$RW_PASS" FSCACHE_RO_USERNAME="$RO_USER" FSCACHE_RO_PASSWORD="$RO_PASS" || { mvn_env_off; return; }
  mvn_case g3setup rw on 1 0; expect d-maven-g3setup "BUILD SUCCESS"; check_entries "D Maven row 6, setup (CI build of the original code)" "$MS" 3
  mvn_case r6 none "" 1 0
  grep -qE "Error downloading cache item: .*buildinfo\.xml" "$W/d-maven-r6.out" || fail "D Maven row 6: no 'Error downloading cache item: ...buildinfo.xml' line, as the page shows"
  expect d-maven-r6 "BUILD SUCCESS" "Error downloading cache item" "Remote cache is incomplete or missing, trying local build for demo:mtest"
  check_entries "D Maven row 6 (developer, no login, same code: built, error logged)" "$MS" 3
  stop_server
  # group 4: rows 7 and 8, a config file that says saveToRemote="true"
  start_server d-maven4 "$P" "$RW_USER" "$RW_PASS" FSCACHE_RO_USERNAME="$RO_USER" FSCACHE_RO_PASSWORD="$RO_PASS" || { mvn_env_off; return; }
  mvn_case g4setup rw "" 1 1; expect d-maven-g4setup "BUILD SUCCESS"; check_entries "D Maven rows 7 to 8, setup (CI build with saveToRemote in the file)" "$MS" 3
  mvn_case r7 ro false 2 1
  expect d-maven-r7 "BUILD SUCCESS"; absent d-maven-r7 "Unable to save to remote cache"; check_entries "D Maven row 7 (saveToRemote true in the file, flag false: no save attempted)" "$MS" 3
  mvn_case r8 ro "" 2 1
  expect d-maven-r8 "BUILD SUCCESS" "Unable to save to remote cache"
  [ "$(count d-maven-r8 'Unable to save to remote cache')" = 3 ] || fail "D Maven row 8: the page says 3 saves refused; the output has $(count d-maven-r8 'Unable to save to remote cache') lines"
  grep -qE "status code: 403, reason phrase: Forbidden \(403\)" "$W/d-maven-r8.out" || fail "D Maven row 8: the page's 'status code: 403, reason phrase: Forbidden (403)' line is not in the output"
  check_entries "D Maven row 8 (saveToRemote true in the file, no flag: 3 refused)" "$MS" 3
  stop_server
  # the page's note about Maven 3.10.0: an ordinary first-time miss logs the same error line (valid login, empty server)
  start_server d-maven5 "$P" "$RW_USER" "$RW_PASS" FSCACHE_RO_USERNAME="$RO_USER" FSCACHE_RO_PASSWORD="$RO_PASS" || { mvn_env_off; return; }
  mvn_project "$D/m310" 1 0 "$MURL" 1; write_settings rw
  run d-maven-310-firstmiss "$D/m310" <<EOF
export PATH="${MVN310_HOME}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
mvn verify
EOF
  expect d-maven-310-firstmiss "BUILD SUCCESS" "Error downloading cache item"
  echo "OBS D Maven 3.10.0, valid login, empty server: 'Error downloading cache item' appears (as the page says). On Maven 3.9.9 row 1 the same case printed it $(count d-maven-r1 'Error downloading cache item') times"
  stop_server
  mvn_env_off
}

# =====================================================================================
# SCENARIO E: /build-cache-docker-compose-production/
# =====================================================================================
scenario_e() {
  echo; echo "== E  (build-cache-docker-compose-production)"
  local D="$W/e" CACHE_IMG="ghcr.io/fosterstack/cache" S rc
  mkdir -p "$D"
  # images: resolved ONCE; the page's mutable tags are pulled here, logged by digest, and verified with cosign
  pull() { local n; for n in 1 2 3; do docker pull -q "$1" >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
  pull "$CACHE_IMG:${VER}" && pull "$CACHE_IMG:latest" && pull nginx:1.29-alpine || { fail "E: could not pull the images"; return; }
  local D022 DLAT DNGX
  D022="$(docker inspect --format '{{index .RepoDigests 0}}' "$CACHE_IMG:${VER}")"; DLAT="$(docker inspect --format '{{index .RepoDigests 0}}' "$CACHE_IMG:latest")"; DNGX="$(docker inspect --format '{{index .RepoDigests 0}}' nginx:1.29-alpine)"
  echo "OBS images: ${CACHE_IMG}:${VER} = ${D022}"; echo "OBS images: ${CACHE_IMG}:latest = ${DLAT}"; echo "OBS images: nginx:1.29-alpine (the page's tag, resolved once) = ${DNGX}"
  if [ "$D022" = "$DLAT" ]; then echo "OBS the page's :latest is ${VER}"; else fail "E: ${CACHE_IMG}:latest is not the ${VER} image this script verifies, so no image is run (update VER for the new release)"; return; fi
  run e-cosign-verify "$D" <<EOF
cosign verify ${D022} \\
 --certificate-identity-regexp="^https://github.com/fosterstack/cache/.github/workflows/stage-promote.yml@refs/tags/v${VER}\$" \\
 --certificate-oidc-issuer='https://token.actions.githubusercontent.com'
EOF
  expect e-cosign-verify "${D022#*@}"
  [ "$RC" = 0 ] || { fail "E: the image signature did not verify, so no image is run"; return; }
  # --- "Try it first, on one machine": the page's docker run, word for word
  run e-dockerrun "$D" <<'EOF'
docker run -d -p 127.0.0.1:8080:8080 -v fscache-data:/home/nonroot ghcr.io/fosterstack/cache:latest
EOF
  expect e-dockerrun; local CID; CID="$(tail -1 "$W/e-dockerrun.out")"; CONTAINERS="$CONTAINERS $CID"
  wait_up 8080 || { fail "E docker run: nothing answered on 127.0.0.1:8080"; docker logs "$CID" 2>&1 | tail -5; docker rm -f "$CID" >/dev/null 2>&1; return; }
  run e-check-noauth "$D" <<'EOF'
curl -s localhost:8080/healthz                                   # ok
curl -s -X PUT --data-binary 'hello' localhost:8080/testkey123   # 201
curl -s localhost:8080/testkey123                                # hello
EOF
  expect e-check-noauth "ok" "hello"
  echo "OBS the page's three lines printed (| = end of line): $(tr '\n' '|' < "$W/e-check-noauth.out")"
  if grep -qx "okhello" "$W/e-check-noauth.out"; then echo "OBS FINDING? the page shows '# ok', '# 201', '# hello' as three results, but curl -s printed ok and hello run together on one line (healthz ends without a newline) and nothing for the PUT: the status 201 is never shown"; fi
  check_code "E docker run: PUT with no password" 201 -X PUT --data-binary 'hello' localhost:8080/testkey456
  echo "OBS E docker run: server $(statusz 8080 x y)"
  docker inspect --format '{{range .Mounts}}{{.Destination}} {{end}}' "$CID" | grep -qF "/home/nonroot" || fail "E: the volume is not mounted at /home/nonroot"
  docker exec "$CID" sh -c true >/dev/null 2>&1 && fail "E: the page says the image has no shell, but 'sh' ran in it" || echo "OBS E: no shell in the image (docker exec sh fails), as the page says"
  docker rm -f "$CID" >/dev/null 2>&1; docker volume rm fscache-data >/dev/null 2>&1
  # the same bare mapping the page warns about is checked on the Compose stack below
  # --- "Quick start: the Compose file", word for word (its :latest is the local image, checked above to be the cosign-verified 0.2.2 image)
  cat > "$D/compose-quick.yaml" <<'EOF'
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
  COMPOSE_PROJECTS="$COMPOSE_PROJECTS quick"
  run e-quick-up "$D" <<'EOF'
docker compose -p quick -f compose-quick.yaml up -d
EOF
  expect e-quick-up
  wait_up 8080 || { fail "E quick start: nothing answered on 8080"; docker compose -p quick logs 2>&1 | tail -5; docker compose -p quick down -v >/dev/null 2>&1; return; }
  run e-quick-check "$D" <<'EOF'
curl -s localhost:8080/healthz                                   # ok
curl -s -X PUT --data-binary 'hello' localhost:8080/testkey123   # 201
curl -s localhost:8080/testkey123                                # hello
EOF
  [ "$RC" = 0 ] || fail "E quick start: the page's three curl lines exited $RC"
  echo "OBS E quick start, the page's three lines with the password set: $(tr '\n' '|' < "$W/e-quick-check.out")"
  head -c 2 "$W/e-quick-check.out" | grep -qx "ok" || fail "E quick start: /healthz did not print ok with the password set"
  grep -q "hello" "$W/e-quick-check.out" && fail "E quick start: with a password set, the page's unauthenticated PUT/GET lines should not store or return hello, but hello came back"
  check_code "E quick start: PUT with no password" 401 -X PUT --data-binary 'hello' localhost:8080/testkey123
  check_code "E quick start: PUT with -u gradle:change-me" 201 -X PUT --data-binary 'hello' -u "gradle:${COMPOSE_PASS}" localhost:8080/testkey123
  S="$(curl -s -u "gradle:${COMPOSE_PASS}" localhost:8080/testkey123)"; [ "$S" = hello ] || fail "E quick start: reading the key back with the password gave '$S', not hello"
  run e-quick-healthcurl "$D" <<'EOF'
curl -f http://localhost:8080/healthz
EOF
  expect e-quick-healthcurl "ok"
  echo "OBS E quick start: ports as published: $(docker compose -p quick ps --format '{{.Ports}}' | tr '\n' ' ')"
  docker compose -p quick down -v >/dev/null 2>&1
  # --- Production: compose.yaml and nginx.conf, word for word except image digests and the made-up certificate
  mkdir -p "$D/prod/certs"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" -keyout "$D/prod/certs/key.pem" -out "$D/prod/certs/cert.pem" >/dev/null 2>&1 || { fail "E: could not make the test certificate"; return; }
  cat > "$D/prod/compose.yaml" <<EOF
services:
  fscache:
    image: ghcr.io/fosterstack/cache:0.2.2@${D022#*@}
    restart: unless-stopped
    # no "ports:" on purpose: only the proxy is reachable from outside
    volumes:
      - fscache-data:/home/nonroot
    environment:
      FSCACHE_MAX_BYTES: "53687091200"      # 50 GiB
      FSCACHE_USERNAME: gradle
      FSCACHE_PASSWORD: change-me           # generate one: openssl rand -base64 24
  proxy:
    image: nginx:1.29-alpine@${DNGX#*@}
    restart: unless-stopped
    depends_on:
      - fscache
    ports:
      - "127.0.0.1:8443:443"                # use 443:443 on a real server
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certs:/etc/nginx/certs:ro
volumes:
  fscache-data:
EOF
  cat > "$D/prod/nginx.conf.default" <<'EOF'
server {
    listen 443 ssl;
    server_name localhost;
    ssl_certificate     /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;
    location / {
        proxy_pass http://fscache:8080;
        proxy_set_header Host $host;
    }
}
EOF
  cat > "$D/prod/nginx.conf.page" <<'EOF'
server {
    listen 443 ssl;
    server_name localhost;
    ssl_certificate     /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;
    # the cache accepts entries up to 1 GiB by default; nginx's own default is 1 MB
    client_max_body_size 1g;
    location / {
        proxy_pass http://fscache:8080;
        proxy_set_header Host $host;
    }
}
EOF
  cat "$D/prod/nginx.conf.default" > "$D/prod/nginx.conf"      # first: nginx's own default (no client_max_body_size line)
  COMPOSE_PROJECTS="$COMPOSE_PROJECTS prod"
  run e-prod-up "$D/prod" <<'EOF'
docker compose -p prod up -d
EOF
  expect e-prod-up
  local CA="--cacert $D/prod/certs/cert.pem" B=https://localhost:8443
  local i; for i in $(seq 1 100); do curl -sf $CA $B/healthz >/dev/null 2>&1 && break; sleep 0.1; done
  S="$(curl -s $CA $B/healthz)"; [ "$S" = ok ] && echo "OBS E prod: https://localhost:8443/healthz with the certificate trusted: ok" || fail "E prod: healthz with the certificate trusted printed '$S', not ok"
  curl -s $B/healthz >/dev/null 2>&1; rc=$?; [ "$rc" = 60 ] && echo "OBS E prod: the same without trusting the certificate: curl exit 60, as the page says" || fail "E prod: without trusting the certificate curl exited $rc; the page says 60"
  curl -s localhost:8080/healthz >/dev/null 2>&1 && fail "E prod: the cache's own port 8080 answers from the host, but the page says it is not reachable" || echo "OBS E prod: the cache's own port 8080 is not reachable from the host, as the page says"
  check_code "E prod: plain http:// to the proxy's TLS port" 400 http://localhost:8443/healthz
  check_code "E prod: upload with no password, through the proxy" 401 $CA -X PUT --data-binary 'hello' $B/testkey123
  check_code "E prod: upload with the password, through the proxy" 201 $CA -u "gradle:${COMPOSE_PASS}" -X PUT --data-binary 'hello' $B/testkey123
  S="$(curl -s $CA -u "gradle:${COMPOSE_PASS}" $B/testkey123)"; [ "$S" = hello ] && echo "OBS E prod: the value reads back" || fail "E prod: the value read back as '$S', not hello"
  head -c 1100000 /dev/urandom > "$D/f1mb"; head -c 2100000 /dev/urandom > "$D/f2mb"; head -c 20000000 /dev/urandom > "$D/f20mb"
  check_code "E prod: upload of about 1 MB with nginx's default settings" 413 $CA -u "gradle:${COMPOSE_PASS}" -X PUT --data-binary @"$D/f1mb" $B/big1
  check_code "E prod: upload of about 2 MB with nginx's default settings" 413 $CA -u "gradle:${COMPOSE_PASS}" -X PUT --data-binary @"$D/f2mb" $B/big2
  S="$(curl -s --max-time 120 $CA -u "gradle:${COMPOSE_PASS}" -X PUT --data-binary @"$D/f1mb" $B/big1)"
  if printf '%s' "$S" | grep -qiF "nginx"; then echo "OBS E prod: the 413 body comes from nginx, not from the cache"; else fail "E prod: the page says the 413 comes from nginx, but its body does not say nginx"; fi
  cat "$D/prod/nginx.conf.page" > "$D/prod/nginx.conf"       # in place, so the bind mount sees it
  docker compose -p prod exec -T proxy nginx -s reload >/dev/null 2>&1 || fail "E prod: nginx did not reload with the page's file"
  sleep 1
  check_code "E prod: the same 1 MB upload after client_max_body_size 1g" 201 $CA -u "gradle:${COMPOSE_PASS}" -X PUT --data-binary @"$D/f1mb" $B/big1
  check_code "E prod: the same 2 MB upload after client_max_body_size 1g" 201 $CA -u "gradle:${COMPOSE_PASS}" -X PUT --data-binary @"$D/f2mb" $B/big2
  check_code "E prod: a 20 MB upload after client_max_body_size 1g" 201 $CA -u "gradle:${COMPOSE_PASS}" -X PUT --data-binary @"$D/f20mb" $B/big20
  # --- Gradle over HTTPS (Java 21): untrusted certificate, then the page's keytool and gradle.properties lines
  local GU='"gradle"' GP="\"${COMPOSE_PASS}\""
  gradle_project "$D/hg1" "https://localhost:8443/" 'true' "$GU" "$GP"
  run e-gradle-untrusted "$D/hg1" <<'EOF'
gradle compileJava --build-cache
EOF
  expect e-gradle-untrusted "BUILD SUCCESSFUL" "Could not load entry" "from remote build cache" "(certificate_unknown)" "PKIX path building failed" "unable to find valid certification path to requested target"
  "$GRADLE_BIN" --stop >/dev/null 2>&1 || true
  run e-keytool "$D/prod" <<'EOF'
keytool -importcert -alias fsprod -file certs/cert.pem -keystore trust.jks -storepass changeit -noprompt
EOF
  expect e-keytool
  local k
  local HB HA
  for k in 2 3; do
    [ "$k" = 3 ] && HB="$(SCHEME=https statusz 8443 gradle "$COMPOSE_PASS" --cacert "$D/prod/certs/cert.pem")"
    gradle_project "$D/hg$k" "https://localhost:8443/" 'true' "$GU" "$GP"
    printf 'org.gradle.caching=true\nsystemProp.javax.net.ssl.trustStore=%s\nsystemProp.javax.net.ssl.trustStorePassword=changeit\n' "$D/prod/trust.jks" > "$D/hg$k/gradle.properties"
    run e-gradle-trusted-$k "$D/hg$k" <<'EOF'
gradle compileJava --build-cache
EOF
    "$GRADLE_BIN" --stop >/dev/null 2>&1 || true
  done
  expect e-gradle-trusted-2 "BUILD SUCCESSFUL" "> Task :compileJava"; absent e-gradle-trusted-2 "FROM-CACHE" "PKIX"
  expect e-gradle-trusted-3 "> Task :compileJava FROM-CACHE"
  HA="$(SCHEME=https statusz 8443 gradle "$COMPOSE_PASS" --cacert "$D/prod/certs/cert.pem")"; echo "OBS E prod: through the proxy over HTTPS, server before the second build ${HB} / after ${HA}"
  { [ "$(hits_of "$HA")" != unreadable ] && [ "$(hits_of "$HA")" -gt "$(hits_of "$HB")" ]; } 2>/dev/null || fail "E prod: the second build's FROM-CACHE was not a server hit through the proxy ($HB -> $HA)"
  docker compose -p prod down -v >/dev/null 2>&1
}

# ---------- run ----------
for port in 8080 8082 8083 8443; do
  curl -skf "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
scenario_c
scenario_d
scenario_e
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
