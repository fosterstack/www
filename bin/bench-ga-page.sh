#!/usr/bin/env bash
# Helper for the "bench-ga-page" job of .github/workflows/hygiene.yml (manual dispatch only, choice "ga-page"): it runs the workflow steps of
# /github-actions-remote-build-cache/ ON A GITHUB-HOSTED RUNNER, as written, and checks what the cache server saw.
#
# What the JOB does (see the job in hygiene.yml): checkout, one step "setup" (this script), then for each case a step that sets the pretend
# event, THE PAGE'S OWN BUILD STEP, and a step that checks the result (this script). This script does not run the page's build steps itself.
#
# Subcommands: setup | event main|pr|fork | fresh gradle|maven | mutate gradle|maven | expect NAME | extra NAME | finish
# Each subcommand takes only fixed words from the workflow file; nothing from the event or the repository is interpolated into a command.
#
# What replaces what, because a workflow cannot get real secrets or real events here (disclosed in the output of "setup"):
#   - the five secrets are made-up values in the job's env (TEST_*), and the page's `secrets.X` becomes `env.TEST_X`
#   - `github.event_name == 'push'` becomes `env.TEST_EVENT == 'push'` (a manual dispatch is neither a push nor a pull request)
#   - the cache server runs on this runner (127.0.0.1) and is started by "setup", after its release is verified (cosign and sha256)
#   - the page's Gradle project (two modules) and Maven project are generated into the checkout / a sub folder, the Gradle wrapper
#     distribution is checked against a pinned sha256, and each case starts with an empty GRADLE_USER_HOME / local Maven build cache
set -uo pipefail

VER=0.2.2
PORT=18495
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
COSIGN_VER=3.1.3
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) PLAT=linux_amd64; COSIGN_ASSET=cosign-linux-amd64;  COSIGN_SHA=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71 ;;
  Darwin-arm64) PLAT=darwin_arm64; COSIGN_ASSET=cosign-darwin-arm64; COSIGN_SHA=5cf948c2f4dfe59687bdd0b8523709067383e03982cc543475c8a7dc70e92a76 ;;   # a developer's dry run
  *) echo "unsupported machine $(uname -sm)" >&2; exit 2 ;;
esac
EXT_VER=1.2.3
WS="${GITHUB_WORKSPACE:-$PWD}"
T="${RUNNER_TEMP:-/tmp}/gapage"; mkdir -p "$T"
# the server's logins live in a file written by "setup", so the checks can still read the server after a case blanks the TEST_* variables
if [ -f "$T/creds" ]; then . "$T/creds"; else RW_USER="${TEST_RW_USER:-ci}"; RW_PASS="${TEST_RW_PASSWORD:-}"; RO_USER="${TEST_RO_USER:-dev}"; RO_PASS="${TEST_RO_PASSWORD:-}"; fi
URL="http://127.0.0.1:${PORT}/"
FAILS_FILE="$T/fails"; touch "$FAILS_FILE"
fail() { printf 'FAIL %s\n' "$*"; printf '%s\n' "$*" >> "$FAILS_FILE"; }
sha256c() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
sha_check() { echo "$2  $1" | sha256c -c - >/dev/null || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }; }
statusz() { curl -s --max-time 30 -u "$RW_USER:$RW_PASS" "localhost:${PORT}/statusz" | python3 -c "import sys,json;d=json.load(sys.stdin);print('%s %s %s' % (d['store_entries'],d['cache_hits'],d['cache_misses']))" 2>/dev/null || echo "x x x"; }
snap() { read -r E H M <<< "$(statusz)"; echo "$E $H $M"; }
env_out() { [ -n "${GITHUB_ENV:-}" ] && printf '%s\n' "$1" >> "$GITHUB_ENV"; return 0; }

