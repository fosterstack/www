#!/usr/bin/env bash
# proof-watch: runs in the "proof-watch" job of .github/workflows/hygiene.yml on the daily schedule (and on a manual
# dispatch with which=proof-watch, which only prints the decision). It decides whether today's scheduled run proves
# every bench job, and which release the proof uses.
#   - It reads ONLY the published releases of fosterstack/cache (the owner and repo are fixed here, never taken from
#     an input, an event or a file). The newest tag must match ^v[0-9]+\.[0-9]+\.[0-9]+$: any other tag, or a failed
#     lookup, is reported (reason=...) and NEVER run (run=false).
#   - It compares the tag with the last attempt, which the report job leaves in the artifact "proven-release" of this
#     repository (a read of public artifacts with the workflow's own read-only token; nothing is written back).
#   - It starts the full proof when the tag is new, when there is no earlier record, or on Monday (UTC), the weekly run.
# Outputs (to $GITHUB_OUTPUT): run=true|false, tag=vX.Y.Z or empty, ver=X.Y.Z or empty, reason=<plain words>.
set -uo pipefail
CACHE_REPO="fosterstack/cache"
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
WWW_REPO="${GITHUB_REPOSITORY:-fosterstack/www}"

emit() { # run tag reason
  local run="$1" tag="$2" reason="$3" ver=""
  [[ "$tag" =~ $TAG_RE ]] && ver="${tag#v}" || tag=""
  { echo "run=$run"; echo "tag=$tag"; echo "ver=$ver"; echo "reason=$reason"; } >> "$OUT"
  echo "proof-watch: run=$run tag=${tag:-none} reason=$reason"
}
clean() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-40; }   # a tag text is untrusted: keep it to harmless characters

if [ -n "${PROOF_TEST_TAG:-}" ]; then newest="$PROOF_TEST_TAG"; lookup=0   # tests only (a unit test of the rules below)
else newest="$(gh api "repos/${CACHE_REPO}/releases/latest" --jq .tag_name 2>/dev/null)"; lookup=$?; fi
if [ "$lookup" != 0 ] || [ -z "$newest" ]; then emit false "" "release lookup failed: nothing was run"; exit 0; fi
if ! [[ "$newest" =~ $TAG_RE ]]; then emit false "" "the newest release tag '$(clean "$newest")' does not match vX.Y.Z: not run"; exit 0; fi

last=""
if [ -n "${PROOF_TEST_LAST:-}" ]; then last="$PROOF_TEST_LAST"
else
  id="$(gh api "repos/${WWW_REPO}/actions/artifacts?name=proven-release&per_page=1" --jq '.artifacts[0] | select(.expired == false) | .id' 2>/dev/null)"
  if [[ "$id" =~ ^[0-9]+$ ]]; then
    tmp="$(mktemp -d)"
    if gh api "repos/${WWW_REPO}/actions/artifacts/${id}/zip" > "$tmp/a.zip" 2>/dev/null; then
      last="$(unzip -p "$tmp/a.zip" proven-release.txt 2>/dev/null | sed -n 's/^tag=//p' | head -n 1)"
    fi
    rm -rf "$tmp"
  fi
  [[ "$last" =~ $TAG_RE ]] || last=""
fi

dow="${PROOF_TEST_DOW:-$(date -u +%u)}"
if [ -z "$last" ]; then emit true "$newest" "no earlier record: proving $newest"
elif [ "$newest" != "$last" ]; then emit true "$newest" "new release $newest (last proven $last)"
elif [ "$dow" = 1 ]; then emit true "$newest" "weekly run (Monday) for $newest"
else emit false "$newest" "$newest was already proven and it is not Monday"; fi
