#!/usr/bin/env bash
#
# fetch-spec.sh — refresh the replicant.space OpenAPI document used to generate
# the API client, and relax its strict schemas so the generated decoders tolerate
# the keys the server returns but the (hand-maintained, lagging) spec omits.
#
# Without the relax step, ~135 schemas carry "additionalProperties": false and
# swift-openapi-generator emits strict decoders that throw
# `DecodingError … Additional properties are disabled` on any undeclared key —
# e.g. a travel command response includes `origin_name`/`travel_type`, which even
# spec v1.3.1 doesn't declare. (See memory: openapi-spec-drift-leniency.)
#
# Usage:
#   scripts/fetch-spec.sh [SPEC_URL]
# Runs from anywhere (paths are resolved relative to this script). After it runs,
# rebuild to regenerate the client: `swift build` from Modules/, or Build in Xcode.
#
set -euo pipefail

SPEC_URL="${1:-https://api.replicant.space/swagger/openapi.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="$SCRIPT_DIR/../Modules/API/Sources/openapi.json"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "Fetching $SPEC_URL …"
curl -fsSL "$SPEC_URL" -o "$tmp"

python3 - "$tmp" "$SPEC" <<'PY'
import json, os, re, shutil, sys

src, dest = sys.argv[1], sys.argv[2]
raw = open(src).read()
json.loads(raw)  # validate before touching the destination

# Relax strict schemas: capture unknown server keys instead of rejecting them.
# Leaves "additionalProperties": {} (intentionally untyped objects) alone.
relaxed, n = re.subn(r'"additionalProperties"\s*:\s*false', '"additionalProperties": true', raw)

old_version = None
if os.path.exists(dest):
    try:
        old_version = json.load(open(dest)).get("info", {}).get("version")
    except Exception:
        pass
    shutil.copy(dest, dest + ".bak")  # one-deep safety backup

with open(dest, "w") as f:
    f.write(relaxed)

new_version = json.loads(relaxed).get("info", {}).get("version")
print(f"Wrote {dest}")
print(f"  relaxed {n} occurrences of additionalProperties:false → true")
print(f"  info.version: {old_version} → {new_version}")
PY

echo "Done. Rebuild to regenerate the client (swift build, or Build in Xcode)."
