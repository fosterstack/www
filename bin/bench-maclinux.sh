#!/usr/bin/env bash
# Does a build result stored from Linux restore on a Mac, and the other way round? The claim of /laptop-builds-reuse-ci-build-cache/.
#   bash bin/bench-maclinux.sh store     build a small Gradle project and a small Maven project against a fresh cache server, stop the
#                                        server, and pack the server's data folder (nothing else) into $RUNNER_TEMP/maclinux/cache-data.tgz
#   bash bin/bench-maclinux.sh restore   unpack that data folder (downloaded from the other operating system's job) into a fresh cache
#                                        server on THIS machine, build the same two projects with an empty Gradle home and an empty
#                                        ~/.m2, and check that both builds restore from the server (the server's hit counter moves)
# Run by four jobs of .github/workflows/hygiene.yml (manual dispatch only, choice "mac-linux"): Linux store -> Mac restore, and
# Mac store -> Linux restore. The cache server's own operating system does not matter to the claim: it only holds files. What is tested
# is the CLIENT side: Gradle and Maven on one operating system produce a cache key that the same tools on the other one find.
#
# Same Java build on both sides (Temurin 21.0.12.1, as the page says), Gradle 9.8.0, Maven 3.9.9 with every plugin version pinned and
# the build-cache extension 1.2.3; all downloads are checked against pinned checksums except the extension, the Maven plugins and the
# test library, which come from Maven Central at run time (said again in the output). No token and no secret: the release downloads
# without a login and the passwords are made up. A step that fails or prints something else is RECORDED and fails the job at the end.
set -uo pipefail

ROLE="${1:-}"; case "$ROLE" in store|restore) ;; *) echo "usage: $0 store|restore" >&2; exit 2;; esac
VER=0.2.2
GR_VER=9.8.0; GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
MVN_URL="https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz"
MVN_SHA512=a555254d6b53d267965a3404ecb14e53c3827c09c3b94b5678835887ab404556bfaf78dcfe03ba76fa2508649dca8531c74bca4d5846513522404d48e8c4ac8b
COSIGN_VER=3.1.3
EXT_VER=1.2.3
USER_NAME=bench; PASS='maclinux-test-secret-not-real'
PORT=8085

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    PLATFORM=linux_amd64; OSNAME=linux
    COSIGN_URL="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VER}/cosign-linux-amd64"; COSIGN_SHA=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
    JDK_URL="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz"; JDK_SHA=ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94; JDK_HOME_SUB=".";;
  Darwin-arm64)
    PLATFORM=darwin_arm64; OSNAME=mac
    COSIGN_URL="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VER}/cosign-darwin-arm64"; COSIGN_SHA=5cf948c2f4dfe59687bdd0b8523709067383e03982cc543475c8a7dc70e92a76
    JDK_URL="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz"; JDK_SHA=3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998; JDK_HOME_SUB="Contents/Home";;
  *) echo "unsupported machine $(uname -sm)" >&2; exit 2;;
esac

FAILS=0
now() { python3 -c 'import time;print(time.time())'; }
fail() { FAILS=$((FAILS+1)); printf 'FAIL %s\n' "$*"; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
sha512_of() { if command -v sha512sum >/dev/null 2>&1; then sha512sum "$1" | cut -d' ' -f1; else shasum -a 512 "$1" | cut -d' ' -f1; fi; }
check256() { [ "$(sha256_of "$1")" = "$2" ] || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }; }
check512() { [ "$(sha512_of "$1")" = "$2" ] || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }; }

W="$(mktemp -d)"; OUT="${RUNNER_TEMP:-/tmp}/maclinux"; IN="${RUNNER_TEMP:-/tmp}/maclinux-in"
SERVER_PID=""
stop_server() {
  local i
  if [ -n "$SERVER_PID" ]; then
    pkill -P "$SERVER_PID" 2>/dev/null; kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
    for i in $(seq 1 100); do curl -sf --max-time 5 "localhost:${PORT}/healthz" >/dev/null 2>&1 || break; sleep 0.1; done
    curl -sf --max-time 5 "localhost:${PORT}/healthz" >/dev/null 2>&1 && fail "the server on port ${PORT} did not stop"
  fi
}
trap 'stop_server; [ -n "${W:-}" ] && rm -rf "${W:?}"' EXIT

