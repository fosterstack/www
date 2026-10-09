#!/usr/bin/env bash
# Timed runs on a GitHub-hosted runner: what does a remote-cache MISS cost, and what does a HIT save?
# Run by the "bench" job of .github/workflows/hygiene.yml (manual dispatch only). Prints its own
# disclosure (runner image, CPU count, tool versions, n per cell) so the numbers can be quoted honestly.
#
# Cells, each repeated BENCH_N times, in this order inside every repetition (so drift is spread evenly):
#   A  no remote cache at all                       (Gradle's own cold compile)
#   B  remote cache on, server EMPTY                (every task misses and stores: the cost of a miss)
#   C  remote cache on, server FILLED by B          (every compile task restored: the saving of a hit)
# Every timed build uses a fresh copy of the generated project, a new empty Gradle home, no daemon,
# and Gradle's local build cache switched off. One untimed warm-up repetition is run first and dropped.
set -euo pipefail

N="${BENCH_N:-7}"
FS_VER=0.2.1
FS_URL="https://github.com/fosterstack/cache/releases/download/v${FS_VER}/fscache_${FS_VER}_linux_amd64.tar.gz"
FS_SHA=7d464d7926cdc0c10636dde754e23a37fc6518e341465c67f58fe88a617aaf6a   # checksums.txt of release v0.2.1
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf   # same value Homebrew pins for this file
MODULES="${BENCH_MODULES:-4}"
CLASSES="${BENCH_CLASSES:-150}"
PORT=18490
WORK="$(mktemp -d)"
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; true' EXIT
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

# ---- disclosure
echo "== runner"; uname -sr; echo "cpus (nproc): $(nproc 2>/dev/null || sysctl -n hw.ncpu)"
(lscpu 2>/dev/null | grep -E 'Model name' || true); (free -m 2>/dev/null | sed -n 2p || true)
echo "image: ${ImageOS:-?} ${ImageVersion:-?}   runner: ${RUNNER_NAME:-?} (${RUNNER_ENVIRONMENT:-?})"
echo "java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
echo "gradle: ${GR_VER} (distribution checked against pinned sha256)   fscache: v${FS_VER} (checked against checksums.txt value)"
echo "project: ${MODULES} independent modules x ${CLASSES} generated classes; n per cell: ${N} (plus 1 untimed warm-up)"

# ---- project generator
mkproj() { # dir port
  mkdir -p "$1"
  python3 - "$1" "$2" "$MODULES" "$CLASSES" <<'PY'
import sys, os
d, port, mods, classes = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
open(f"{d}/settings.gradle.kts", "w").write(
    'rootProject.name = "bench"\n' + "include(" + ", ".join(f'":m{m}"' for m in range(1, mods + 1)) + ")\n\n"
    'buildCache {\n    local { isEnabled = false }\n    remote<HttpBuildCache> {\n'
    f'        url = uri("http://127.0.0.1:{port}/")\n        isPush = true\n        isAllowInsecureProtocol = true\n    }}\n}}\n')
open(f"{d}/build.gradle.kts", "w").write("")
for m in range(1, mods + 1):
    base = f"{d}/m{m}"; pkg = f"{base}/src/main/java/bench/m{m}"
    os.makedirs(pkg, exist_ok=True)
    open(f"{base}/build.gradle.kts", "w").write("plugins { `java-library` }\n")
    for c in range(1, classes + 1):
        body = "".join(f"    public long f{k}(long x) {{ long s = x; for (int i = 0; i < {k + 3}; i++) {{ s += (s * {k + 7}) ^ i; }} return s + {c * 31 + k}; }}\n" for k in range(1, 26))
        open(f"{pkg}/C{c}.java", "w").write(f"package bench.m{m};\n\npublic class C{c} {{\n{body}}}\n")
PY
}

now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

