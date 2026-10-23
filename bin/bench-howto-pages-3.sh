#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 2: do the commands and promised outputs of these pages really happen?
#   I  /gradle-remote-cache-not-working/               steps 2 to 5 (the local-cache trap, 401, http://localhost, the counters), the three low-hit-rate
#                                                      causes with the page's Greet tasks, the Gradle-version and Maven-pinning table
#   G  /upgrade-build-cache-server/                    upgrade and rollback between releases on one Docker volume, back up and restore a volume,
#                                                      and the Maven move to a new server (change the address; or copy the data folder)
# Run by the "bench-howto-pages-3" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-3"). Same method as
# bin/bench-howto-pages.sh and bin/bench-howto-pages-2.sh: commands word for word, the server's own counters checked, every output line the
# page promises asserted, a step that fails or prints something else is RECORDED (FAIL) and fails the job at the end, and observations that
# are not failures are printed as OBS lines.
#
# No token and no secret: the release downloads without a login. Tools (Gradle 9.8.0, 9.7.1 and 9.5.1, Maven 3.10.0 and 3.9.9, JDK 27, cosign)
# are downloaded and checked against pinned checksums; Docker is the runner's own, and each cache image is pinned by its expected digest and
# verified with cosign before it is run. NOT pinned (said again in the output): the Maven build-cache extension, the Maven plugins and
# JUnit from Maven Central, and the helper image ubuntu:24.04 that the page's backup commands use (resolved once to a digest that is logged).
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
GR971_URL="https://services.gradle.org/distributions/gradle-9.7.1-bin.zip"; GR971_SHA=acd53f1edaf02f1a8ff99879f8a34b302661a057d9b063ae9e35b552f804d20a
GR951_URL="https://services.gradle.org/distributions/gradle-9.5.1-bin.zip"; GR951_SHA=bafc141b619ad6350fd975fc903156dd5c151998cc8b058e8c1044ab5f7b031f
MVN399_URL="https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz"
MVN399_SHA512=a555254d6b53d267965a3404ecb14e53c3827c09c3b94b5678835887ab404556bfaf78dcfe03ba76fa2508649dca8531c74bca4d5846513522404d48e8c4ac8b
IMG_010=sha256:2ec45a131312597be2ebc601407bbc57f81939fc2efd849f527a230fda70d8c0   # ghcr.io/fosterstack/cache:0.1.0
IMG_021=sha256:8df991b5febdf5b4a177325b8af95b6bb6c321059e1715c06cb659c659f5a4f0   # ghcr.io/fosterstack/cache:0.2.1
IMG_022=sha256:f2b330cf27b3814405230cc001a771909ae5bbf3b1e223a90ee7a9ee5d0e53dd   # ghcr.io/fosterstack/cache:0.2.2
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
  docker volume rm fscache-data fscache-data-restored g-up-0.1.0-0.2.1 g-up-0.2.1-0.2.2 >/dev/null 2>&1 || true
}
trap 'stop_server; cleanup_docker; [ -z "${BENCH_WORK:-}" ] && [ -n "${W:-}" ] && rm -rf "${W:?}"' EXIT


# ---------- tools (not timed) ----------
mkdir -p "$W/tools/bin"; cd "$W/tools"
if [ "$LOCAL" = 1 ]; then
  export GH_CONFIG_DIR="$W/gh-empty-config"; mkdir -p "$GH_CONFIG_DIR"; unset GH_TOKEN GITHUB_TOKEN
  command -v sha256sum >/dev/null 2>&1 || { printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > bin/sha256sum; chmod +x bin/sha256sum; export PATH="$W/tools/bin:$PATH"; }
  MVN310_HOME="${BENCH_MVN310_HOME:-$(mvn --version 2>/dev/null | sed -n "s/^Maven home: //p")}"
  JDK27_HOME="${BENCH_JDK27_HOME:?set BENCH_JDK27_HOME for a dry run}"
  JDK21_HOME="${BENCH_JAVA_HOME:-$(/usr/libexec/java_home -v 21 2>/dev/null || echo "${JAVA_HOME:-}")}"
else
  unset GH_TOKEN GITHUB_TOKEN; export GH_CONFIG_DIR="$W/gh-empty-config"; mkdir -p "$GH_CONFIG_DIR"
  curl -fsSL -o cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VER}/cosign-linux-amd64"; sha_check cosign "$COSIGN_SHA"; install -m 0755 cosign bin/cosign
  curl -fsSL -o gr.zip "$GR_URL"; sha_check gr.zip "$GR_SHA"; unzip -q gr.zip; ln -s "$W/tools/gradle-${GR_VER}/bin/gradle" bin/gradle
  curl -fsSL -o mvn310.tgz "$MVN310_URL"; sha512_check mvn310.tgz "$MVN310_SHA512"; tar -xzf mvn310.tgz; MVN310_HOME="$W/tools/apache-maven-3.10.0"
  curl -fsSL -o jdk27.tgz "$JDK27_URL"; sha_check jdk27.tgz "$JDK27_SHA"; mkdir jdk27 && tar -xzf jdk27.tgz -C jdk27 --strip-components=1; JDK27_HOME="$W/tools/jdk27"
  JDK21_HOME="${BENCH_JAVA_HOME:-${JAVA_HOME_21_X64:-${JAVA_HOME:-}}}"
  export PATH="$W/tools/bin:$PATH"
