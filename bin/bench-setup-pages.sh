#!/usr/bin/env bash
# Timed runs on a GitHub-hosted runner: how long do the commands on two setup pages take, and does each page say what really happens?
#   A  /first-15-minutes-build-cache/   steps 2 to 6, the commands word for word
#   B  /maven-remote-build-cache-setup/ steps 1 to 4, the commands word for word
# Run by the "bench-setup-pages" job of .github/workflows/hygiene.yml (manual dispatch only, choice "setup-pages"). Prints its own
# disclosure (runner image, CPUs, tool versions, repetitions) so the numbers can be quoted honestly.
#
# A runner times commands, not people: the pages' "15 minutes" and "about ten minutes" are mostly reading, choosing values and pointing
# your own project at the server, which no machine can time. This script measures only the commands.
#
# Repetition 1 starts with an empty Gradle home and an empty ~/.m2 (a machine that has never built); repetition 2 reuses them (a machine
# that has built before). Every repetition uses a new project folder and a new, empty server data folder. A step that fails, or prints
# something other than what the page says, is RECORDED and fails the job at the end; it is not hidden. Observations that are not
# failures (for example which cache served a hit) are printed as OBS lines.
#
# No token and no secret: the release files download without a login (as the verify-a-release timing showed). Tools: Gradle, Maven and
# cosign are downloaded and checked against pinned checksums; the Maven build-cache extension and the Maven plugins come from Maven
# Central at run time and are NOT checksum-pinned (said again in the output).
set -uo pipefail

REPS="${BENCH_REPS:-2}"
VER=0.2.2                                    # the release the pages name
LOCAL="${BENCH_LOCAL:-0}"                    # 1 = use the tools already on this machine (a developer's dry run: nothing is downloaded or checked)
if [ "$LOCAL" = 1 ]; then PLATFORM="${BENCH_PLATFORM:-darwin_arm64}"; else PLATFORM=linux_amd64; fi
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf   # services.gradle.org/distributions/gradle-9.8.0-all.zip.sha256 (the value the other bench jobs pin)
MVN_VER=3.10.0
MVN_URL="https://archive.apache.org/dist/maven/maven-3/${MVN_VER}/binaries/apache-maven-${MVN_VER}-bin.tar.gz"
MVN_SHA512=908b1501bfb420bf7c8affb855534a9c407fd6099367bfb9f2f2dcb8e9799102bffb84518cde74c679bd76870247c6528683abdd620581bffa90f95d92d175aa   # archive.apache.org, the .sha512 next to the tarball
COSIGN_VER=3.1.3
COSIGN_SHA=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71   # cosign_checksums.txt of v3.1.3, cosign-linux-amd64
EXT_VER=1.2.3                                # the extension version the Maven page names
PASS_GRADLE='first15-test-secret-not-real'
PASS_MAVEN='mvn-test-secret-not-real'
PORT_A=8080                                  # the port the first-15 page uses
PORT_B=8081

FAILS=0
now() { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }
note() { printf '%s\n' "$*"; }
fail() { FAILS=$((FAILS+1)); printf 'FAIL %s\n' "$*"; }
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
    # do not go on until the port stops answering: a stale server would be mistaken for the next one
    for i in $(seq 1 100); do curl -sf "localhost:${SERVER_PORT}/healthz" >/dev/null 2>&1 || break; sleep 0.1; done
    curl -sf "localhost:${SERVER_PORT}/healthz" >/dev/null 2>&1 && fail "the server on port ${SERVER_PORT} did not stop"
  fi
}
trap 'stop_server; [ -z "${BENCH_WORK:-}" ] && [ -n "${W:-}" ] && rm -rf "${W:?}"' EXIT

# ---------- tools (not timed: the pages say you need these already) ----------
mkdir -p "$W/tools/bin"; cd "$W/tools"
[ "$LOCAL" = 1 ] && { export GH_CONFIG_DIR="$W/gh-empty-config"; mkdir -p "$GH_CONFIG_DIR"; unset GH_TOKEN GITHUB_TOKEN; }
if [ "$LOCAL" != 1 ]; then
  curl -fsSL -o cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VER}/cosign-linux-amd64"; sha_check cosign "$COSIGN_SHA"; install -m 0755 cosign bin/cosign
  curl -fsSL -o gr.zip "$GR_URL"; sha_check gr.zip "$GR_SHA"; unzip -q gr.zip; ln -s "$W/tools/gradle-${GR_VER}/bin/gradle" bin/gradle
  curl -fsSL -o mvn.tgz "$MVN_URL"; echo "${MVN_SHA512}  mvn.tgz" | sha512sum -c - >/dev/null || { echo "CHECKSUM MISMATCH: maven" >&2; exit 2; }; tar -xzf mvn.tgz; ln -s "$W/tools/apache-maven-${MVN_VER}/bin/mvn" bin/mvn
  export PATH="$W/tools/bin:$PATH"
