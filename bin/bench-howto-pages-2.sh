#!/usr/bin/env bash
# End-to-end runs on a GitHub-hosted runner, batch 2: do the commands and promised outputs of these pages really happen?
#   F  /gradle-remote-build-cache-private-ca-https/   the six runs of the page's table (no trust settings; a trust store with only our CA in
#                                                     gradle.properties and on the command line; the trap; a store with Java's list plus our CA)
#   H  /migrate-build-cache-node/                     the Gradle settings in Kotlin and Groovy, 'build twice and look for FROM-CACHE', the
#                                                     local-cache-clearing commands, the /metrics counters, the /cache/ URL rows, Maven
#   K  /build-cache-docker-compose-production/        the 'Check it works' block as the page now writes it (it was rewritten after the first
#                                                     hosted run), with and without a password
# Run by the "bench-howto-pages-2" job of .github/workflows/hygiene.yml (manual dispatch only, choice "howto-pages-2"). Same method as
# bin/bench-howto-pages.sh: commands word for word, the server's own counters checked, every output line the page promises asserted, a
# step that fails or prints something else is RECORDED (FAIL) and fails the job at the end, and observations that are not failures are
# printed as OBS lines.
#
# No token and no secret: the release downloads without a login. Tools (Gradle, Maven 3.10.0, JDK 27, cosign) are downloaded and checked
# against pinned checksums; Docker and Compose are the runner's own, and the cache image is verified with cosign before it is run. NOT
# pinned (said again in the output): the Maven build-cache extension, the Maven plugins and JUnit from Maven Central.
set -uo pipefail

VER=0.2.2                                    # the release the pages name
LOCAL="${BENCH_LOCAL:-0}"                    # 1 = a developer's dry run with local tools (nothing downloaded or checked: do not quote times)
if [ "$LOCAL" = 1 ]; then PLATFORM="${BENCH_PLATFORM:-darwin_arm64}"; else PLATFORM=linux_amd64; fi
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
MVN310_URL="https://archive.apache.org/dist/maven/maven-3/3.10.0/binaries/apache-maven-3.10.0-bin.tar.gz"
MVN310_SHA512=908b1501bfb420bf7c8affb855534a9c407fd6099367bfb9f2f2dcb8e9799102bffb84518cde74c679bd76870247c6528683abdd620581bffa90f95d92d175aa
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
for h in "$JDK21_HOME" "$JDK27_HOME"; do [ -x "$h/bin/java" ] || { echo "no usable Java at $h" >&2; exit 1; }; done
[ -x "$MVN310_HOME/bin/mvn" ] || { echo "Maven home not usable" >&2; exit 1; }
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
echo "NOT checksum-pinned: the Maven build-cache extension ${EXT_VER}, the Maven plugin jars (their eight versions are pinned in the pom, the files come from Maven Central), JUnit (5.11.0 for scenario F's project, 5.11.4 for Maven); the Gradle wrapper's distribution IS checked against the pinned sha256 by the wrapper itself"
echo "release under test: FosterStack Cache ${VER}, downloaded with no login and verified (cosign + sha256) before it runs; the image for scenario K is verified by digest with cosign before it runs"
echo "invented by this script (the pages show none): the Gradle and Maven projects and their small sources, test passwords, and for F the TLS front end: a small Python proxy (the page says it used a small proxy it wrote), the test CA and server certificate made with the page's own openssl commands, and the build.gradle.kts with a JUnit test"
echo "values replaced: https://cache.example.com/ by http://127.0.0.1:PORT/ (H) or https://127.0.0.1:18443/ (F); /path/to/... by real paths; the page's Java for F is the pinned Temurin 27 (the page used Homebrew Java 27)"
echo "Gradle's own local cache is switched off in the runs that count hits (as the pages' own runs did) unless a step says otherwise; developer builds run with CI unset"
echo "NOT tested here: how a long-running Gradle daemon picks up the trust settings, a certificate that names another host, an expired certificate, Windows; the migrate page's old Build Cache Node rows and its rollback (there is no old node here)"
echo "scenario H tests the CORRECTED procedure of the migrate page: its text said to run the build twice and look for FROM-CACHE, but a second build with nothing changed prints UP-TO-DATE, so the script runs ./gradlew clean between builds and records the UP-TO-DATE fact as an OBS line (the page is fixed after this run); Maven runs in a recreated project, not a clean checkout, and the comment lines inside the page's XML are left out"
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
# SCENARIO F: /gradle-remote-build-cache-private-ca-https/  (the page's six runs)
# =====================================================================================
tls_proxy() { # writes the small TLS proxy the page's own run used a stand-in of: https://127.0.0.1:LISTEN -> http://127.0.0.1:TARGET
  cat > "$W/tlsproxy.py" <<'PYEOF'
import http.client, http.server, ssl, sys
listen, target, crt, key = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _do(self):
        body = b""
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline(); break
                body += self.rfile.read(size); self.rfile.readline()
        else:
            n = int(self.headers.get("Content-Length", "0") or 0)
            body = self.rfile.read(n) if n else b""
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("transfer-encoding", "content-length", "connection", "expect")}
        if body or self.command in ("PUT", "POST"):
            hdrs["Content-Length"] = str(len(body))
        c = http.client.HTTPConnection("127.0.0.1", target, timeout=60)
        c.request(self.command, self.path, body=body or None, headers=hdrs)
        r = c.getresponse(); data = r.read()
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        c.close()
    do_GET = do_PUT = do_HEAD = do_POST = do_DELETE = _do
    def log_message(self, *a): pass
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(crt, key)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", listen), H)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PYEOF
}
PROXY_PID=""
stop_proxy() { [ -n "$PROXY_PID" ] && { kill "$PROXY_PID" 2>/dev/null; wait "$PROXY_PID" 2>/dev/null; PROXY_PID=""; }; return 0; }