case "${1:-}" in
setup)
  [ -n "$RW_PASS" ] && [ -n "$RO_PASS" ] || { echo "the test logins are missing from the job env" >&2; exit 1; }
  printf 'RW_USER=%q\nRW_PASS=%q\nRO_USER=%q\nRO_PASS=%q\n' "$RW_USER" "$RW_PASS" "$RO_USER" "$RO_PASS" > "$T/creds"
  cd "$T"
  curl -fsSL -o cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VER}/${COSIGN_ASSET}"; sha_check cosign "$COSIGN_SHA"; chmod 0755 cosign
  curl -fsSL -o gr.zip "$GR_URL"; sha_check gr.zip "$GR_SHA"; unzip -q gr.zip
  mkdir -p rel && cd rel
  unset GH_TOKEN GITHUB_TOKEN
  gh release download "v${VER}" --repo fosterstack/cache -p checksums.txt -p checksums.txt.bundle -p "fscache_${VER}_${PLAT}.tar.gz" || { echo "release download failed" >&2; exit 1; }
  "$T/cosign" verify-blob --bundle checksums.txt.bundle --certificate-identity-regexp='^https://github.com/fosterstack/cache/' --certificate-oidc-issuer='https://token.actions.githubusercontent.com' checksums.txt 2>&1 | grep -q "Verified OK" || { echo "the release did not verify" >&2; exit 1; }
  sha256c -c <(grep "fscache_${VER}_${PLAT}.tar.gz" checksums.txt | grep -v sbom) || { echo "the release checksum failed" >&2; exit 1; }
  tar xzf "fscache_${VER}_${PLAT}.tar.gz"
  mkdir -p "$T/data"
  ( cd "$T" && FSCACHE_ADDR="127.0.0.1:${PORT}" FSCACHE_DATA_DIR="$T/data" FSCACHE_USERNAME="$RW_USER" FSCACHE_PASSWORD="$RW_PASS" FSCACHE_RO_USERNAME="$RO_USER" FSCACHE_RO_PASSWORD="$RO_PASS" nohup $(command -v setsid || true) "$T/rel/fscache" > "$T/server.log" 2>&1 & )
  for i in $(seq 1 100); do curl -sf --max-time 3 "localhost:${PORT}/healthz" >/dev/null 2>&1 && break; sleep 0.2; done
  curl -sf --max-time 3 "localhost:${PORT}/healthz" >/dev/null 2>&1 || { echo "the cache server did not start" >&2; cat "$T/server.log" >&2; exit 1; }
  # --- the Gradle project: the page's settings block, verbatim, plus what a project needs around it
  cd "$WS"
  mkdir -p lib/src/main/java/demo app/src/main/java/demo
  cat > settings.gradle.kts <<'EOF'
rootProject.name = "demo"
include("lib", "app")

buildCache {
    remote<HttpBuildCache> {
        val cacheUrl = providers.environmentVariable("CACHE_URL").orNull
        isEnabled = !cacheUrl.isNullOrBlank()
        if (!cacheUrl.isNullOrBlank()) {
            url = uri(cacheUrl)
        }
        isPush = providers.environmentVariable("CACHE_PUSH").orNull == "true"
        credentials {
            username = providers.environmentVariable("CACHE_USER").orNull
            password = providers.environmentVariable("CACHE_PASSWORD").orNull
        }
    }
}
EOF
  printf 'org.gradle.caching=true\n' > gradle.properties
  printf 'plugins { java }\n' > lib/build.gradle.kts
  printf 'plugins { java }\ndependencies { implementation(project(":lib")) }\n' > app/build.gradle.kts
  printf 'package demo;\n\npublic class Lib {\n    public static String name() { return "lib"; }\n}\n' > lib/src/main/java/demo/Lib.java
  printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println(Lib.name() + " app 1");\n    }\n}\n' > app/src/main/java/demo/App.java
  J21="${JAVA_HOME_21_X64:-${JAVA_HOME:-$(/usr/libexec/java_home -v 21 2>/dev/null)}}"
  JAVA_HOME="$J21" "$T/gradle-${GR_VER}/bin/gradle" wrapper --gradle-version "$GR_VER" --distribution-type all --gradle-distribution-sha256-sum "$GR_SHA" >/dev/null 2>&1 || { echo "could not create the wrapper" >&2; exit 1; }
  # first fill of the wrapper distribution, kept so that each case does not download it again
  export GRADLE_USER_HOME="$T/gh-seed"; JAVA_HOME="$J21" ./gradlew --version >/dev/null 2>&1 || { echo "wrapper download failed" >&2; exit 1; }
  rm -rf "$T/dists"; mkdir -p "$T/dists"; cp -R "$T/gh-seed/wrapper/dists" "$T/dists/"; rm -rf "$T/gh-seed"
  # --- the Maven project: the page's three files, verbatim
  mkdir -p mproj/.mvn mproj/src/main/java/demo mproj/src/test/java/demo
  cat > mproj/.mvn/maven-build-cache-config.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<cache xmlns="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       xsi:schemaLocation="http://maven.apache.org/BUILD-CACHE-CONFIG/1.2.0 https://maven.apache.org/xsd/build-cache-config-1.2.0.xsd">
  <configuration>
    <enabled>true</enabled>
    <remote enabled="false" id="fosterstack-cache">
      <url>https://cache.example.com/</url>
    </remote>
  </configuration>
