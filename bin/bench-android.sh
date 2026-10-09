#!/usr/bin/env bash
# What does the Gradle remote build cache restore in an Android build? Run on a GitHub-hosted runner by the "bench-android" job of
# .github/workflows/hygiene.yml (manual dispatch only). This script measures NO times: it records, task by task, what Gradle did.
#
# Project (generated here): an Android library module (lib: Kotlin + one Java file) and an Android application module (app: Kotlin,
# depends on lib), built with `assembleDebug`. Kotlin is compiled by the Android Gradle plugin's built-in Kotlin support (AGP 9.x).
# Per scenario there is a NEW empty FosterStack Cache server on 127.0.0.1:
#   repeat  build 1 stores; build 2 is a fresh copy of the same project
#   body    build 1 stores; build 2 is a fresh copy with a body-only change in lib
#   api     build 1 stores; build 2 is a fresh copy with a new public function in lib
# Every build uses a fresh copy of the project and Gradle's local build cache is switched off. ONE shared Gradle home keeps downloads
# (Gradle distribution is separate; AGP and its dependencies come from Google's Maven repository, Maven Central and the Gradle plugin
# portal at run time and are NOT checksum-pinned here; the Android SDK is the one preinstalled on the runner and is not downloaded).
# The shared home was filled first by one throwaway build with the build cache off. It also keeps Gradle's artifact-transform results.
set -euo pipefail

FS_VER=0.2.1
FS_URL="https://github.com/fosterstack/cache/releases/download/v${FS_VER}/fscache_${FS_VER}_linux_amd64.tar.gz"
FS_SHA=7d464d7926cdc0c10636dde754e23a37fc6518e341465c67f58fe88a617aaf6a   # checksums.txt of release v0.2.1
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf   # services.gradle.org/distributions/gradle-9.8.0-all.zip.sha256
AGP_VER="${BENCH_AGP:-9.4.1}"      # AGP 9.4 needs Gradle >= 9.6.0, SDK Build Tools >= 36.0.0, JDK >= 17, API level <= 37 (developer.android.com release notes)
LIMIT="${BENCH_LIMIT:-1500}"       # seconds allowed per build before it is stopped and recorded as TIMEOUT
PORT=18495
WORK="$(mktemp -d)"
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"; true' EXIT
cd "$WORK"

sha_check() { # file expected
  local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1)"
  [ "$got" = "$2" ] || { echo "CHECKSUM MISMATCH for $1: $got" >&2; exit 1; }
}

# ---- tools (BENCH_FSCACHE_BIN / BENCH_GRADLE_BIN let a developer test the script locally without downloads)
if [ -n "${BENCH_FSCACHE_BIN:-}" ]; then FSCACHE="$BENCH_FSCACHE_BIN"; else
  curl -fsSL "$FS_URL" -o fs.tgz; sha_check fs.tgz "$FS_SHA"; mkdir fs && tar -xzf fs.tgz -C fs; FSCACHE="$WORK/fs/fscache"
fi
if [ -n "${BENCH_GRADLE_BIN:-}" ]; then GRADLE="$BENCH_GRADLE_BIN"; else
  curl -fsSL "$GR_URL" -o gr.zip; sha_check gr.zip "$GR_SHA"; unzip -q gr.zip; GRADLE="$WORK/gradle-${GR_VER}/bin/gradle"
fi
JAVA_HOME="${BENCH_JAVA_HOME:-${JAVA_HOME_21_X64:-${JAVA_HOME:-}}}"; export JAVA_HOME
[ -x "$JAVA_HOME/bin/java" ] || { echo "no usable Java (JAVA_HOME=$JAVA_HOME)" >&2; exit 1; }

# ---- the Android SDK that is already on the runner (never downloaded here)
SDK="${BENCH_ANDROID_HOME:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}}"
[ -n "$SDK" ] && [ -d "$SDK/platforms" ] || { echo "no Android SDK found (ANDROID_HOME=${ANDROID_HOME:-unset}, ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-unset})" >&2; exit 1; }
export ANDROID_HOME="$SDK"
PLATFORMS="$(ls "$SDK/platforms" | sort -V | tr '\n' ' ')"
BTOOLS="$(ls "$SDK/build-tools" 2>/dev/null | sort -V | tr '\n' ' ')"
# compileSdk: the highest installed whole-number platform that AGP 9.4 supports (<= 37); build tools: the highest installed >= 36.0.0
COMPILE_SDK="$( (ls "$SDK/platforms" | grep -E '^android-[0-9]+$' | sed 's/android-//' | awk '$1<=37' | sort -n | tail -1) || true)"
BUILD_TOOLS="$( (ls "$SDK/build-tools" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | awk -F. '$1>=36' | tail -1) || true)"
[ -n "$COMPILE_SDK" ] || { echo "no usable platform in $SDK/platforms: $PLATFORMS" >&2; exit 1; }
[ -n "$BUILD_TOOLS" ] || { echo "no SDK build-tools >= 36.0.0 in $SDK/build-tools: $BTOOLS" >&2; exit 1; }