ca_project() { # DIR  (the page's project: needs Maven Central for its test dependency; the settings point at the TLS front end, no login)
  local d="$1"; rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo" "$d/src/test/java/demo"
  cat > "$d/settings.gradle.kts" <<EOF
rootProject.name = "demo"

// FosterStack Cache — remote Gradle build cache.
// https://github.com/fosterstack/cache
buildCache {
    local { isEnabled = false } // so a hit can only come from the remote
    remote<HttpBuildCache> {
        url = uri("https://127.0.0.1:18443/")
        isPush = true
        credentials {
            username = "gradle"
            password = "unused-the-server-has-no-login"
        }
    }
}
EOF
  cat > "$d/build.gradle.kts" <<'EOF'
plugins { java }
repositories { mavenCentral() }
dependencies {
    testImplementation(platform("org.junit:junit-bom:5.11.0"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}
tasks.test { useJUnitPlatform() }
EOF
  printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
  printf 'package demo;\n\npublic class App {\n    public static String hello() { return "hello"; }\n}\n' > "$d/src/main/java/demo/App.java"
  printf 'package demo;\n\nimport static org.junit.jupiter.api.Assertions.assertEquals;\nimport org.junit.jupiter.api.Test;\n\nclass AppTest {\n    @Test void hello() { assertEquals("hello", App.hello()); }\n}\n' > "$d/src/test/java/demo/AppTest.java"
}

scenario_f() {
  echo; echo "== F  (gradle-remote-build-cache-private-ca-https)"
  local D="$W/f" P=8084 S rc n E0
  mkdir -p "$D/ca"
  # the page's certificate commands, word for word, run in a folder called ca (the page's keytool commands read ca/ca.crt)
  run f-certs "$D/ca" <<'EOF'
openssl genrsa -out ca.key 2048
openssl req -x509 -new -key ca.key -sha256 -days 30 -subj "/CN=Test Private CA" -out ca.crt
openssl genrsa -out server.key 2048
openssl req -new -key server.key -subj "/CN=cache.test" -out server.csr
printf "subjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n" > ext.cnf
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 30 -sha256 -extfile ext.cnf
EOF
  expect f-certs; [ -f "$D/ca/ca.crt" ] && [ -f "$D/ca/server.crt" ] && [ -f "$D/ca/server.key" ] || { fail "F: the page's openssl commands did not make ca.crt, server.crt and server.key"; return; }
  echo "OBS F: the page's 'How we made the test certificates' commands write ca.crt into the folder they are run in, while its keytool commands read ca/ca.crt: they match only if the openssl commands are run inside a folder called ca"
  start_server f "$P" "" "" || return
  tls_proxy; ( cd "$W" && exec python3 "$W/tlsproxy.py" 18443 "$P" "$D/ca/server.crt" "$D/ca/server.key" ) > "$W/tlsproxy.log" 2>&1 &
  PROXY_PID=$!
  local i; for i in $(seq 1 100); do curl -sf --max-time 5 --cacert "$D/ca/ca.crt" https://127.0.0.1:18443/healthz >/dev/null 2>&1 && break; sleep 0.1; done
  # curl: exit 60 without the CA, works with --cacert
  curl -s --max-time 10 https://127.0.0.1:18443/healthz >/dev/null 2>&1; rc=$?
  [ "$rc" = 60 ] && echo "OBS F: curl without the CA: exit 60, as the page says" || fail "F: curl without the CA exited $rc; the page says 60"
  S="$(curl -s --max-time 10 --cacert "$D/ca/ca.crt" https://127.0.0.1:18443/healthz)"; [ "$S" = ok ] && echo "OBS F: curl with --cacert ca/ca.crt: ok" || fail "F: curl with --cacert printed '$S', not ok"
  # trust stores, with the page's commands
  run f-keytool-only "$D" <<EOF
${JDK27_HOME}/bin/keytool -importcert -alias testca -file ca/ca.crt -keystore truststore-only.p12 -storepass changeit -noprompt
EOF
  expect f-keytool-only
  local TS_ONLY="$D/truststore-only.p12" TS_ALL="$D/truststore-combined.p12"
  fgradle() { # RUN-NAME PROJECT-DIR PROPS(none|only|combined|cmdline) TASK   (a new empty Gradle home each run; --no-daemon as the page says)
    local name="$1" proj="$2" props="$3" task="$4" extra=""
    ca_project "$proj"
    case "$props" in
      only)     printf 'systemProp.javax.net.ssl.trustStore=%s\nsystemProp.javax.net.ssl.trustStorePassword=changeit\n' "$TS_ONLY" >> "$proj/gradle.properties";;
      combined) printf 'systemProp.javax.net.ssl.trustStore=%s\nsystemProp.javax.net.ssl.trustStorePassword=changeit\n' "$TS_ALL" >> "$proj/gradle.properties";;
      cmdline)  extra="-Djavax.net.ssl.trustStore=${TS_ONLY} -Djavax.net.ssl.trustStorePassword=changeit";;
    esac
    run "$name" "$proj" <<EOF
export JAVA_HOME="${JDK27_HOME}"
export GRADLE_USER_HOME="${W}/gh-${name}"
rm -rf "\$GRADLE_USER_HOME"
gradle ${task} --no-daemon ${extra}
EOF
  }
  # run 1: no trust settings
  fgradle f-run1 "$D/p1" none compileJava
  expect f-run1 "BUILD SUCCESSFUL" "Could not load entry" "from remote build cache" "(certificate_unknown)" "PKIX path building failed" "unable to find valid certification path to requested target" "The remote build cache was disabled during the build due to errors." "> Task :compileJava"
  absent f-run1 "FROM-CACHE"
  echo "OBS F run 1: server $(statusz "$P" x y)"
  # run 2 and 3: a trust store with only our CA, in gradle.properties
  fgradle f-run2 "$D/p2" only compileJava
  expect f-run2 "BUILD SUCCESSFUL" "> Task :compileJava"; absent f-run2 "FROM-CACHE" "PKIX"
  E0="$(statusz "$P" x y)"; echo "OBS F run 2: server ${E0}"
  [ "$(entries_of "$E0")" -ge 1 ] 2>/dev/null || fail "F run 2: nothing was stored on the server (${E0})"
  fgradle f-run3 "$D/p3" only compileJava
  expect f-run3 "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
  # run 4: command line only
  fgradle f-run4 "$D/p4" cmdline compileJava
  expect f-run4 "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
  # run 5: a trust store with only our CA, a project that needs Maven Central
  fgradle f-run5 "$D/p5" only test
  NOZERO=1 expect f-run5 "> Task :compileJava FROM-CACHE" "BUILD FAILED" "Could not GET 'https://repo.maven.apache.org/maven2/org/junit/junit-bom/5.11.0/junit-bom-5.11.0.pom'" "Got SSL handshake exception during request" "PKIX path building failed"
  [ "$RC" != 0 ] || fail "F run 5: the page says this build fails, but it succeeded"
  # run 6: Java's normal list plus our CA (the page's commands; the cacerts path is this Java's)
  run f-keytool-combined "$D" <<EOF