</cache>
EOF
  cat > mproj/.mvn/ci-settings.xml <<'EOF'
<settings>
  <servers>
    <server>
      <id>fosterstack-cache</id>
      <username>${env.CACHE_USER}</username>
      <password>${env.CACHE_PASSWORD}</password>
    </server>
  </servers>
</settings>
EOF
  cat > mproj/.mvn/extensions.xml <<EOF
<extensions>
  <extension>
    <groupId>org.apache.maven.extensions</groupId>
    <artifactId>maven-build-cache-extension</artifactId>
    <version>${EXT_VER}</version>
  </extension>
</extensions>
EOF
  cat > mproj/pom.xml <<'EOF'
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
  printf 'package demo;\n\npublic class App {\n    public static String hello() { return "hello 1"; }\n}\n' > mproj/src/main/java/demo/App.java
  printf 'package demo;\n\nimport static org.junit.jupiter.api.Assertions.assertTrue;\nimport org.junit.jupiter.api.Test;\n\nclass AppTest {\n    @Test void startsWithHello() { assertTrue(App.hello().startsWith("hello")); }\n    @Test void isNotEmpty() { assertTrue(App.hello().length() > 0); }\n}\n' > mproj/src/test/java/demo/AppTest.java
  # --- instrumentation that changes nothing in the page's steps: a Gradle init script that logs each task's outcome, and Maven's own log file
  env_out "JAVA_HOME=$J21"
  env_out "GRADLE_USER_HOME=$T/gh"
  env_out "TASK_LOG=$T/tasks.log"
  env_out "MAVEN_ARGS=-l $T/mvn.log"
  mkdir -p "$T/init"
  cat > "$T/init/log-tasks.gradle" <<'EOF'
gradle.taskGraph.afterTask { t ->
    def f = System.getenv('TASK_LOG')
    if (f) { new File(f).append(t.path + ' ' + (t.state.skipMessage ?: (t.state.didWork ? 'EXECUTED' : 'NO-WORK')) + '\n') }
}
EOF
  echo "== DISCLOSURE"
  echo "runner: $(uname -sr); image: ${ImageOS:-?} ${ImageVersion:-?}; cpus: $(nproc 2>/dev/null || sysctl -n hw.ncpu)"
  echo "java: $("$J21/bin/java" -version 2>&1 | head -1)   maven (the runner's own): $(mvn -v 2>/dev/null | head -1)"
  echo "release under test: FosterStack Cache ${VER}, downloaded with no login and verified (cosign + sha256) before it was started; Gradle ${GR_VER} (sha256 pinned, wrapper distribution checked by the wrapper); cosign ${COSIGN_VER} (sha256 pinned)"
  echo "NOT checksum-pinned: the Maven build-cache extension ${EXT_VER}, the Maven plugin jars (versions pinned in the pom, files from Maven Central), JUnit 5.11.4, the runner's own Maven"
  echo "replaced in the page's workflow step: secrets.X -> env.TEST_X (made-up logins in the job's env), github.event_name == 'push' -> env.TEST_EVENT == 'push' (a manual dispatch is neither a push nor a pull request); working-directory for the Maven step; the Gradle project (two modules) and the Maven project are generated; each case starts with an empty GRADLE_USER_HOME (the wrapper distribution is copied back) and an empty local Maven build cache, so a hit can only come from the server"
  echo "NOT exercised from the page's workflow file: its name, the on: triggers (push to main, pull_request), the workflow-level permissions: contents: read (this job inherits the bench workflow's own), the job name, and the fact that the checkout there is the project itself (here it is this repository; the Gradle and Maven projects are written in afterwards)"
  echo "the Maven results depend on the runner's own Maven version (the page's tests used 3.9.9): the 'flags with an empty address' case is only asserted on Maven 3.9.x; on another version it is reported"
  echo "instrumentation: a Gradle init script logs each task's outcome to a file (no change to the page's step) and MAVEN_ARGS=-l writes Maven's log to a file"
  echo "NOT tested here: real secrets, a runner reaching a server on another network, a real fork pull request, other Maven versions"
  snap > "$T/last"; echo "server at the start: entries/hits/misses = $(cat "$T/last")"
  ;;
