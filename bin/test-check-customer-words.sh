#!/usr/bin/env bash
# Tests for bin/check-customer-words.py: a pull request may not ADD shop words to a file a customer can read.
# Each case builds a throwaway two-commit repository, feeds `git diff -U0 -M --no-color --diff-filter=AMR HEAD^1 HEAD`
# to the script (the line hygiene.yml runs) and checks the exit code (0 clean, 1 hits, 2 any error) and the output.
set -uo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1   # a developer's own git configuration must not change the result
cd "$(dirname "$0")/.."
ROOT="$PWD"
SCRIPT="${CUSTOMER_WORDS_SCRIPT:-$ROOT/bin/check-customer-words.py}"   # a mutant copy, when the mutants are run
DIFF_OPTS="${DIFF_OPTS:--U0 --no-renames --no-color}"

pass=0; fail=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t   # identity by environment: the test writes no git configuration
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# mk <old-path-or-"-"> <old-content> <new-path> <new-content>: base commit with the old file, then the PR commit.
mk() {
  rm -rf "$work/r"; mkdir "$work/r"; cd "$work/r" || exit 2
  git init -q .
  mkdir -p .github/policy; printf '# header\n' > .github/policy/customer-words-allow.txt
  if [ "$1" != - ]; then mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; fi
  git add -A && git commit -qm base
  mkdir -p "$(dirname "$3")"
  if [ "$1" != - ] && [ "$1" != "$3" ]; then git mv "$1" "$3"; fi
  printf '%s' "$4" > "$3"
  git add -A && git commit -qm pr
}
# check <expect-rc> <desc> [grep-pattern-for-output]: run the script on the PR commit; env PR_TITLE / PR_BODY pass through.
check() {
  local want="$1" desc="$2" pat="${3:-}" pat2="${4:-}" out rc
  out="$(git diff $DIFF_OPTS HEAD^1 HEAD | CUSTOMER_WORDS_ALLOW="${ALLOW:-.github/policy/customer-words-allow.txt}" python3 -I "$SCRIPT" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$pat" ] || printf '%s\n' "$out" | grep -qE -- "$pat"; } && { [ -z "$pat2" ] || printf '%s\n' "$out" | grep -qE -- "$pat2"; }; then
    echo "ok:   $desc"; pass=$((pass+1))
  else
    echo "FAIL: $desc (want rc=$want, got rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail+1))
  fi
  cd "$ROOT" || exit 2
}
# add <path> <line> <expect-rc> <desc>: a one-line file added on top of an empty base.
add() { mk - "" "$1" "$2"$'\n'; check "$3" "$4"; }
unset PR_TITLE PR_BODY

# T1 the word owner, in each spelling
for w in owner Owner OWNER owners "owner's"; do add README.md "x $w y" 1 "T1 README.md: added '$w' fails"; done
# T2 each word and plural
for w in lane lanes orchestrator orchestrators advisor advisors handoff handoffs ratify ratified ratifies ratification; do
  add docs/a.md "text $w text" 1 "T2 added '$w' fails"
done
# T3 near misses pass
for w in ownership downer plane land elaborate advisory "hand off" "hand-off" REQ-PROTO-001-AC1 SC-8 "step 2" "Rows 4 to 6"; do
  add docs/a.md "text $w text" 0 "T3 added '$w' passes"
done
# T4 internal paths, rule numbers, id families
for w in docs/ratify/x handoffs/ audits/ /srv/ ops#794 "rule 9" "rules 3" SB-3 HS-5 MC-37 CR-23 lane-outbox; do
  add docs/a.md "see $w now" 1 "T4 added '$w' fails"
done
add docs/verify-release.md "see [REQ-REL-001](release-notes.md#req-rel-001)" 0 "T3 a public requirement id (a link to the release notes) passes"
add docs/a.md "ruler 9" 0 "T4 'ruler 9' passes"
# T4b a word cannot hide behind an underscore, a digit or markup, and "rule N" survives extra white space
for w in _owner_ '**owner**' the_owner owner2 'rule  9' $'rule\t9'; do
  add docs/a.md "text $w text" 1 "T4b added '$w' fails"