cp ${JDK27_HOME}/lib/security/cacerts truststore-combined.p12
chmod u+w truststore-combined.p12
${JDK27_HOME}/bin/keytool -importcert -alias testca -file ca/ca.crt -keystore truststore-combined.p12 -storepass changeit -noprompt
EOF
  expect f-keytool-combined
  n="$("$JDK27_HOME/bin/keytool" -list -keystore "$TS_ALL" -storepass changeit 2>/dev/null | grep -c 'trustedCertEntry')"
  echo "OBS F: this Java's combined store holds ${n} certificates (the page's Homebrew Java held 112: the 111 that came with Java plus ours)"
  fgradle f-run6 "$D/p6" combined test
  expect f-run6 "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
  stop_proxy; stop_server
}

# =====================================================================================
# SCENARIO H: /migrate-build-cache-node/
# =====================================================================================
scenario_h() {
  echo; echo "== H  (migrate-build-cache-node)"
  local D="$W/h" P=8086 S HB HA H0 H1
  mkdir -p "$D"
  local PW='h-test-secret-not-real'
  start_server h "$P" gradle "$PW" || return
  # --- Step 2, Kotlin: the page's settings (host replaced), plus the local-cache line so a hit has to come from the server
  hproj() { # DIR URLSUFFIX LANG(kts|groovy) [asthepage]   (asthepage: the page's own settings, Gradle's local cache left on)
    local d="$1" sfx="$2" lang="$3" lk="    local { isEnabled = false } // so a hit can only come from the remote" lg="    local { enabled = false } // so a hit can only come from the remote"
    [ "${4:-}" = asthepage ] && { lk=""; lg=""; }
    rm -rf "${d:?}"; mkdir -p "$d/src/main/java/demo"
    if [ "$lang" = kts ]; then
      cat > "$d/settings.gradle.kts" <<EOF
rootProject.name = "demo"
// FosterStack Cache — remote Gradle build cache.
// https://github.com/fosterstack/cache
buildCache {
${lk}
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:${P}/${sfx}")
        isPush = true
        credentials {
            username = "gradle"
            password = System.getenv("FSCACHE_PASSWORD")
        }
    }
}
EOF
      printf 'plugins { java }\n' > "$d/build.gradle.kts"
    else
      cat > "$d/settings.gradle" <<EOF
rootProject.name = 'demo'
// FosterStack Cache — remote Gradle build cache.
// https://github.com/fosterstack/cache
buildCache {
${lg}
    remote(HttpBuildCache) {
        url = 'http://127.0.0.1:${P}/${sfx}'
        push = true
        credentials {
            username = 'gradle'
            password = System.getenv('FSCACHE_PASSWORD')
        }
    }
}
EOF
      printf "plugins { id 'java' }\n" > "$d/build.gradle"
    fi
    printf 'org.gradle.caching=true\n' > "$d/gradle.properties"
    gradle_code "$d" 1
  }
  # step 4: the page's settings as written (Gradle's local cache left on). The page's first version said 'run the build twice' and 'look
  # for FROM-CACHE'; a second run with nothing changed prints UP-TO-DATE, so the corrected page says to run clean in between.
  metric() { curl -s --max-time 30 "http://127.0.0.1:${P}/metrics" | sed -n "s/^$1 \([0-9][0-9]*\)\$/\1/p"; }
  hproj "$D/k1" "" kts asthepage
  run h-wrapper "$D/k1" <<EOF