event)
  case "${2:-}" in
    main|pr) env_out "TEST_EVENT=$([ "$2" = main ] && echo push || echo pull_request)"; env_out "TEST_CACHE_URL=$URL"; env_out "TEST_RW_USER=$RW_USER"; env_out "TEST_RW_PASSWORD=$RW_PASS"; env_out "TEST_RO_USER=$RO_USER"; env_out "TEST_RO_PASSWORD=$RO_PASS" ;;
    fork) env_out "TEST_EVENT=pull_request"; env_out "TEST_CACHE_URL="; env_out "TEST_RO_USER="; env_out "TEST_RO_PASSWORD="; env_out "TEST_RW_USER="; env_out "TEST_RW_PASSWORD=" ;;
    *) echo "event main|pr|fork" >&2; exit 2 ;;
  esac
  ;;
fresh)
  case "${2:-}" in
    gradle)
      cd "$WS"; rm -rf "$T/gh" lib/build app/build build .gradle; mkdir -p "$T/gh/init.d" "$T/gh/wrapper"; cp -R "$T/dists/dists" "$T/gh/wrapper/"
      cp "$T/init/log-tasks.gradle" "$T/gh/init.d/"; : > "$T/tasks.log"
      printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println(Lib.name() + " app 1");\n    }\n}\n' > app/src/main/java/demo/App.java ;;
    maven)
      rm -rf "$HOME/.m2/build-cache" "$WS/mproj/target"; : > "$T/mvn.log"
      printf 'package demo;\n\npublic class App {\n    public static String hello() { return "hello 1"; }\n}\n' > "$WS/mproj/src/main/java/demo/App.java" ;;
    *) echo "fresh gradle|maven" >&2; exit 2 ;;
  esac
  ;;
mutate)
  case "${2:-}" in
    gradle) printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println(Lib.name() + " app 2");\n    }\n}\n' > "$WS/app/src/main/java/demo/App.java" ;;
    maven)  printf 'package demo;\n\npublic class App {\n    public static String hello() { return "hello 2"; }\n}\n' > "$WS/mproj/src/main/java/demo/App.java" ;;
    *) echo "mutate gradle|maven" >&2; exit 2 ;;
  esac
  ;;
