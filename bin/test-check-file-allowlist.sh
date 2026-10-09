#!/usr/bin/env bash
# Self-test for bin/check-file-allowlist.sh. Run by .github/workflows/hygiene.yml.
# Dot-prefixed folders are SERVED by Cloudflare Pages (found Oct 9, 2026), so the
# script must reject any dot path that is not on its short DOT_OK list.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

must_pass() {  # description, paths...
  local d=$1; shift
  if printf '%s\n' "$@" | bash bin/check-file-allowlist.sh >/dev/null 2>&1; then echo "ok   $d"; else echo "FAIL $d (should pass)"; fail=1; fi
}
must_fail() {  # description, paths...
  local d=$1; shift
  if printf '%s\n' "$@" | bash bin/check-file-allowlist.sh >/dev/null 2>&1; then echo "FAIL $d (should be blocked)"; fail=1; else echo "ok   $d"; fi
}

must_pass "a normal page"                   "gradle-build-cache-tutorial/index.html"
must_pass "the real security.txt"           ".well-known/security.txt"
must_pass "the hook and the workflow"       ".githooks/pre-commit" ".github/workflows/hygiene.yml" ".github/PULL_REQUEST_TEMPLATE.md" ".gitignore"
must_fail "a draft page under .drafts/"     ".drafts/bcn-removed/index.html"
must_fail "a contract file under .contracts/" ".contracts/checkout-session.md"
must_fail "a dot folder nested in a page"   "some-page/.hidden/index.html"
must_fail "another file in .well-known/"    ".well-known/drafts.html"
must_fail "an unknown dot file at the root" ".env"
must_fail "a file that is not on the list"  "notes.md"
tracked=$(git ls-files)
if [ -z "$tracked" ]; then echo "FAIL no tracked files found (run inside the repository)"; fail=1
elif printf '%s\n' "$tracked" | bash bin/check-file-allowlist.sh >/dev/null 2>&1; then echo "ok   the whole real tracked tree"; else echo "FAIL the real tracked tree is blocked"; fail=1; fi
must_fail "a workflow hidden behind a leading dot" ".github/workflows/.hidden.yml"

[ "$fail" -eq 0 ] && echo "all allowlist self-tests passed" || { echo "allowlist self-test FAILED"; exit 1; }