else
  # the machine's own sha256sum may be missing (macOS): a shim for the page's command only
  command -v sha256sum >/dev/null 2>&1 || { printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > bin/sha256sum; chmod +x bin/sha256sum; export PATH="$W/tools/bin:$PATH"; }
fi
if [ "$LOCAL" = 1 ]; then JAVA_HOME="${BENCH_JAVA_HOME:-$(/usr/libexec/java_home -v 21 2>/dev/null || echo "${JAVA_HOME:-}")}"; else JAVA_HOME="${BENCH_JAVA_HOME:-${JAVA_HOME_21_X64:-${JAVA_HOME:-}}}"; fi
export JAVA_HOME
[ -x "$JAVA_HOME/bin/java" ] || { echo "no usable Java (JAVA_HOME=$JAVA_HOME)" >&2; exit 1; }
export PATH="$JAVA_HOME/bin:$PATH"
for t in gh cosign gradle mvn curl python3 tar; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

# ---------- disclosure ----------
echo "== DISCLOSURE"
echo "runner: $(uname -sr); cpus: $(nproc 2>/dev/null || sysctl -n hw.ncpu); image: ${ImageOS:-?} ${ImageVersion:-?}"
(lscpu 2>/dev/null | grep -E 'Model name' || true); (free -m 2>/dev/null | sed -n 2p || true)
echo "java: $(java -version 2>&1 | head -1)"
echo "gradle: $(gradle --version 2>/dev/null | grep -E '^Gradle ' | head -1)   maven: $(mvn --version 2>/dev/null | head -1)   cosign: $(cosign version 2>/dev/null | grep -i GitVersion | head -1)   gh: $(gh --version | head -1)"
if [ "$LOCAL" = 1 ]; then echo "tools: LOCAL tools in use, nothing downloaded or checked (a developer's dry run: do not quote these times)"; else
  echo "tools: Gradle ${GR_VER} (sha256 pinned), Maven ${MVN_VER} (sha512 pinned), cosign ${COSIGN_VER} (sha256 pinned), checked before use; the Maven build-cache extension ${EXT_VER} and the Maven plugins come from Maven Central at run time and are NOT checksum-pinned"; fi
echo "release under test: FosterStack Cache ${VER} (${PLATFORM}), downloaded from its GitHub release with no login"
echo "repetitions: ${REPS}; rep 1 = empty Gradle home and empty ~/.m2 (never built here), rep 2 = a machine that has built before: Gradle home and ~/.m2 repository kept, but both local BUILD caches emptied; each with a new project and a new empty server data folder"
echo "invented by this script (the pages show none): the Gradle project's rootProject.name, build.gradle.kts (plugins { java }) and a small App.java, and the Maven pom and App.java; scenario A's server is started as the page starts it, with no FSCACHE_ADDR, so it listens on the default :8080 (all interfaces) for a few minutes behind a made-up password; scenario B's server listens on 127.0.0.1 only"
echo "the pages' hard-coded values replaced: PLATFORM=${PLATFORM}, a made-up password, and (Maven page) the example host https://cache.example.com/ by http://127.0.0.1:${PORT_B}/; the Maven page shows no pom: a minimal one with pinned plugin versions is used"
echo "page commands run with 'bash -o pipefail' so a failing first command in a pipeline is not hidden"
echo "a runner times commands, not people: the pages' '15 minutes' and 'about ten minutes' are mostly reading and choosing, which is not timed here"

export GRADLE_USER_HOME="$W/gradle-home"
mvnhome="$W/mvn-home"; mkdir -p "$mvnhome"

# the local build caches of an earlier repetition would answer this one's first build: empty them (the Gradle home and ~/.m2 stay warm)
clear_local_caches() {
  rm -rf "${GRADLE_USER_HOME:?}/caches/build-cache-1" "${mvnhome:?}/.m2/build-cache"
}