fi
# platform-independent tools (Java archives): downloaded and checked in dry runs too
cd "$W/tools"
curl -fsSL -o gr971.zip "$GR971_URL"; sha_check gr971.zip "$GR971_SHA"; unzip -q gr971.zip; GR971_HOME="$W/tools/gradle-9.7.1"
curl -fsSL -o gr951.zip "$GR951_URL"; sha_check gr951.zip "$GR951_SHA"; unzip -q gr951.zip; GR951_HOME="$W/tools/gradle-9.5.1"
curl -fsSL -o mvn399.tgz "$MVN399_URL"; sha512_check mvn399.tgz "$MVN399_SHA512"; tar -xzf mvn399.tgz; MVN399_HOME="$W/tools/apache-maven-3.9.9"
GR980_BIN="$(command -v gradle)"
for h in "$JDK21_HOME" "$JDK27_HOME"; do [ -x "$h/bin/java" ] || { echo "no usable Java at $h" >&2; exit 1; }; done
[ -x "$MVN310_HOME/bin/mvn" ] && [ -x "$MVN399_HOME/bin/mvn" ] || { echo "Maven homes not usable" >&2; exit 1; }
for g in "$GR971_HOME" "$GR951_HOME"; do [ -x "$g/bin/gradle" ] || { echo "Gradle home not usable: $g" >&2; exit 1; }; done
"$JDK21_HOME/bin/java" -version 2>&1 | head -1 | grep -q '"21\.' || { echo "JAVA_HOME for Java 21 is not Java 21: $("$JDK21_HOME/bin/java" -version 2>&1 | head -1)" >&2; exit 1; }
export JAVA_HOME="$JDK21_HOME"; export PATH="$JDK21_HOME/bin:$PATH"
for t in gh cosign gradle curl python3 tar docker openssl; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
command -v "$JDK27_HOME/bin/keytool" >/dev/null || { echo "missing keytool in JDK 27" >&2; exit 1; }
GRADLE_BIN="$(command -v gradle)"

# ---------- disclosure ----------
echo "== DISCLOSURE"
echo "runner: $(uname -sr); cpus: $(nproc 2>/dev/null || sysctl -n hw.ncpu); image: ${ImageOS:-?} ${ImageVersion:-?}"
echo "java 21: $("$JDK21_HOME/bin/java" -version 2>&1 | head -1)   java 27: $("$JDK27_HOME/bin/java" -version 2>&1 | head -1)"
echo "gradle: $(gradle --version 2>/dev/null | grep -E '^Gradle ' | head -1)   maven 3.10.0: $("$MVN310_HOME/bin/mvn" --version 2>/dev/null | head -1)   cosign: $(cosign version 2>/dev/null | grep -i GitVersion | head -1)   docker: $(docker --version)"
if [ "$LOCAL" = 1 ]; then echo "tools: LOCAL tools in use, nothing checked (a developer's dry run: do not quote these times)"; else
  echo "tools: Gradle ${GR_VER}, Maven 3.10.0, JDK 27 (Temurin 27+35) and cosign ${COSIGN_VER} are downloaded and checked against pinned checksums before use; Java 21, Docker and Compose are the runner's own"; fi
echo "gradle 9.7.1: $("$GR971_HOME/bin/gradle" --version 2>/dev/null | grep -E '^Gradle ' | head -1)   gradle 9.5.1: $("$GR951_HOME/bin/gradle" --version 2>/dev/null | grep -E '^Gradle ' | head -1)   maven 3.9.9: $("$MVN399_HOME/bin/mvn" --version 2>/dev/null | head -1)"
echo "NOT checksum-pinned: the Maven build-cache extension ${EXT_VER}, the Maven plugin jars (their versions are pinned in the poms, the files come from Maven Central), JUnit 5.11.4, the Gradle wrapper's distribution (checked against the pinned sha256 by the wrapper itself), and ubuntu:24.04 (the backup commands' helper image: resolved once, its digest is logged)"
echo "release under test: FosterStack Cache ${VER}, downloaded with no login and verified (cosign + sha256) before it runs (binary servers); the images 0.1.0, 0.2.1 and 0.2.2 are pulled by tag, must equal the digests pinned in this script, and are verified with cosign by digest before docker runs them"
echo "invented by this script (the pages show none): the Gradle and Maven projects and their small sources (the Greet tasks are the page's own), test passwords, the values stored in the upgrade and backup steps (chosen to give the byte counts the page shows: 29 and 49 bytes for the upgrade steps, 32 for the backup), the Maven projects' two tests"
echo "differences from the pages' own runs: the Gradle-version series use ONE module with :compileJava (the page: four modules, :core:compileJava) and Temurin 21.0.12.1 or the runner's Java 21; Maven runs on Java 21 (the page: OpenJDK 27); Linux (the pages: a Mac); the Greet-task runs use Java 27 to fill and Java 21 to test, as the page does"
echo "Gradle's own local cache is switched off in the runs that count hits (as the pages' own runs did) unless a step says otherwise; developer builds run with CI unset; page commands that use ~/.gradle run with an isolated HOME and GRADLE_USER_HOME=\$HOME/.gradle"
echo "scenario I tests the CORRECTED step 2 of the not-working page: as the page writes it (clear the local cache, --stop, build -i, run it twice, no clean) a second build with nothing changed prints UP-TO-DATE and tells you nothing; the script records that as an OBS FINDING and asserts the sequence with ./gradlew clean first (the page is fixed after this run). The 401 steps (page step 3) use a NEW Gradle home for each of the first two builds because, in a home that has built the project before, Gradle finds the compiled build script and the task output locally and never asks the server; they run 'gradle', not './gradlew'"
echo "scenario G: option 2 of the Maven move runs 'cp -R <old server data folder> data-new-copied' and starts the binary with FSCACHE_ADDR and FSCACHE_DATA_DIR (the page's data-old is the folder the old server wrote); the Maven plugin pin set '1' is not on any page (used only by earlier scenarios)"
echo "NOT reproduced: step 1 of the not-working page (the buildCache block does nothing without org.gradle.caching=true), step 6 (isPush false), the configuration-cache aside, 'a four-task project stored six entries', the 'Why it happens' key comparisons; on the upgrade page the sentence about '3 entries and 9 bytes' on 0.2.1 (a different volume), '0.2.1's metrics read 0 until the next upload', the archive size and 'one folder per entry prefix'"
echo "NOT tested here: the upgrade page's 0.1.0 /statusz and entry-count metric differences are checked, but other release pairs, copying a data folder while the server runs, Kubernetes or Compose rollouts, the FIPS image, a cache near its size cap; Gradle versions other than 9.8.0, 9.7.1 and 9.5.1; Java toolchains"
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
mvn_project() { # DIR PIN(0|1|s|r|p) SAVEFILE(0|1) URL CODE [ARTIFACT]   (pin: 0 none; 1 our eight; s only surefire; r surefire+resources+compiler+jar; p the eight of the not-working page)
  local d="$1" pin="$2" save="$3" url="$4" code="$5" art="${6:-mtest}"
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
  case "$pin" in
    s) mgmt='<pluginManagement><plugins>
      <plugin><artifactId>maven-surefire-plugin</artifactId><version>3.5.2</version></plugin>
    </plugins></pluginManagement>';;
    r) mgmt='<pluginManagement><plugins>
      <plugin><artifactId>maven-resources-plugin</artifactId><version>3.5.0</version></plugin>
      <plugin><artifactId>maven-compiler-plugin</artifactId><version>3.16.0</version></plugin>
      <plugin><artifactId>maven-jar-plugin</artifactId><version>3.5.1</version></plugin>
      <plugin><artifactId>maven-surefire-plugin</artifactId><version>3.5.2</version></plugin>
    </plugins></pluginManagement>';;
    p) mgmt='<pluginManagement><plugins>
      <plugin><artifactId>maven-resources-plugin</artifactId><version>3.5.0</version></plugin>
      <plugin><artifactId>maven-compiler-plugin</artifactId><version>3.16.0</version></plugin>
      <plugin><artifactId>maven-jar-plugin</artifactId><version>3.5.1</version></plugin>
      <plugin><artifactId>maven-clean-plugin</artifactId><version>3.5.0</version></plugin>
      <plugin><artifactId>maven-install-plugin</artifactId><version>3.2.0</version></plugin>
      <plugin><artifactId>maven-deploy-plugin</artifactId><version>3.2.0</version></plugin>
      <plugin><artifactId>maven-site-plugin</artifactId><version>3.22.0</version></plugin>
      <plugin><artifactId>maven-surefire-plugin</artifactId><version>3.5.2</version></plugin>
    </plugins></pluginManagement>';;
  esac
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
  <artifactId>${art}</artifactId>
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
# SCENARIO I: /gradle-remote-cache-not-working/
# =====================================================================================
with_wrapper() { # DIR PASSWORD   (the pages' commands use ./gradlew; the wrapper's distribution is checked against the pinned sha256)
  run "wrapper-$(basename "$1")" "$1" <<EOF
export FSCACHE_PASSWORD='$2'
gradle wrapper --gradle-version ${GR_VER} --distribution-type all --gradle-distribution-sha256-sum ${GR_SHA}
EOF
  expect "wrapper-$(basename "$1")" "BUILD SUCCESSFUL"
}
metric() { curl -s --max-time 30 "http://127.0.0.1:$2/metrics" | sed -n "s/^$1 \([0-9][0-9]*\)\$/\1/p"; }