export FSCACHE_PASSWORD='${PW}'
gradle wrapper --gradle-version ${GR_VER} --distribution-type all --gradle-distribution-sha256-sum ${GR_SHA}
EOF
  expect h-wrapper "BUILD SUCCESSFUL"
  local HH="$W/h-home"; mkdir -p "$HH"
  run h-build1 "$D/k1" <<EOF
export HOME="${HH}"; export GRADLE_USER_HOME="${HH}/.gradle"; export FSCACHE_PASSWORD='${PW}'
./gradlew build --build-cache
EOF
  expect h-build1 "BUILD SUCCESSFUL" "> Task :compileJava"; absent h-build1 "FROM-CACHE"
  run h-build2-noclean "$D/k1" <<EOF
export HOME="${HH}"; export GRADLE_USER_HOME="${HH}/.gradle"; export FSCACHE_PASSWORD='${PW}'
./gradlew build --build-cache
EOF
  expect h-build2-noclean "BUILD SUCCESSFUL" "> Task :compileJava UP-TO-DATE"; absent h-build2-noclean "FROM-CACHE"
  echo "OBS H: a second build with nothing changed prints UP-TO-DATE, not FROM-CACHE (so the page must say to run clean between)"
  H0="$(metric fscache_cache_hits_total)"
  run h-build3 "$D/k1" <<EOF
