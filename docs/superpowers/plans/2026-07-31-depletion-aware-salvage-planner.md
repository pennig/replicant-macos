# Depletion-aware Salvage Planner — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stop the Salvage Run planner from targeting systems whose salvage is fully spent, by making the `SiteAssay` store carry a sticky `depleted` flag maintained on every depletion-observation path and excluded by the planner.

**Architecture:** The planner (`SalvageTargetPlanner.nextTarget`) ranks systems purely from the `SiteAssay` store, which is merge-only-raises and never lowered — so a drained system keeps its original units and keeps getting targeted. `salvage.depleted` today only flips the `SystemDetail` blob's site flag (which the within-system `nextBody` reads), never the assay store. Fix: add `SiteAssay.depleted`, set it wherever a salvage site is observed spent (the `salvage.depleted` event AND a location re-fetch that returns depleted), preserve it through the assay merge writers, and filter it in the planner.

**Tech Stack:** Swift, SQLiteData/StructuredQueries (`@Table` `SiteAssay`), GRDB migrations via `GameDatabase.manifest`, Swift Testing.

## Global Constraints

- **Migrations are append-only.** Add a NEW `SchemaMigration` (`ALTER TABLE`), never edit `SiteAssay.createSiteAssays`. Append its identifier to the END of `GameDatabase.manifest` and to the END of `SchemaManifestTests.frozenIdentifiers`. STRICT table → the column is `INTEGER NOT NULL DEFAULT 0`. Regenerate the golden fixture with `RC_REGENERATE_SCHEMA_FIXTURE=1` (it rewrites `Tests/Fixtures/schema.sql` AND still fails, so the change lands in a diff — re-run without the env var to confirm green).
- **`depleted` is sticky (one-way true).** A salvage site never replenishes. Nothing clears the flag; the assay merge writers must PRESERVE it (they rebuild the whole row and would otherwise reset it to the `false` default). No path sets it back to false.
- **Tests read the JSON event stream** with an explicit product: `swift test --filter <name> --test-product <Product>Tests --event-stream-output-path <path>` (bare `--filter` truncates the stream in this multi-target package). Use the `swift-test-event-stream` skill.
- **LSP is only as fresh as your last build** — `cd app/Modules && swift build --build-tests` before trusting `findReferences`.
- **Commit on local `main`** — no branch/PR/push. Trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Loud test defaults / os.Logger only / never hard-code colors** — not exercised here, listed for completeness.

## File Structure

