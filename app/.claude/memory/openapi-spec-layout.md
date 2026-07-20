---
name: openapi-spec-layout
description: "OpenAPI spec files live in Modules/API/Sources/OpenAPI/ as pristine + -edits per version; openapi.json is a symlink to the active -edits file."
metadata: 
  node_type: memory
  type: project
  originSessionId: current
---

As of the v2.1.1 upgrade (2026-07-09), the OpenAPI spec is version-tracked in `Modules/API/Sources/OpenAPI/`:
- `openapi-<version>.json` — pristine spec fetched from the server (untouched).
- `openapi-<version>-edits.json` — pristine + the local drift patches (this is what the generator consumes).
- prior versions' `-edits` files are kept for history (e.g. `openapi-2.0.1-edits.json`).
- `Modules/API/Sources/openapi.json` is a **symlink** → the active `OpenAPI/openapi-<version>-edits.json`. The swift-openapi-generator build plugin auto-discovers the file literally named `openapi.json`, so the symlink is what makes a version active.

To see exactly which local patches are applied: `diff` the pristine vs the `-edits` file for a version. Patches are strict, typed key additions only — the spec is kept strict, no `additionalProperties` relaxation ([[openapi-spec-drift-leniency]]).

Upgrade steps that worked: repoint the symlink to the new `-edits`, then `swift build --target API` + regenerate the diagnostic decorator ([[decode-diagnostics-decorator]]) because new operations (2.1.1 added `getV1Achievements` / `getV1AchievementsAchievementKey`) change the `APIProtocol` surface.