# ---- disclosure
echo "== runner"; uname -sr; echo "cpus (nproc): $(nproc 2>/dev/null || sysctl -n hw.ncpu)"
(lscpu 2>/dev/null | grep -E 'Model name' || true); (free -m 2>/dev/null | sed -n 2p || true)
echo "image: ${ImageOS:-?} ${ImageVersion:-?}   runner: ${RUNNER_NAME:-?} (${RUNNER_ENVIRONMENT:-?})"
echo "java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
if [ -n "${BENCH_FSCACHE_BIN:-}${BENCH_GRADLE_BIN:-}" ]; then echo "tools: LOCAL OVERRIDES in use, downloads not checked"; else echo "gradle: ${GR_VER} (distribution checked against pinned sha256)   fscache: v${FS_VER} (checked against checksums.txt value)"; fi
echo "android sdk: $SDK"; echo "  platforms installed: $PLATFORMS"; echo "  build-tools installed: $BTOOLS"
echo "  used: compileSdk $COMPILE_SDK, build-tools $BUILD_TOOLS, Android Gradle plugin $AGP_VER (downloaded at run time, not checksum-pinned)"
echo "per-build limit: ${LIMIT} s; no times are measured by this script"

# ---- project generator
mkproj() { # dir variant(base|body|api)
  local d="$1" v="$2" ret=1 extra=""
  [ "$v" = body ] && ret=2
  [ "$v" = api ] && extra="
    fun extra(): Int = 3"
  mkdir -p "$d/lib/src/main/kotlin/bench/lib" "$d/lib/src/main/java/bench/lib" "$d/app/src/main/kotlin/bench/app"
  cat > "$d/settings.gradle.kts" <<EOT
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "benchandroid"
include(":lib", ":app")

buildCache {
    local { isEnabled = false }
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:$PORT/")
        isPush = true
        isAllowInsecureProtocol = true
    }
}
EOT
  printf 'org.gradle.caching=true\norg.gradle.jvmargs=-Xmx3g -Dfile.encoding=UTF-8\nandroid.useAndroidX=false\n' > "$d/gradle.properties"
  printf 'plugins {\n    id("com.android.library") version "%s" apply false\n    id("com.android.application") version "%s" apply false\n}\n' "$AGP_VER" "$AGP_VER" > "$d/build.gradle.kts"
  cat > "$d/lib/build.gradle.kts" <<EOT
plugins { id("com.android.library") }

android {
    namespace = "bench.lib"
    compileSdk = $COMPILE_SDK
    buildToolsVersion = "$BUILD_TOOLS"
    defaultConfig { minSdk = 24 }
}
EOT
  cat > "$d/app/build.gradle.kts" <<EOT
plugins { id("com.android.application") }

android {
    namespace = "bench.app"
    compileSdk = $COMPILE_SDK
    buildToolsVersion = "$BUILD_TOOLS"
    defaultConfig {
        applicationId = "bench.app"
        minSdk = 24
        targetSdk = $COMPILE_SDK
        versionCode = 1
        versionName = "1.0"
    }
}

dependencies { implementation(project(":lib")) }
EOT
  printf '<?xml version="1.0" encoding="utf-8"?>\n<manifest xmlns:android="http://schemas.android.com/apk/res/android" />\n' > "$d/lib/src/main/AndroidManifest.xml"
  printf '<?xml version="1.0" encoding="utf-8"?>\n<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n    <application android:label="bench" />\n</manifest>\n' > "$d/app/src/main/AndroidManifest.xml"
  printf 'package bench.lib\n\nclass Lib {\n    fun base(): Int = %s%s\n}\n' "$ret" "$extra" > "$d/lib/src/main/kotlin/bench/lib/Lib.kt"
  printf 'package bench.lib;\n\npublic class JavaPart {\n    public int one() { return 1; }\n}\n' > "$d/lib/src/main/java/bench/lib/JavaPart.java"
  printf 'package bench.app\n\nimport bench.lib.Lib\n\nclass App {\n    fun total(): Int = Lib().base() + 10\n}\n' > "$d/app/src/main/kotlin/bench/app/App.kt"
}

start_server() { # datadir
  FSCACHE_ADDR="127.0.0.1:$PORT" FSCACHE_DATA_DIR="$1" "$FSCACHE" >"$WORK/server.log" 2>&1 & SRV_PID=$!
  for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null && return 0; sleep 0.2; done
  echo "server did not start" >&2; exit 1
}
stop_server() { if [ -n "$SRV_PID" ]; then kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; fi; SRV_PID=""; }