# ---------- tools (downloaded and checked) ----------
mkdir -p "$W/tools/bin" "$OUT"; cd "$W/tools"
curl -fsSL -o cosign "$COSIGN_URL"; check256 cosign "$COSIGN_SHA"; install -m 0755 cosign bin/cosign
curl -fsSL -o gr.zip "$GR_URL"; check256 gr.zip "$GR_SHA"; unzip -q gr.zip; ln -s "$W/tools/gradle-${GR_VER}/bin/gradle" bin/gradle
curl -fsSL -o mvn.tgz "$MVN_URL"; check512 mvn.tgz "$MVN_SHA512"; tar -xzf mvn.tgz; MVN_HOME="$W/tools/apache-maven-3.9.9"
curl -fsSL -o jdk.tgz "$JDK_URL"; check256 jdk.tgz "$JDK_SHA"; mkdir jdk && tar -xzf jdk.tgz -C jdk --strip-components=1
export JAVA_HOME="$W/tools/jdk/${JDK_HOME_SUB}"
[ -x "$JAVA_HOME/bin/java" ] || { echo "no usable Java at $JAVA_HOME" >&2; exit 1; }
export PATH="$W/tools/bin:$JAVA_HOME/bin:$PATH"
command -v sha256sum >/dev/null 2>&1 || { printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > bin/sha256sum; chmod +x bin/sha256sum; }
unset GH_TOKEN GITHUB_TOKEN; export GH_CONFIG_DIR="$W/gh-empty-config"; mkdir -p "$GH_CONFIG_DIR"   # gh runs with no login, here and on the runners
for t in gh cosign gradle curl python3 tar; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

echo "== DISCLOSURE"
echo "role: ${ROLE}; machine: $(uname -sm) $(uname -r) (${OSNAME}); runner image: ${ImageOS:-?} ${ImageVersion:-?}"
echo "java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1) (Temurin, downloaded and checksum-checked; the same build on both operating systems)"
echo "gradle: $(gradle --version 2>/dev/null | grep -E '^Gradle ' | head -1)   maven: $("$MVN_HOME/bin/mvn" --version 2>/dev/null | head -1)   cosign: $(cosign version 2>/dev/null | grep -i GitVersion | head -1)"
echo "release under test: FosterStack Cache ${VER} (${PLATFORM}), downloaded with no login and verified (cosign + sha256) before it runs"
echo "NOT pinned: the Maven build-cache extension ${EXT_VER}, the Maven plugins (all versions pinned in the pom but fetched from Maven Central) and JUnit"
echo "invented here: the Gradle project (rootProject.name, build.gradle.kts, App.java), the Maven pom with two tests, test passwords; the server listens on 127.0.0.1:${PORT} only"
echo "Gradle's own local cache is off (local { isEnabled = false }), the Gradle home and ~/.m2 are new and empty, so a hit can only come from the server"
echo "differences from the page's own runs (said again on the page): ONE Gradle module here (the page's run had four); a login is set (the page's runs had none); both systems here are GitHub-hosted VMs (Linux amd64, macOS arm64), not a Linux container on the Mac; the cache server runs on the machine that restores, on a data folder carried over from the machine that stored; the same Java build on both sides (the page's Maven run had 21.0.12.1 on the Mac and 21.0.7 on Linux)"
echo "gh runs with no login (the release downloads without one); gh $(gh --version | head -1 | cut -d' ' -f3), python3 $(python3 --version 2>&1 | cut -d' ' -f2), curl $(curl --version | head -1 | cut -d' ' -f2) are the runner's own, not pinned"
echo "what crosses between the two jobs: only the cache server's data folder, packed from a server that was stopped first; it holds the made-up projects' build results and nothing else"

# ---------- helpers ----------
run() { local name="$1" dir="$2" t0 t1; cat > "$W/$name.sh"; t0=$(now); ( cd "$dir" && bash -o pipefail "$W/$name.sh" ) > "$W/$name.out" 2>&1; RC=$?; t1=$(now); EL=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}'); }
expect() { local name="$1"; shift; local ok=yes w; [ "$RC" = 0 ] || ok="NO(exit $RC)"; for w in "$@"; do grep -qF -- "$w" "$W/$name.out" || ok="${ok}; missing: ${w}"; done
  printf 'STEP %-34s %7s s  exit=%s  expected=%s\n' "$name" "$EL" "$RC" "$ok"; case "$ok" in yes) ;; *) FAILS=$((FAILS+1)); sed 's/^/    | /' "$W/$name.out" | tail -14;; esac; }
