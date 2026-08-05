#!/usr/bin/env bash
# Flags comments that record history rather than explain the code.
# See app/CLAUDE.md § Comments and
# docs/superpowers/specs/2026-08-05-comment-policy-design.md
set -uo pipefail

DEFAULT_PATH="app/Modules/DirectiveEngine/Sources"
paths=("${@:-$DEFAULT_PATH}")

# Patterns that are objectively history, never in-situ explanation.
# Matched case-insensitively.
ci_patterns=(
  '\b(19|20)[0-9]{2}-[0-9]{2}-[0-9]{2}\b'
  '\bas of\b'
  '\bused to\b'
  '\bpreviously\b'
  '\bbefore the fix\b'
  '\bno longer\b'
  '\bwe considered\b'
  '\bthe alternative\b'
  '\bturned out\b'
  '\bthis (used|shipped) '
)

# Live-fleet device codes: an uppercase 8-char alphanumeric token. Matched
# case-SENSITIVELY (not folded into ci_patterns) so it doesn't also catch
# lowercase hex — e.g. a commit SHA in a provenance-pointer comment, which
# CLAUDE.md explicitly allows. Excludes a token immediately preceded by
# '#' (hex-color literal), '0x' (hex literal, caught via the 'x'), or '/'
# (URL/path segment) — none of those are device codes.
code_pattern='(^|[^#/A-Za-z0-9])[0-9A-F]{8}\b'

ci_joined=$(IFS='|'; echo "${ci_patterns[*]}")
status=0

while IFS= read -r file; do
  # Comment lines only: whole-line // and /* */ block bodies.
  comments=$(grep -nE '^[[:space:]]*(//|/\*|\*)' "$file")
  [ -z "$comments" ] && continue

  hits=$(
    {
      printf '%s\n' "$comments" | grep -iE "$ci_joined"
      printf '%s\n' "$comments" | grep -E "$code_pattern"
    } | sort -t: -k1,1n -u
  )

  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s|^|${file}:|"
    status=1
  fi
done < <(find "${paths[@]}" -name '*.swift' -type f)

if [ "$status" -ne 0 ]; then
  echo ""
  echo "Comments above record history, not the code as it exists."
  echo "Move the fact to app/.claude/memory/ and delete it here."
  echo "See app/CLAUDE.md § Comments."
fi

exit "$status"
