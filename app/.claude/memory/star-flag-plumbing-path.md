---
name: star-flag-plumbing-path
description: "The seven touchpoints a new per-star column needs (StarItem, Star, both StarsClient mappers, upsertCatalogue, a migration, the frozen list + golden fixture) — and why the survey path deliberately writes only two columns."
metadata:
  node_type: memory
  type: project
---

A new field on the star endpoints reaches the app through exactly seven edits.
Missing any one is silent — the build stays green and the value is simply never
stored. `hasHub` (2.3.3), `region` (2.3.3) and `hasWard` (2.5.1, 2026-08-21) all
took this same path:

1. `UniverseModels/Sources/StarItem.swift` — the property, with a default so
   existing call sites (the `previewSeed`, every test fixture) keep compiling.
2. `UniverseModels/Sources/Star.swift` — the `@Table` column, the `init`
   parameter, `Star.item`, and `Star.init(item:createdAt:)`. Four edits in one
   file, and `Star.item` is the one most easily forgotten because nothing fails.
3. `GameServices/Sources/StarsClient.swift` — **both** `StarItem.init(schema:)`
   overloads. `CatalogueStarSchema` and `StarItemSchema` are different generated
   types serving `GET /v1/stars` and `GET /v1/replicants/{code}/stars`; patching
   one leaves the other silently defaulting.
4. `Star.upsertCatalogue`'s `doUpdate` list — without it the column is written on
   first insert and then never refreshed, so it is correct on a fresh database and
   stale on everyone else's.
5. A new `SchemaMigration` appended to `GameDatabase.manifest` (append-only, see
   the migrations rule in `app/CLAUDE.md`).
6. `SchemaManifestTests.frozenIdentifiers` — append in the same position.
7. `GameDatabase/Tests/Fixtures/schema.sql` — regenerate with
   `RC_REGENERATE_SCHEMA_FIXTURE=1`. The regeneration run reports one failure by
   design; that is the fixture being rewritten, not a problem.

**The survey overlay writes only `explored` and `hasLife`, and that is
deliberate.** `NewStarMapFeature`'s second upsert (the per-replicant walk) lists
those two columns alone because the objective catalogue is the authority for
everything else and runs first over all ~21,700 stars. A catalogue-carried field
belongs in `upsertCatalogue`, never in that overlay.

**Prove a new flag with opposing values.** `StarIngestionTests` sets `has_hub`
and `has_ward` to *different* booleans in every case, so a mapper reading the
neighbouring key fails instead of passing by coincidence — mutating
`schema.hasWard` to `schema.hasHub` fails 4 of 6 tests, and deleting the
`upsertCatalogue` line fails all 6. A same-value fixture catches neither.

Neither `hasHub`, `region` nor `hasWard` has a consumer beyond the model: they
are persisted and unread. See [[openapi-spec-layout]] for the payload shapes and
[[new-star-map-feature]] for the two write paths.