# ---------- helpers ----------
# run NAME DIR  (command text on stdin): run it with bash -o pipefail in DIR, time it, keep output in $W/NAME.out, set RC and EL
run() {
  local name="$1" dir="$2" t0 t1
  cat > "$W/$name.sh"
  t0=$(now); ( cd "$dir" && bash -o pipefail "$W/$name.sh" ) > "$W/$name.out" 2>&1; RC=$?; t1=$(now); EL=$(secs "$t0" "$t1")
}
expect() { # NAME text...   (every text must be in the output of NAME; RC must be 0 unless NOZERO=1)
  local name="$1"; shift; local ok=yes w
  [ "${NOZERO:-0}" = 1 ] || [ "$RC" = 0 ] || ok="NO(exit $RC)"
  for w in "$@"; do grep -qF -- "$w" "$W/$name.out" || ok="${ok}; missing: ${w}"; done
  printf 'STEP %-34s %7s s  exit=%s  expected=%s\n' "$name" "$EL" "$RC" "$ok"
  case "$ok" in yes) ;; *) FAILS=$((FAILS+1)); sed 's/^/    | /' "$W/$name.out" | tail -12 ;; esac
}
statusz() { # port user pass -> "entries=N hits=N misses=N"
  curl -s -u "$2:$3" "localhost:$1/statusz" | python3 -c "import sys,json;d=json.load(sys.stdin);print('entries=%s hits=%s misses=%s' % (d['store_entries'],d['cache_hits'],d['cache_misses']))" 2>/dev/null || echo "statusz-unreadable"
}
hits_of() { case "$1" in *hits=*) printf '%s' "$1" | sed -E 's/.*hits=([0-9]+).*/\1/';; *) printf 'unreadable';; esac; }
readable() { case "$1" in *hits=*) return 0;; *) fail "the status page could not be read ($2)"; return 1;; esac; }
wait_up() { # port -> seconds waited via EL
  local i; for i in $(seq 1 400); do curl -sf "localhost:$1/healthz" >/dev/null 2>&1 && return 0; sleep 0.05; done; return 1
}

# =====================================================================================
# SCENARIO A: /first-15-minutes-build-cache/ steps 2 to 6
# =====================================================================================
scenario_a() { # rep variant(aswritten|localoff)
  local rep="$1" variant="$2"
  local D="$W/a${rep}-${variant}"
  mkdir -p "$D"; cd "$D"; clear_local_caches
  echo; echo "== A rep=${rep}/${REPS} variant=${variant}  (first-15-minutes, steps 2 to 6)"
  local T0 T1
  # step 2: download it and check it is ours
  run a-step2-download-verify "$D" <<EOF
VER=${VER}
PLATFORM=${PLATFORM}
gh release download v\${VER} --repo fosterstack/cache \\
  -p checksums.txt -p checksums.txt.bundle -p "fscache_\${VER}_\${PLATFORM}.tar.gz"
cosign verify-blob --bundle checksums.txt.bundle \\
  --certificate-identity-regexp='^https://github.com/fosterstack/cache/' \\
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' checksums.txt
sha256sum -c <(grep "fscache_\${VER}_\${PLATFORM}.tar.gz" checksums.txt | grep -v sbom)
EOF
  expect a-step2-download-verify "Verified OK" "fscache_${VER}_${PLATFORM}.tar.gz: OK"; A2=$EL
  # never unpack or start a release that did not verify
  if [ "$RC" != 0 ] || ! grep -qF "Verified OK" "$W/a-step2-download-verify.out"; then fail "A step 2: the release did not verify, so it is not unpacked or started"; return; fi
  [ -n "$VERIFIED_TARBALL" ] || VERIFIED_TARBALL="$D/fscache_${VER}_${PLATFORM}.tar.gz"
  # step 3: unpack it and start it with a password and a size cap (in the background; the time includes waiting until it answers)
  cat > "$D/start.sh" <<EOF
VER=${VER}
PLATFORM=${PLATFORM}
tar xzf fscache_\${VER}_\${PLATFORM}.tar.gz
FSCACHE_USERNAME=gradle FSCACHE_PASSWORD=${PASS_GRADLE} \\
FSCACHE_MAX_BYTES=1073741824 ./fscache
EOF
  T0=$(now); ( cd "$D" && exec bash -o pipefail "$D/start.sh" ) > "$D/server.log" 2>&1 &
  SERVER_PID=$!; SERVER_PORT="$PORT_A"
  if wait_up "$PORT_A"; then T1=$(now); A3=$(secs "$T0" "$T1"); printf 'STEP %-34s %7s s  server answers on %s\n' a-step3-unpack-start "$A3" "$PORT_A"; else fail "A step 3: the server did not answer on ${PORT_A}"; sed 's/^/    | /' "$D/server.log" | tail -5; stop_server; return; fi
  # step 4: check it is up
  run a-step4-healthz "$D" <<EOF
curl localhost:${PORT_A}/healthz
EOF
  expect a-step4-healthz "ok"
  grep -qx "ok" "$W/a-step4-healthz.out" || fail "A step 4: /healthz did not print a line that is exactly ok"
  run a-step4-statusz "$D" <<EOF
curl -u gradle:${PASS_GRADLE} localhost:${PORT_A}/statusz
EOF
  expect a-step4-statusz "\"version\": \"v${VER}\""
  # step 5: point Gradle at it (the page's snippet; 'localoff' adds the tutorial's line that turns Gradle's own cache off)
  T0=$(now)
  mkdir -p "$D/proj/src/main/java/demo"
  if [ "$variant" = aswritten ]; then
    cat > "$D/proj/settings.gradle.kts" <<'EOF'
rootProject.name = "demo"
// FosterStack Cache — remote Gradle build cache.
// https://github.com/fosterstack/cache
buildCache {
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:8080/")
        isPush = true
        credentials {
            username = "gradle"
            password = System.getenv("FSCACHE_PASSWORD")
        }
    }
}
EOF
  else
    cat > "$D/proj/settings.gradle.kts" <<'EOF'
