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

**Migrating the edits to a new version is a per-patch decision, not a blanket re-apply.** Diff pristine→`-edits` for the outgoing version to enumerate the patches, then for each one check whether the new pristine already covers it — the server does eventually adopt our fixes, and carrying a superseded patch forward means fighting the real spec. Retire a patch only on evidence: probe the live endpoint (`replicant raw GET …`, see the `probe-api` skill) and confirm the payload matches upstream's declaration. Insert carried-over patches at the same position in their parent object, so the new pristine↔`-edits` diff stays hunk-for-hunk comparable with the old one.

On the **2.3.2 upgrade (2026-07-26)** that retired two patches: the server now declares `/v1/stars`'s `200` natively as `app_schemas_stars_CatalogueResponseSchema`, replacing the hand-written `app_schemas_stars_FullStarCatalogueSchema` + response block we had added. Note the catalogue row got its **own** schema (`CatalogueStarSchema`), distinct from the per-replicant `StarItemSchema` the survey endpoints still use — so `StarsClient` needs a second `StarItem.init(schema:)` overload, and the catalogue genuinely carries no `explored`/`has_life` (14,066 stars probed; only `has_hub`/`name` beyond the common fields). The other 20 patches carried over unchanged. 2.3.2 also added `/v1/leaderboards/colony_planet` + `/v1/leaderboards/colony_moon`, which grew the decorator 84 → 86 operations.
