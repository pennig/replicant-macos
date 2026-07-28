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

On the **2.3.3 upgrade (2026-07-27)**: no new/removed paths or schemas, so the decorator stayed at 86 operations — all 17 upstream changes were inside existing definitions. One patch retired: upstream now declares `has_hub` on `StarItemSchema` (as non-nullable `boolean`; a live survey probe returns `false`, never null), so ours was dropped. `name` on `StarItemSchema` was **kept** — the survey endpoint still doesn't send it and upstream still only declares it on `CatalogueStarSchema`, so the same rare-named-system reasoning as 2.3.2 applies. It had to move to the end of the property list because upstream took over the slot after `entry_point`. The other 18 patches carried over at their original positions.

Worth knowing from 2.3.3: **upstream narrowed `eta_seconds` `number`→`integer` on six schemas, plus `BlueprintSchema.print_time`** — so the generated Swift types went `Double?`→`Int?`. Nothing broke, because the app either coerces (`Int(schema.printTime ?? 0)`) or reads the value out of an untyped container (`Printing.etaSeconds` via `["eta_seconds"]?.numberValue`). Live probes confirmed the narrowing is accurate (eta values 2779/28/1371/86, 31 integral `print_time`s). Note the *sibling* fields are still genuinely fractional — `route_eta_seconds` (27.8) and a route leg's `time_seconds` (45.4) — so don't generalise the narrowing to them. 2.3.3 also added `region` to both star schemas (survey returns `"solzone"`), `hosting_replicant` to `DeviceStatusSchema`, `quantity` to `EnqueuePrintSchema`, `tag`/`untagged` query params on `GET /v1/devices`, and a `cursor` param + `422` on `/v1/events/stream`. **`region` is not yet plumbed into `StarItem`** — the mappers in `StarsClient` ignore it.

On the **2.3.2 upgrade (2026-07-26)** that retired two patches: the server now declares `/v1/stars`'s `200` natively as `app_schemas_stars_CatalogueResponseSchema`, replacing the hand-written `app_schemas_stars_FullStarCatalogueSchema` + response block we had added. Note the catalogue row got its **own** schema (`CatalogueStarSchema`), distinct from the per-replicant `StarItemSchema` the survey endpoints still use — so `StarsClient` needs a second `StarItem.init(schema:)` overload, and the catalogue genuinely carries no `explored`/`has_life` (14,066 stars probed; only `has_hub`/`name` beyond the common fields). The other 20 patches carried over unchanged. 2.3.2 also added `/v1/leaderboards/colony_planet` + `/v1/leaderboards/colony_moon`, which grew the decorator 84 → 86 operations.