export HOME="${HH}"; export GRADLE_USER_HOME="${HH}/.gradle"; export FSCACHE_PASSWORD='${PW}'
./gradlew clean
./gradlew build --build-cache
EOF
  expect h-build3 "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
  H1="$(metric fscache_cache_hits_total)"
  echo "OBS H: after clean, the second build printed FROM-CACHE; the server's hit counter went ${H0} -> ${H1} (Gradle's own local cache is on in the page's settings, so this hit can come from the machine itself)"
  # the local-cache-clearing commands as the corrected page writes them (clean first), then the server's counters
  H0="$(metric fscache_cache_hits_total)"
  run h-clear "$D/k1" <<EOF
export HOME="${HH}"; export GRADLE_USER_HOME="${HH}/.gradle"; export FSCACHE_PASSWORD='${PW}'
./gradlew clean
rm -rf ~/.gradle/caches/build-cache-1
./gradlew --stop
./gradlew build --build-cache -i
EOF
  expect h-clear "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE" "Build cache key for task ':compileJava' is"
  H1="$(metric fscache_cache_hits_total)"
  echo "OBS H: fscache_cache_hits_total before the cache-clearing commands ${H0} / after ${H1}"
  [ "$H1" -gt "$H0" ] 2>/dev/null && echo "OBS H: the hit counter moved (the page says the hit and miss counters should move: a hit is what to look for here)" || fail "H: the page says the counters should move after the cache-clearing commands, but the hit counter did not (${H0} -> ${H1})"
  # the page's /metrics command, as written (no login) and with the login
  S="$(curl -s --max-time 30 "http://127.0.0.1:${P}/metrics" | grep -E 'fscache_cache_(hits|misses)_total' | tr '\n' ' ')"
  case "$S" in *fscache_cache_hits_total*fscache_cache_misses_total*) echo "OBS H: the page's curl .../metrics | grep (no login needed) printed both counters";; *) fail "H: the page's /metrics command did not print both fscache_cache_hits_total and fscache_cache_misses_total: ${S}";; esac
  # the same, with the clean the first-15 page uses between builds, to see the server do the work
  hproj "$D/k2" "" kts; cp -R "$D/k1/gradle" "$D/k1/gradlew" "$D/k2/" 2>/dev/null
  run h-clean-build "$D/k2" <<EOF
export HOME="${HH}"; export GRADLE_USER_HOME="${HH}/.gradle"; export FSCACHE_PASSWORD='${PW}'
./gradlew build --build-cache
./gradlew clean
rm -rf ~/.gradle/caches/build-cache-1
./gradlew build --build-cache
EOF
  expect h-clean-build "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
  # Groovy settings
  hproj "$D/g1" "" groovy; cp -R "$D/k1/gradle" "$D/k1/gradlew" "$D/g1/" 2>/dev/null
  HB="$(statusz "$P" gradle "$PW")"
  run h-groovy "$D/g1" <<EOF
export HOME="${HH}"; export GRADLE_USER_HOME="${HH}/.gradle"; export FSCACHE_PASSWORD='${PW}'
./gradlew build --build-cache
./gradlew clean
./gradlew build --build-cache
EOF
  expect h-groovy "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"; HA="$(statusz "$P" gradle "$PW")"
  echo "OBS H Groovy settings: server before ${HB} / after ${HA}"
  # the checklist rows: only the URL changed vs a URL kept with /cache/ (separate entries)
  hproj "$D/c1" "cache/" kts; cp -R "$D/k1/gradle" "$D/k1/gradlew" "$D/c1/" 2>/dev/null
  HB="$(statusz "$P" gradle "$PW")"
  run h-cachepath "$D/c1" <<EOF