scenario_i() {
  echo; echo "== I  (gradle-remote-cache-not-working)"
  local D="$W/i" P=8087 PW='i-test-secret-not-real' HH="$W/i-home" H0 H1 M0 M1 S k
  mkdir -p "$D" "$HH"
  local ENVP="export HOME=\"${HH}\"; export GRADLE_USER_HOME=\"${HH}/.gradle\""
  # ---- steps 2 and 3 to 5, against a server with a password
  start_server i "$P" gradle "$PW" || return
  ip_project() { # DIR URL WITHCREDS(1|0)   (the page's own settings: Gradle's local cache left ON)
    local d="$1" url="$2" cred="$3"; rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo"
    { printf 'rootProject.name = "demo"\nbuildCache {\n    remote<HttpBuildCache> {\n        url = uri("%s")\n        isPush = true\n' "$url"
      [ "$cred" = 1 ] && printf '        credentials {\n            username = "gradle"\n            password = System.getenv("FSCACHE_PASSWORD")\n        }\n'
      printf '    }\n}\n'; } > "$d/settings.gradle.kts"
    printf 'plugins { java }\n' > "$d/build.gradle.kts"; printf 'org.gradle.caching=true\n' > "$d/gradle.properties"; gradle_code "$d" 1
  }
  ip_project "$D/s2" "http://127.0.0.1:${P}/" 1; with_wrapper "$D/s2" "$PW"
  run i-first "$D/s2" <<EOF
${ENVP}; export FSCACHE_PASSWORD='${PW}'
./gradlew build --build-cache
EOF
  expect i-first "BUILD SUCCESSFUL" "> Task :compileJava"
  # step 2 as written: no clean first
  run i-s2-asis "$D/s2" <<EOF
${ENVP}; export FSCACHE_PASSWORD='${PW}'
rm -rf ~/.gradle/caches/build-cache-1
./gradlew --stop
./gradlew build --build-cache -i
EOF
  expect i-s2-asis "BUILD SUCCESSFUL"
  if grep -qF "> Task :compileJava UP-TO-DATE" "$W/i-s2-asis.out"; then echo "OBS FINDING? step 2 as the page writes it (no clean first): compileJava is UP-TO-DATE, so Gradle never asks the cache and the run tells you nothing"; else echo "OBS step 2 as written did not print UP-TO-DATE"; fi
  # step 2 with a clean first: the second run is the one that tells you something
  H0="$(metric fscache_cache_hits_total "$P")"
  for k in 1 2; do
    run "i-s2-fixed$k" "$D/s2" <<EOF
${ENVP}; export FSCACHE_PASSWORD='${PW}'
./gradlew clean
rm -rf ~/.gradle/caches/build-cache-1
./gradlew --stop
./gradlew build --build-cache -i
EOF
    expect "i-s2-fixed$k" "BUILD SUCCESSFUL" "Build cache key for task ':compileJava' is"
  done
  H1="$(metric fscache_cache_hits_total "$P")"
  grep -qF "> Task :compileJava FROM-CACHE" "$W/i-s2-fixed2.out" && echo "OBS I step 2 with a clean first: the second run printed FROM-CACHE; server hits ${H0} -> ${H1}" || fail "I step 2 with a clean first: the second run did not print FROM-CACHE"
  [ "$H1" -gt "$H0" ] 2>/dev/null || fail "I step 2 with a clean first: the server's hit counter did not move (${H0} -> ${H1})"
  # step 3: no credentials, a wrong password, then the right one in the same daemon. A NEW Gradle home for the first two builds: in a home that
  # has built the same project before, Gradle finds the compiled build script and the task output locally and never asks the server, so no
  # 401 can appear. The third build uses new code (a key the server has not seen) in the second build's home, so it has to talk to the
  # server: its store succeeding shows the daemon used the new password.
  local H3a="$W/i-home3a" H3b="$W/i-home3b" E0 E1; mkdir -p "$H3a" "$H3b"
  ip_project "$D/s3a" "http://127.0.0.1:${P}/" 0
  run i-s3-nocred "$D/s3a" <<EOF
export HOME="${H3a}"; export GRADLE_USER_HOME="${H3a}/.gradle"
gradle build --build-cache
EOF
  expect i-s3-nocred "BUILD SUCCESSFUL" "response status 401: Unauthorized"
  ip_project "$D/s3b" "http://127.0.0.1:${P}/" 1
  run i-s3-wrong "$D/s3b" <<EOF
export HOME="${H3b}"; export GRADLE_USER_HOME="${H3b}/.gradle"; export FSCACHE_PASSWORD='wrong-password'
gradle build --build-cache
EOF
  expect i-s3-wrong "BUILD SUCCESSFUL" "response status 401: Unauthorized"
  ip_project "$D/s3c" "http://127.0.0.1:${P}/" 1; gradle_code "$D/s3c" 7
  E0="$(statusz "$P" gradle "$PW")"
  HOME="$H3b" GRADLE_USER_HOME="$H3b/.gradle" "$GRADLE_BIN" --status 2>&1 | grep -qE "IDLE|BUSY" && echo "OBS I step 3: a Gradle daemon from the wrong-password build is still running (the next build reuses it)" || fail "I step 3: no Gradle daemon is running before the right-password build, so it cannot show that a running daemon picks up a new password"
  run i-s3-right-same-daemon "$D/s3c" <<EOF
export HOME="${H3b}"; export GRADLE_USER_HOME="${H3b}/.gradle"; export FSCACHE_PASSWORD='${PW}'
gradle build --build-cache
EOF
  expect i-s3-right-same-daemon "BUILD SUCCESSFUL"; absent i-s3-right-same-daemon "response status 401"
  E1="$(statusz "$P" gradle "$PW")"
  [ "$(entries_of "$E1")" -gt "$(entries_of "$E0")" ] 2>/dev/null && echo "OBS I step 3: a password exported after the daemon was running was used by the next build: no 401, and the server stored the new entry (${E0} -> ${E1})" || fail "I step 3: the build after the right password was exported stored nothing on the server (${E0} -> ${E1})"
  for k in "$H3a" "$H3b"; do HOME="$k" GRADLE_USER_HOME="$k/.gradle" "$GRADLE_BIN" --stop >/dev/null 2>&1 || true; done
  check_code "I step 3: curl with a wrong password" 401 -u gradle:wrong-password "http://127.0.0.1:${P}/some-key"
  check_code "I step 3: curl with the right password, key not there" 404 -u "gradle:${PW}" "http://127.0.0.1:${P}/some-key"
  # step 4: http://localhost is refused, 127.0.0.1 allowed (the runs above)
  ip_project "$D/s4" "http://localhost:${P}/" 1
  run i-s4-localhost "$D/s4" <<EOF
${ENVP}; export FSCACHE_PASSWORD='${PW}'
gradle build --build-cache -i
EOF
  NOZERO=1 expect i-s4-localhost; grep -qi "insecure" "$W/i-s4-localhost.out" && echo "OBS I step 4: http://localhost is refused as an insecure protocol (exit ${RC}), while http://127.0.0.1 worked above, as the page says" || fail "I step 4: the page says Gradle refuses http://localhost, but the output does not mention an insecure protocol (exit ${RC})"
  # step 5: the counters
  S="$(curl -s --max-time 30 "http://127.0.0.1:${P}/metrics" | grep -E 'fscache_cache_(hits|misses)_total' | grep -cv '^#')"
  [ "$S" = 2 ] && echo "OBS I step 5: the page's metrics command shows both counters (plus # comment lines)" || fail "I step 5: expected two counter lines, found ${S}"
  "$GRADLE_BIN" --stop >/dev/null 2>&1; HOME="$HH" GRADLE_USER_HOME="$HH/.gradle" "$GRADLE_BIN" --stop >/dev/null 2>&1 || true
  stop_server
  # ---- the three low-hit-rate causes, with the page's own Greet tasks (no login, Gradle's local cache off)
  start_server i2 "$P" "" "" || return
  greet_project() { # DIR   (the page's block, verbatim, in build.gradle.kts)
    local d="$1"; rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo"
    cat > "$d/settings.gradle.kts" <<EOF
rootProject.name = "demo"
buildCache {
    local { isEnabled = false } // so a hit can only come from the remote
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:${P}/")
        isPush = true
    }
}
EOF
    cat > "$d/build.gradle.kts" <<'EOF'
plugins { java }

@CacheableTask
abstract class Greet : DefaultTask() {
    @get:Input abstract val label: Property<String>
    @get:OutputFile abstract val out: RegularFileProperty
    @TaskAction fun run() { out.get().asFile.writeText("hello " + label.get()) }
}

tasks.register<Greet>("greetStable") {          // same input everywhere
    label.set("demo")
    out.set(layout.buildDirectory.file("greet-stable.txt"))
}
tasks.register<Greet>("greetAbsPath") {         // input holds an absolute path
    label.set(projectDir.absolutePath)
    out.set(layout.buildDirectory.file("greet-abs.txt"))
}
tasks.register<Greet>("greetTime") {            // input changes every build
    label.set(System.currentTimeMillis().toString())
    out.set(layout.buildDirectory.file("greet-time.txt"))
}
EOF
    printf 'org.gradle.caching=true\n' > "$d/gradle.properties"; gradle_code "$d" 1
  }
  local GH27="$W/ig27" GH21="$W/ig21"
  greet_project "$D/g1"
  run i-greet-fill "$D/g1" <<EOF