- `app/Modules/UniverseModels/Sources/LocationRecords.swift` — `SiteAssay` struct (add `depleted`), the `ALTER TABLE` migration constant, `SiteAssay.raising` is unchanged.
- `app/Modules/GameDatabase/Sources/GameDatabase.swift` — append the migration to `manifest`.
- `app/Modules/GameDatabase/Tests/{SchemaManifestTests,GoldenSchemaTests}.swift` + `Tests/Fixtures/schema.sql` — freeze list + regenerated golden.
- `app/Modules/GameServices/Sources/LocationsClient.swift` — the three assay writers (preserve `depleted`), `markSalvageDepleted` (also set the assay flag), and the fetch-path sink (mark depleted sites' assays after a system persist).
- `app/Modules/DirectiveEngine/Sources/SalvageTargetPlanner.swift` — exclude `depleted` assays.
- Tests: `UniverseModels/Tests/SiteAssayTests.swift`, `GameServices/Tests/SalvageDiscoveryTests.swift` (+ a new depletion-ingestion test), `DirectiveEngine/Tests/SalvageTargetPlannerTests.swift`.

Three tasks: (1) schema+model, (2) maintain+preserve the flag on all paths, (3) planner filter + end-to-end. Each is independently reviewable.

---

### Task 1: `SiteAssay.depleted` — schema + model

**Files:** `LocationRecords.swift`, `GameDatabase.swift`, `SchemaManifestTests.swift`, `GoldenSchemaTests.swift`, `Fixtures/schema.sql`. Fixtures across ~8 test files gain the field via an init default.

**Interfaces:**
- Produces: `SiteAssay.depleted: Bool` (init default `false`), and a migration `SiteAssay.addDepleted` (identifier `"Add 'depleted' to 'siteAssays'"`).

- [ ] **Step 1: Add the field to the model (init default keeps call sites compiling).** In `LocationRecords.swift`, add to `SiteAssay` after `assayedAt`:
```swift
    /// Whether this site's salvage is fully spent. Sticky — a salvage site never
    /// replenishes, so once set nothing clears it. Set by every depletion-
    /// observation path (the `salvage.depleted` event and a location re-fetch that
    /// returns depleted) and PRESERVED by the merge writers, which rebuild the row.
    /// The Salvage Run's target planner excludes depleted assays so a drained
    /// system stops being chosen (the merge-only-raises `totals` never lower).
    public var depleted: Bool
```
Add `depleted: Bool = false` to the memberwise `init` signature (as the last parameter, defaulted) and `self.depleted = depleted` in the body. The default means the ~8 test/production `SiteAssay(...)` call sites keep compiling unchanged.

- [ ] **Step 2: Write the migration constant** beside the table, in the same `extension SiteAssay` as `createSiteAssays`:
```swift
    /// Append-only: adds the `depleted` flag introduced for the depletion-aware
    /// Salvage planner. STRICT table, so INTEGER-boolean defaulting to 0 (false).
    public static let addDepleted = SchemaMigration("Add 'depleted' to 'siteAssays'") { db in
        try #sql("""
            ALTER TABLE "siteAssays" ADD COLUMN "depleted" INTEGER NOT NULL DEFAULT 0
            """).execute(db)
    }
```

- [ ] **Step 3: Append to the manifest.** In `GameDatabase.swift` `manifest`, add `SiteAssay.addDepleted` as the LAST element of the array (after the current tail).

- [ ] **Step 4: Extend the frozen identifier list.** In `SchemaManifestTests.swift`, append `"Add 'depleted' to 'siteAssays'"` as the LAST entry of `frozenIdentifiers`. Run the test to confirm `manifest.map(\.identifier)` matches.

- [ ] **Step 5: Regenerate the golden schema.** Run the golden test once with `RC_REGENERATE_SCHEMA_FIXTURE=1` (it rewrites `Fixtures/schema.sql` and fails by design), then again without it to confirm green. The `siteAssays` CREATE-TABLE in the fixture should now include the `depleted` column.

- [ ] **Step 6: Run + commit.**
```bash
cd app/Modules && swift build --build-tests && swift test --filter GameDatabase --test-product GameDatabaseTests --event-stream-output-path /tmp/t1.jsonl
```
Expect: manifest + golden tests green; no other module broke (the init default keeps call sites compiling). Commit: `SiteAssay: add a sticky 'depleted' flag (schema + model)`.

---

### Task 2: Maintain `depleted` on every path; preserve it through the merge writers

**Files:** `LocationsClient.swift` (+ `SalvageDiscoveryTests.swift`, a new depletion-ingestion test).

**Interfaces:**
- Consumes: `SiteAssay.depleted` (Task 1), `SiteAssay.raising`, `mutateSalvage`, `SystemDetail.persist`.
- Produces: `markSalvageDepleted(site:)` now also sets `SiteAssay.depleted`; a fetch-path sink marks depleted sites' assays; the three assay writers preserve `depleted`.

- [ ] **Step 1 (failing test — preservation):** In `SalvageDiscoveryTests.swift`, add a test: seed a `SiteAssay` with `depleted: true`, then run the discovery/scan ingestion (`recordSalvageDiscovery` / `ingestScanResult`) for that same site with fresh units, and assert the stored row still has `depleted == true` (a units observation must not resurrect a spent site). Run → FAILS (the writers rebuild the row from scratch and default `depleted` to false).

- [ ] **Step 2: Preserve `depleted` in the three assay writers.** In `LocationsClient.swift`, at `ingestScanResult` (~:265-272), `ingestSurveyScans` (~:341-348), and `recordSalvageDiscovery` (~:381-388), each builds a new `SiteAssay(...)` from `stored?.totals`. Add `depleted: stored?.depleted ?? false` to each constructed `SiteAssay` so a pre-existing depleted flag survives the upsert. (Read the current code for exact field order.) Run the Step-1 test → PASSES.

- [ ] **Step 3 (failing test — event path):** Add a test that drives the `salvage.depleted` ingestion path (via `LocationsIngestion` → `markSalvageDepleted`, or call `markSalvageDepleted(site:)` directly) for a site that has an existing `SiteAssay`, and asserts the assay row's `depleted == true` afterward (in addition to the blob). Run → FAILS (`markSalvageDepleted` only touches the blob today).

- [ ] **Step 4: Extend `markSalvageDepleted`** (~:412-418) to ALSO set the site's `SiteAssay.depleted = true`. Do it as a scoped `UPDATE` on the assay row keyed by `id == site` (do NOT full-upsert — the row may not exist if the site was never assayed, in which case there's nothing to mark and that's fine; the planner only counts assayed sites anyway). Keep the existing blob mutation. Run the Step-3 test → PASSES.

- [ ] **Step 5 (failing test — fetch path):** Add a test that persists a `StarSystem` (via the location-fetch ingestion path in `LocationsClient`) containing a salvage site whose fetched state is `depleted == true`, with a pre-existing `SiteAssay` for it, and asserts the assay's `depleted` becomes true. Run → FAILS.

- [ ] **Step 6: Add the fetch-path sink.** In the `LocationsClient` ingestion that persists a fetched `StarSystem` (the caller of `SystemDetail.persist`, in GameServices — NOT `persist` itself, which lives in UniverseModels and has no assay access), after the persist, iterate the system's salvage sites and for each with `depleted == true`, set its `SiteAssay.depleted = true` (reuse the same scoped-UPDATE helper as Step 4; keying by site designation). One-way only — never set it false. Run the Step-5 test → PASSES.

- [ ] **Step 7: Full run + commit.**
```bash
cd app/Modules && swift test --filter GameServices --test-product GameServicesTests --event-stream-output-path /tmp/t2.jsonl
```
Expect green. Commit: `SiteAssay: mark 'depleted' on the event and fetch paths; preserve it through assay merges`.

---

### Task 3: Planner excludes depleted assays (the fix) + end-to-end

**Files:** `SalvageTargetPlanner.swift` (+ `SalvageTargetPlannerTests.swift`).

**Interfaces:**
- Consumes: `SiteAssay.depleted`.

- [ ] **Step 1 (failing test):** In `SalvageTargetPlannerTests.swift`, add a test: two salvage systems in `assays`, the richer one's assay(s) marked `depleted: true`; assert `nextTarget` returns the OTHER system (not the richer, depleted one). Add a second test: a system whose ONLY salvage assay is depleted is never returned (nil when it's the only candidate). Use the existing `assay(_:body:units:)` fixture helper — give it a `depleted:` parameter defaulting to false. Run → FAILS (planner still counts the depleted system).