run_build() { # dir cache(on|off) id -> writes "seconds from-cache-count" into $WORK/last.txt
  local dir="$1" cache="$2" id="$3" t0 t1 flag out="$WORK/log-$3.txt"
  flag="--no-build-cache"; [ "$cache" = on ] && flag="--build-cache"
  t0="$(now)"
  (cd "$dir" && GRADLE_USER_HOME="$WORK/gh-$id" "$GRADLE" compileJava $flag --no-daemon --console=plain >"$out" 2>&1) || { cat "$out"; echo "BUILD FAILED" >&2; exit 1; }
  t1="$(now)"
  grep -q 'BUILD SUCCESSFUL' "$out" || { cat "$out"; exit 1; }
  echo "$(python3 -c "print(f'{$t1 - $t0:.2f}')") $(grep -c 'compileJava FROM-CACHE' "$out" || true)" > "$WORK/last.txt"
  rm -rf "$WORK/gh-$id"
}

start_server() { # datadir
  FSCACHE_ADDR="127.0.0.1:$PORT" FSCACHE_DATA_DIR="$1" "$FSCACHE" >"$WORK/server.log" 2>&1 & SRV_PID=$!
  for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null && return 0; sleep 0.2; done
  echo "server did not start" >&2; exit 1
}
stop_server() { if [ -n "$SRV_PID" ]; then kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; fi; SRV_PID=""; }

CSV="$WORK/results.csv"; echo "rep,cell,seconds,compile_tasks_from_cache" > "$CSV"
for rep in 0 $(seq 1 "$N"); do
  # A: no remote cache
  mkproj "$WORK/pA$rep" "$PORT"; run_build "$WORK/pA$rep" off "A$rep"; read -r sA fA < "$WORK/last.txt"
  [ "$fA" = 0 ] || { echo "cell A restored something: $fA" >&2; exit 1; }
  # B: remote cache, empty server
  start_server "$WORK/data$rep"
  mkproj "$WORK/pB$rep" "$PORT"; run_build "$WORK/pB$rep" on "B$rep"; read -r sB fB < "$WORK/last.txt"
  [ "$fB" = 0 ] || { echo "cell B restored something: $fB" >&2; exit 1; }
  # C: same server, now filled
  mkproj "$WORK/pC$rep" "$PORT"; run_build "$WORK/pC$rep" on "C$rep"; read -r sC fC < "$WORK/last.txt"
  [ "$fC" = "$MODULES" ] || { echo "cell C restored $fC of $MODULES compile tasks" >&2; exit 1; }
  stop_server
  rm -rf "$WORK/pA$rep" "$WORK/pB$rep" "$WORK/pC$rep" "$WORK/data$rep"
  if [ "$rep" = 0 ]; then echo "warm-up done (not recorded): A=$sA B=$sB C=$sC"; else
    printf '%s,A,%s,%s\n%s,B,%s,%s\n%s,C,%s,%s\n' "$rep" "$sA" "$fA" "$rep" "$sB" "$fB" "$rep" "$sC" "$fC" >> "$CSV"
    echo "rep $rep: A(no cache)=${sA}s  B(miss, stores)=${sB}s  C(hit)=${sC}s"
  fi
done

echo; echo "== results (seconds, wall clock of the whole gradle command incl. JVM start; n=$N per cell)"
python3 - "$CSV" <<'PY' | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
cells = {"A": "A: no remote cache", "B": "B: remote cache, server empty (miss + store)", "C": "C: remote cache, server filled (hit)"}
med = {}
print("| cell | n | min | median | max |\n|---|---|---|---|---|")
for k, name in cells.items():
    v = sorted(float(r["seconds"]) for r in rows if r["cell"] == k)
    med[k] = statistics.median(v)
    print(f"| {name} | {len(v)} | {v[0]:.2f} | {med[k]:.2f} | {v[-1]:.2f} |")
print(f"\nmiss cost, median B minus median A: {med['B'] - med['A']:+.2f} s ({(med['B'] / med['A'] - 1) * 100:+.1f}%)")
print(f"hit saving, median A minus median C: {med['A'] - med['C']:+.2f} s ({(1 - med['C'] / med['A']) * 100:.1f}% less)")
PY
echo; echo "== raw rows"; cat "$CSV"