export JAVA_HOME="${JDK27_HOME}"; export GRADLE_USER_HOME="${GH27}"
gradle compileJava greetStable greetAbsPath greetTime --build-cache
EOF
  expect i-greet-fill "BUILD SUCCESSFUL"; absent i-greet-fill "FROM-CACHE"
  # a different directory, a clean checkout
  rm -rf "$D/g2"; mkdir -p "$D/g2"; ( cd "$D/g1" && tar cf - --exclude=build --exclude=.gradle . ) | ( cd "$D/g2" && tar xf - )
  run i-greet-copy "$D/g2" <<EOF
export JAVA_HOME="${JDK27_HOME}"; export GRADLE_USER_HOME="${GH27}"
gradle compileJava greetStable greetAbsPath greetTime --build-cache
EOF
  expect i-greet-copy "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE" "> Task :greetStable FROM-CACHE"
  grep -qE "^> Task :greetAbsPath$" "$W/i-greet-copy.out" || fail "I: in the copy, greetAbsPath should have run again (a path in its input), but it did not"
  grep -qE "^> Task :greetTime$" "$W/i-greet-copy.out" || fail "I: greetTime should have run (its input changes every build)"
  echo "OBS I: in a different directory, compileJava and greetStable came from the cache; greetAbsPath and greetTime ran, as the page says"
  run i-greet-key1 "$D/g1" <<EOF