done
# T5 lines and files that must not count
mk docs/a.md $'the owner\n' docs/a.md $'fine\n';                       check 0 "T5 a removed line with owner passes"
mk docs/a.md $'the owner\nx\n' docs/a.md $'the owner\ny\n';            check 0 "T5 an unchanged context line with owner passes"
mk - "" bin/x.sh $'# owner\n';                                           check 0 "T5 owner added under bin/ passes"
mk - "" bin/proof-pages.txt $'owner\n';                                 check 0 "T5 owner added in a .txt under bin/ passes"
mk - "" .github/workflows/x.yml $'# owner\n';                           check 0 "T5 owner added in a workflow passes"
mk - "" .github/policy/x.md $'owner\n';                              check 0 "T5 owner added under .github/policy passes"
mk docs/a.md $'the owner\n' docs/b.md $'the owner\n';                  check 1 "T5 a moved page keeps its old lines checked"
mk docs/a.md $'the owner\n' docs/b.md $'the owner\nmore\n';            check 1 "T5 a moved and edited page is checked whole"
mk bin/notes.txt $'the owner\n' p/index.html $'the owner\n';           check 1 "T5 a file moved out of bin/ into a page is checked"
# a symlink replaced by a regular page (a type change)
rm -rf "$work/r"; mkdir -p "$work/r/.github/policy"; cd "$work/r" || exit 2; git init -q
printf '# header\n' > .github/policy/customer-words-allow.txt; printf 'fine\n' > README.md; ln -s README.md index.html
git add -A && git commit -qm base; rm index.html; printf '<p>owner</p>\n' > index.html; git add -A && git commit -qm pr
check 1 "T5 a symlink replaced by a page holding owner fails"
mk docs/a.md $'x\n' docs/a.md $'the owner\n'; git rm -q docs/a.md; git commit -qm rm; check 0 "T5 deleting a page passes"
mk docs/a.md $'the owner\n' docs/b.md $'fine\n';                       check 0 "T5 a page with owner deleted and a clean one added passes"
mk docs/a.md $'x\n' docs/b.md $'the owner\n';                          check 1 "T5 deleting one page and adding another with owner fails"
# T6 depth and header tracking
mk - "" some-page/index.html $'<p>approved by the owner</p>\n';         check 1 "T6 owner added in a nested page/index.html fails"
mk - "" docs/a.md $'++ owner\n';                                        check 1 "T6 an added line that starts with ++ is still read" 'docs/a.md'
mk - "" llms.txt $'owner\n';                                            check 1 "T6 llms.txt fails"
mk - "" x.svg $'<title>owner</title>\n';                                check 1 "T6 an svg fails"
mk - "" sitemap.xml $'<!-- owner -->\n';                                check 1 "T6 an xml file fails"
mk - "" 404.html $'owner\n';                                            check 1 "T6 404.html fails"
mk - "" .github/PULL_REQUEST_TEMPLATE.md $'owner\n';                    check 1 "T6 the PR template fails"
mk - "" x.json $'{"t": "lane"}\n';                                       check 0 "T6 a .json file is not a covered type"
mk - "" x.css $'/* lane */\n';                                           check 0 "T6 a .css file is not a covered type"
mk - "" "a b.md" $'owner\n';                                            check 1 "T6 a page name with a space is read"
# T6b a binary change to a page fails closed; under bin/ or .github/ it is ignored
mk - "" index.html $'fine\n'; printf '<!-- \0 --><p>owner</p>\n' > index.html; git commit -qam bin
check 2 "T6b index.html changed to binary exits 2" 'binary change'
mk - "" other.html $'fine\n'; mkdir some; printf '<!-- \0 --><p>owner</p>\n' > some/index.html; git add -A; git commit -q --amend --no-edit
check 2 "T6b a new binary page exits 2" 'binary change'
mk - "" bin/x.bin $'fine\n'; printf 'a\0' > bin/x.bin; git commit -qam bin
check 0 "T6b a binary file under bin/ passes"
# T7 allowlist: exact path|line
mk - "" README.md $'Fix the file owner or mode\n'
printf '# header\nREADME.md|Fix the file owner or mode\n' > .github/policy/customer-words-allow.txt
check 0 "T7 an exact path|line entry passes"
mk - "" docs/a.md $'Fix the file owner or mode\n'
printf '# header\nREADME.md|Fix the file owner or mode\n' > .github/policy/customer-words-allow.txt
check 1 "T7 the same line in another path fails"
mk - "" README.md $'Fix the file owner or mode.\n'
printf '# header\nREADME.md|Fix the file owner or mode\n' > .github/policy/customer-words-allow.txt
check 1 "T7 a line one character different fails"
mk - "" README.md $'  Fix the file owner or mode  \n'
printf '# header\nREADME.md|Fix the file owner or mode\n' > .github/policy/customer-words-allow.txt
check 0 "T7 leading and trailing whitespace is trimmed"
for bad in 'README.md|' 'owner' 'docs/*.md|owner' 'docs/a.md?|owner' '|owner'; do
  mk - "" README.md $'fine\n'; printf '%s\n' "$bad" > .github/policy/customer-words-allow.txt
  check 2 "T7 malformed allowlist line '$bad' exits 2" 'malformed'