export HOME="${HH}"; export GRADLE_USER_HOME="${HH}/.gradle"; export FSCACHE_PASSWORD='${PW}'
./gradlew build --build-cache
./gradlew clean
./gradlew build --build-cache
EOF
  expect h-cachepath "BUILD SUCCESSFUL" "> Task :compileJava"; HA="$(statusz "$P" gradle "$PW")"
  grep -qF "> Task :compileJava FROM-CACHE" "$W/h-cachepath.out" || fail "H: with the URL kept with /cache/ the second build should come from the cache"
  [ "$(entries_of "$HA")" -gt "$(entries_of "$HB")" ] 2>/dev/null && echo "OBS H: the URL with /cache/ made its own entries (${HB} -> ${HA}), as the page says" || fail "H: the page says entries under a different path are separate, but the entry count did not grow (${HB} -> ${HA})"
  HOME="$HH" GRADLE_USER_HOME="$HH/.gradle" "$GRADLE_BIN" --stop >/dev/null 2>&1 || true
  # --- credentials block with a server that has no password is ignored (the page says leave it in)
  stop_server
  start_server h2 "$P" "" "" || return
  hproj "$D/n1" "" kts
  run h-nopass "$D/n1" <<EOF
export HOME="${HH}"; export GRADLE_USER_HOME="${HH}/.gradle"; export FSCACHE_PASSWORD='anything'
gradle build --build-cache
gradle clean
gradle build --build-cache
EOF
  expect h-nopass "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
  echo "OBS H: with a credentials block and a server that has no password, the build still used the cache (the page says the block is ignored then)"
  HOME="$HH" GRADLE_USER_HOME="$HH/.gradle" "$GRADLE_BIN" --stop >/dev/null 2>&1 || true
  stop_server
  # --- Maven (Maven 3.10.0): extension and config from the page, mvn install twice from a clean checkout
  mvn_env
  start_server h3 "$P" maven "$PW" || { mvn_env_off; return; }
  mvn_project "$D/m1" 1 1 "http://127.0.0.1:${P}/" 1
  printf '<settings>\n  <servers>\n    <server>\n      <id>fosterstack-cache</id>\n      <username>maven</username>\n      <password>%s</password>\n    </server>\n  </servers>\n</settings>\n' "$PW" > "$mvnhome/.m2/settings.xml"
  run h-mvn1 "$D/m1" <<EOF
export PATH="${MVN310_HOME}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
mvn install
EOF
  expect h-mvn1 "BUILD SUCCESS" "Saved to remote cache"
  mvn_project "$D/m2" 1 1 "http://127.0.0.1:${P}/" 1
  run h-mvn2 "$D/m2" <<EOF
export PATH="${MVN310_HOME}/bin:\$PATH"
rm -rf "\$HOME"/.m2/build-cache
mvn install
EOF
  expect h-mvn2 "BUILD SUCCESS" "Found cached build, restoring demo:mtest from cache by checksum"; absent h-mvn2 "Compiling"
  stop_server; mvn_env_off
}