- [ ] **Step 2: Filter in `nextTarget`.** In `SalvageTargetPlanner.swift` (~:98-101), extend the fold guard:
```swift
        for assay in assays
        where assay.siteType == "salvage" && !assay.depleted && !attempted.contains(assay.system) {
            units[assay.system, default: 0] += assay.totals.values.reduce(0, +)
        }
```
Update the doc comment above the fold to note depleted sites are excluded (a drained site's `totals` never lower, so this flag is what removes it from ranking). Run → PASSES.

- [ ] **Step 3: End-to-end guard.** Add/confirm a test through the engine's `RoamContext` → `SalvageRun.plan` path (mirror the existing planner-hook end-to-end test if present in `DirectiveEngineTests`) that a fully-depleted system is not planned as a target. If an existing end-to-end test seeds assays, extend it; else a focused planner test is sufficient (the fold is the only consumer).

- [ ] **Step 4: Full DirectiveEngine run + commit.**
```bash
cd app/Modules && swift test --filter DirectiveEngine --test-product DirectiveEngineTests --event-stream-output-path /tmp/t3.jsonl
```
Expect green. Commit: `Salvage planner: exclude depleted assays so drained systems stop being targeted`.

---

## Self-Review

**1. Spec coverage.** Add `depleted` to SiteAssay (T1); set on `salvage.depleted` event (T2 S3-4) and location re-fetch (T2 S5-6); preserve through merges (T2 S1-2); planner excludes (T3). All present. ✓
**2. Placeholder scan.** Edits to existing writers reference the mapping's file:line and instruct reading current code for exact field order — acceptable for modification tasks; the new code (migration, field, filter, tests) is given in full. ✓
**3. Type consistency.** `SiteAssay.depleted: Bool`; migration identifier `"Add 'depleted' to 'siteAssays'"` used identically in the constant, manifest, and frozen list; planner filter `!assay.depleted`. ✓
**4. Sticky invariant.** No step ever sets `depleted` false; writers preserve, paths only set true. The one risk — a units observation resurrecting a spent site — is the explicit target of T2 S1-2. ✓