export JAVA_HOME="${JDK27_HOME}"; export GRADLE_USER_HOME="${GH27}"
gradle greetAbsPath --info --build-cache
EOF
  run i-greet-key2 "$D/g2" <<EOF
export JAVA_HOME="${JDK27_HOME}"; export GRADLE_USER_HOME="${GH27}"
gradle greetAbsPath --info --build-cache
EOF
  local K1 K2; K1="$(grep -o "Build cache key for task ':greetAbsPath' is [0-9a-f]*" "$W/i-greet-key1.out" | head -1)"; K2="$(grep -o "Build cache key for task ':greetAbsPath' is [0-9a-f]*" "$W/i-greet-key2.out" | head -1)"
  { [ -n "$K1" ] && [ -n "$K2" ] && [ "$K1" != "$K2" ]; } && echo "OBS I: the greetAbsPath keys differ between the directories (${K1##* is } vs ${K2##* is }), as the page shows" || fail "I: the page shows two different greetAbsPath keys; got '${K1}' and '${K2}'"
  # back in the first directory, greetAbsPath hits again; greetTime never hits
  rm -rf "$D/g1/build" "$D/g1/.gradle"
  run i-greet-back "$D/g1" <<EOF
export JAVA_HOME="${JDK27_HOME}"; export GRADLE_USER_HOME="${GH27}"
gradle compileJava greetStable greetAbsPath greetTime --build-cache
EOF
  expect i-greet-back "> Task :greetAbsPath FROM-CACHE"; absent i-greet-back "greetTime FROM-CACHE"
  absent i-greet-copy "greetTime FROM-CACHE"; absent i-greet-fill "greetTime FROM-CACHE"
  echo "OBS I: back in the first directory greetAbsPath hit again; greetTime never hit in any build"
  # a different Java: filled with Gradle on JDK 27, now Gradle on JDK 21 in the same directory
  for k in 1 2; do
    rm -rf "$D/g1/build" "$D/g1/.gradle"
    run "i-greet-j21-$k" "$D/g1" <<EOF
export JAVA_HOME="${JDK21_HOME}"; export GRADLE_USER_HOME="${GH21}"
gradle compileJava greetStable --build-cache
EOF
    expect "i-greet-j21-$k" "BUILD SUCCESSFUL"
  done
  grep -qE "^> Task :compileJava$" "$W/i-greet-j21-1.out" && grep -qE "^> Task :greetStable$" "$W/i-greet-j21-1.out" || fail "I: with Gradle on JDK 21 the page says compileJava and greetStable ran again, but they did not both run"
  grep -qF "> Task :compileJava FROM-CACHE" "$W/i-greet-j21-2.out" && grep -qF "> Task :greetStable FROM-CACHE" "$W/i-greet-j21-2.out" || fail "I: a second run on JDK 21 should hit for both tasks"
  rm -rf "$D/g1/build" "$D/g1/.gradle"
  run i-greet-back27 "$D/g1" <<EOF