# =====================================================================================
# SCENARIO K: the 'Check it works' block of /build-cache-docker-compose-production/ as the page now writes it
# =====================================================================================
scenario_k() {
  echo; echo "== K  (build-cache-docker-compose-production: Check it works)"
  local D="$W/k" CACHE_IMG="ghcr.io/fosterstack/cache" D022 DLAT CID OUTTXT
  mkdir -p "$D"
  pull() { local n; for n in 1 2 3; do docker pull -q "$1" >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
  pull "$CACHE_IMG:${VER}" && pull "$CACHE_IMG:latest" || { fail "K: could not pull the images"; return; }
  D022="$(docker inspect --format '{{index .RepoDigests 0}}' "$CACHE_IMG:${VER}")"; DLAT="$(docker inspect --format '{{index .RepoDigests 0}}' "$CACHE_IMG:latest")"
  echo "OBS images: ${CACHE_IMG}:${VER} = ${D022}; ${CACHE_IMG}:latest = ${DLAT}"
  if [ "$D022" != "$DLAT" ]; then fail "K: ${CACHE_IMG}:latest is not the ${VER} image this script verifies, so no image is run (update VER for the new release)"; return; fi
  run k-cosign "$D" <<EOF
cosign verify ${D022} \\
 --certificate-identity-regexp="^https://github.com/fosterstack/cache/.github/workflows/stage-promote.yml@refs/tags/v${VER}\$" \\
 --certificate-oidc-issuer='https://token.actions.githubusercontent.com'
EOF
  expect k-cosign "${D022#*@}"; [ "$RC" = 0 ] || { fail "K: the image signature did not verify, so no image is run"; return; }
  # the block, word for word as the page now writes it
  cat > "$D/check.sh" <<'EOF'
curl -s localhost:8080/healthz; echo
curl -s -u gradle:change-me -o /dev/null -w '%{http_code}\n' -X PUT --data-binary 'hello' localhost:8080/testkey123
curl -s -u gradle:change-me localhost:8080/testkey123; echo
EOF
  # (1) a server with no password: the page's docker run
  run k-dockerrun "$D" <<'EOF'
docker run -d -p 127.0.0.1:8080:8080 -v fscache-data:/home/nonroot ghcr.io/fosterstack/cache:latest
EOF
  expect k-dockerrun; CID="$(tail -1 "$W/k-dockerrun.out")"; CONTAINERS="$CONTAINERS $CID"
  wait_up 8080 || { fail "K: nothing answered on 8080"; return; }
  run k-check-nopass "$D" < "$D/check.sh"
  expect k-check-nopass "ok" "201" "hello"
  OUTTXT="$(cat "$W/k-check-nopass.out")"; [ "$OUTTXT" = "$(printf 'ok\n201\nhello')" ] && echo "OBS K: with no password the block printed ok, 201, hello on three lines" || fail "K: with no password the block printed '$(printf '%s' "$OUTTXT" | tr '\n' '|')', not ok|201|hello"
  docker rm -f "$CID" >/dev/null 2>&1; docker volume rm fscache-data >/dev/null 2>&1
  # (2) a server with the Compose file's password: the quick-start file, word for word
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
  COMPOSE_PROJECTS="$COMPOSE_PROJECTS kq"
  run k-up "$D" <<'EOF'
docker compose -p kq -f compose-quick.yaml up -d
EOF
  expect k-up; wait_up 8080 || { fail "K: nothing answered on 8080 for the Compose file"; return; }
  run k-check-pass "$D" < "$D/check.sh"
  expect k-check-pass "ok" "201" "hello"
  OUTTXT="$(cat "$W/k-check-pass.out")"; [ "$OUTTXT" = "$(printf 'ok\n201\nhello')" ] && echo "OBS K: with the Compose file's password the block printed ok, 201, hello on three lines" || fail "K: with the Compose file's password the block printed '$(printf '%s' "$OUTTXT" | tr '\n' '|')', not ok|201|hello"
  # without -u on a server that has a password: the page says the PUT prints 401 and the read prints unauthorized
  run k-nou "$D" <<'EOF'
curl -s localhost:8080/healthz; echo
curl -s -o /dev/null -w '%{http_code}\n' -X PUT --data-binary 'hello' localhost:8080/testkey999
curl -s localhost:8080/testkey123; echo
EOF
  OUTTXT="$(cat "$W/k-nou.out")"; [ "$OUTTXT" = "$(printf 'ok\n401\nunauthorized')" ] && echo "OBS K: without -u on a server with a password: ok, 401, unauthorized, as the page says" || fail "K: without -u the page says the PUT prints 401 and the read prints unauthorized; the output was '$(printf '%s' "$OUTTXT" | tr '\n' '|')'"
  docker compose -p kq down -v >/dev/null 2>&1
}

# ---------- run ----------
for port in 8080 8084 8086 18443; do
  curl -skf --max-time 3 "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
trap 'stop_proxy; stop_server; cleanup_docker; [ -z "${BENCH_WORK:-}" ] && [ -n "${W:-}" ] && rm -rf "${W:?}"' EXIT
scenario_f
scenario_h
scenario_k
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
