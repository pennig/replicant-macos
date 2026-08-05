#!/usr/bin/env bash
# Flags comments that record history rather than explain the code.
# See app/CLAUDE.md § Comments and
# docs/superpowers/specs/2026-08-05-comment-policy-design.md
set -uo pipefail

DEFAULT_PATH="app/Modules/DirectiveEngine/Sources"
paths=("${@:-$DEFAULT_PATH}")

# Patterns that are objectively history, never in-situ explanation.
patterns=(
  '\b(19|20)[0-9]{2}\b'
  '\bas of\b'
  '\bused to\b'
  '\bpreviously\b'
  '\bbefore the fix\b'
  '\bno longer\b'
  '\bwe considered\b'
  '\bthe alternative\b'
  '\bturned out\b'
  '\bthis (used|shipped) '
  '\b[0-9A-F]{8}\b'
)

joined=$(IFS='|'; echo "${patterns[*]}")
status=0

while IFS= read -r file; do
  # Comment lines only: whole-line // and /* */ block bodies.
  if grep -nE '^[[:space:]]*(//|/\*|\*)' "$file" \
     | grep -inE "$joined" \
     | sed "s|^|${file}:|" \
     | grep . ; then
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