export JAVA_HOME="${JDK27_HOME}"; export GRADLE_USER_HOME="${GH27}"
gradle compileJava greetStable --build-cache
EOF
  expect i-greet-back27 "> Task :compileJava FROM-CACHE" "> Task :greetStable FROM-CACHE"
  echo "OBS I: filled on JDK 27, JDK 21 ran both tasks again, a second JDK 21 run hit, and going back to JDK 27 hit its own entries, as the page says"
  stop_server
  # ---- the 'Upgrade' table: Gradle versions (one module here), each series on a new empty server
  gseries() { # NAME FIRST-HOME SECOND-HOME   (home = a Gradle install dir)
    local name="$1" g1="$2" g2="$3" n
    start_server "iu-$name" "$P" "" "" || return
    gradle_project "$D/u-$name-1" "http://127.0.0.1:${P}/" 'true' '"x"' '"y"'
    gradle_project "$D/u-$name-2" "http://127.0.0.1:${P}/" 'true' '"x"' '"y"'
    gradle_project "$D/u-$name-3" "http://127.0.0.1:${P}/" 'true' '"x"' '"y"'
    run "iu-$name-a" "$D/u-$name-1" <<EOF
export JAVA_HOME="${JDK21_HOME}"; export GRADLE_USER_HOME="${W}/ghu-$(basename "$g1")"
"${g1}/bin/gradle" compileJava --build-cache
EOF
    expect "iu-$name-a" "BUILD SUCCESSFUL" "> Task :compileJava"; absent "iu-$name-a" "FROM-CACHE"
    run "iu-$name-b" "$D/u-$name-2" <<EOF
export JAVA_HOME="${JDK21_HOME}"; export GRADLE_USER_HOME="${W}/ghu-$(basename "$g2")"
"${g2}/bin/gradle" compileJava --build-cache
EOF
    expect "iu-$name-b" "BUILD SUCCESSFUL" "> Task :compileJava"
    absent "iu-$name-b" "Could not load entry" "Could not store entry" "remote build cache was disabled"
    S="$(statusz "$P" x y)"; [ "$(entries_of "$S")" -ge 2 ] 2>/dev/null || fail "I Gradle ${name}: the second version should have stored its own entry beside the first's (server: ${S})"
    if grep -qF "> Task :compileJava FROM-CACHE" "$W/iu-$name-b.out"; then fail "I Gradle ${name}: the second version restored the first version's entry, but the page says it rebuilt"; else echo "OBS I Gradle ${name}: the other version rebuilt and stored its own entry (server: ${S}), as the page says"; fi
    run "iu-$name-c" "$D/u-$name-3" <<EOF
export JAVA_HOME="${JDK21_HOME}"; export GRADLE_USER_HOME="${W}/ghu-$(basename "$g1")"
"${g1}/bin/gradle" compileJava --build-cache
EOF
    expect "iu-$name-c" "> Task :compileJava FROM-CACHE"
    HOME="$HH" "${g1}/bin/gradle" --stop >/dev/null 2>&1 || true; "${g2}/bin/gradle" --stop >/dev/null 2>&1 || true
    stop_server
  }
  GR980_HOME="$(python3 -c 'import os,sys;print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$GRADLE_BIN")"
  gseries 980-971 "$GR980_HOME" "$GR971_HOME"
  gseries 971-980 "$GR971_HOME" "$GR980_HOME"
  gseries 951-980 "$GR951_HOME" "$GR980_HOME"
  # ---- the 'Upgrade' table: Maven 3.10.0 and 3.9.9, three levels of pinning, both orders
  mvn_env
  mseries() { # NAME PIN FIRST-HOME SECOND-HOME EXPECT(rebuilt|restored)
    local name="$1" pin="$2" m1="$3" m2="$4" want="$5"
    start_server "im-$name" "$P" "" "" || return
    printf '<settings>\n</settings>\n' > "$mvnhome/.m2/settings.xml"
    local step
    for step in a b c; do mvn_project "$D/m-$name-$step" "$pin" 1 "http://127.0.0.1:${P}/" 1; done
    run "im-$name-a" "$D/m-$name-a" <<EOF
export PATH="${m1}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
mvn verify
EOF
    expect "im-$name-a" "BUILD SUCCESS" "Saved to remote cache"
    run "im-$name-b" "$D/m-$name-b" <<EOF
export PATH="${m2}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
mvn verify
EOF
    expect "im-$name-b" "BUILD SUCCESS"
    absent "im-$name-b" "Unable to save to remote cache"
    if grep -qF "Found cached build, restoring demo:mtest" "$W/im-$name-b.out"; then
      [ "$want" = restored ] && echo "OBS I Maven ${name}: the other Maven version restored the entry, as the page says" || fail "I Maven ${name}: the page says the other version rebuilt, but it restored"
    else
      [ "$want" = rebuilt ] && { grep -qF "Saved to remote cache" "$W/im-$name-b.out" && echo "OBS I Maven ${name}: the other Maven version rebuilt and saved its own result, as the page says" || fail "I Maven ${name}: the other version rebuilt but saved nothing to the server"; } || fail "I Maven ${name}: the page says the other version restored (all eight pinned), but it rebuilt"
    fi
    run "im-$name-c" "$D/m-$name-c" <<EOF
export PATH="${m1}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
mvn verify
EOF
    expect "im-$name-c" "BUILD SUCCESS" "Found cached build, restoring demo:mtest from cache by checksum"
    stop_server
  }
  local gd; for gd in "$W"/ghu-* "$GH27" "$GH21"; do [ -d "$gd" ] && GRADLE_USER_HOME="$gd" "$GRADLE_BIN" --stop >/dev/null 2>&1; done
  mseries s-310-399 s "$MVN310_HOME" "$MVN399_HOME" rebuilt
  mseries s-399-310 s "$MVN399_HOME" "$MVN310_HOME" rebuilt
  mseries r-310-399 r "$MVN310_HOME" "$MVN399_HOME" rebuilt
  mseries r-399-310 r "$MVN399_HOME" "$MVN310_HOME" rebuilt
  mseries p-310-399 p "$MVN310_HOME" "$MVN399_HOME" restored
  mseries p-399-310 p "$MVN399_HOME" "$MVN310_HOME" restored
  mvn_env_off
}