rootProject.name = "demo"
// FosterStack Cache — remote Gradle build cache.
// https://github.com/fosterstack/cache
buildCache {
    local { isEnabled = false } // so a hit can only come from the remote
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:8080/")
        isPush = true
        credentials {
            username = "gradle"
            password = System.getenv("FSCACHE_PASSWORD")
        }
    }
}
EOF
  fi
  printf 'org.gradle.caching=true\n' > "$D/proj/gradle.properties"
  printf 'plugins { java }\n' > "$D/proj/build.gradle.kts"
  printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println("hello");\n    }\n}\n' > "$D/proj/src/main/java/demo/App.java"
  T1=$(now); A5=$(secs "$T0" "$T1"); printf 'STEP %-34s %7s s\n' a-step5-write-project-files "$A5"
  # step 6: build twice and look for FROM-CACHE (the page's three commands, each timed)
  run a-step6-build1 "$D/proj" <<EOF
export FSCACHE_PASSWORD=${PASS_GRADLE}
gradle build --build-cache
EOF
  expect a-step6-build1 "BUILD SUCCESSFUL" "> Task :compileJava"; B1=$EL
  grep -qF "> Task :compileJava FROM-CACHE" "$W/a-step6-build1.out" && { fail "A step 6: the FIRST build already said FROM-CACHE"; }
  echo "OBS ${variant} after build 1: server $(statusz "$PORT_A" gradle "$PASS_GRADLE")"
  run a-step6-clean "$D/proj" <<EOF
export FSCACHE_PASSWORD=${PASS_GRADLE}
gradle clean
EOF
  expect a-step6-clean "BUILD SUCCESSFUL"; B2=$EL
  run a-step6-build2 "$D/proj" <<EOF
