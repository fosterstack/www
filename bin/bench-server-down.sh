#!/usr/bin/env bash
# Timed runs on a GitHub-hosted runner: what does it cost a Gradle build when the remote cache server is not there?
# Run by the "bench-server-down" job of .github/workflows/hygiene.yml (manual dispatch only, choice "server-down"). Prints its own
# disclosure (runner image, CPU count, tool versions, n per cell) so the numbers can be quoted honestly.
#
# Cells, each repeated BENCH_N times, in this order inside every repetition (so drift is spread evenly):
#   A  no remote cache at all                                   (the baseline)
#   B  remote cache configured, server reachable and EMPTY      (a normal miss: results are stored)
#   C  remote cache configured, NOTHING listening on the port   (connection refused)
#   D  remote cache configured, address that never answers      (BENCH_BLACKHOLE, default 10.255.255.1)
# Every timed build uses a fresh copy of the generated project, a new empty Gradle home, no daemon, and Gradle's local build
# cache switched off. Because the Gradle home is new each time, every timed build also pays for Gradle's start-up and for compiling
# its build scripts, like a build on a fresh CI machine; that fixed cost is the same in all cells. One untimed warm-up repetition
# is run first and dropped. A build that fails or runs past BENCH_LIMIT seconds in cell C or D is RECORDED (that is the finding),
# not hidden; in cells A and B it stops the run. No cell may restore anything from the cache.
set -euo pipefail

N="${BENCH_N:-7}"
FS_VER=0.2.1
FS_URL="https://github.com/fosterstack/cache/releases/download/v${FS_VER}/fscache_${FS_VER}_linux_amd64.tar.gz"
FS_SHA=7d464d7926cdc0c10636dde754e23a37fc6518e341465c67f58fe88a617aaf6a   # checksums.txt of release v0.2.1
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf   # services.gradle.org/distributions/gradle-9.8.0-all.zip.sha256
MODULES="${BENCH_MODULES:-4}"
CLASSES="${BENCH_CLASSES:-150}"
BLACKHOLE="${BENCH_BLACKHOLE:-10.255.255.1}"
LIMIT="${BENCH_LIMIT:-600}"
PORT_UP=18491      # the server for cell B
PORT_DOWN=18492    # nothing is ever started here (cell C)
PORT_HOLE=18493    # on the blackhole address (cell D)
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

# ---- disclosure
echo "== runner"; uname -sr; echo "cpus (nproc): $(nproc 2>/dev/null || sysctl -n hw.ncpu)"
(lscpu 2>/dev/null | grep -E 'Model name' || true); (free -m 2>/dev/null | sed -n 2p || true)
echo "image: ${ImageOS:-?} ${ImageVersion:-?}   runner: ${RUNNER_NAME:-?} (${RUNNER_ENVIRONMENT:-?})"
echo "java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
if [ -n "${BENCH_FSCACHE_BIN:-}${BENCH_GRADLE_BIN:-}" ]; then echo "tools: LOCAL OVERRIDES in use, downloads not checked"; else echo "gradle: ${GR_VER} (distribution checked against pinned sha256)   fscache: v${FS_VER} (checked against checksums.txt value)"; fi
echo "project: ${MODULES} independent modules x ${CLASSES} generated classes; n per cell: ${N} (plus 1 untimed warm-up); per-build limit ${LIMIT} s"
echo "cells: A no remote cache | B cache on, server reachable and empty | C cache on, nothing listening on 127.0.0.1:${PORT_DOWN} | D cache on, address ${BLACKHOLE}:${PORT_HOLE}"
if command -v ip >/dev/null 2>&1; then ROUTE="$(ip route get "$BLACKHOLE" 2>&1 | head -2 | tr '\n' ' ')"; else ROUTE="$(route -n get "$BLACKHOLE" 2>&1 | head -3 | tr '\n' ' ')"; fi
echo "route to ${BLACKHOLE}: ${ROUTE}"