expect)
  [ -f "$T/last" ] || { echo "setup did not finish: no server snapshot" >&2; exit 1; }
  read -r E0 H0 M0 < "$T/last"; read -r E1 H1 M1 <<< "$(snap)"; echo "server: entries ${E0} -> ${E1}, hits ${H0} -> ${H1}, misses ${M0} -> ${M1}"
  DE=$((E1-E0)); DH=$((H1-H0)); LOG="$T/tasks.log"; ML="$T/mvn.log"
  outcome() { grep -E "^$1 " "$LOG" | tail -1 | cut -d' ' -f2; }
  case "${2:-}" in
    gradle-main1) [ "$(outcome :lib:compileJava)" = EXECUTED ] && [ "$(outcome :app:compileJava)" = EXECUTED ] || fail "main build 1: both compile tasks should have run ($(grep compileJava "$LOG" | tr '\n' ';'))"
                  [ "$DE" -gt 0 ] || fail "main build 1: nothing was stored on the server"; [ "$DH" = 0 ] || fail "main build 1: the server counted $DH hits on an empty cache" ;;
    gradle-main2) [ "$(outcome :lib:compileJava)" = FROM-CACHE ] && [ "$(outcome :app:compileJava)" = FROM-CACHE ] || fail "main build 2 (fresh checkout): both compile tasks should come from the cache ($(grep compileJava "$LOG" | tr '\n' ';'))"
                  [ "$DH" -gt 0 ] || fail "main build 2: FROM-CACHE but the server counted no hit"; [ "$DE" = 0 ] || fail "main build 2: the server stored $DE new entries on a repeat build" ;;
    gradle-pr)    [ "$(outcome :lib:compileJava)" = FROM-CACHE ] || fail "pull request: the unchanged module should come from the cache ($(grep compileJava "$LOG" | tr '\n' ';'))"
                  [ "$(outcome :app:compileJava)" = EXECUTED ] || fail "pull request: the changed module should have run"
                  [ "$DE" = 0 ] || fail "pull request: the read-only login stored $DE entries" ;;
    gradle-fork)  [ "$(outcome :lib:compileJava)" = EXECUTED ] && [ "$(outcome :app:compileJava)" = EXECUTED ] || fail "fork pull request: both compile tasks should have run without the cache ($(grep compileJava "$LOG" | tr '\n' ';'))"
                  [ "$DE" = 0 ] && [ "$DH" = 0 ] && [ "$((M1-M0))" = 0 ] || fail "fork pull request: the server saw requests (entries $DE, hits $DH, misses $((M1-M0)))" ;;
    mvn-main1)    [ "$DE" -gt 0 ] || fail "Maven main build 1: nothing was stored on the server"; grep -q "Saved to remote cache" "$ML" || fail "Maven main build 1: no 'Saved to remote cache' line in Maven's log" ;;
    mvn-main2)    grep -q "Found cached build, restoring demo:mtest from cache by checksum" "$ML" || fail "Maven main build 2: it did not restore from the cache"
                  [ "$DH" -gt 0 ] || fail "Maven main build 2: restored but the server counted no hit"; grep -q "Compiling" "$ML" && fail "Maven main build 2: it compiled" ;;
    mvn-pr)       grep -q "Compiling" "$ML" || fail "Maven pull request: the changed module should have been built"
                  [ "$DE" = 0 ] || fail "Maven pull request: the read-only login stored $DE entries" ;;
    mvn-fork)     grep -qE "BUILD SUCCESS" "$ML" || fail "Maven fork pull request: no BUILD SUCCESS in Maven's log"
                  [ "$DE" = 0 ] && [ "$DH" = 0 ] && [ "$((M1-M0))" = 0 ] || fail "Maven fork pull request: the server saw requests (entries $DE, hits $DH, misses $((M1-M0)))" ;;
    *) echo "unknown expectation" >&2; exit 2 ;;
  esac
  case "${2:-}" in mvn-*) echo "---- Maven's log of this case (last 70 lines) ----"; tail -n 70 "$ML"; echo "---- end of Maven's log ----";; gradle-*) echo "---- Gradle task outcomes of this case ----"; cat "$LOG"; echo "---- end ----";; esac
  echo "$E1 $H1 $M1" > "$T/last"; echo "checked: ${2}"
  ;;
