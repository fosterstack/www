#!/usr/bin/env bash
# Shared allowlist logic for public-repo hygiene, called by both
# .githooks/pre-commit (local, every commit) and
# .github/workflows/hygiene.yml (CI backstop, catches anything committed
# without the hook installed/enabled). One definition, so the two never
# drift apart.
#
# Reads file paths, one per line, on stdin. Exits 1 (with the offending
# paths listed) if any path doesn't match an allowed pattern.

set -euo pipefail

ALLOW_PATTERNS=(
  '^index\.html$'
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
  '^\.githooks/pre-commit$'
  '^bin/check-file-allowlist\.sh$'
  '^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$'
  '^functions/(api/)?[A-Za-z0-9._-]+\.js$'
  '^[A-Za-z0-9._-]+/index\.html$'   # pre-positioned pages, e.g. bcn-removed/index.html
)

blocked=()
while IFS= read -r path; do
  [ -z "$path" ] && continue
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