statusz() { curl -s --max-time 30 -u "$USER_NAME:$PASS" "localhost:${PORT}/statusz" | python3 -c "import sys,json;d=json.load(sys.stdin);print('entries=%s hits=%s misses=%s' % (d['store_entries'],d['cache_hits'],d['cache_misses']))" 2>/dev/null || echo "statusz-unreadable"; }
num() { printf '%s' "$1" | sed -n "s/.*$2=\([0-9][0-9]*\).*/\1/p"; }
wait_up() { local i; for i in $(seq 1 400); do curl -sf --max-time 5 "localhost:${PORT}/healthz" >/dev/null 2>&1 && return 0; sleep 0.05; done; return 1; }

# the release: downloaded and verified (first-15 step 2, word for word), then unpacked
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

DATA="$W/data"; mkdir -p "$DATA"; EXPECT_ENTRIES=""
if [ "$ROLE" = restore ]; then
  [ -f "$IN/cache-data.tgz" ] || { fail "no data folder was handed over from the other job (expected $IN/cache-data.tgz)"; echo "FAILURES $FAILS"; exit 1; }
  mkdir -p "$W/unpack"
  tar -xzf "$IN/cache-data.tgz" -C "$W/unpack" || { fail "could not unpack the handed-over data folder"; echo "FAILURES $FAILS"; exit 1; }
  [ -d "$W/unpack/data" ] && [ -f "$W/unpack/entries.txt" ] || { fail "the handed-over file does not hold a data folder and entries.txt"; echo "FAILURES $FAILS"; exit 1; }
  rm -rf "${DATA:?}"; mv "$W/unpack/data" "$DATA"; EXPECT_ENTRIES="$(tr -d ' \n' < "$W/unpack/entries.txt")"
  case "$EXPECT_ENTRIES" in ''|*[!0-9]*) fail "the handed-over entry count is not a number ('${EXPECT_ENTRIES}')"; echo "FAILURES $FAILS"; exit 1;; esac
  echo "OBS handed over: $(find "$DATA" -type f | wc -l | tr -d ' ') files from the other operating system's server; its server held ${EXPECT_ENTRIES} entries when it was stopped"
fi
curl -sf --max-time 5 "localhost:${PORT}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${PORT}: not starting" >&2; exit 1; }
( cd "$W" && exec env FSCACHE_ADDR="127.0.0.1:${PORT}" FSCACHE_DATA_DIR="$DATA" FSCACHE_USERNAME="$USER_NAME" FSCACHE_PASSWORD="$PASS" "$REL/fscache" ) > "$W/server.log" 2>&1 &
SERVER_PID=$!
wait_up && kill -0 "$SERVER_PID" 2>/dev/null || { fail "the server did not answer on ${PORT}"; sed 's/^/    | /' "$W/server.log" | tail -5; echo "FAILURES $FAILS"; exit 1; }
S0="$(statusz)"; echo "OBS server at the start: ${S0}"
if [ "$ROLE" = store ]; then [ "$(num "$S0" entries)" = 0 ] || fail "the store job's server did not start empty (${S0})"; fi
if [ "$ROLE" = restore ]; then [ "$(num "$S0" entries)" = "$EXPECT_ENTRIES" ] 2>/dev/null || fail "the restored server holds $(num "$S0" entries) entries, but the other job's server held ${EXPECT_ENTRIES} when it stopped (${S0})"; fi

