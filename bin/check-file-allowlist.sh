#!/usr/bin/env bash
# Shared allowlist logic for public-repo hygiene, called by both
# .githooks/pre-commit (local, every commit) and
# .github/workflows/hygiene.yml (CI backstop, catches anything committed
# without the hook installed/enabled). One definition, so the two never
# drift apart.
#
# Reads file paths, one per line, on stdin. Exits 1 (with the offending
# paths listed) if any path doesn't match an allowed pattern.
#
# EVERYTHING tracked in this repo is served by Cloudflare Pages, dot-prefixed
# folders included, AND is public on GitHub. (Found Oct 9, 2026: a draft kept in
# .drafts/ was being served at /.drafts/..., so nothing here may be a private
# draft.) Dot-prefixed paths are therefore held to their own short list, DOT_OK,
# on top of ALLOW_PATTERNS, so a broad new pattern can never let one through.

set -euo pipefail

ALLOW_PATTERNS=(
  '^CONTRIBUTING\.md$'
  '^\.github/PULL_REQUEST_TEMPLATE\.md$'
  '^index\.html$'
  '^404\.html$'
  '^README\.md$'
  '^LICENSE$'
  '^_headers$'
  '^_redirects$'
  '^robots\.txt$'
  '^sitemap\.xml$'
  '^llms\.txt$'
  '^favicon\.(ico|svg)$'
  '^favicon-(16|32)\.png$'
  '^apple-touch-icon\.png$'
  '^\.gitignore$'
  '^\.well-known/security\.txt$'
  '^\.githooks/pre-commit$'
  '^bin/check-file-allowlist\.sh$'
  '^bin/test-check-file-allowlist\.sh$'
  '^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$'
  '^functions/(api/)?[A-Za-z0-9._-]+\.js$'
  '^[A-Za-z0-9._-]+/index\.html$'   # pre-positioned pages, e.g. bcn-removed/index.html
)

# The only dot-prefixed paths allowed to exist. .github/ is where GitHub requires
# the workflow and the PR template; .githooks/ holds the opt-in local hook; both
# are already public in the repo, so being served adds no exposure. .well-known/
# security.txt is meant to be public.
DOT_OK=(
  '^\.well-known/security\.txt$'
  '^\.githooks/pre-commit$'
  '^\.github/PULL_REQUEST_TEMPLATE\.md$'
  '^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$'
  '^\.gitignore$'
)

blocked=()
while IFS= read -r path; do
  [ -z "$path" ] && continue
  if [[ "$path" =~ (^|/)\. ]]; then
    dot_ok=0
    for pattern in "${DOT_OK[@]}"; do
      if [[ "$path" =~ $pattern ]]; then dot_ok=1; break; fi
    done
    if [ "$dot_ok" -eq 0 ]; then
      blocked+=("$path  (dot-prefixed paths are served too; only DOT_OK paths are allowed)")
      continue
    fi
  fi
  ok=0
  for pattern in "${ALLOW_PATTERNS[@]}"; do
    if [[ "$path" =~ $pattern ]]; then
      ok=1
      break
    fi
  done
  if [ "$ok" -eq 0 ]; then
    blocked+=("$path")
  fi
done

if [ "${#blocked[@]}" -gt 0 ]; then
  echo "blocked — file(s) not on the public-repo allowlist:" >&2
  for f in "${blocked[@]}"; do
    echo "  $f" >&2
  done
  echo "" >&2
  echo "This is a public repo served verbatim by Cloudflare Pages. If a file" >&2
  echo "genuinely belongs here, add a pattern to ALLOW_PATTERNS in" >&2
  echo "bin/check-file-allowlist.sh." >&2
  exit 1
fi
