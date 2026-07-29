# Nearest Unexplored Survey Targets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the New Survey Run dialog suggest the five nearest unexplored systems, which requires first making the dead `Star.fullyScannedAt` column actually get written.

**Architecture:** The scan-completeness predicate moves down from `SurveyRun` onto `StarSystem` in UniverseModels so every layer can share one definition. A single persistence helper beside `SystemDetail` upserts a system's blob and stamps `stars.fullyScannedAt` in the same transaction; all nine production upsert sites route through it. With the stamp reliable, the picker's exclusion is a single nullable column on rows it already fetches — no `SystemDetail` fetch and no JSON decode.

**Tech Stack:** Swift 6, SwiftUI, Composable Architecture, SQLiteData (GRDB), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-29-nearest-unexplored-survey-targets-design.md`

## Global Constraints

- Working directory for all `swift` commands: `app/Modules` (where `Package.swift` lives).
- Test results are read from Swift Testing's JSON event stream, never by scraping console text. Use `--test-product <Product>` to avoid the one-path-many-processes truncation trap. Canonical invocation:
  ```bash
  swift test --test-product <Product> --filter '<Suite>' \
    --disable-xctest --event-stream-version 0 \
    --event-stream-output-path .build/events.jsonl
  ```
  `--filter` is a regex over test *IDs* (`Module.TypeName/function()`), so it matches the suite's **type name** — never its `@Suite("display name")`. A display-name filter silently runs nothing and reports "No matching test cases were run".

  Failures:
  ```bash
  jq -r 'select(.kind=="event").payload
         | select(.kind=="issueRecorded" and .issue.isFailure != false)
         | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
    .build/events.jsonl
  ```
  Pass/fail counts:
  ```bash
  jq -s '[.[] | select(.kind=="event").payload | select(.kind=="testEnded")] | length' .build/events.jsonl
  ```
- **Migrations are append-only.** Never edit, rename, or reorder a shipped `SchemaMigration`. A new one is appended to `GameDatabase.manifest` AND to `SchemaManifestTests.frozenIdentifiers`.
- **Logging:** `os.Logger` only, never `print`. Subsystem `name.pennig.replicould`, category = module name.
- **Any system/location designation renders in a monospace font token** (`.rcMono`, `.rcMonoSmall`, `.rcTitleMono`, …). Never inline `design: .monospaced`.
- **Never hard-code colors, spacing, or font sizes.** Use `DesignSystem.swift` tokens (`.rcTextPrimary`, `Space.m`, `Radius.card`, `Font.rcCaption`, …).
- **Pure logic must never live as a static on a SwiftUI `View`** — it traps with signal 5 under `swift test`. Use a plain SwiftUI-free namespace.
- LSP index is only as fresh as the last build. After changes, `swift build --build-tests` before trusting any reference query. This worktree has already been built and `./scripts/link-index-store.sh` has been run.

---

## File Structure

**Created:**
- `app/Modules/UniverseModels/Sources/SystemScanState.swift` — `StarSystem.isFullyScanned` and the `SystemDetail.persist` choke point. One file, one responsibility: "when is a system done, and what happens to the census row when it becomes done."
- `app/Modules/UniverseModels/Tests/SystemScanStateTests.swift`
- `app/Modules/DirectiveEngine/Sources/SurveyTargetSuggestions.swift` — the pure nearest-unexplored resolver.
- `app/Modules/DirectiveEngine/Tests/SurveyTargetSuggestionsTests.swift`
- `app/Modules/DirectivesFeature/Sources/SuggestedTargetRow.swift` — the suggestion list row (its own file: a list-row struct must never sit beside a `#Preview`).

**Modified:**
- `app/Modules/DirectiveEngine/Sources/SurveyRun.swift` — `isFullyScanned` becomes a forwarder.
- `app/Modules/GameServices/Sources/LocationsClient.swift` — 7 upsert sites route through the choke point; stale presence-gate doc comment corrected.
- `app/Modules/GameServices/Sources/LocationsIngestion.swift` — `directive.completed` case.
- `app/Modules/NewStarMapFeature/Sources/NewStarMapFeature.swift` — duplicate `hydrateSystem` body replaced with a client call.
- `app/Modules/LocationsFeature/Sources/LocationsFeature.swift` — hydrate-on-select upsert routed through the choke point.
- `app/Modules/UniverseModels/Sources/Star.swift` — the backfill migration.
- `app/Modules/GameDatabase/Sources/GameDatabase.swift` — manifest gains the migration.
- `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift` — frozen list gains the identifier.
- `app/Modules/DirectivesFeature/Sources/NewDirectiveFeature.swift` — anchor + suggestions on State.
- `app/Modules/DirectivesFeature/Sources/NewDirectiveSheet.swift` — the suggestions block.
- `app/Modules/DirectivesFeature/Tests/NewDirectiveFeatureTests.swift` — suggestion cases.

---

### Task 1: `StarSystem.isFullyScanned`, shared with the engine

Moves the predicate down to the data so UniverseModels can use it. UniverseModels cannot import DirectiveEngine (DirectiveEngine → GameServices → UniverseModels), so this move is what makes one shared definition possible at all.

**Files:**
- Create: `app/Modules/UniverseModels/Sources/SystemScanState.swift`
- Create: `app/Modules/UniverseModels/Tests/SystemScanStateTests.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/SurveyRun.swift:170-184`

**Interfaces:**
- Consumes: `StarSystem` (UniverseModels), with `planetsScanned/planetsTotal/moonsScanned/moonsTotal: Int?`.
- Produces: `StarSystem.isFullyScanned: Bool` — used by Tasks 2, 4. `SurveyRun.isFullyScanned(_ system: StarSystem?) -> Bool` keeps its exact current signature.

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/UniverseModels/Tests/SystemScanStateTests.swift`:

```swift
//
//  SystemScanStateTests.swift
//  UniverseModelsTests
//
//  The one definition of "this system is completely surveyed". Its bias is
//  deliberate and load-bearing: unknown counts are never "scanned", because
//  re-surveying a done system costs one wasted trip while skipping an unscanned
//  one silently loses the point of the survey.
//

import Foundation
import Testing

@testable import UniverseModels

@Suite("System scan state")
struct SystemScanStateTests {
    private func system(
        planetsScanned: Int? = nil, planetsTotal: Int? = nil,
        moonsScanned: Int? = nil, moonsTotal: Int? = nil
    ) -> StarSystem {
        StarSystem(
            designation: "SOL",
            planetsScanned: planetsScanned, planetsTotal: planetsTotal,
            moonsScanned: moonsScanned, moonsTotal: moonsTotal
        )
    }

    @Test func everyPlanetScannedAndNoMoonsReportedIsFull() {
        #expect(system(planetsScanned: 6, planetsTotal: 6).isFullyScanned)
    }