# =====================================================================================
# SCENARIO G: /upgrade-build-cache-server/
# =====================================================================================
scenario_g() {
  echo; echo "== G  (upgrade-build-cache-server)"
  local D="$W/g" IMG="ghcr.io/fosterstack/cache" v d got
  mkdir -p "$D"
  gpull() { local n; for n in 1 2 3; do docker pull -q "$1" >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
  # the three images: by tag, must equal the pinned digest, verified with cosign by digest
  for v in 0.1.0:$IMG_010 0.2.1:$IMG_021 0.2.2:$IMG_022; do
    gpull "$IMG:${v%%:*}" || { fail "G: could not pull $IMG:${v%%:*}"; return; }
    got="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMG:${v%%:*}")"
    [ "${got#*@}" = "${v#*:}" ] || { fail "G: $IMG:${v%%:*} is ${got#*@}, not the pinned ${v#*:}: no image is run"; return; }
    run "g-cosign-${v%%:*}" "$D" <<EOF
cosign verify ${IMG}@${v#*:} --certificate-identity-regexp='^https://github.com/fosterstack/cache/' --certificate-oidc-issuer='https://token.actions.githubusercontent.com'
EOF
    expect "g-cosign-${v%%:*}" "${v#*:}"; [ "$RC" = 0 ] || { fail "G: the signature of $IMG:${v%%:*} did not verify: no image is run"; return; }
  done
  CONTAINERS="$CONTAINERS fscache"
  gstart() { # VERSION VOLUME  (the page's docker run line)
    run "g-start-$1-$2" "$D" <<EOF
docker run -d --name fscache -p 127.0.0.1:8080:8080 \
  -v $2:/home/nonroot \
  ghcr.io/fosterstack/cache:$1
EOF
    expect "g-start-$1-$2"; wait_up 8080 || fail "G: $1 did not answer on 8080 with volume $2"
  }
  gstop() { docker stop fscache >/dev/null 2>&1 && docker rm fscache >/dev/null 2>&1; }
  gput() { check_code "G: PUT $1" 201 -X PUT --data-binary "$2" "localhost:8080/$1"; }
  gget() { local t; t="$(curl -s --max-time 10 "localhost:8080/$1")"; [ "$t" = "$2" ] || fail "G: GET $1 gave '$t', not '$2'"; }
  gstatus() { # LABEL WANT-ENTRIES WANT-BYTES [WANT-VERSION]
    local t; t="$(curl -s --max-time 10 localhost:8080/statusz)"
    local e b ver; e="$(printf '%s' "$t" | python3 -c 'import sys,json;print(json.load(sys.stdin)["store_entries"])' 2>/dev/null)"; b="$(printf '%s' "$t" | python3 -c 'import sys,json;print(json.load(sys.stdin)["store_bytes"])' 2>/dev/null)"; ver="$(printf '%s' "$t" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null)"
    if [ "$e" = "$2" ] && [ "$b" = "$3" ] && { [ -z "${4:-}" ] || [ "$ver" = "$4" ]; }; then echo "OBS $1: status page ${ver:+version \"$ver\", }${e} entries, ${b} bytes, as the page says"; else fail "$1: the page says ${2} entries, ${3} bytes${4:+, version $4}; the status page says entries=${e} bytes=${b} version=${ver}"; fi
  }
  gmetric() { curl -s --max-time 10 localhost:8080/metrics | sed -n "s/^$1 \([0-9][0-9]*\)\$/\1/p"; }
  # ---- the upgrade, in two pairs of releases (old, new)
  gpair() { # OLD NEW  (old may be 0.1.0: no status page)
    local old="$1" new="$2" vol="g-up-$1-$2"
    echo "OBS G pair ${old} -> ${new} -> ${old}"
    docker volume rm "$vol" >/dev/null 2>&1
    gstart "$old" "$vol" || return
    gput one value-one; gput two value-two; gput three value-three
    if [ "$old" = 0.1.0 ]; then
      check_code "G ${old}: /statusz" 404 localhost:8080/statusz
      [ "$(gmetric fscache_store_entries)" = 3 ] && [ "$(gmetric fscache_store_bytes)" = 29 ] && echo "OBS G ${old}: its metrics show 3 entries, 29 bytes, as the page says" || fail "G ${old}: metrics should show 3 entries, 29 bytes (entries=$(gmetric fscache_store_entries) bytes=$(gmetric fscache_store_bytes))"
    else gstatus "G ${old} after three stores" 3 29 "v${old}"; fi
    # the page's upgrade commands, word for word except the version tag
    # the page's block, in two parts so that the pulled image can be compared with the verified digest before it runs
    run "g-upgrade-pull-$new" "$D" <<EOF
docker pull ghcr.io/fosterstack/cache:${new}
EOF
    expect "g-upgrade-pull-$new"
    local want_digest; case "$new" in 0.2.1) want_digest="$IMG_021";; 0.2.2) want_digest="$IMG_022";; *) want_digest="";; esac
    got="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMG:${new}")"
    [ "${got#*@}" = "$want_digest" ] || { fail "G: after the page's own docker pull, $IMG:${new} is ${got#*@}, not the verified ${want_digest}: it is not run"; return; }
    run "g-upgrade-$new" "$D" <<EOF
docker stop fscache && docker rm fscache
docker run -d --name fscache -p 127.0.0.1:8080:8080 \
  -v ${vol}:/home/nonroot \
  ghcr.io/fosterstack/cache:${new}
EOF
    expect "g-upgrade-$new"; wait_up 8080 || { fail "G: ${new} did not start on the ${old} volume"; return; }
    gstatus "G ${new} on the ${old} volume" 3 29 "v${new}"
    gget one value-one; gget two value-two; gget three value-three
    [ "$(gmetric fscache_store_entries)" = 0 ] && echo "OBS G ${new} right after the start: fscache_store_entries reads 0 while /statusz shows 3, as the page says" || fail "G ${new}: the page says fscache_store_entries reads 0 right after the start while /statusz shows 3; it reads '$(gmetric fscache_store_entries)'"
    gput four value-four; gput five value-five
    gstatus "G ${new} after two more stores" 5 49 "v${new}"
    gstop; gstart "$old" "$vol" || return
    if [ "$old" = 0.1.0 ]; then
      [ "$(gmetric fscache_store_entries)" = 0 ] && echo "OBS G ${old} after the rollback: fscache_store_entries reads 0 although every value is readable, as the page says" || fail "G ${old} after the rollback: fscache_store_entries should read 0 (page), it reads $(gmetric fscache_store_entries)"
    else gstatus "G ${old} after the rollback" 5 49 "v${old}"; fi
    gget one value-one; gget two value-two; gget three value-three; gget four value-four; gget five value-five
    gstop; docker volume rm "$vol" >/dev/null 2>&1
  }
  gpair 0.1.0 0.2.1
  gpair 0.2.1 0.2.2
  # ---- back up and restore, on the 0.2.1 image as the page does
  gpull ubuntu:24.04 || { fail "G: could not pull ubuntu:24.04"; return; }
  echo "OBS G: the backup commands' helper image ubuntu:24.04 = $(docker inspect --format '{{index .RepoDigests 0}}' ubuntu:24.04)"
  cd "$D" || return
  docker volume rm fscache-data fscache-data-restored >/dev/null 2>&1
  gstart 0.2.1 fscache-data || return
  gput alpha value-alpha; gput beta value-beta; gput gamma value-gamma
  gstatus "G backup source" 3 32
  run g-backup "$D" <<'EOF'
