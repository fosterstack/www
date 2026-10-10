#!/usr/bin/env bash
# proof-report: the last job of a scheduled proof run (and of a manual dispatch with which=proof-selftest). It is the
# only job of the workflow with `issues: write`. It reads this run's jobs with the workflow's own token (no secret),
# and keeps exactly ONE open tracking issue:
#   - a failed job: ONE issue labelled proof-failure (or one more comment on the issue that is already open) naming the
#     page(s) (bin/proof-pages.txt), the failing step, the first FAIL lines of the job log, the release and the run link;
#   - a tag the watch refused (reason= starts with "the newest release tag" or "release lookup failed"): the same issue;
#   - everything green and an issue is open: a "green again" comment, then the issue is closed.
# It states only what the job log shows. It writes $OUT_FILE (tag, run id) for the "proven-release" artifact ONLY when everything
# was green (a red or refused run leaves no file, so the watch tries the new tag again the next day).
# Environment: GH_TOKEN, GITHUB_REPOSITORY, RUN_ID, RUN_URL, TAG (may be empty), WATCH_REASON, WATCH_RUN, MODE=schedule|selftest, OUT_FILE.
set -uo pipefail
REPO="${GITHUB_REPOSITORY:?}"; RUN_ID="${RUN_ID:?}"; RUN_URL="${RUN_URL:?}"
MODE="${MODE:-schedule}"; TAG="${TAG:-}"; REASON="${WATCH_REASON:-}"; WATCH_RUN="${WATCH_RUN:-}"; OUT_FILE="${OUT_FILE:-proven-release.txt}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL=proof-failure; [ "$MODE" = selftest ] && LABEL=proof-selftest

safe() { printf '%s' "$1" | tr -d '`\r' | cut -c1-300; }   # log text goes into a fenced block: no backticks, no CR, bounded
pages_of() { awk -F'\t' -v j="$1" '$1 == j { print $2; exit }' "$HERE/proof-pages.txt"; }

jobs_json="$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs?per_page=100" --paginate 2>/dev/null)" || { echo "proof-report: the jobs of this run could not be read: not reporting green" >&2; exit 1; }
failed="$(printf '%s' "$jobs_json" | python3 -c '
import sys, json
dec = json.JSONDecoder(); s = sys.stdin.read().strip(); i = 0; jobs = []
while i < len(s):
    obj, n = dec.raw_decode(s, i); i = n
    while i < len(s) and s[i] in " \n": i += 1
    jobs += obj.get("jobs", [])
for j in jobs:
    if j.get("conclusion") not in ("success", "skipped", None) or (j.get("conclusion") is None and j.get("status") == "completed"):
        steps = [st["name"] for st in j.get("steps", []) if st.get("conclusion") == "failure"]
        print("%s\t%s\t%s" % (j["id"], j["name"], "; ".join(steps) or "(no failing step recorded; job result: %s)" % j.get("conclusion")))
if not jobs: sys.exit(3)
' 2>/dev/null)" || { echo "proof-report: no job could be read from this run: not reporting green" >&2; exit 1; }

refused=0
case "$REASON" in "the newest release tag"*|"release lookup failed"*) refused=1;; esac

body=""
if [ -n "$failed" ]; then
  body="A scheduled proof run failed. Release used: ${TAG:-none}. Run: ${RUN_URL}"$'\n'
  while IFS=$'\t' read -r jid jname jsteps; do
    [[ "$jid" =~ ^[0-9]+$ ]] || continue
    pages="$(pages_of "$jname")"; [ -n "$pages" ] || pages="(job not in bin/proof-pages.txt)"
    body+=$'\n'"### ${jname}"$'\n'"Pages: ${pages}"$'\n'"Failing step: ${jsteps}"$'\n'"Job: ${RUN_URL}/job/${jid}"$'\n'
    lines="$(gh api "repos/${REPO}/actions/jobs/${jid}/logs" 2>/dev/null | sed -n -E 's/^[0-9T:.Z-]+ (FAIL.*)$/\1/p' | head -n 5)"
    if [ -n "$lines" ]; then body+=$'\n''```'$'\n'; while IFS= read -r l; do body+="$(safe "$l")"$'\n'; done <<< "$lines"; body+='```'$'\n'; fi
  done <<< "$failed"
fi
if [ "$refused" = 1 ]; then body+=$'\n'"Release check: $(safe "$REASON")"$'\n'; fi

result=success; { [ -n "$failed" ] || [ "$refused" = 1 ]; } && result=failure
rm -f "$OUT_FILE"
if [ "$result" = success ] && [ "$MODE" = schedule ] && [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then { echo "tag=${TAG}"; echo "run=${RUN_ID}"; } > "$OUT_FILE"; fi

gh label create "$LABEL" --repo "$REPO" --color B60205 --description "A scheduled proof run found a page that no longer matches what runs" >/dev/null 2>&1 || true
open="$(gh issue list --repo "$REPO" --label "$LABEL" --state open --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null)"
if [ "$result" = failure ]; then
  if [ -n "$open" ]; then gh issue comment "$open" --repo "$REPO" --body "$body" >/dev/null && echo "proof-report: commented on #$open"
  else
    title="Proof run failed: $(printf '%s' "$failed" | awk -F'\t' '{print $2}' | head -n 3 | paste -sd, - | cut -c1-80)"
    [ -n "$failed" ] || title="Proof run: the newest release tag was not run"
    [ "$MODE" = selftest ] && title="[self-test] $title"
    gh issue create --repo "$REPO" --label "$LABEL" --title "$title" --body "$body" && echo "proof-report: opened an issue"
  fi
elif [ -n "$open" ]; then
  gh issue comment "$open" --repo "$REPO" --body "Green again on ${TAG:-the release used}: ${RUN_URL}" >/dev/null && gh issue close "$open" --repo "$REPO" >/dev/null && echo "proof-report: closed #$open"
else echo "proof-report: all green, no open issue"; fi
exit 0