# ---------- the two projects (identical text on both operating systems) ----------
gradle_project() { # DIR
  local d="$1"; mkdir -p "$d/src/main/java/demo"
  cat > "$d/settings.gradle.kts" <<EOF
rootProject.name = "demo"

// FosterStack Cache — remote Gradle build cache.
// https://github.com/fosterstack/cache
buildCache {
    local { isEnabled = false } // so a hit can only come from the remote
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:${PORT}/")
        isPush = true
        credentials {
            username = "${USER_NAME}"
            password = "${PASS}"
        }
    }
}
EOF
  printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
  printf 'plugins { java }\n' > "$d/build.gradle.kts"
  printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println("hello 1");\n    }\n}\n' > "$d/src/main/java/demo/App.java"
}
mvn_project() { # DIR
  local d="$1"; mkdir -p "$d/.mvn" "$d/src/main/java/demo" "$d/src/test/java/demo"
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
      <url>http://127.0.0.1:${PORT}/</url>
    </remote>
  </configuration>
</cache>
EOF
  cat > "$d/pom.xml" <<'EOF'
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
  printf 'package demo;\n\npublic class App {\n    public static String hello() { return "hello 1"; }\n}\n' > "$d/src/main/java/demo/App.java"
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

# ---------- Gradle ----------
export GRADLE_USER_HOME="$W/gradle-home"
gradle_project "$W/gproj"
HB="$(statusz)"
run gradle-build "$W/gproj" <<'EOF'
gradle compileJava --build-cache
EOF
HA="$(statusz)"
echo "OBS Gradle: server before ${HB} / after ${HA}"
if [ "$ROLE" = store ]; then
  expect gradle-build "BUILD SUCCESSFUL" "> Task :compileJava"
  grep -qF "> Task :compileJava FROM-CACHE" "$W/gradle-build.out" && fail "Gradle (store): the first build already said FROM-CACHE"
  [ "$(num "$HA" entries)" -gt "$(num "$HB" entries)" ] 2>/dev/null || fail "Gradle (store): nothing was stored on the server (${HB} -> ${HA})"
else
  expect gradle-build "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
  grep -E "^> Task :compileJava$" "$W/gradle-build.out" >/dev/null && fail "Gradle (restore): compileJava ran instead of coming from the cache"
  [ "$(num "$HA" hits)" -gt "$(num "$HB" hits)" ] 2>/dev/null || fail "Gradle (restore): FROM-CACHE was printed but the server counted no hit (${HB} -> ${HA})"
  echo "OBS Gradle (restore): the FROM-CACHE line is the proof for compileJava; the hit counter is supporting (it also counts the compiled build script, which is why one build can show 2 hits); misses before/after: $(num "$HB" misses)/$(num "$HA" misses)"
fi
gradle --stop >/dev/null 2>&1 || true

# ---------- Maven ----------
mvnhome="$W/mvn-home"; mkdir -p "$mvnhome/.m2"
printf '<settings>\n  <servers>\n    <server>\n      <id>fosterstack-cache</id>\n      <username>%s</username>\n      <password>%s</password>\n    </server>\n  </servers>\n</settings>\n' "$USER_NAME" "$PASS" > "$mvnhome/.m2/settings.xml"
ORIGHOME="$HOME"; export HOME="$mvnhome"; export MAVEN_OPTS="-Duser.home=${mvnhome}"
mvn_project "$W/mproj"
HB="$(statusz)"
run maven-build "$W/mproj" <<EOF
export PATH="${MVN_HOME}/bin:\$PATH"
mvn verify
EOF
HA="$(statusz)"
echo "OBS Maven: server before ${HB} / after ${HA}"
if [ "$ROLE" = store ]; then
  expect maven-build "Saved to remote cache" "BUILD SUCCESS"
  grep -qF "Found cached build, restoring demo:mtest" "$W/maven-build.out" && fail "Maven (store): the first build already restored from the cache"
  [ "$(num "$HA" entries)" -gt "$(num "$HB" entries)" ] 2>/dev/null || fail "Maven (store): nothing was stored on the server (${HB} -> ${HA})"
else
  expect maven-build "Found cached build, restoring demo:mtest from cache by checksum" "BUILD SUCCESS"
  grep -qF "Compiling" "$W/maven-build.out" && fail "Maven (restore): the build printed Compiling, so it did not restore everything from the cache"
  echo "OBS Maven (restore): a restored build can still save a small report file (entries ${HB} -> ${HA}); misses before/after: $(num "$HB" misses)/$(num "$HA" misses)"
  [ "$(num "$HA" hits)" -gt "$(num "$HB" hits)" ] 2>/dev/null || fail "Maven (restore): the build said it restored but the server counted no hit (${HB} -> ${HA})"
fi
export HOME="$ORIGHOME"; unset MAVEN_OPTS

# ---------- hand the data folder over (store role) ----------
FINAL="$(statusz)"; stop_server
if [ "$ROLE" = store ]; then
  case "$(num "$FINAL" entries)" in ''|*[!0-9]*) fail "the server's final entry count could not be read (${FINAL}), so nothing is handed over";; esac
  mkdir -p "$W/pack"; cp -R "$DATA" "$W/pack/data"; printf '%s\n' "$(num "$FINAL" entries)" > "$W/pack/entries.txt"
  tar -czf "$OUT/cache-data.tgz" -C "$W/pack" data entries.txt || fail "could not pack the server's data folder"
  echo "OBS packed the server's data folder: $(find "$DATA" -type f | wc -l | tr -d ' ') files, $(wc -c < "$OUT/cache-data.tgz" | tr -d ' ') bytes (the only thing that leaves this job)"
fi
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED (${ROLE} on ${OSNAME})" || echo "== AT LEAST ONE STEP FAILED (see FAIL and STEP lines above)"
[ "$FAILS" = 0 ]