export FSCACHE_PASSWORD=${PASS_GRADLE}
gradle build --build-cache
EOF
  expect a-step6-build2 "> Task :compileJava FROM-CACHE"; B3=$EL
  SZ="$(statusz "$PORT_A" gradle "$PASS_GRADLE")"
  echo "OBS ${variant} after build 2: server ${SZ}"
  if ! readable "$SZ" "A ${variant}, after build 2"; then echo "OBS no conclusion about where the second build restored from"; else
  case "$variant" in
    aswritten) case "$SZ" in *"hits=0"*) echo "OBS FINDING? page as written (Gradle's own cache left ON): the second build says FROM-CACHE but the server counted 0 hits: the hit came from the local cache, as the page's own sentence warns";; *) echo "OBS page as written (local cache ON): the server counted a hit too: ${SZ}";; esac;;
    localoff) case "$SZ" in "entries=1 hits=1 misses=1") echo "OBS page's recorded numbers confirmed with Gradle's local cache off: ${SZ}";; *) fail "A localoff: the page says one entry and one hit; the server says ${SZ}";; esac;;
  esac
  fi
  T_ALL=$(awk -v a="$A2" -v b="$A3" -v c="$A5" -v d="$B1" -v e="$B2" -v f="$B3" 'BEGIN{printf "%.2f", a+b+c+d+e+f}')
  echo "TABLE A rep=${rep} variant=${variant}: download+verify ${A2} s | unpack+start ${A3} s | write files ${A5} s | build ${B1} s + clean ${B2} s + build ${B3} s = $(awk -v a="$B1" -v b="$B2" -v c="$B3" 'BEGIN{printf "%.2f", a+b+c}') s | all steps ${T_ALL} s"
  "$GRADLE_BIN" --stop >/dev/null 2>&1 || true
  stop_server
}
GRADLE_BIN="$(command -v gradle)"
VERIFIED_TARBALL=""

# =====================================================================================
# SCENARIO B: /maven-remote-build-cache-setup/ steps 1 to 4
# =====================================================================================
scenario_b() { # rep
  local rep="$1"
  local D="$W/b${rep}" T0 T1
  mkdir -p "$D/proj/.mvn" "$D/proj/src/main/java/demo" "$D/server"
  echo; echo "== B rep=${rep}/${REPS}  (maven-remote-build-cache-setup, steps 1 to 4)"
  # a server for the page to talk to (the page assumes one exists: it is not part of the timed steps)
  [ -n "$VERIFIED_TARBALL" ] || { fail "B: no release has verified, so the Maven scenario is skipped"; return; }
  clear_local_caches
  tar -xzf "$VERIFIED_TARBALL" -C "$D/server" || { fail "B: could not unpack the verified release"; return; }
  ( cd "$D/server" && FSCACHE_ADDR="127.0.0.1:${PORT_B}" FSCACHE_USERNAME=maven FSCACHE_PASSWORD="$PASS_MAVEN" exec ./fscache ) > "$D/server.log" 2>&1 &
  SERVER_PID=$!; SERVER_PORT="$PORT_B"
  wait_up "$PORT_B" || { fail "B: the server did not answer on ${PORT_B}"; stop_server; return; }
  ORIGHOME="$HOME"; export HOME="$mvnhome"; mkdir -p "$HOME/.m2"
  export MAVEN_OPTS="-Duser.home=${mvnhome}"   # so that ~/.m2 means this empty folder (the JVM reads user.home from the account, not from $HOME)
  # step 1: add the extension
  T0=$(now)
  cat > "$D/proj/.mvn/extensions.xml" <<EOF
<extensions>
  <extension>
    <groupId>org.apache.maven.extensions</groupId>
    <artifactId>maven-build-cache-extension</artifactId>
    <version>${EXT_VER}</version>
  </extension>
</extensions>
EOF
  T1=$(now); M1=$(secs "$T0" "$T1"); printf 'STEP %-34s %7s s\n' b-step1-extension "$M1"
  # step 2: point it at the server and switch uploads on
  T0=$(now)
  cat > "$D/proj/.mvn/maven-build-cache-config.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<cache xmlns="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       xsi:schemaLocation="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0 https://maven.apache.org/xsd/build-cache-config-1.2.0.xsd">
  <configuration>
    <enabled>true</enabled>
    <!-- FosterStack Cache — remote Maven build cache.
         https://github.com/fosterstack/cache -->
    <remote enabled="true" saveToRemote="true" id="fosterstack-cache">
      <url>http://127.0.0.1:${PORT_B}/</url>
    </remote>
  </configuration>
</cache>
EOF
  T1=$(now); M2=$(secs "$T0" "$T1"); printf 'STEP %-34s %7s s\n' b-step2-config "$M2"
  # step 3: add the password
  T0=$(now)
  cat > "$HOME/.m2/settings.xml" <<EOF
<settings>
  <servers>
    <server>
      <id>fosterstack-cache</id>
      <username>maven</username>
      <password>${PASS_MAVEN}</password>
    </server>
  </servers>
</settings>
EOF
  T1=$(now); M3=$(secs "$T0" "$T1"); printf 'STEP %-34s %7s s\n' b-step3-password "$M3"
  # the project (the page shows none): one class, pinned plugin versions
  cat > "$D/proj/pom.xml" <<'EOF'
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
    <plugins>
      <plugin><artifactId>maven-resources-plugin</artifactId><version>3.3.1</version></plugin>
      <plugin><artifactId>maven-compiler-plugin</artifactId><version>3.13.0</version></plugin>
      <plugin><artifactId>maven-surefire-plugin</artifactId><version>3.5.2</version></plugin>
      <plugin><artifactId>maven-jar-plugin</artifactId><version>3.4.2</version></plugin>
    </plugins>
  </build>
</project>
EOF
  printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println("hello");\n    }\n}\n' > "$D/proj/src/main/java/demo/App.java"
  # step 4: build, then build again
  run b-step4-build1 "$D/proj" <<'EOF'