# ---- project generator
mkproj() { # dir url
  mkdir -p "$1"
  python3 - "$1" "$2" "$MODULES" "$CLASSES" <<'PY'
import sys, os
d, url, mods, classes = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
open(f"{d}/settings.gradle.kts", "w").write(
    'rootProject.name = "bench"\n' + "include(" + ", ".join(f'":m{m}"' for m in range(1, mods + 1)) + ")\n\n"
    'buildCache {\n    local { isEnabled = false }\n    remote<HttpBuildCache> {\n'
    f'        url = uri("{url}")\n        isPush = true\n        isAllowInsecureProtocol = true\n    }}\n}}\n')
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

# run one build with a time limit; never exits the script. Writes "seconds outcome from-cache" to $WORK/last.txt
# outcome: OK (BUILD SUCCESSFUL) | FAILED (Gradle reported a failure) | TIMEOUT (killed at the limit) | CRASHED (ended with neither)
run_build() { # dir cache(on|off) id
  local dir="$1" cache="$2" id="$3" t0 t1 flag out="$WORK/log-$3.txt" outcome rc pid wpid
  flag="--no-build-cache"; [ "$cache" = on ] && flag="--build-cache"
  t0="$(now)"
  (cd "$dir" && GRADLE_USER_HOME="$WORK/gh-$id" exec "$GRADLE" compileJava $flag --no-daemon --console=plain >"$out" 2>&1) &
  pid=$!
  ( sleep "$LIMIT"; kill "$pid" 2>/dev/null ) & wpid=$!
  rc=0; wait "$pid" || rc=$?
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  t1="$(now)"
  if grep -q 'BUILD SUCCESSFUL' "$out"; then outcome=OK; elif grep -q 'BUILD FAILED' "$out"; then outcome=FAILED; elif [ "$rc" = 143 ] || [ "$rc" = 137 ]; then outcome=TIMEOUT; else outcome=CRASHED; fi
  echo "$(python3 -c "print(f'{$t1 - $t0:.2f}')") $outcome $(grep -c 'compileJava FROM-CACHE' "$out" || true)" > "$WORK/last.txt"
  rm -rf "$WORK/gh-$id"
}

# show what the build printed about the cache (first repetition only), so the numbers can be read with the words
show_cache_lines() { # id
  echo "   what Gradle printed about the cache ($1):"
  (grep -i -E 'remote build cache|build cache|timed out|refused|unreachable|Connect to|disabled|WARNING|error' "$WORK/log-$1.txt" | head -6 | sed 's/^/     | /') || true
}

start_server() { # datadir
  FSCACHE_ADDR="127.0.0.1:$PORT_UP" FSCACHE_DATA_DIR="$1" "$FSCACHE" >"$WORK/server.log" 2>&1 & SRV_PID=$!
  for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT_UP/healthz" >/dev/null && return 0; sleep 0.2; done
  echo "server did not start" >&2; exit 1
}
stop_server() { if [ -n "$SRV_PID" ]; then kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; fi; SRV_PID=""; }
must_be_empty_port() { # nothing may listen on the "down" port
  local rc=0; curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT_DOWN/healthz" || rc=$?
  [ "$rc" = 7 ] || { echo "port $PORT_DOWN is not free (curl exit $rc); cell C would not be a refused connection" >&2; exit 1; }
}
# the "never answers" address must not answer: any HTTP answer aborts; a timeout is the intended case; print what was seen
check_blackhole() {
  local rc=0; curl -s -o /dev/null --max-time 5 "http://$BLACKHOLE:$PORT_HOLE/" || rc=$?
  case "$rc" in
    0) echo "something answered at ${BLACKHOLE}:${PORT_HOLE}; cell D would not be a non-answering address" >&2; exit 1;;
    28) echo "blackhole check: no answer within 5 s (curl 28), as intended";;
    *) echo "blackhole check: curl exit $rc (7 = refused or no route: cell D then measures a fast failure, not a wait)";;
  esac
}

