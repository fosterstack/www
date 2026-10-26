#!/usr/bin/env bash
# Timed run on a GitHub-hosted runner: how long does /verify-a-release/ take a reader on a clean machine?
# Run by the "bench-verify-release" job of .github/workflows/hygiene.yml (manual dispatch only, choice "verify-release").
# It prints its own disclosure so the numbers can be quoted honestly.
#
# What it does: starts a FRESH container from a pinned debian image, installs only what the page names (curl and jq from apt;
# cosign and gh from their official releases, each checked against a pinned sha256), then runs the page's commands word for word,
# timing every step (bin/bench-verify-release-inner.sh). It does this REPS times for the page's own release (0.2.1) and REPS times
# for the latest release (set with the page's own command), each time in a NEW container. A step that fails, or prints something
# other than what the page says, is RECORDED and fails the job at the end; it is not hidden.
#
# The token: steps 5 to 7 (gh attestation verify) need one by the page's own words. The job passes the automatic read-only
# GITHUB_TOKEN as TOKEN_FOR_STEPS_5_TO_7 and this script hands it to the container on stdin (not as an environment variable,
# so it is in no process's environment and not in `docker inspect`); the inner script exports it as GH_TOKEN only for steps 5
# to 7, so steps 1 to 4 run unauthenticated exactly as the page says. It is not a repository secret and it is not written to any file.
set -euo pipefail

REPS="${BENCH_REPS:-2}"
IMAGE='debian@sha256:2c037a04925515fdd6ea85ea14a682d0e79931f5e9f5d07b6dbfc6ba12f9e858'   # debian:12 (index digest)
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== DISCLOSURE"
echo "runner: ${ImageOS:-?} image ${ImageVersion:-?}; $(nproc) vCPU; $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs); $(awk '/MemTotal/ {printf "%.0f GB", $2/1048576}' /proc/meminfo)"
echo "docker: $(docker --version)"
echo "container image: $IMAGE"
echo "apt packages (curl, ca-certificates, jq, tar) come from Debian and are not version-pinned; cosign and gh are pinned by sha256"
echo "repetitions: $REPS per version, each in a new container; times are wall-clock seconds per step; install time is separate"
echo "page commands run with 'bash -o pipefail' so a failing first command in a pipeline is not hidden by jq"
echo "token for steps 5 to 7 only (read-only, automatic GITHUB_TOKEN): $([ -n "${TOKEN_FOR_STEPS_5_TO_7:-}" ] && echo present || echo ABSENT)"

status=0
for ver in 0.2.1 latest; do
  for rep in $(seq 1 "$REPS"); do
    echo
    echo "== RUN version=$ver rep=$rep/$REPS (new container)"
    start=$(date +%s.%N)
    printf '%s\n' "${TOKEN_FOR_STEPS_5_TO_7:-}" | docker run -i --rm \
      -e VER="$ver" -e PLATFORM=linux_amd64 \
      -v "$HERE/bench-verify-release-inner.sh:/inner.sh:ro" \
      "$IMAGE" bash /inner.sh || status=1
    end=$(date +%s.%N)
    echo "RUN_WALL_SECONDS $(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.2f", b-a}')  (the whole container, install included)"
  done
done
echo
[ "$status" = 0 ] && echo "== ALL RUNS: every step passed" || echo "== AT LEAST ONE STEP FAILED (see STEP lines above)"
exit "$status"