docker stop fscache
docker run --rm -v fscache-data:/data:ro -v "$PWD":/backup ubuntu:24.04 \
  tar czf /backup/fscache-data.tgz -C /data .
EOF
  expect g-backup
  tar tzf "$D/fscache-data.tgz" | grep -q 'data/blobs/' && echo "OBS G: the archive holds a data/blobs/ folder, as the page says ($(wc -c < "$D/fscache-data.tgz" | tr -d ' ') bytes)" || fail "G: the archive does not hold a data/blobs/ folder"
  docker rm -f fscache >/dev/null 2>&1; docker volume rm fscache-data >/dev/null 2>&1
  run g-restore "$D" <<'EOF'
docker volume create fscache-data-restored
docker run --rm -v fscache-data-restored:/data -v "$PWD":/backup:ro ubuntu:24.04 \
  sh -c 'tar xzf /backup/fscache-data.tgz -C /data'
EOF
  expect g-restore
  run g-restore-ls "$D" <<'EOF'
docker run --rm -v fscache-data-restored:/data ubuntu:24.04 ls -ln /data
EOF
  expect g-restore-ls; grep -q ' 65532 *65532 ' "$W/g-restore-ls.out" && echo "OBS G: the restored data folder is owned by 65532, as the page says" || fail "G: the restored data folder is not owned by 65532: $(cat "$W/g-restore-ls.out" | tr '\n' '|')"
  run g-restore-start "$D" <<'EOF'
docker run -d --name fscache -p 127.0.0.1:8080:8080 \
  -v fscache-data-restored:/home/nonroot ghcr.io/fosterstack/cache:0.2.1
EOF
  expect g-restore-start; wait_up 8080 || { fail "G: the restored server did not answer"; return; }
  run g-restore-check "$D" <<'EOF'
curl -s localhost:8080/statusz | grep -E '"store_entries"|"store_bytes"'
curl -s localhost:8080/alpha
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/nothere
EOF
  expect g-restore-check '"store_bytes": 32,' '"store_entries": 3,' "value-alpha" "404"
  gstop; docker volume rm fscache-data-restored >/dev/null 2>&1
  # ---- the Maven move (Maven 3.10.0, extension 1.2.3): five builds
  mvn_env
  local OLDP=18150 NEWP=18151 CPP=18152
  printf '<settings>\n</settings>\n' > "$mvnhome/.m2/settings.xml"
  start_server g-old "$OLDP" "" "" || { mvn_env_off; return; }
  mvhbuild() { # NAME PORT  (a fresh copy of the project, an empty local build cache, Maven 3.10.0)
    mvn_project "$D/mv-$1" 1 1 "http://127.0.0.1:$2/" 1 demo
    run "g-mvn-$1" "$D/mv-$1" <<EOF
export PATH="${MVN310_HOME}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
mvn package
EOF
    expect "g-mvn-$1" "BUILD SUCCESS" "Attempting to restore project demo:demo from build cache"
  }
  mvhbuild 1 "$OLDP"; grep -qF "Saved to remote cache" "$W/g-mvn-1.out" || fail "G Maven build 1: nothing was saved to the old server"
  mvhbuild 2 "$OLDP"; grep -qF "Found cached build, restoring demo:demo from cache by checksum" "$W/g-mvn-2.out" || fail "G Maven build 2: it should restore from the old server"; absent g-mvn-2 "Compiling"
  stop_server
  # option 1: change the address only (a new, empty server)
  start_server g-new "$NEWP" "" "" || { mvn_env_off; return; }
  mvhbuild 3 "$NEWP"
  grep -qF "Compiling 1 source file with javac" "$W/g-mvn-3.out" && grep -qF "Saved to remote cache http://127.0.0.1:${NEWP}//v1.1/demo/demo/" "$W/g-mvn-3.out" && grep -qE "Saved to remote cache http://127.0.0.1:${NEWP}//v1.1/demo/demo/[0-9a-f]+/demo.jar" "$W/g-mvn-3.out" || fail "G Maven build 3: the page shows 'Compiling 1 source file with javac' and 'Saved to remote cache http://.../v1.1/demo/demo/<hash>/demo.jar'; the output differs"
  mvhbuild 4 "$NEWP"; grep -qF "Found cached build, restoring demo:demo from cache by checksum" "$W/g-mvn-4.out" || fail "G Maven build 4: it should restore from the new server"
  stop_server
  # option 2: stop the old server, copy its data folder, start the new server on the copy
  mkdir -p "$D/copy"
  run g-copy "$D/copy" <<EOF
cp -R ${W}/srv-g-old/data data-new-copied
EOF
  [ -d "$D/copy/data-new-copied" ] || { fail "G: could not copy the old server's data folder"; mvn_env_off; return; }
  ( cd "$D/copy" && exec env FSCACHE_ADDR="127.0.0.1:${CPP}" FSCACHE_DATA_DIR="$D/copy/data-new-copied" "$W/rel/fscache" ) > "$D/copy/server.log" 2>&1 &
  SERVER_PID=$!; SERVER_PORT="$CPP"; wait_up "$CPP" || { fail "G: the server on the copied data folder did not start"; stop_server; mvn_env_off; return; }
  mvhbuild 5 "$CPP"; grep -qF "Found cached build, restoring demo:demo from cache by checksum" "$W/g-mvn-5.out" || fail "G Maven build 5: it should restore from the copied data folder"; absent g-mvn-5 "Compiling"
  S="$(statusz "$CPP" x y)"; echo "OBS G: the copied server's status after build 5: ${S}"
  [ "$(hits_of "$S")" = 2 ] && case "$S" in *"misses=0"*) echo "OBS G: 2 hits and 0 misses, as the page says";; *) fail "G: the page says 2 hits and 0 misses; the server says ${S}";; esac || fail "G: the page says 2 hits and 0 misses; the server says ${S}"
  stop_server; mvn_env_off
}

# ---------- run ----------
for port in 8080 8087 18150 18151 18152; do
  curl -skf --max-time 3 "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
scenario_i
scenario_g
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