    @Test func everyPlanetAndEveryMoonScannedIsFull() {
        #expect(
            system(planetsScanned: 6, planetsTotal: 6, moonsScanned: 14, moonsTotal: 14)
                .isFullyScanned
        )
    }

    @Test func planetsShortIsNotFull() {
        #expect(!system(planetsScanned: 5, planetsTotal: 6).isFullyScanned)
    }

    /// The case a `recon`-column shortcut gets wrong: `recon == .scanned` is
    /// computed from planets alone, so a system with every planet but not every
    /// moon reads as scanned there while still being real survey work.
    @Test func moonsShortIsNotFull() {
        #expect(
            !system(planetsScanned: 6, planetsTotal: 6, moonsScanned: 11, moonsTotal: 14)
                .isFullyScanned
        )
    }

    @Test func unknownMoonsScannedAgainstAKnownTotalIsNotFull() {
        #expect(
            !system(planetsScanned: 6, planetsTotal: 6, moonsScanned: nil, moonsTotal: 14)
                .isFullyScanned
        )
    }

    @Test func unknownCountsAreNeverFull() {
        #expect(!system().isFullyScanned)
        #expect(!system(planetsScanned: nil, planetsTotal: 6).isFullyScanned)
    }

    @Test func zeroPlanetTotalIsNeverFull() {
        #expect(!system(planetsScanned: 0, planetsTotal: 0).isFullyScanned)
    }

    /// A moon total of zero is "no moons to scan", not an unmet requirement.
    @Test func zeroMoonTotalDoesNotBlockFullness() {
        #expect(
            system(planetsScanned: 6, planetsTotal: 6, moonsScanned: 0, moonsTotal: 0)
                .isFullyScanned
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules && swift test --test-product UniverseModelsTests \
  --filter 'SystemScanStateTests' --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: build failure — `value of type 'StarSystem' has no member 'isFullyScanned'`.

- [ ] **Step 3: Add the property**

Create `app/Modules/UniverseModels/Sources/SystemScanState.swift`:

```swift
//
//  SystemScanState.swift
//  UniverseModels
//
//  When is a star system completely surveyed, and what happens to its census
//  row when it becomes so.
//
//  The predicate lives here rather than on the survey mission that first needed
//  it because it is phrased entirely in a `StarSystem`'s own fields — and
//  because the persistence layer below the engine has to ask it too.
//  UniverseModels cannot import DirectiveEngine, so this is the only level at
//  which one shared definition is possible.
//

import Foundation
import SQLiteData

extension StarSystem {
    /// Whether this system's scan counts say it is completely surveyed.
    ///
    /// UNKNOWN counts are never "scanned": re-surveying an already-done system
    /// costs one wasted trip, but skipping an unscanned one silently loses the
    /// whole point of the survey. Wrong in the cheap direction, deliberately.
    public var isFullyScanned: Bool {
        guard let planetsTotal, planetsTotal > 0,
              let planetsScanned, planetsScanned >= planetsTotal
        else { return false }
        // Moons are optional in the payload; when the server reports a total, it
        // has to be met too.
        if let moonsTotal, moonsTotal > 0 {
            guard let moonsScanned, moonsScanned >= moonsTotal else { return false }
        }
        return true
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd app/Modules && swift test --test-product UniverseModelsTests \
  --filter 'SystemScanStateTests' --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Then check for failures:

```bash
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl
```

Expected: no output from the jq (no failures).

- [ ] **Step 5: Make `SurveyRun.isFullyScanned` a forwarder**

In `app/Modules/DirectiveEngine/Sources/SurveyRun.swift`, replace the whole existing `isFullyScanned` implementation (currently lines 170–184) with:

```swift
    /// Whether a system's scan counts say it is completely surveyed.
    ///
    /// Forwards to `StarSystem.isFullyScanned`, which is the one definition —
    /// shared with the persistence layer that stamps `stars.fullyScannedAt`, so
    /// the picker, the engine, and the catalog can never disagree about whether
    /// a system is done. The `nil`-tolerance stays here: a system we hold no
    /// blob for is not evidence of completeness.
    public static func isFullyScanned(_ system: StarSystem?) -> Bool {
        system?.isFullyScanned ?? false
    }
```

- [ ] **Step 6: Verify the engine's existing tests still pass**

```bash
cd app/Modules && swift test --test-product DirectiveEngineTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-engine.jsonl
```

```bash
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events-engine.jsonl
```

Expected: no output. `SurveyRun`'s signature is unchanged, so every existing call site and test is untouched.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/UniverseModels/Sources/SystemScanState.swift \
        app/Modules/UniverseModels/Tests/SystemScanStateTests.swift \
        app/Modules/DirectiveEngine/Sources/SurveyRun.swift
git commit -m "Move the fully-scanned predicate onto StarSystem

SurveyRun asked a question phrased entirely in a StarSystem's own
fields, which left the persistence layer below it unable to ask the
same question — UniverseModels cannot import DirectiveEngine. Moving
it down is what lets the picker, the engine, and the catalog share
one definition. SurveyRun.isFullyScanned stays as a forwarder, so
its call sites and tests are untouched."
```

---

### Task 2: The persistence choke point

One helper that upserts a system's blob and stamps the census row in the same transaction, so no path can update the catalog without `stars.fullyScannedAt` following.

**Files:**
- Modify: `app/Modules/UniverseModels/Sources/SystemScanState.swift`
- Modify: `app/Modules/UniverseModels/Tests/SystemScanStateTests.swift`

**Interfaces:**
- Consumes: `StarSystem.isFullyScanned` (Task 1); `SystemDetail.init(system:hydratedAt:)` and `Star` (both existing).
- Produces: `SystemDetail.persist(system: StarSystem, at: Date, in: Database) throws` — called by every site in Task 3, and used by Task 4's test fixtures.

- [ ] **Step 1: Write the failing tests**

Append to `app/Modules/UniverseModels/Tests/SystemScanStateTests.swift`. Note this suite needs a database, so it goes in its own suite in the same file:

```swift
@Suite("System detail persistence")
struct SystemDetailPersistenceTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    /// A census row for `designation`, unstamped.
    private func star(_ designation: String) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: true, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func complete(_ designation: String) -> StarSystem {
        StarSystem(
            designation: designation, recon: .scanned, systemScanned: true,
            planetsScanned: 6, planetsTotal: 6, moonsScanned: 14, moonsTotal: 14
        )
    }

    @Test func stampsTheCensusRowWhenTheSystemBecomesComplete() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(system: self.complete("SOL"), at: Self.now, in: db)
        }
        let stored = try await database.read { db in
            try Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored?.fullyScannedAt == Self.now)
    }

    @Test func persistsTheBlobRegardlessOfCompleteness() async throws {
        let database = try GameDatabase.bootstrap()
        let partial = StarSystem(
            designation: "SOL", recon: .visited, systemScanned: true,
            planetsScanned: 2, planetsTotal: 6
        )
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(system: partial, at: Self.now, in: db)
        }
        let stored = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored != nil)
        #expect(try stored?.system().planetsScanned == 2)
    }

    @Test func doesNotStampWhenPlanetsFallShort() async throws {
        let database = try GameDatabase.bootstrap()
        let partial = StarSystem(
            designation: "SOL", recon: .visited, systemScanned: true,
            planetsScanned: 5, planetsTotal: 6
        )
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(system: partial, at: Self.now, in: db)
        }
        let stored = try await database.read { db in
            try Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored?.fullyScannedAt == nil)
    }

    /// The case a `recon`-column shortcut gets wrong. `recon` is computed from
    /// planets alone, so this system reads as `.scanned` there — but its moons
    /// are unfinished and it is still real survey work.
    @Test func doesNotStampWhenMoonsFallShort() async throws {
        let database = try GameDatabase.bootstrap()
        let moonShort = StarSystem(
            designation: "SOL", recon: .scanned, systemScanned: true,
            planetsScanned: 6, planetsTotal: 6, moonsScanned: 11, moonsTotal: 14
        )
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(system: moonShort, at: Self.now, in: db)
        }
        let stored = try await database.read { db in
            try Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored?.fullyScannedAt == nil)
    }

    /// Write-once. The column is named for an event, and moon totals get revised
    /// (`moonsTotalEstimated`), so a later re-persist must not move the stamp.
    @Test func doesNotOverwriteAnExistingStamp() async throws {
        let database = try GameDatabase.bootstrap()
        let first = Date(timeIntervalSince1970: 500_000)
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(system: self.complete("SOL"), at: first, in: db)
            try SystemDetail.persist(system: self.complete("SOL"), at: Self.now, in: db)
        }
        let stored = try await database.read { db in
            try Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored?.fullyScannedAt == first)
    }

    /// A single body's scan seeds a minimal system with no planet totals. That
    /// can never imply the whole system is done.
    @Test func doesNotStampASeededMinimalSystem() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Star.insert { self.star("SOL") }.execute(db)
            try SystemDetail.persist(
                system: StarSystem(designation: "SOL", recon: .visited),
                at: Self.now, in: db
            )
        }
        let stored = try await database.read { db in
            try Star.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored?.fullyScannedAt == nil)
    }

    /// No census row to stamp is not an error — the blob still persists.
    @Test func persistsTheBlobWhenNoCensusRowExists() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try SystemDetail.persist(system: self.complete("NOSTAR"), at: Self.now, in: db)
        }
        let detail = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("NOSTAR") }.fetchOne(db)
        }
        #expect(detail != nil)
    }
}
```

The file's import list becomes:

```swift
import Foundation
import GameDatabase
import SQLiteData
import Testing

@testable import UniverseModels
```

- [ ] **Step 2: Add the test dependencies**

`UniverseModelsTests` currently depends only on `"API"` and `"UniverseModels"`, so it cannot call `GameDatabase.bootstrap()` or use the query builder. In `app/Modules/Package.swift`, add both to the `UniverseModelsTests` target, keeping the existing alphabetical style:

```swift
            name: "UniverseModelsTests",
            dependencies: [
                "API",
                "GameDatabase",
                "UniverseModels",
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "UniverseModels/Tests"
```

Do not reorder or touch any other target. No dependency cycle results: `GameDatabase` depends on `UniverseModels`, and this is a test target, which nothing depends on.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd app/Modules && swift test --test-product UniverseModelsTests \
  --filter 'SystemDetailPersistenceTests' --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: build failure — `type 'SystemDetail' has no member 'persist'`.

- [ ] **Step 4: Implement the choke point**

Append to `app/Modules/UniverseModels/Sources/SystemScanState.swift`:

```swift
extension SystemDetail {
    /// Persist a system's blob AND reconcile its census row's scan lifecycle
    /// stamp, in one transaction.
    ///
    /// Every path that writes a `SystemDetail` goes through here — the seven in
    /// `LocationsClient`, the star map's hydrate, and the Locations catalog's
    /// hydrate-on-select. That is the point: `stars.fullyScannedAt` was declared,
    /// documented, and read by the star map as the `.full` survey tier, but
    /// written by nothing at all, so it was null on every one of 14,122 rows and
    /// the map could never show a system as fully scanned. A stamp attached to
    /// one write path would simply have grown new holes.
    ///
    /// The stamp is WRITE-ONCE. The column is named for an event, not a state,
    /// and `Star`'s three local lifecycle timestamps are documented as ones the
    /// survey never overwrites. Concretely: `moonsTotalEstimated` means moon
    /// totals do get revised upward, and a retractable stamp would flip systems
    /// between `.full` and `.partial` on estimate churn.
    ///
    /// A system with no census row still persists its blob — nothing to stamp is
    /// not a failure.
    public static func persist(system: StarSystem, at now: Date, in db: Database) throws {
        let row = try SystemDetail(system: system, hydratedAt: now)
        try SystemDetail.upsert { row }.execute(db)

        guard system.isFullyScanned else { return }
        // Read-then-write rather than a nullable predicate in the UPDATE: it
        // makes write-once explicit at the call site, and folds "no census row"
        // into the same guard. Only ever reached on the completing write, which
        // happens once per system.
        let star = try Star.where { $0.designation.eq(system.designation) }.fetchOne(db)
        guard let star, star.fullyScannedAt == nil else { return }
        try Star.where { $0.designation.eq(system.designation) }
            .update { $0.fullyScannedAt = #bind(now) }
            .execute(db)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd app/Modules && swift test --test-product UniverseModelsTests \
  --filter 'SystemDetailPersistenceTests' --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

```bash
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/UniverseModels/Sources/SystemScanState.swift \
        app/Modules/UniverseModels/Tests/SystemScanStateTests.swift \
        app/Modules/Package.swift
git commit -m "Add one choke point for persisting a system's scan state

stars.fullyScannedAt was declared, documented, and read by
LiveStar.scanState as the .full survey tier — and written by
nothing, so it was null on all 14,122 rows of the live database
and the star map could never render a system as fully scanned.

SystemDetail.persist upserts the blob and stamps the census row in
one transaction. Write-once, because the column names an event and
moon totals get revised upward, which a retractable stamp would
turn into map flicker."
```

---

### Task 3: Route all nine production sites through the choke point

**Files:**
- Modify: `app/Modules/GameServices/Sources/LocationsClient.swift` (7 sites at lines 164, 192, 210, 249, 329, 404, 454, plus the stale doc comment at 176-181)
- Modify: `app/Modules/NewStarMapFeature/Sources/NewStarMapFeature.swift:485-500`
- Modify: `app/Modules/LocationsFeature/Sources/LocationsFeature.swift:299-302`

**Interfaces:**
- Consumes: `SystemDetail.persist(system:at:in:)` (Task 2).
- Produces: nothing new. Behaviour change only — every catalog write now stamps.

- [ ] **Step 1: Replace the seven `LocationsClient` sites**

Each site currently reads:

```swift
                let row = try SystemDetail(system: <merged>, hydratedAt: now)
                try SystemDetail.upsert { row }.execute(db)
```

Replace each with:

```swift
                try SystemDetail.persist(system: <merged>, at: now, in: db)
```

preserving the surrounding indentation and the local variable name at each site (`merged`, `assembled`, `updated`, or `scanned` — check each). The seven are in `scanAndPersist`, `hydrateSystem`, `hydrateBody`, `ingestScanResult`, `ingestSurveyScans`, `recordSalvageDiscovery`, `markSalvageDepleted`.

**`hydrateSystem` needs one extra change.** It currently builds its row *outside* the write block, so the upsert and the stamp would not be one transaction. Move the construction inside:

```swift
    public func hydrateSystem(designation: String) async throws {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        guard let fresh = try? await system(designation) else { return }
        try await database.write { db in
            let cached = try SystemDetail.where { $0.designation.eq(designation) }.fetchOne(db)
            let merged = (try? cached?.system()).flatMap { $0 }.map { $0.mergingSystemDetail(fresh) } ?? fresh
            try SystemDetail.persist(system: merged, at: now, in: db)
        }
    }
```

- [ ] **Step 2: Correct the stale doc comment on `hydrateSystem`**

The comment claims the endpoint is presence-gated. It is exploration-gated; the 403's "No replicant in system" message lies (corrected 2026-07-27). Task 5's trigger depends on this distinction, so fix it here. Replace the "Best-effort by contract: …" paragraph with:

```swift
    /// Best-effort by contract: `GET locations/{star}` is **exploration**-gated,
    /// not presence-gated — its 403 says "No replicant in system", which is a
    /// lie, and any *explored* system rehydrates from anywhere (see the
    /// location-endpoint-presence-gate note). So a caller away from the system
    /// is the normal case and succeeds; an unexplored system 403s and leaves the
    /// cache exactly as it was. Used by `DirectiveEngine`'s `refreshSystem`
    /// action to pull fresh scan counts after a survey completes, and by the
    /// `directive.completed` catalog route for the same reason.
```

- [ ] **Step 3: Replace the star map's duplicate hydrate**

`NewStarMapFeature.hydrateSystem` (lines 485–500) is functionally identical to `LocationsClient.hydrateSystem`. Replace its body with a client call — one duplicate gone, and the stamp comes with it. This changes only *how* it hydrates, not *when*, so the deferral that fixed the drill-in fly hitch is untouched:

```swift
    /// Best-effort refresh of one system's roster (GET locations), merged onto any
    /// existing (possibly scanned) `SystemDetail` and re-persisted — the orrery's
    /// `@Fetch` then re-renders. Silently no-ops for systems the server won't serve.
    ///
    /// Delegates to `LocationsClient.hydrateSystem`, which does exactly this and
    /// additionally stamps `stars.fullyScannedAt` when the merge completes the
    /// system — the signal this view's own `.full` scan tier reads.
    private func hydrateSystem(_ designation: String) -> Effect<Action> {
        let client = locationsClient
        return .run { _ in
            try? await client.hydrateSystem(designation: designation)
        }
    }
```

If `database` or `date` become unused in the reducer after this, leave them — they are used elsewhere in the file. Verify with a build rather than assuming.

- [ ] **Step 4: Route the Locations catalog's hydrate-on-select**

In `LocationsFeature.swift`, the site at lines 299–302 currently reads:

```swift
                    let row = try SystemDetail(system: assembled, hydratedAt: now)
                    try await database.write { db in
                        try SystemDetail.upsert { row }.execute(db)
                    }
```

Replace with:

```swift
                    try await database.write { db in
                        try SystemDetail.persist(system: assembled, at: now, in: db)
                    }
```

- [ ] **Step 5: Build and run the full affected test suites**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: clean build. Then:

```bash
cd app/Modules && for p in GameServicesTests UniverseModelsTests DirectiveEngineTests LocationsFeatureTests NewStarMapFeatureTests; do
  swift test --test-product "$p" --disable-xctest --event-stream-version 0 \
    --event-stream-output-path ".build/events-$p.jsonl"
done
cat .build/events-*Tests.jsonl > .build/events.jsonl
```

```bash
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl
```

Expected: no output. Existing `LocationsClientHydrateTests`, `SurveyScanIngestionTests`, `SalvageScanAssayTests`, and `LocationsClientSalvageTests` all exercise these paths and must stay green — they assert on the persisted blob, which is unchanged.

- [ ] **Step 6: Verify no production upsert site was missed**

```bash
cd /Users/matt/Developer/replicant-macos/.claude/worktrees/nearest-unexplored-survey-targets && \
  grep -rn "SystemDetail.upsert" --include="*.swift" --exclude-dir=.build app/ | grep -v "/Tests/"
```

Expected: exactly one hit — the one inside `SystemDetail.persist` itself. Any other hit is a hole in the stamp.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/GameServices/Sources/LocationsClient.swift \
        app/Modules/NewStarMapFeature/Sources/NewStarMapFeature.swift \
        app/Modules/LocationsFeature/Sources/LocationsFeature.swift
git commit -m "Route every catalog write through the scan-state choke point

Nine production paths persisted a SystemDetail: seven in
LocationsClient plus the star map's hydrate and the Locations
catalog's hydrate-on-select. The two feature-level ones matter —
opening the catalog or drilling into a system is a realistic moment
for a system to become known-complete, and a choke point confined
to LocationsClient would have left both as silent holes.

The star map's hydrate was a near-exact copy of the client's, so it
now calls it instead. LocationsClient.hydrateSystem built its row
outside its write block; moved inside so the upsert and the stamp
are one transaction. Also corrects that method's doc comment, which
still claimed presence-gating — the endpoint is exploration-gated,
which is what Task 5's trigger rests on."
```

---

### Task 4: Backfill the existing 31 fully-scanned systems

Without this the star map stays wrong for all existing data and the picker suggests finished systems until each is re-hydrated.

**Files:**
- Modify: `app/Modules/UniverseModels/Sources/Star.swift` (append to the `// MARK: - Schema` extension)
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift:47-70`
- Modify: `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift:31-52`
- Create: `app/Modules/GameDatabase/Tests/FullyScannedBackfillTests.swift`

**Interfaces:**
- Consumes: `SystemDetail.persist` is NOT used here — the migration is raw SQL, because a migration must not depend on Swift model shapes that may drift later.
- Produces: `Star.backfillFullyScannedAt: SchemaMigration` with identifier `"Backfill 'fullyScannedAt' from systemDetails"`.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/GameDatabase/Tests/FullyScannedBackfillTests.swift`:

```swift
//
//  FullyScannedBackfillTests.swift
//  GameDatabaseTests
//
//  The backfill for `stars.fullyScannedAt`. Nothing ever wrote the column, so
//  every already-surveyed system was left unstamped — 31 of them on the live
//  database. Without the backfill the star map keeps showing them as partial and
//  the survey-target picker keeps offering them.
//
//  Applies the same planets-and-moons rule as `StarSystem.isFullyScanned`, in
//  SQL, over the stored blob.
//

import Foundation
import SQLiteData
import Testing
import UniverseModels

@testable import GameDatabase

@Suite("Fully-scanned backfill")
struct FullyScannedBackfillTests {
    private static let hydrated = Date(timeIntervalSince1970: 900_000)

    private func star(_ designation: String) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: true, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Migrate only up to (not including) the backfill, seed rows as they would
    /// have existed before it, then run the backfill through the real migrator.
    ///
    /// `GameDatabase.bootstrap()` takes no arguments and always migrates the
    /// whole manifest, which would run the backfill against an empty database.
    /// So this opens the connection the same way bootstrap does and drives
    /// `GameDatabase.migrator(_:)` — the parameter exists for exactly this.
    private func seeded() async throws -> any DatabaseWriter {
        let upToBackfill = GameDatabase.manifest.filter {
            $0.identifier != "Backfill 'fullyScannedAt' from systemDetails"
        }
        let database = try SQLiteData.defaultDatabase(configuration: GameDatabase.configuration)
        try GameDatabase.migrator(upToBackfill).migrate(database)
        try await database.write { db in
            for designation in ["DONE", "PLANETSHORT", "MOONSHORT", "NODETAIL"] {
                try Star.insert { self.star(designation) }.execute(db)
            }
            let systems = [
                StarSystem(
                    designation: "DONE", recon: .scanned, systemScanned: true,
                    planetsScanned: 6, planetsTotal: 6, moonsScanned: 14, moonsTotal: 14
                ),
                StarSystem(
                    designation: "PLANETSHORT", recon: .visited, systemScanned: true,
                    planetsScanned: 5, planetsTotal: 6
                ),
                StarSystem(
                    designation: "MOONSHORT", recon: .scanned, systemScanned: true,
                    planetsScanned: 6, planetsTotal: 6, moonsScanned: 11, moonsTotal: 14
                ),
            ]
            for system in systems {
                let row = try SystemDetail(system: system, hydratedAt: Self.hydrated)
                try SystemDetail.upsert { row }.execute(db)
            }
        }
        return database
    }

    private func stamp(_ database: any DatabaseWriter, _ designation: String) async throws -> Date? {
        try await database.read { db in
            try Star.where { $0.designation.eq(designation) }.fetchOne(db)?.fullyScannedAt
        }
    }

    @Test func stampsAFullyScannedSystemFromItsHydrationTime() async throws {
        let database = try await seeded()
        try GameDatabase.migrator().migrate(database)
        #expect(try await stamp(database, "DONE") == Self.hydrated)
    }

    @Test func leavesAPlanetShortSystemUnstamped() async throws {
        let database = try await seeded()
        try GameDatabase.migrator().migrate(database)
        #expect(try await stamp(database, "PLANETSHORT") == nil)
    }

    /// `recon` is "scanned" for this system (it is computed from planets alone),
    /// so a recon-column backfill would wrongly stamp it.
    @Test func leavesAMoonShortSystemUnstamped() async throws {
        let database = try await seeded()
        try GameDatabase.migrator().migrate(database)
        #expect(try await stamp(database, "MOONSHORT") == nil)
    }

    @Test func leavesACensusOnlySystemUnstamped() async throws {
        let database = try await seeded()
        try GameDatabase.migrator().migrate(database)
        #expect(try await stamp(database, "NODETAIL") == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/Modules && swift test --test-product GameDatabaseTests \
  --filter 'FullyScannedBackfillTests' --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: failure. `stampsAFullyScannedSystemFromItsHydrationTime` gets `nil`, and `manifestMatchesTheFrozenList` in the sibling suite still passes (nothing added yet).

- [ ] **Step 3: Write the migration**

Append to the `// MARK: - Schema` extension in `app/Modules/UniverseModels/Sources/Star.swift`:

```swift
    /// Backfills `fullyScannedAt` for systems already known to be fully
    /// surveyed. Nothing ever wrote the column, so every system surveyed before
    /// it started being stamped was left null — 31 of them on the live database,
    /// which is why the star map showed none as fully scanned.
    ///
    /// Raw SQL against the stored blob rather than decoding through
    /// `StarSystem`: a migration runs forever against databases whose Swift
    /// model may have moved on, so it must not depend on today's model shape.
    /// The predicate mirrors `StarSystem.isFullyScanned` exactly — every planet
    /// scanned against a positive total, and every moon scanned whenever a
    /// positive moon total is reported. A NULL count makes its comparison NULL,
    /// which is falsy, matching that property's "unknown is never scanned" bias.
    ///
    /// The timestamp is the detail row's own `hydratedAt` — the best available
    /// evidence of when we learned the system was complete — and both columns
    /// are TEXT, so copying it across preserves the exact serialization.
    public static let backfillFullyScannedAt = SchemaMigration(
        "Backfill 'fullyScannedAt' from systemDetails"
    ) { db in
        try #sql(
            """
            UPDATE "stars" SET "fullyScannedAt" = (
              SELECT "d"."hydratedAt" FROM "systemDetails" AS "d"
              WHERE "d"."designation" = "stars"."designation"
            )
            WHERE "fullyScannedAt" IS NULL
              AND "designation" IN (
                SELECT "designation" FROM "systemDetails"
                WHERE json_extract("systemJSON", '$.planetsTotal') > 0
                  AND json_extract("systemJSON", '$.planetsScanned')
                      >= json_extract("systemJSON", '$.planetsTotal')
                  AND (
                    json_extract("systemJSON", '$.moonsTotal') IS NULL
                    OR json_extract("systemJSON", '$.moonsTotal') = 0
                    OR json_extract("systemJSON", '$.moonsScanned')
                       >= json_extract("systemJSON", '$.moonsTotal')
                  )
              )
            """
        )
        .execute(db)
    }
```

- [ ] **Step 4: Append to the manifest**

In `app/Modules/GameDatabase/Sources/GameDatabase.swift`, append as the LAST entry of `manifest` (append-only — do not insert it anywhere else):

```swift
        EventLog.createEventLogs,
        Star.backfillFullyScannedAt,
    ]
```

- [ ] **Step 5: Append to the frozen identifier list**

In `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift`, append as the LAST entry of `frozenIdentifiers`:

```swift
        "Create 'eventLogs' table",
        "Backfill 'fullyScannedAt' from systemDetails",
    ]
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd app/Modules && swift test --test-product GameDatabaseTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

```bash
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl
```

Expected: no output — including `SchemaManifestTests` and `GoldenSchemaTests`. This migration is data-only, so the golden schema snapshot is unchanged; **do not** regenerate it. If `GoldenSchemaTests` fails, the migration accidentally altered the schema — fix the migration, do not set `RC_REGENERATE_SCHEMA_FIXTURE=1`.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/UniverseModels/Sources/Star.swift \
        app/Modules/GameDatabase/Sources/GameDatabase.swift \
        app/Modules/GameDatabase/Tests/SchemaManifestTests.swift \
        app/Modules/GameDatabase/Tests/FullyScannedBackfillTests.swift
git commit -m "Backfill fullyScannedAt for already-surveyed systems

31 systems on the live database are fully scanned with a null
stamp, so without a backfill the star map keeps showing them as
partial and the survey picker keeps offering them until each is
re-hydrated.

Raw SQL over the stored blob rather than a decode through
StarSystem: a migration outlives today's model shape. The
predicate mirrors StarSystem.isFullyScanned, including the moons
clause a recon-column shortcut would get wrong. Data-only, so the
golden schema snapshot is untouched."
```

---

### Task 5: Stamp on survey-directive completion

**Files:**
- Modify: `app/Modules/GameServices/Sources/LocationsIngestion.swift:163-207`
- Create: `app/Modules/GameServices/Tests/DirectiveCompletedCatalogRouteTests.swift`

**Interfaces:**
- Consumes: `LocationsClient.hydrateSystem(designation:)` (existing); `SystemDetail.persist` indirectly (Task 3 routed it).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Read an existing route test first to match the harness — `app/Modules/GameServices/Tests/SurveyScanIngestionTests.swift` shows how a route is driven with a stubbed `locationsClient`. Create `app/Modules/GameServices/Tests/DirectiveCompletedCatalogRouteTests.swift`:

```swift
//
//  DirectiveCompletedCatalogRouteTests.swift
//  GameServicesTests
//
//  A completed survey means the system's scan counts have moved, and those
//  counts are what stamp `stars.fullyScannedAt`. The completion event itself is
//  NOT taken as evidence: SurveyRun.confirm already refuses to trust a
//  completion over the counts (it stalls `.surveyIncomplete` when the server
//  says done and the numbers disagree), so this route only triggers the re-read
//  and lets the counts decide.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels
import Utils

@testable import GameServices

@Suite("directive.completed catalog route")
struct DirectiveCompletedCatalogRouteTests {
    /// Drive just the catalog route with one event, recording which systems got
    /// re-read.
    ///
    /// The stub is on `locationsClient.system` — the closure property
    /// `hydrateSystem` actually calls — because `hydrateSystem` is a real method
    /// built on top of those closures, not an overridable closure itself. Which
    /// makes this the better observation anyway: it drives the real hydrate path
    /// rather than a fake of it. `testValue` is `unimplemented(...)` by house
    /// rule, so any *other* client call this route makes would fail loudly.
    private func hydrated(for event: GameEventEnvelope) async throws -> [String] {
        let recorder = LockIsolated<[String]>([])
        let database = try GameDatabase.bootstrap()
        let ingestion = LocationsIngestion()
        guard let route = ingestion.eventRoutes.first(where: { $0.id == "locations.catalog" })
        else { return [] }
        await withDependencies {
            $0.defaultDatabase = database
            $0.date.now = Date(timeIntervalSince1970: 1_000_000)
            $0.locationsClient.system = { designation in
                recorder.withValue { $0.append(designation) }
                return StarSystem(designation: designation, recon: .visited)
            }
        } operation: {
            await route.apply(event)
        }
        return recorder.value
    }

    private func completion(directive: String, star: String?) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: "directive",
            event: "directive.completed",
            star: star,
            payload: ["directive": .string(directive)]
        )
    }

    @Test func hydratesTheSystemAfterASurveyCompletes() async throws {
        let read = try await hydrated(for: completion(directive: "survey_system", star: "SOL"))
        #expect(read == ["SOL"])
    }

    @Test func ignoresANonSurveyDirective() async throws {
        let read = try await hydrated(for: completion(directive: "mine_resource", star: "SOL"))
        #expect(read.isEmpty)
    }

    @Test func ignoresACompletionWithNoSystem() async throws {
        let read = try await hydrated(for: completion(directive: "survey_system", star: nil))
        #expect(read.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/Modules && swift test --test-product GameServicesTests \
  --filter 'DirectiveCompletedCatalogRouteTests' --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: `hydratesTheSystemAfterASurveyCompletes` fails (nothing hydrates, so the recorder is empty). The other two already pass — they assert an absence, and are there to pin the guards once the case exists.

`GameServicesTests` already depends on `GameDatabase`, `API`, and `GameModels`, so no `Package.swift` change is needed here.

- [ ] **Step 3: Add the route case**

In `LocationsIngestion.catalogRoute`, add a case to the `switch event.event`. Place it directly after the `"ami.survey.digest"` case:

```swift
            case "directive.completed":
                // A survey finished, so this system's scan counts have moved —
                // and those counts are what stamp `stars.fullyScannedAt` (see
                // `SystemDetail.persist`). Re-read rather than trusting the
                // completion: `SurveyRun.confirm` already refuses to believe a
                // completion over the counts, stalling `.surveyIncomplete` when
                // the server says done and the numbers disagree, and stamping a
                // half-scanned system would show it as fully surveyed on the map.
                //
                // Safe from anywhere: `GET locations/{star}` is exploration-
                // gated, not presence-gated, and a system that was just
                // surveyed is explored.
                //
                // Survey Run performs this same read itself via `.refreshSystem`,
                // so for engine-driven runs this duplicates one request.
                // Accepted: surveys complete minutes to hours apart, and the
                // alternative is a "is a directive driving this device" query on
                // every completion.
                guard payload["directive"]?.stringValue == "survey_system",
                      let system = event.star ?? event.location
                else { break }
                try? await locationsClient.hydrateSystem(designation: system)
```

Note `guard let payload = event.payload else { return }` already runs at the top of this closure, so `payload` is in scope.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd app/Modules && swift test --test-product GameServicesTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

```bash
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl
```

Expected: no output. The whole GameServices suite runs because this route is `match: .all` and sees every event — a regression here would show up in the other ingestion suites.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameServices/Sources/LocationsIngestion.swift \
        app/Modules/GameServices/Tests/DirectiveCompletedCatalogRouteTests.swift
git commit -m "Re-read a system's counts when a survey directive completes

The second trigger for stamping fullyScannedAt. Deliberately not
config-trusting: SurveyRun.confirm already refuses to believe a
completion over the server's own counts, and stamping a
half-scanned system would render it as fully surveyed on the map.
So the completion triggers the re-read and the counts decide.

Lives in LocationsIngestion.catalogRoute, whose documented job is
folding catalog data into SystemDetail. DirectiveIngestion owns
directive.completed today but documents that writing one
DirectiveLogEntry is its ONLY job."
```

---

### Task 6: The `SurveyTargetSuggestions` resolver

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/SurveyTargetSuggestions.swift`
- Create: `app/Modules/DirectiveEngine/Tests/SurveyTargetSuggestionsTests.swift`

**Interfaces:**
- Consumes: `Star` and `Position` (UniverseModels), `Star.fullyScannedAt` now reliable (Tasks 2–4).
- Produces:
  - `SurveyTargetSuggestions.count: Int` (= 5)
  - `SurveyTargetSuggestions.Suggestion` with `designation: String`, `distanceLY: Double`, `id: String`
  - `SurveyTargetSuggestions.nearest(to: Position, anchorDesignation: String, stars: [Star], excluding: Set<String>, limit: Int) -> [Suggestion]`

  Task 7 depends on these exact names.

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/DirectiveEngine/Tests/SurveyTargetSuggestionsTests.swift`:

```swift
//
//  SurveyTargetSuggestionsTests.swift
//  DirectiveEngineTests
//
//  The launcher's nearest-unexplored suggestions. Pure function over fixtures,
//  the same shape as SurveyRun's stall matrix.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Survey target suggestions")
struct SurveyTargetSuggestionsTests {
    /// A census row `x` light-years out along the X axis.
    private func star(_ designation: String, x: Double, fullyScannedAt: Date? = nil) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            firstVisitedAt: nil, fullyScannedAt: fullyScannedAt
        )
    }

    private let origin = Position(x: 0, y: 0, z: 0)

    private func nearest(
        _ stars: [Star], excluding queued: Set<String> = [], anchor: String = "HOME"
    ) -> [String] {
        SurveyTargetSuggestions.nearest(
            to: origin, anchorDesignation: anchor, stars: stars, excluding: queued
        ).map(\.designation)
    }

    @Test func returnsTheFiveNearestInAscendingDistanceOrder() {
        let stars = [
            star("FAR", x: 60), star("NEAR", x: 10), star("MID", x: 30),
            star("FARTHER", x: 70), star("NEARER", x: 5), star("MIDDLE", x: 40),
        ]
        #expect(nearest(stars) == ["NEARER", "NEAR", "MID", "MIDDLE", "FAR"])
    }

    @Test func returnsFewerThanFiveWhenCandidatesAreScarce() {
        #expect(nearest([star("A", x: 1), star("B", x: 2)]) == ["A", "B"])
    }

    @Test func excludesTheAnchorsOwnSystem() {
        let stars = [star("HOME", x: 0), star("A", x: 4)]
        #expect(nearest(stars, anchor: "HOME") == ["A"])
    }

    @Test func excludesAlreadyQueuedTargets() {
        let stars = [star("A", x: 1), star("B", x: 2), star("C", x: 3)]
        #expect(nearest(stars, excluding: ["B"]) == ["A", "C"])
    }

    /// The whole point of Part A: a stamped system is done and must not be
    /// offered. A partially scanned one carries no stamp and stays suggestable —
    /// it is genuine survey work.
    @Test func excludesFullyScannedSystems() {
        let stars = [
            star("DONE", x: 1, fullyScannedAt: Date(timeIntervalSince1970: 5)),
            star("PARTIAL", x: 2),
        ]
        #expect(nearest(stars) == ["PARTIAL"])
    }

    /// A stable list is the whole design, so equal distances must not reorder
    /// between calls.
    @Test func breaksDistanceTiesOnDesignation() {
        let stars = [star("ZULU", x: 10), star("ALPHA", x: 10), star("MIKE", x: 10)]
        #expect(nearest(stars) == ["ALPHA", "MIKE", "ZULU"])
    }

    @Test func measuresDistanceInThreeDimensions() {
        let star = Star(
            designation: "PYTH", spectralType: "G", color: "yellow",
            positionX: 3, positionY: 4, positionZ: 0, estimatedPlanets: 1,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let result = SurveyTargetSuggestions.nearest(
            to: origin, anchorDesignation: "HOME", stars: [star], excluding: []
        )
        #expect(result.first?.distanceLY == 5)
    }

    @Test func honoursAnExplicitLimit() {
        let stars = (1...10).map { star("S\($0)", x: Double($0)) }
        let result = SurveyTargetSuggestions.nearest(
            to: origin, anchorDesignation: "HOME", stars: stars, excluding: [], limit: 3
        )
        #expect(result.map(\.designation) == ["S1", "S2", "S3"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules && swift test --test-product DirectiveEngineTests \
  --filter 'SurveyTargetSuggestionsTests' --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: build failure — `cannot find 'SurveyTargetSuggestions' in scope`.

- [ ] **Step 3: Implement the resolver**

Create `app/Modules/DirectiveEngine/Sources/SurveyTargetSuggestions.swift`:

```swift
//
//  SurveyTargetSuggestions.swift
//  Replicould — DirectiveEngine
//
//  What the New Survey Run launcher offers before you have typed anything: the
//  five nearest systems still worth surveying, measured from the vessel you
//  picked.
//
//  Pure by contract — no I/O, no clock, no randomness — so it tests as plain
//  function calls over fixtures, the same way `SurveyRun`'s stall matrix does.
//  It must NOT be a static on a SwiftUI `View`: pure logic in that position
//  traps with signal 5 under `swift test` (see the
//  swiftui-view-statics-trap-in-tests note).
//
//  "Still worth surveying" is `Star.fullyScannedAt == nil`, one nullable column
//  on rows the launcher already holds. That is only trustworthy because every
//  catalog write now stamps it (`SystemDetail.persist`); before that the column
//  was null on all 14,122 rows.
//

import Foundation
import UniverseModels

public enum SurveyTargetSuggestions {
    /// How many systems to offer. Five is the launcher's whole suggestion budget.
    public static let count = 5

    public struct Suggestion: Equatable, Sendable, Identifiable {
        public let designation: String
        /// Straight-line distance from the anchor, in light-years — the map's
        /// world unit.
        public let distanceLY: Double
        public var id: String { designation }

        public init(designation: String, distanceLY: Double) {
            self.designation = designation
            self.distanceLY = distanceLY
        }
    }

    /// The nearest systems to `anchor` that are neither already queued nor
    /// already fully surveyed, nearest first.
    ///
    /// Distances are always measured from the anchor and never re-based onto the
    /// growing queue, so adding a target removes it and pulls in the
    /// next-nearest rather than reshuffling the whole list.
    ///
    /// Selection is a single pass keeping the best `limit` by SQUARED distance:
    /// the census runs to 14,000+ rows, so a full sort (or a `sqrt` per
    /// candidate) would be paid on every keystroke that re-renders the picker.
    /// `sqrt` is applied only to the handful that survive.
    ///
    /// Ties break on designation. That is not cosmetic — a stable list is the
    /// point, and two equidistant stars must not swap places between renders.
    public static func nearest(
        to anchor: Position,
        anchorDesignation: String,
        stars: [Star],
        excluding queued: Set<String>,
        limit: Int = count
    ) -> [Suggestion] {
        guard limit > 0 else { return [] }

        // (squared distance, designation) — the sort key, cheapest form first.
        var best: [(distanceSquared: Double, designation: String)] = []
        best.reserveCapacity(limit + 1)

        for star in stars {
            let designation = star.designation
            guard designation != anchorDesignation,
                  star.fullyScannedAt == nil,
                  !queued.contains(designation)
            else { continue }

            let dx = star.positionX - anchor.x
            let dy = star.positionY - anchor.y
            let dz = star.positionZ - anchor.z
            let candidate = (distanceSquared: dx * dx + dy * dy + dz * dz, designation: designation)

            // Cheap reject: once the shortlist is full, anything worse than its
            // tail cannot make it. This is what keeps the pass linear.
            if best.count == limit, !isBetter(candidate, than: best[limit - 1]) { continue }

            let index = best.firstIndex { isBetter(candidate, than: $0) } ?? best.count
            best.insert(candidate, at: index)
            if best.count > limit { best.removeLast() }
        }

        return best.map {
            Suggestion(designation: $0.designation, distanceLY: $0.distanceSquared.squareRoot())
        }
    }

    /// Nearer wins; equal distance breaks on designation so the order is total
    /// and therefore stable.
    private static func isBetter(
        _ lhs: (distanceSquared: Double, designation: String),
        than rhs: (distanceSquared: Double, designation: String)
    ) -> Bool {
        lhs.distanceSquared == rhs.distanceSquared
            ? lhs.designation < rhs.designation
            : lhs.distanceSquared < rhs.distanceSquared
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd app/Modules && swift test --test-product DirectiveEngineTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

```bash
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/SurveyTargetSuggestions.swift \
        app/Modules/DirectiveEngine/Tests/SurveyTargetSuggestionsTests.swift
git commit -m "Add the nearest-unexplored survey target resolver

Pure, so it tests as function calls over fixtures like SurveyRun's
stall matrix — and deliberately not a static on a View, which traps
under swift test.

Selection is one linear pass keeping the best five by squared
distance: the census is 14,000+ rows and the picker re-renders on
every keystroke, so a full sort or a sqrt per candidate would be
paid each time. Ties break on designation because a stable list is
the whole design."
```

---

### Task 7: Wire the suggestions into the dialog

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/NewDirectiveFeature.swift:42-84`
- Create: `app/Modules/DirectivesFeature/Sources/SuggestedTargetRow.swift`
- Modify: `app/Modules/DirectivesFeature/Sources/NewDirectiveSheet.swift:76-119`
- Modify: `app/Modules/DirectivesFeature/Tests/NewDirectiveFeatureTests.swift`

**Interfaces:**
- Consumes: `SurveyTargetSuggestions.nearest(to:anchorDesignation:stars:excluding:limit:)` and `.Suggestion` (Task 6); `SiteAssay.system(of:)` (existing, UniverseModels); the existing `.targetAdded(String)` action.
- Produces: `NewDirectiveFeature.State.anchorSystem: String?` and `.suggestedTargets: [SurveyTargetSuggestions.Suggestion]`.

- [ ] **Step 1: Write the failing tests**

Append to `app/Modules/DirectivesFeature/Tests/NewDirectiveFeatureTests.swift`, inside the existing `NewDirectiveFeatureTests` suite. The suite already has a `star(_:)` fixture at line 260, but it hard-codes position 0 and no stamp — add a richer one alongside it rather than changing it (existing tests depend on it):

```swift
    /// A census row at `x` light-years along the X axis, optionally stamped as
    /// fully scanned.
    nonisolated static func star(
        _ designation: String, x: Double, fullyScannedAt: Date? = nil
    ) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            firstVisitedAt: nil, fullyScannedAt: fullyScannedAt
        )
    }
```

Then the test cases:

```swift
    /// The launcher suggests the five nearest systems still worth surveying,
    /// measured from the chosen vessel's own system.
    @Test func suggestsTheFiveNearestUnexploredSystems() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Star.insert { Self.star("SOL", x: 0) }.execute(db)
            for (index, name) in ["A", "B", "C", "D", "E", "F"].enumerated() {
                try Star.insert { Self.star(name, x: Double(index + 1)) }.execute(db)
            }
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(\.binding.vesselCode, "VES1")
        #expect(store.state.anchorSystem == "SOL")
        #expect(store.state.suggestedTargets.map(\.designation) == ["A", "B", "C", "D", "E"])
    }

    /// Adding a suggestion removes it and pulls in the next-nearest — the list
    /// stays anchored on the vessel rather than re-basing on the queue.
    @Test func addingASuggestionPullsInTheNextNearest() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Star.insert { Self.star("SOL", x: 0) }.execute(db)
            for (index, name) in ["A", "B", "C", "D", "E", "F"].enumerated() {
                try Star.insert { Self.star(name, x: Double(index + 1)) }.execute(db)
            }
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(\.binding.vesselCode, "VES1")
        await store.send(.targetAdded("B"))
        #expect(store.state.suggestedTargets.map(\.designation) == ["A", "C", "D", "E", "F"])
    }

    /// A fully-scanned system is done and must not be offered. This is what the
    /// fullyScannedAt work exists for.
    @Test func doesNotSuggestFullyScannedSystems() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Star.insert { Self.star("SOL", x: 0) }.execute(db)
            try Star.insert {
                Self.star("DONE", x: 1, fullyScannedAt: Date(timeIntervalSince1970: 10))
            }.execute(db)
            try Star.insert { Self.star("UNDONE", x: 2) }.execute(db)
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(\.binding.vesselCode, "VES1")
        #expect(store.state.suggestedTargets.map(\.designation) == ["UNDONE"])
    }

    /// No vessel chosen, or one in transit with no location, means no anchor to
    /// measure from — and so no suggestions. Consistent with the row this dialog
    /// writes, which already leaves `originDesignation` nil for such a vessel.
    @Test func offersNoSuggestionsWithoutAnAnchor() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Star.insert { Self.star("SOL", x: 0) }.execute(db)
            try Star.insert { Self.star("A", x: 1) }.execute(db)
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.anchorSystem == nil)
        #expect(store.state.suggestedTargets.isEmpty)
    }
