#!/usr/bin/env bash
# Fetch the replicant.space OpenAPI spec into the package, where the
# swift-openapi-generator build plugin expects it.
#
# The docs say the spec lives at api.replicant.space/swagger/ — the exact
# document path may differ, so we try the common ones. If none hit, open
# https://api.replicant.space/swagger/ in a browser and grab the document
# URL it loads, then: ./scripts/fetch-spec.sh <that-url>

set -euo pipefail

TARGET_DIR="$(cd "$(dirname "$0")/.." && pwd)/Sources/ReplicantKit"

CANDIDATES=(
  "${1:-}"
  "https://api.replicant.space/swagger/openapi.json"
  "https://api.replicant.space/swagger/openapi.yaml"
  "https://api.replicant.space/swagger/swagger.json"
  "https://api.replicant.space/openapi.json"
)

for url in "${CANDIDATES[@]}"; do
  [ -z "$url" ] && continue
  echo "Trying ${url} ..."
  if BODY=$(curl -fsSL "$url" 2>/dev/null) && [ -n "$BODY" ]; then
    rm -f "${TARGET_DIR}/openapi.json" "${TARGET_DIR}/openapi.yaml"
    case "$BODY" in
      \{*) OUT="${TARGET_DIR}/openapi.json" ;;
      *)   OUT="${TARGET_DIR}/openapi.yaml" ;;
    esac
    printf '%s' "$BODY" > "$OUT"
    echo "Saved spec to ${OUT}"
    exit 0
  fi
done

echo "Could not fetch the spec automatically. Find the document URL behind"
echo "https://api.replicant.space/swagger/ and pass it as an argument."
exit 1