mvn package
EOF
  expect b-step4-build1 "Attempting to restore project demo:demo from build cache" "Saved to remote cache" "BUILD SUCCESS"; MB1=$EL
  grep -qE "Error downloading cache item|Cache item not found" "$W/b-step4-build1.out" || fail "B step 4: neither 'Error downloading cache item' nor 'Cache item not found' appeared on the first build (the page says one of them is the normal first miss)"
  echo "OBS after build 1: server $(statusz "$PORT_B" maven "$PASS_MAVEN")"
  echo "OBS where the extension keeps its local copy: $(find "$HOME/.m2" -maxdepth 2 -iname 'build-cache*' 2>/dev/null | head -3 | tr '\n' ' ') (the page's 'rm -rf target build-cache' is run in the project folder)"
  H0="$(statusz "$PORT_B" maven "$PASS_MAVEN")"
  run b-step4-build2-aswritten "$D/proj" <<'EOF'
rm -rf target build-cache # 'build-cache' is the extension's local folder, next to your local repository
mvn package
EOF
  expect b-step4-build2-aswritten "Found cached build, restoring demo:demo from cache by checksum" "BUILD SUCCESS"; MB2=$EL
  H1="$(statusz "$PORT_B" maven "$PASS_MAVEN")"
  echo "OBS second build as the page writes it: server before ${H0} / after ${H1}"
  if ! readable "$H0" "Maven build 2, before" || ! readable "$H1" "Maven build 2, after"; then echo "OBS no conclusion about where build 2 restored from";
  elif [ "$(hits_of "$H0")" = "$(hits_of "$H1")" ]; then echo "OBS FINDING? the page says deleting target and build-cache leaves 'the only copy ... on the server', but the server's hit counter did not move: this restore came from the local copy (the command was run in the project folder; the extension keeps its folder next to the local repository)"; else echo "OBS the server counted the restore: it came from the server"; fi
  # to be sure the server can serve it: delete the extension's real local folder too
  H0b="$(statusz "$PORT_B" maven "$PASS_MAVEN")"
  run b-step4-build3-localcopygone "$D/proj" <<'EOF'
rm -rf target "$HOME"/.m2/build-cache
mvn package
EOF
  expect b-step4-build3-localcopygone "Found cached build, restoring demo:demo from cache by checksum" "BUILD SUCCESS"; MB3=$EL
  H1b="$(statusz "$PORT_B" maven "$PASS_MAVEN")"
  echo "OBS third build, extension's local folder deleted too: server before ${H0b} / after ${H1b}"
  if readable "$H0b" "Maven build 3, before" && readable "$H1b" "Maven build 3, after"; then [ "$(hits_of "$H0b")" != "$(hits_of "$H1b")" ] || fail "B: with the extension's local folder deleted, the restore still did not come from the server (hit counter unchanged)"; fi
  echo "TABLE B rep=${rep}: add extension ${M1} s | config ${M2} s | password ${M3} s | build ${MB1} s | build again as written ${MB2} s | build with local copy gone ${MB3} s"
  stop_server
  export HOME="$ORIGHOME"; unset MAVEN_OPTS
}

# ---------- run ----------
for port in "$PORT_A" "$PORT_B"; do
  curl -sf "localhost:${port}/healthz" >/dev/null 2>&1 && { echo "something already answers on port ${port}: not starting" >&2; exit 1; }
done
for rep in $(seq 1 "$REPS"); do
  scenario_a "$rep" aswritten
  scenario_a "$rep" localoff
  scenario_b "$rep"
done
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL and STEP lines above)"
[ "$FAILS" = 0 ]