extra)
  cd "$WS"; export JAVA_HOME="${JAVA_HOME:-${JAVA_HOME_21_X64:-}}"
  gradle_extra() { # NAME USER PASS PUSH URL  -- the page's variables set by hand, ./gradlew build, log kept
    local name="$1" gh="$T/gh-$1"
    rm -rf "$gh" lib/build app/build build .gradle; mkdir -p "$gh/wrapper"; cp -R "$T/dists/dists" "$gh/wrapper/"
    ( CACHE_URL="$5" CACHE_USER="$2" CACHE_PASSWORD="$3" CACHE_PUSH="$4" GRADLE_USER_HOME="$gh" ./gradlew build ) > "$T/$name.out" 2>&1
    echo "extra ${name}: exit $?"
  }
  case "${2:-}" in
    gradle-403)  read -r E0 _ _ <<< "$(snap)"; printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println(Lib.name() + " app 3");\n    }\n}\n' > app/src/main/java/demo/App.java
                 gradle_extra g403 "$RO_USER" "$RO_PASS" true "$URL"; read -r E1 _ _ <<< "$(snap)"
                 case "$E0$E1" in *[!0-9]*|'') fail "read-only login with push on: the server's entry count could not be read ($E0 / $E1)";; esac
                 grep -q "BUILD SUCCESSFUL" "$T/g403.out" || fail "read-only login with push on: the build should still succeed"
                 grep -q "response status 403: Forbidden" "$T/g403.out" || fail "read-only login with push on: no 'response status 403: Forbidden' line"
                 grep -q "The remote build cache was disabled during the build due to errors." "$T/g403.out" || fail "read-only login with push on: no 'remote build cache was disabled' line"
                 [ "$E1" = "$E0" ] || fail "read-only login with push on: the server stored entries ($E0 -> $E1)"; echo "checked: gradle-403"; snap > "$T/last" ;;
    gradle-401)  gradle_extra g401 "$RW_USER" "wrong-password" false "$URL"
                 grep -q "BUILD SUCCESSFUL" "$T/g401.out" || fail "wrong password: the build should still succeed"
                 grep -q "response status 401: Unauthorized" "$T/g401.out" || fail "wrong password: no 'response status 401: Unauthorized' line"; echo "checked: gradle-401"; snap > "$T/last" ;;
    gradle-empty-login) gradle_extra gempty "" "" false "$URL"
                 grep -q "BUILD SUCCESSFUL" "$T/gempty.out" || fail "empty login with an address set: the build should still succeed"
                 grep -q "response status 401: Unauthorized" "$T/gempty.out" || fail "empty login with an address set: no 401 line"; echo "checked: gradle-empty-login"; snap > "$T/last" ;;
    mvn-empty-url) cd "$WS/mproj"; rm -rf "$HOME/.m2/build-cache" target
                 MAVEN_ARGS= CACHE_USER="$RW_USER" CACHE_PASSWORD="$RW_PASS" mvn -B -s .mvn/ci-settings.xml -Dmaven.build.cache.remote.enabled=true -Dmaven.build.cache.remote.url="" -Dmaven.build.cache.remote.save.enabled=false verify > "$T/mempty.out" 2>&1; echo "extra mvn-empty-url: exit $?"
                 MV="$(MAVEN_ARGS= mvn -v 2>/dev/null | head -1)"; echo "Maven here: ${MV}"
                 case "$MV" in
                   *"Apache Maven 3.9."*) grep -q "NoTransporterException" "$T/mempty.out" && echo "OBS flags with an empty address: Maven stopped with NoTransporterException, as the page says" || fail "flags with an empty address: no NoTransporterException on ${MV} (the page says Maven stops with an internal error)" ;;
                   *) echo "OBS flags with an empty address on ${MV} (not 3.9.x): $(grep -m1 -E 'NoTransporter|ERROR|BUILD' "$T/mempty.out" | cut -c1-200)" ;;
                 esac
                 tail -n 25 "$T/mempty.out"; echo "checked: mvn-empty-url" ;;
    mvn-403)     cd "$WS/mproj"; rm -rf "$HOME/.m2/build-cache" target; printf 'package demo;\n\npublic class App {\n    public static String hello() { return "hello 3"; }\n}\n' > src/main/java/demo/App.java
                 read -r E0 _ _ <<< "$(snap)"
                 MAVEN_ARGS= CACHE_USER="$RO_USER" CACHE_PASSWORD="$RO_PASS" mvn -B -s .mvn/ci-settings.xml -Dmaven.build.cache.remote.enabled=true -Dmaven.build.cache.remote.url="$URL" -Dmaven.build.cache.remote.save.enabled=true verify > "$T/m403.out" 2>&1; echo "extra mvn-403: exit $?"
                 read -r E1 _ _ <<< "$(snap)"
                 grep -q "BUILD SUCCESS" "$T/m403.out" || fail "Maven, read-only login with saving on: the build should still succeed"
                 [ "$(grep -c 'Unable to save to remote cache' "$T/m403.out")" -ge 1 ] || fail "Maven, read-only login with saving on: no 'Unable to save to remote cache' line"
                 MV="$(MAVEN_ARGS= mvn -v 2>/dev/null | head -1)"
                 case "$MV" in
                   *"Apache Maven 3.9."*) grep -qE "status code: 403, reason phrase: Forbidden" "$T/m403.out" || fail "Maven 3.9.x, read-only login with saving on: no 'status code: 403, reason phrase: Forbidden' line (the page shows it)" ;;
                   *) grep -q "403" "$T/m403.out" && echo "OBS Maven here is ${MV} (not 3.9.x): the 403 shows as: $(grep -m1 -E 'Unable to save|403' "$T/m403.out" | cut -c1-220)" || fail "Maven ${MV}, read-only login with saving on: no 403 anywhere in the log" ;;
                 esac
                 [ "$E1" = "$E0" ] || fail "Maven, read-only login with saving on: the server stored entries ($E0 -> $E1)"
                 echo "OBS 'Unable to save to remote cache' lines: $(grep -c 'Unable to save to remote cache' "$T/m403.out") (the page says 3)"; echo "checked: mvn-403"; snap > "$T/last" ;;
    mvn-missing-login) cd "$WS/mproj"; rm -rf "$HOME/.m2/build-cache" target; printf 'package demo;\n\npublic class App {\n    public static String hello() { return "hello 1"; }\n}\n' > src/main/java/demo/App.java
                 ( unset CACHE_USER CACHE_PASSWORD; MAVEN_ARGS= mvn -B -s .mvn/ci-settings.xml -Dmaven.build.cache.remote.enabled=true -Dmaven.build.cache.remote.url="$URL" -Dmaven.build.cache.remote.save.enabled=false verify > "$T/mmissing.out" 2>&1 ); echo "extra mvn-missing-login: exit $?"
                 grep -q "BUILD SUCCESS" "$T/mmissing.out" || fail "Maven with a missing login: the build should still succeed"
                 grep -q "Error downloading cache item" "$T/mmissing.out" || fail "Maven with a missing login: no 'Error downloading cache item' line"; echo "checked: mvn-missing-login"; snap > "$T/last" ;;
    mvn-wrong-password) cd "$WS/mproj"; rm -rf "$HOME/.m2/build-cache" target
                 MAVEN_ARGS= CACHE_USER="$RW_USER" CACHE_PASSWORD="wrong-password" mvn -B -s .mvn/ci-settings.xml -Dmaven.build.cache.remote.enabled=true -Dmaven.build.cache.remote.url="$URL" -Dmaven.build.cache.remote.save.enabled=false verify > "$T/mwrong.out" 2>&1; echo "extra mvn-wrong-password: exit $?"
                 grep -q "BUILD SUCCESS" "$T/mwrong.out" || fail "Maven with a wrong password: the build should still succeed"
                 grep -q "Error downloading cache item" "$T/mwrong.out" || fail "Maven with a wrong password: no 'Error downloading cache item' line"; echo "checked: mvn-wrong-password"; snap > "$T/last" ;;
    *) echo "unknown extra" >&2; exit 2 ;;
  esac
  case "${2:-}" in mvn-*) for f in mempty m403 mmissing mwrong; do [ -f "$T/$f.out" ] && { echo "---- tail of $f.out ----"; tail -n 15 "$T/$f.out"; }; done ;; esac
  ;;
finish)
  curl -s --max-time 5 -o /dev/null "localhost:${PORT}/healthz"; pkill -f "$T/rel/fscache" 2>/dev/null || true
  if [ -s "$FAILS_FILE" ]; then echo "FAILURES $(wc -l < "$FAILS_FILE")"; cat "$FAILS_FILE"; echo "== AT LEAST ONE CHECK FAILED"; exit 1; fi
  echo "FAILURES 0"; echo "== NO CHECK FAILED (a failed or skipped earlier step still turns the job red)"
  ;;
*) echo "usage: $0 setup|event|fresh|mutate|expect|extra|finish" >&2; exit 2 ;;
esac