done
# T8 the PR title and body
mk - "" README.md $'fine\n'; PR_TITLE="the lane fix" check 1 "T8 a title with lane fails" 'title'
mk - "" README.md $'fine\n'; PR_BODY=$'one\nthe advisor said' check 1 "T8 a body with advisor fails" 'body'
mk - "" README.md $'fine\n'; PR_BODY="" PR_TITLE="plain title" check 0 "T8 an empty body and a clean title pass"
# T9 every hit is printed; a broken input fails closed
mk - "" docs/a.md $'owner\n'; printf 'a lane here\n' > docs/b.md; git add -A; git commit -qm more
git reset -q --soft HEAD~2; git commit -qm pr2
check 1 "T9 two hits in two files exit 1 and both files are printed" 'docs/a\.md' 'docs/b\.md'
cd "$ROOT" || exit 2
printf 'not a diff at all\n+++ b/docs/a.md\n' | CUSTOMER_WORDS_ALLOW="$work/r/.github/policy/customer-words-allow.txt" python3 -I "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then echo "ok:   T9 input that is not a diff exits 2"; pass=$((pass+1)); else echo "FAIL: T9 input that is not a diff exits 2 (rc=$rc)"; fail=$((fail+1)); fi
step="$(sed -n 's/^ *run: \(git diff .*check-customer-words\.py\)$/\1/p' .github/workflows/hygiene.yml)"   # the step's own command line
printf 'diff --git a/docs/a.md b/docs/a.md\n+++ b/docs/a.md\n@@ -0,0 +1 @@\n+\377\n' | CUSTOMER_WORDS_ALLOW="$work/r/.github/policy/customer-words-allow.txt" python3 -I "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then echo "ok:   T9 an invalid byte on stdin exits 2"; pass=$((pass+1)); else echo "FAIL: T9 an invalid byte on stdin exits 2 (rc=$rc)"; fail=$((fail+1)); fi
printf '# header\n\377|owner\n' > "$work/bad-allow.txt"; : | CUSTOMER_WORDS_ALLOW="$work/bad-allow.txt" python3 -I "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then echo "ok:   T9 an invalid byte in the allowlist exits 2"; pass=$((pass+1)); else echo "FAIL: T9 an invalid byte in the allowlist exits 2 (rc=$rc)"; fail=$((fail+1)); fi
rm -rf "$work/r"; mkdir "$work/r"; (cd "$work/r" && git init -q && git commit -q --allow-empty -m only && bash --noprofile --norc -eo pipefail -c "${step//bin\/check-customer-words.py/$SCRIPT}" >/dev/null 2>&1); rc=$?   # no HEAD^1
if [ -n "$step" ] && [ "$rc" -ne 0 ]; then echo "ok:   T9 a failing git diff fails the step"; pass=$((pass+1)); else echo "FAIL: T9 a failing git diff fails the step (rc=$rc)"; fail=$((fail+1)); fi

echo "----"
echo "check-customer-words: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