# dry run for a developer without an Android SDK: only the generator and the server are exercised
if [ -n "${BENCH_DRY_RUN:-}" ]; then
  mkproj "$WORK/dry" base; start_server "$WORK/data-dry"; echo "dry run: generated files:"; (cd "$WORK/dry" && find . -type f | sort); stop_server; exit 0
fi

SHARED="$WORK/shared-gradle-home"
# run one build with a time limit; never exits the script. Result: $WORK/last.txt = "outcome"; per-task lines in $WORK/tasks-<id>.txt
run_build() { # dir cache(on|off) id
  local dir="$1" cache="$2" id="$3" flag out="$WORK/log-$3.txt" outcome rc=0 pid wpid
  flag="--no-build-cache"; [ "$cache" = on ] && flag="--build-cache"
  (cd "$dir" && GRADLE_USER_HOME="$SHARED" exec "$GRADLE" assembleDebug $flag --no-daemon --console=plain >"$out" 2>&1) &
  pid=$!
  ( sleep "$LIMIT"; kill "$pid" 2>/dev/null ) & wpid=$!
  wait "$pid" || rc=$?
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  if grep -q 'BUILD SUCCESSFUL' "$out"; then outcome=OK; elif grep -q 'BUILD FAILED' "$out"; then outcome=FAILED; elif [ "$rc" = 143 ] || [ "$rc" = 137 ]; then outcome=TIMEOUT; else outcome=CRASHED; fi
  grep -E '^> Task ' "$out" | sed 's/^> Task //' > "$WORK/tasks-$id.txt" || true
  echo "$outcome" > "$WORK/last.txt"
}
need_ok() { # id: abort the script with the tail of the log if the build did not succeed
  local o; o="$(cat "$WORK/last.txt")"
  [ "$o" = OK ] || { echo "build $1 ended $o; last lines:" >&2; tail -40 "$WORK/log-$1.txt" >&2; exit 1; }
}

# throwaway build to fill the shared Gradle home with downloads (build cache off)
echo; echo "== warm-up (downloads only, build cache off)"
mkproj "$WORK/warm" base; run_build "$WORK/warm" off warm; need_ok warm; echo "warm-up: $(cat "$WORK/last.txt"), $(wc -l < "$WORK/tasks-warm.txt" | tr -d ' ') tasks"

for sc in repeat body api; do
  start_server "$WORK/data-$sc"
  case "$sc" in repeat) v=base;; body) v=body;; api) v=api;; esac
  echo; echo "== scenario: $sc (new empty cache server)"
  mkproj "$WORK/$sc-1" base; run_build "$WORK/$sc-1" on "$sc-1"; need_ok "$sc-1"
  mkproj "$WORK/$sc-2" "$v"; run_build "$WORK/$sc-2" on "$sc-2"; need_ok "$sc-2"
  stop_server
  echo "$sc: build 1 and build 2 ended OK"
done

# ---- results: every task, what Gradle did in build 1 and in build 2 of each scenario
echo; echo "== results (what Gradle did with each task; no times)"
python3 - "$WORK" <<'PY' | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
import sys, re, collections
w = sys.argv[1]
def load(i):
    out = collections.OrderedDict()
    for line in open(f"{w}/tasks-{i}.txt"):
        m = re.match(r"(\S+)(?: (\S[^\n]*))?$", line.strip())
        if m: out[m.group(1)] = (m.group(2) or "executed")
    return out
for sc in ("repeat", "body", "api"):
    b1, b2 = load(f"{sc}-1"), load(f"{sc}-2")
    c1, c2 = collections.Counter(b1.values()), collections.Counter(b2.values())
    print(f"\n### scenario {sc}\n")
    print("| build | tasks | " + " | ".join(sorted(set(c1) | set(c2))) + " |")
    keys = sorted(set(c1) | set(c2))
    print("|---|---|" + "---|" * len(keys))
    print(f"| 1 (stores) | {len(b1)} | " + " | ".join(str(c1.get(k, 0)) for k in keys) + " |")
    print(f"| 2 ({sc}) | {len(b2)} | " + " | ".join(str(c2.get(k, 0)) for k in keys) + " |")
    print("\nTasks that came FROM-CACHE in build 2: " + ", ".join(t for t, s in b2.items() if s == "FROM-CACHE"))
    print("\nTasks that ran (no label) in build 2: " + ", ".join(t for t, s in b2.items() if s == "executed"))
print("\n### every task in the repeat scenario\n\n| task | build 1 | build 2 |\n|---|---|---|")
b1, b2 = load("repeat-1"), load("repeat-2")
for t in b1:
    print(f"| {t} | {b1[t]} | {b2.get(t, '-')} |")
PY