CSV="$WORK/results.csv"; echo "rep,cell,seconds,outcome,compile_tasks_from_cache" > "$CSV"
must_be_empty_port
check_blackhole
for rep in 0 $(seq 1 "$N"); do
  # A: no remote cache
  mkproj "$WORK/pA$rep" "http://127.0.0.1:$PORT_UP/"; run_build "$WORK/pA$rep" off "A$rep"; read -r sA oA fA < "$WORK/last.txt"
  [ "$oA" = OK ] && [ "$fA" = 0 ] || { echo "cell A misbehaved: $oA, restored $fA" >&2; exit 1; }
  # B: remote cache on, server reachable and empty
  start_server "$WORK/data$rep"
  mkproj "$WORK/pB$rep" "http://127.0.0.1:$PORT_UP/"; run_build "$WORK/pB$rep" on "B$rep"; read -r sB oB fB < "$WORK/last.txt"
  stop_server
  [ "$oB" = OK ] && [ "$fB" = 0 ] || { echo "cell B misbehaved: $oB, restored $fB" >&2; exit 1; }
  # C: remote cache on, nothing listening
  mkproj "$WORK/pC$rep" "http://127.0.0.1:$PORT_DOWN/"; run_build "$WORK/pC$rep" on "C$rep"; read -r sC oC fC < "$WORK/last.txt"
  [ "$fC" = 0 ] || { echo "cell C restored something: $fC" >&2; exit 1; }
  # D: remote cache on, address that never answers
  mkproj "$WORK/pD$rep" "http://$BLACKHOLE:$PORT_HOLE/"; run_build "$WORK/pD$rep" on "D$rep"; read -r sD oD fD < "$WORK/last.txt"
  [ "$fD" = 0 ] || { echo "cell D restored something: $fD" >&2; exit 1; }
  if [ "$rep" = 0 ]; then
    echo "warm-up done (not recorded): A=$sA B=$sB C=$sC($oC) D=$sD($oD)"; show_cache_lines "C0"; show_cache_lines "D0"
  else
    printf '%s,A,%s,%s,%s\n%s,B,%s,%s,%s\n%s,C,%s,%s,%s\n%s,D,%s,%s,%s\n' "$rep" "$sA" "$oA" "$fA" "$rep" "$sB" "$oB" "$fB" "$rep" "$sC" "$oC" "$fC" "$rep" "$sD" "$oD" "$fD" >> "$CSV"
    echo "rep $rep: A(no cache)=${sA}s  B(miss)=${sB}s  C(refused)=${sC}s [$oC]  D(no answer)=${sD}s [$oD]" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
    [ "$rep" = 1 ] && { show_cache_lines "C1"; show_cache_lines "D1"; }
  fi
  rm -rf "$WORK/pA$rep" "$WORK/pB$rep" "$WORK/pC$rep" "$WORK/pD$rep" "$WORK/data$rep"
done

echo; echo "== results (seconds, wall clock of the whole gradle command; each build includes JVM start, a new Gradle home and compiling the build scripts; n=$N per cell)"
python3 - "$CSV" <<'PY' | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
import csv, statistics, sys, collections
rows = list(csv.DictReader(open(sys.argv[1])))
cells = {"A": "A: no remote cache", "B": "B: cache on, server reachable and empty (miss)", "C": "C: cache on, connection refused", "D": "D: cache on, address that never answers"}
med = {}
print("| cell | n | min | median | max | outcomes |\n|---|---|---|---|---|---|")
for k, name in cells.items():
    rs = [r for r in rows if r["cell"] == k]
    v = sorted(float(r["seconds"]) for r in rs)
    oc = collections.Counter(r["outcome"] for r in rs)
    med[k] = statistics.median(v)
    print(f"| {name} | {len(v)} | {v[0]:.2f} | {med[k]:.2f} | {v[-1]:.2f} | " + ", ".join(f"{o} x{c}" for o, c in sorted(oc.items())) + " |")
for k, label in (("B", "empty reachable server (miss)"), ("C", "connection refused"), ("D", "address that never answers")):
    print(f"\nextra time with {label}, median {k} minus median A: {med[k] - med['A']:+.2f} s ({(med[k] / med['A'] - 1) * 100:+.1f}%)")
PY
echo; echo "== raw rows"; cat "$CSV"