```

The anchor is `SOL` because `bareVessel` already sets `location: "SOL-3"`, and `SiteAssay.system(of: "SOL-3")` is `"SOL"`. No fixture change is needed — do not modify `bareVessel`, other tests depend on it.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules && swift test --test-product DirectivesFeatureTests \
  --filter 'NewDirectiveFeatureTests' --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: build failure — `value of type 'NewDirectiveFeature.State' has no member 'anchorSystem'`.

- [ ] **Step 3: Add the anchor and suggestions to State**

In `NewDirectiveFeature.State`, after the existing `searchResults` computed property, add:

```swift
        /// The system the chosen vessel is in — the point every suggested
        /// distance is measured from.
        ///
        /// Nil covers both "no vessel picked yet" and "vessel in transit or
        /// stowed" (`location == nil`), and the dialog offers no suggestions in
        /// either case. That matches the row it would write: `originDesignation`
        /// is already nil for a locationless vessel.
        public var anchorSystem: String? {
            guard let vesselCode,
                  let vessel = devices.first(where: { $0.deviceCode == vesselCode }),
                  let location = vessel.location
            else { return nil }
            return SiteAssay.system(of: location)
        }

        /// The five nearest systems still worth surveying, measured from the
        /// vessel. Always anchored on the vessel and never re-based onto the
        /// queue, so adding one removes it and pulls in the next-nearest instead
        /// of reshuffling the list.
        public var suggestedTargets: [SurveyTargetSuggestions.Suggestion] {
            guard let anchorSystem,
                  let anchor = stars.first(where: { $0.designation == anchorSystem })
            else { return [] }
            return SurveyTargetSuggestions.nearest(
                to: anchor.position,
                anchorDesignation: anchorSystem,
                stars: stars,
                excluding: Set(targets)
            )
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd app/Modules && swift test --test-product DirectivesFeatureTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

```bash
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl
```

Expected: no output.

- [ ] **Step 5: Create the suggestion row**

Its own file, because a list-row struct beside a `#Preview` wedges the Xcode 26 preview JIT. Create `app/Modules/DirectivesFeature/Sources/SuggestedTargetRow.swift`:

```swift
//
//  SuggestedTargetRow.swift
//  Replicould — Directives feature
//
//  One row of the launcher's nearest-unexplored suggestions. Its own file: a
//  list-row struct sharing a file with a `#Preview` wedges the Xcode 26 preview
//  JIT (see the list-row-preview-crash memory note).
//

import DirectiveEngine
import SwiftUI
import UI

struct SuggestedTargetRow: View {
    let suggestion: SurveyTargetSuggestions.Suggestion
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack {
                // A designation is a code, so it renders mono — project rule.
                Text(suggestion.designation)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextPrimary)
                Spacer()
                Text(String(format: "%.1f ly", suggestion.distanceLY))
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
            .padding(.vertical, Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 6: Render the block in the sheet**

In `NewDirectiveSheet.swift`, add a computed property and call it from `targetPicker`. The block occupies the slot where search results render and appears only when the search field is empty, so typing swaps to search and clearing swaps back:

```swift
    /// The nearest unexplored systems, offered before any search is typed. Sits
    /// in the same slot as `searchResults` and yields to it the moment the field
    /// has text.
    @ViewBuilder private var suggestions: some View {
        if !store.suggestedTargets.isEmpty {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Nearest Unexplored")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                ForEach(store.suggestedTargets) { suggestion in
                    SuggestedTargetRow(suggestion: suggestion) {
                        store.send(.targetAdded(suggestion.designation))
                    }
                }
            }
        }
    }
```

Then in `targetPicker`, replace:

```swift
            RCField("Search systems", text: $store.search)
            if !store.searchResults.isEmpty {
```

with:

```swift
            RCField("Search systems", text: $store.search)
            if store.search.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestions
            }
            if !store.searchResults.isEmpty {
```

- [ ] **Step 7: Build and run the full package test suite**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: clean build. Then the whole suite, per-product to dodge the truncation trap:

```bash
cd app/Modules && rm -f .build/events-*.jsonl && \
for p in $(swift package describe --type json | jq -r '.targets[] | select(.type=="test") | .name'); do
  swift test --test-product "$p" --disable-xctest --event-stream-version 0 \
    --event-stream-output-path ".build/events-$p.jsonl" || true
done
cat .build/events-*.jsonl > .build/events.jsonl
```

```bash
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl
```

Expected: no output. Also confirm every product actually ran (the concatenated-stream gate):

```bash
jq -r 'select(.kind=="test").payload.id | split(".")[0]' .build/events.jsonl | sort -u
```

Expected: every test module listed, not just one.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/DirectivesFeature/Sources/NewDirectiveFeature.swift \
        app/Modules/DirectivesFeature/Sources/NewDirectiveSheet.swift \
        app/Modules/DirectivesFeature/Sources/SuggestedTargetRow.swift \
        app/Modules/DirectivesFeature/Tests/NewDirectiveFeatureTests.swift
git commit -m "Suggest the five nearest unexplored systems in the launcher

Shown before anything is typed, in the slot the search results
occupy, and yielding to them as soon as the field has text.
Anchored on the chosen vessel's own system; no vessel or a vessel
in transit means no anchor and no suggestions, matching the nil
originDesignation the dialog already writes for one.

Tapping a suggestion reuses .targetAdded, so the row leaves
because the queue now excludes it and the next-nearest slides in —
no new action, and the list never re-bases on the queue."
```

---

## Verification

After Task 7, verify the whole feature against the spec:

- [ ] `grep -rn "SystemDetail.upsert" --include="*.swift" --exclude-dir=.build app/ | grep -v "/Tests/"` returns exactly one hit, inside `SystemDetail.persist`.
- [ ] Spec §A5 falls out with no code change: confirm `LiveStar.scanState` is untouched by this branch (`git diff --stat main -- app/Modules/NewStarMapFeature/Sources/LiveStar.swift` is empty) and that it reads `fullyScannedAt` for its `.full` tier, which is now populated.
- [ ] Full package suite green via the event stream, with every test module present in the concatenated stream.
- [ ] `swift build --build-tests` clean, then re-run `./scripts/link-index-store.sh` so the LSP index reflects the new code before any review pass.
- [ ] The app target still compiles: `xcodebuild -project app/Replicant.xcodeproj -scheme Replicant -configuration Debug build` (per the memory note, an app-target *build* succeeds from a background job even though running it is blocked by the Keychain login wall).

## Out of scope

- Re-anchoring suggestions on the queue.
- The `partial · n/m scanned` caption on suggestion rows.
- Deduplicating the extra hydrate for engine-driven runs.
- Any change to Relay Run or the rest of Stage 5.
