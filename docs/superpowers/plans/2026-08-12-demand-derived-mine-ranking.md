# Demand-Derived Mine-Site Ranking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-aim `MineSitePlanner`'s scarcity bonus from hand-tuned constants at whichever resource types have the least headroom (theatre stock ÷ live demand), derived per brain tick.

**Architecture:** Three new pure units and one new table. `ResourceDemand` prices open location-event criteria through persisted blueprint bills to yield per-type demand. A new `locationInventories` table records per-type stock, written by the paths that already fetch inventory plus one hourly depot sweep. `WorldView` gains `theatreStock`; `ResourceHeadroom` turns stock ÷ demand into a two-slot weight table; `MineSitePlanner.scarceBonus` takes those weights instead of its constants, falling back to today's constants when stock is missing or stale.

**Tech Stack:** Swift 6, SwiftPM package at `app/Modules`, SQLiteData/GRDB, swift-testing, swift-dependencies.

## Global Constraints

- **Design source of truth:** `docs/superpowers/specs/2026-08-12-demand-derived-mine-ranking-design.md`.
- **Comment budget is hard:** file header ≤ 6 lines, `///` doc ≤ 3 lines, inline `//` ≤ 2 lines. Blank `///` lines and `//` separator lines COUNT against the budget; the two-line `//  <Name>.swift` / `//  Replicould — <Module>` banner is EXEMPT (`docs/superpowers/comment-cleanup-standard.md`). No dated history, no rejected alternatives, no live-fleet snapshots (device codes, current stock figures), no provenance pointers. Verify with `./app/scripts/check-comments.sh <paths>` from the repo root (paths repo-root relative) — exit 0 is a floor, not proof, since it is eleven regexes with no notion of line counts or prose.
- **Migrations are append-only.** New migration appends to `GameDatabase.manifest`; never edit or reorder a shipped one.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = module/service name.
- **Loud test defaults:** a shared client's `testValue` uses `unimplemented(...)`; rich fixtures belong on `previewValue`.
- **Reading test results:** never grep console text. Every run in this plan uses the canonical invocation — `--test-product <Target>` (one process, so the event stream is not truncated by a sibling target), `--disable-xctest`, `--event-stream-version 0`, and a per-filter output path under `.build/`. The `jq` gate after each run prints `started` and `failed`. **`started: 0` is a FAILED run, not a pass:** a filter that matches nothing exits 0 and prints only `warning: No matching test cases were run`. `--filter` matches the suite's Swift TYPE name, never its `@Suite("display name")`. Background and more recipes: the `swift-test-event-stream` skill.
- **Resource type vocabulary (verified live):** exactly `carbon`, `conductive`, `rares`, `silicates`, `structural`, `volatiles`.
- **Belt richness qualifiers (verified live):** `scarce`, `low`, `moderate`, `high`, `rich`. `atLeastModerate` means one of `moderate`, `high`, `rich`.
- **Commits go to local `main`.** No PRs, no pushes, no branches unless asked.
- **Build/test from `app/Modules`:** `swift build --build-tests`, `swift test`.
- **LSP:** after any build, `./scripts/link-index-store.sh` from `app/Modules` keeps reference queries working. An empty `findReferences` is never evidence a symbol is unused.

---

## File Structure

**Create:**
- `app/Modules/UniverseModels/Sources/LocationInventoryRecord.swift` — the `LocationInventory` `@Table` record, its `replace(...)` write helper, and its migration.
- `app/Modules/DirectiveEngine/Sources/ResourceDemand.swift` — the pure demand calculator.
- `app/Modules/DirectiveEngine/Sources/ResourceHeadroom.swift` — stock ÷ demand → the two-slot weight table, with the staleness fallback.
- `app/Modules/DirectiveEngine/Tests/ResourceDemandTests.swift`
- `app/Modules/DirectiveEngine/Tests/ResourceHeadroomTests.swift`
- `app/Modules/UniverseModels/Tests/LocationInventoryTests.swift`

**Modify:**
- `app/Modules/GameDatabase/Sources/GameDatabase.swift` — append the migration to `manifest`.
- `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift` — the frozen identifier list.
- `app/Modules/GameDatabase/Tests/Fixtures/` — regenerated golden schema.
- `app/Modules/GameServices/Sources/LocationsClient.swift` — persist per-type inventory on fetch; add `refreshDepotInventories(_:)`.
- `app/Modules/GameSync/Sources/DeadlineScheduler.swift` — the hourly depot-inventory sweep.
- `app/Modules/DirectiveEngine/Sources/WorldView.swift` — `theatreStock`, `theatreStockFreshness`, and their read.
- `app/Modules/DirectiveEngine/Sources/MineSitePlanner.swift` — `scarceBonus(richness:weights:)`, `Candidate.headroom`, `site(view:occupiedBelts:headroom:)`.
- `app/Modules/DirectiveEngine/Sources/Brain.swift` — derive weights per tick in `mineReadiness`.
- `app/Modules/DirectiveEngine/Tests/MineSitePlannerTests.swift` — weight-driven ranking and fallback.

---

### Task 1: `LocationInventory` record, migration, and write helper

**Files:**
- Create: `app/Modules/UniverseModels/Sources/LocationInventoryRecord.swift`
- Create: `app/Modules/UniverseModels/Tests/LocationInventoryTests.swift`
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift`
- Modify: `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks. `InventoryItem` (`UniverseModels/Sources/LocationModels.swift`) has `resourceType: String`, `quantity: Double`.
- Produces:
  - `public struct LocationInventory: Identifiable, Equatable, Sendable` with `location: String`, `resourceType: String`, `quantity: Double`, `fetchedAt: Date`, `id: String { "\(location)|\(resourceType)" }`.
  - `public static let createLocationInventories: SchemaMigration`
  - `public static func replace(location: String, items: [InventoryItem], fetchedAt: Date, in db: Database) throws`

- [ ] **Step 1: Write the failing test**

Create `app/Modules/UniverseModels/Tests/LocationInventoryTests.swift`:

```swift
//
//  LocationInventoryTests.swift
//  Replicould — UniverseModels
//

import Foundation
import GameDatabase
import SQLiteData
import Testing
@testable import UniverseModels

@Suite("LocationInventory — the per-type stock record")
struct LocationInventoryTests {
    private func database() throws -> any DatabaseWriter {
        try GameDatabase.bootstrap()
    }

    @Test("replace writes one row per resource type")
    func replaceWritesRows() throws {
        let db = try database()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        try db.write { db in
            try LocationInventory.replace(
                location: "AINALRAM-BELT-1",
                items: [
                    InventoryItem(resourceType: "conductive", quantity: 120),
                    InventoryItem(resourceType: "volatiles", quantity: 10),
                ],
                fetchedAt: now,
                in: db
            )
        }
        let rows = try db.read { db in
            try LocationInventory.all.order { $0.resourceType }.fetchAll(db)
        }
        #expect(rows.map(\.resourceType) == ["conductive", "volatiles"])
        #expect(rows.map(\.quantity) == [120, 10])
        #expect(rows.allSatisfy { $0.fetchedAt == now })
    }

    @Test("replace drops types absent from the fresh reading")
    func replaceDropsStaleTypes() throws {
        let db = try database()
        let first = Date(timeIntervalSince1970: 1_750_000_000)
        let second = first.addingTimeInterval(3600)
        try db.write { db in
            try LocationInventory.replace(
                location: "AINALRAM-BELT-1",
                items: [
                    InventoryItem(resourceType: "conductive", quantity: 120),
                    InventoryItem(resourceType: "volatiles", quantity: 10),
                ],
                fetchedAt: first,
                in: db
            )
            try LocationInventory.replace(
                location: "AINALRAM-BELT-1",
                items: [InventoryItem(resourceType: "conductive", quantity: 90)],
                fetchedAt: second,
                in: db
            )
        }
        let rows = try db.read { db in try LocationInventory.all.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.resourceType == "conductive")
        #expect(rows.first?.quantity == 90)
    }

    @Test("replace scopes its delete to the one location")
    func replaceScopesToLocation() throws {
        let db = try database()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        try db.write { db in
            try LocationInventory.replace(
                location: "OTHER-BELT-1",
                items: [InventoryItem(resourceType: "rares", quantity: 40)],
                fetchedAt: now, in: db
            )
            try LocationInventory.replace(
                location: "AINALRAM-BELT-1",
                items: [InventoryItem(resourceType: "conductive", quantity: 120)],
                fetchedAt: now, in: db
            )
        }
        let rows = try db.read { db in
            try LocationInventory.all.order { $0.location }.fetchAll(db)
        }
        #expect(rows.map(\.location) == ["AINALRAM-BELT-1", "OTHER-BELT-1"])
    }
}
```

No `Package.swift` change is needed: `UniverseModelsTests` already depends on `GameDatabase`, `UniverseModels`, and `SQLiteData`.

- [ ] **Step 2: Run the test to verify it fails**

From `app/Modules`:

```
swift test --test-product UniverseModelsTests --filter LocationInventoryTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-LocationInventoryTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-LocationInventoryTests.jsonl
```

Expected: compile failure — `cannot find 'LocationInventory' in scope`.

- [ ] **Step 3: Write the record, helper, and migration**

Create `app/Modules/UniverseModels/Sources/LocationInventoryRecord.swift`:

```swift
//
//  LocationInventoryRecord.swift
//  Replicould — UniverseModels
//
//  Per-resource-type stock at one location, beside the totals-only
//  `LocationFootprint`. Written wholesale per location, so a type absent from a
//  fresh reading is gone rather than stale.
//

import Foundation
import SQLiteData

@Table
public struct LocationInventory: Identifiable, Equatable, Sendable {
    public var location: String
    public var resourceType: String
    public var quantity: Double
    public var fetchedAt: Date

    public var id: String { "\(location)|\(resourceType)" }

    public init(location: String, resourceType: String, quantity: Double, fetchedAt: Date) {
        self.location = location
        self.resourceType = resourceType
        self.quantity = quantity
        self.fetchedAt = fetchedAt
    }
}

extension LocationInventory {
    /// Replace one location's rows with `items`. Call inside a write
    /// transaction: the delete and the insert must land together, or a reader
    /// between them sees the location holding nothing.
    public static func replace(
        location: String, items: [InventoryItem], fetchedAt: Date, in db: Database
    ) throws {
        try LocationInventory.where { $0.location.eq(location) }.delete().execute(db)
        let rows = items.map {
            LocationInventory(
                location: location, resourceType: $0.resourceType.lowercased(),
                quantity: $0.quantity, fetchedAt: fetchedAt
            )
        }
        guard !rows.isEmpty else { return }
        try LocationInventory.insert { rows }.execute(db)
    }

    /// Creates the `locationInventories` table.
    public static let createLocationInventories = SchemaMigration(
        "Create 'locationInventories' table"
    ) { db in
        try #sql(
            """
            CREATE TABLE "locationInventories" (
              "location" TEXT NOT NULL,
              "resourceType" TEXT NOT NULL,
              "quantity" REAL NOT NULL DEFAULT 0,
              "fetchedAt" TEXT NOT NULL,
              PRIMARY KEY ("location", "resourceType")
            ) STRICT
            """
        )
        .execute(db)
    }
}
```

- [ ] **Step 4: Append the migration to the manifest**

In `app/Modules/GameDatabase/Sources/GameDatabase.swift`, append to the END of the `manifest` array, immediately after `Directive.addTheatreDepot,`:

```swift
        LocationInventory.createLocationInventories,
```

`GameDatabase.swift` already imports `UniverseModels` (it references `LocationFootprint`); confirm and add the import only if missing.

Per that file's own note, decide the logout fate: `locationInventories` is account-scoped stock, so register a clear for it wherever `LocationFootprint` is cleared. Find that site with:

```
grep -rn "LocationFootprint" app/macOS app/Modules/AccountManager --include="*.swift"
```

Add a matching `try LocationInventory.all.delete().execute(db)` beside the footprint clear. If no footprint clear exists, skip this — do not invent a new cleanup site.

- [ ] **Step 5: Update the frozen manifest test**

Open `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift`, find the frozen array of migration identifier strings, and append `"Create 'locationInventories' table"` as the LAST element. Do not reorder anything.

- [ ] **Step 6: Regenerate the golden schema**

From `app/Modules`:

```
RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --test-product GameDatabaseTests \
  --filter GoldenSchemaTests --disable-xctest
```

Then re-run without the variable to confirm it passes against the regenerated fixture:

```
swift test --test-product GameDatabaseTests --filter GoldenSchemaTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-GoldenSchemaTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-GoldenSchemaTests.jsonl
```

Expected: PASS.

- [ ] **Step 7: Run the new tests**

```
swift test --test-product UniverseModelsTests --filter LocationInventoryTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-LocationInventoryTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-LocationInventoryTests.jsonl
swift test --test-product GameDatabaseTests --filter SchemaManifestTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-SchemaManifestTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-SchemaManifestTests.jsonl
```

Expected: all PASS.

- [ ] **Step 8: Check comments and commit**

```bash
./app/scripts/check-comments.sh app/Modules/UniverseModels/Sources/LocationInventoryRecord.swift
git add app/Modules/UniverseModels app/Modules/GameDatabase app/Modules/Package.swift
git commit -m "feat(stock): per-type locationInventories record and migration

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Persist per-type inventory from the paths that already fetch it

**Files:**
- Modify: `app/Modules/GameServices/Sources/LocationsClient.swift`
- Test: `app/Modules/GameServices/Tests/LocationInventoryPersistenceTests.swift` (create)

**Interfaces:**
- Consumes: `LocationInventory.replace(location:items:fetchedAt:in:)` from Task 1.
- Produces: `LocationsClient.refreshDepotInventories(_ depots: [String]) async` — fetches each depot's inventory and persists it, skipping (never throwing on) a depot that fails.

**Client shape (verified):** `LocationsClient` is a struct of `@Sendable` closures. `body: @Sendable (_ designation: String) async throws -> BodyDetail` is the stub point; `inventory(at:)` is an extension method over it (`LocationsClient.swift:90`). `BodyDetail` is an enum with cases `.planet`/`.moon`/`.belt`/`.special` (`UniverseModels/Sources/LocationDTOs.swift:679`), and `Belt`'s init defaults everything but `designation`, so `.belt(Belt(designation:inventory:))` is the whole fixture.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/GameServices/Tests/LocationInventoryPersistenceTests.swift`:

```swift
//
//  LocationInventoryPersistenceTests.swift
//  Replicould — GameServices
//

import Dependencies
import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
@testable import GameServices

@Suite("Depot inventory persistence")
struct LocationInventoryPersistenceTests {
    @Test("refreshDepotInventories writes one location's per-type rows")
    func writesRows() async throws {
        let db = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var client = LocationsClient.testValue
        client.body = { designation in
            #expect(designation == "AINALRAM-BELT-1")
            return .belt(Belt(
                designation: designation,
                inventory: [
                    InventoryItem(resourceType: "conductive", quantity: 19161),
                    InventoryItem(resourceType: "volatiles", quantity: 6538),
                ]
            ))
        }
        let stubbed = client
        await withDependencies {
            $0.defaultDatabase = db
            $0.date = .constant(now)
        } operation: {
            await stubbed.refreshDepotInventories(["AINALRAM-BELT-1"])
        }
        let rows = try db.read { db in
            try LocationInventory.all.order { $0.resourceType }.fetchAll(db)
        }
        #expect(rows.map(\.resourceType) == ["conductive", "volatiles"])
        #expect(rows.map(\.quantity) == [19161, 6538])
    }

    @Test("a failing depot is skipped, not fatal")
    func failingDepotIsSkipped() async throws {
        struct Boom: Error {}
        let db = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var client = LocationsClient.testValue
        client.body = { designation in
            if designation == "BAD-BELT-1" { throw Boom() }
            return .belt(Belt(
                designation: designation,
                inventory: [InventoryItem(resourceType: "rares", quantity: 40)]
            ))
        }
        let stubbed = client
        await withDependencies {
            $0.defaultDatabase = db
            $0.date = .constant(now)
        } operation: {
            await stubbed.refreshDepotInventories(["BAD-BELT-1", "GOOD-BELT-1"])
        }
        let rows = try db.read { db in try LocationInventory.all.fetchAll(db) }
        #expect(rows.map(\.location) == ["GOOD-BELT-1"])
    }
}
```

`LocationsClient.testValue` is `unimplemented(...)` per the house rule, so overwriting `body` is what makes these two tests the only calls that may happen — any other closure the code reaches fails loudly, which is the point.

`GameServicesTests` declares no direct `Dependencies` product (it gets it transitively through ComposableArchitecture). If `import Dependencies` fails to resolve, add `.product(name: "Dependencies", package: "swift-dependencies"),` to that test target's `dependencies` in `app/Modules/Package.swift`, preserving formatting and trailing commas.

- [ ] **Step 2: Run the test to verify it fails**

From `app/Modules`:

```
swift test --test-product GameServicesTests --filter LocationInventoryPersistenceTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-LocationInventoryPersistenceTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-LocationInventoryPersistenceTests.jsonl
```

Expected: compile failure — `value of type 'LocationsClient' has no member 'refreshDepotInventories'`.

- [ ] **Step 3: Persist on the existing fetch path**

In `LocationsClient.swift`, change `inventory(at:)` so what it fetches is also stored:

```swift
    /// Fresh inventory at a location, fetched through `body(_:)` and recorded
    /// per type so the brain can rank on stock it did not pay to read.
    public func inventory(at designation: String) async throws -> [InventoryItem] {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        let items = try await body(designation).inventory
        try? await database.write { db in
            try LocationInventory.replace(
                location: designation, items: items, fetchedAt: now, in: db
            )
        }
        return items
    }
```

The `try?` is deliberate: a read that succeeded must still return its value when the local write fails.

- [ ] **Step 4: Add the depot sweep**

In the same `extension LocationsClient` block:

```swift
    /// Refresh per-type stock at each depot, one read apiece. A depot that
    /// fails is skipped: the row simply ages, and the planner's staleness
    /// bound is what decides whether the aggregate is still trusted.
    public func refreshDepotInventories(_ depots: [String]) async {
        for depot in depots.sorted() {
            _ = try? await inventory(at: depot)
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```
swift test --test-product GameServicesTests --filter LocationInventoryPersistenceTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-LocationInventoryPersistenceTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-LocationInventoryPersistenceTests.jsonl
```

Expected: PASS. Then run the whole `GameServices` suite for regressions:

```
swift test --test-product GameServicesTests --filter GameServicesTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-GameServicesTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-GameServicesTests.jsonl
```

Expected: no new failures.

- [ ] **Step 6: Check comments and commit**

```bash
./app/scripts/check-comments.sh app/Modules/GameServices/Sources/LocationsClient.swift
git add app/Modules/GameServices
git commit -m "feat(stock): persist per-type inventory on every location read

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Hourly depot-inventory sweep

**Files:**
- Modify: `app/Modules/GameSync/Sources/DeadlineScheduler.swift`
- Test: `app/Modules/GameSync/Tests/DepotInventorySweepTests.swift` (create)

**Interfaces:**
- Consumes: `LocationsClient.refreshDepotInventories(_:)` (Task 2); `TheatreRegistry.recognise` is already used by `WorldView`.
- Produces: an hourly sweep inside `DeadlineScheduler.run()` that refreshes each operational theatre depot.

**Note on depot resolution:** `DirectiveEngine` is where theatres are recognised. Rather than have `GameSync` depend on it, resolve depots the cheap way the sweep can afford: distinct `LocationFootprint` locations that hold a print-capable device. Implement as a small private helper on the scheduler reading `Device.all` and filtering `\.isPrintHub` (the same predicate `WorldView.read` uses at `WorldView.swift:149`), taking each device's non-nil `location`.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/GameSync/Tests/DepotInventorySweepTests.swift`:

```swift
//
//  DepotInventorySweepTests.swift
//  Replicould — GameSync
//

import Foundation
import GameModels
import Testing
@testable import GameSync

@Suite("Depot inventory sweep")
struct DepotInventorySweepTests {
    @Test("depots are the distinct locations of print-capable devices")
    func depotsArePrintHubLocations() {
        let devices = [
            device(code: "AAAA1111", type: "autofactory", location: "AINALRAM-BELT-1"),
            device(code: "BBBB2222", type: "autofactory", location: "AINALRAM-BELT-1"),
            device(code: "CCCC3333", type: "mining_drone", location: "OTHER-BELT-1"),
        ]
        #expect(DeadlineScheduler.depotLocations(in: devices) == ["AINALRAM-BELT-1"])
    }

    @Test("a print-capable device with no location contributes nothing")
    func stowedPrintHubIsSkipped() {
        let devices = [device(code: "AAAA1111", type: "autofactory", location: nil)]
        #expect(DeadlineScheduler.depotLocations(in: devices).isEmpty)
    }
}
```

Write the `device(code:type:location:)` helper to match how other `GameSync` tests build a `Device`. Find an existing one first:

```
grep -rn "func device(" app/Modules/GameSync/Tests app/Modules/DirectiveEngine/Tests | head
```

Reuse that shape rather than inventing a second fixture builder. If the found helper lives in another test target, write a private one in this file with the same field ordering.

- [ ] **Step 2: Run the test to verify it fails**

```
swift test --test-product GameSyncTests --filter DepotInventorySweepTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-DepotInventorySweepTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-DepotInventorySweepTests.jsonl
```

Expected: compile failure — `type 'DeadlineScheduler' has no member 'depotLocations'`.

- [ ] **Step 3: Add the depot resolver**

In `DeadlineScheduler.swift`, add as a `nonisolated static` member so the test can call it without an actor hop:

```swift
    /// The depot locations worth a per-type stock read: where a print-capable
    /// device stands. A stowed one carries no location and is skipped.
    nonisolated static func depotLocations(in devices: [Device]) -> [String] {
        Array(Set(devices.filter(\.isPrintHub).compactMap(\.location))).sorted()
    }
```

- [ ] **Step 4: Add the throttled sweep to the run loop**

Beside `lastRetentionSweepAt` (around `DeadlineScheduler.swift:70-76`), add:

```swift
    /// Minimum spacing between per-type depot stock reads.
    private let depotInventoryInterval: TimeInterval = 3600
    private var lastDepotInventoryAt: Date?
```

In `run()`, after the retention-sweep block (around `DeadlineScheduler.swift:124-129`):

```swift
            if lastDepotInventoryAt.map({ now.timeIntervalSince($0) >= depotInventoryInterval }) ?? true {
                lastDepotInventoryAt = now
                await refreshDepotInventories()
            }
```

And the method itself, next to `sweepContinuousOps`:

```swift
    /// One per-type stock read per depot, hourly. The planner degrades to its
    /// static weights when these rows age, so a skipped round costs efficiency
    /// and never correctness.
    func refreshDepotInventories() async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.locationsClient) var locationsClient
        guard let devices = try? await database.read({ db in try Device.all.fetchAll(db) })
        else { return }
        let depots = Self.depotLocations(in: devices)
        guard !depots.isEmpty else { return }
        logger.debug("depot stock: refreshing \(depots.count, privacy: .public) depot(s)")
        await locationsClient.refreshDepotInventories(depots)
    }
```

If `GameSync`'s `Package.swift` target does not already depend on `GameServices`, it does — `DeadlineScheduler.swift` already imports it. Confirm rather than add.

- [ ] **Step 5: Run the tests to verify they pass**

```
swift test --test-product GameSyncTests --filter DepotInventorySweepTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-DepotInventorySweepTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-DepotInventorySweepTests.jsonl
swift test --test-product GameSyncTests --filter GameSyncTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-GameSyncTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-GameSyncTests.jsonl
```

Expected: new tests PASS, no new failures in `GameSync`.

- [ ] **Step 6: Check comments and commit**

```bash
./app/scripts/check-comments.sh app/Modules/GameSync/Sources/DeadlineScheduler.swift
git add app/Modules/GameSync
git commit -m "feat(stock): hourly per-type depot inventory sweep

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `ResourceDemand` — the pure calculator

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/ResourceDemand.swift`
- Create: `app/Modules/DirectiveEngine/Tests/ResourceDemandTests.swift`

**Interfaces:**
- Consumes: `LocationEvent` and its `quest: LocationEventDetail?` accessor (`GameModels`); `Blueprint.resources: ResourceCost` with typed `carbon`/`silicates`/`structural`/`rares`/`conductive`/`volatiles` `Int` fields (`GameModels/Sources/Blueprint.swift:82`); `BrainCeiling.reserveFloors: [String: Double]`.
- Produces:
  - `public struct ResourceDemand: Equatable, Sendable` with `total: [String: Double]` and `pricedEvents: [String: [ResourceDemand.PricedOption]]`.
  - `public struct ResourceDemand.PricedOption: Equatable, Sendable` with `name: String`, `cost: [String: Double]`, `units: Double`.
  - `public static func compute(events: [LocationEvent], bills: [String: ResourceCost], reserveFloors: [String: Double]) -> ResourceDemand`

**Note on test fixtures:** `LocationEventDetail.Option`'s memberwise init is internal to `GameModels`, so `DirectiveEngine` tests must build events from a `JSONValue` `detail` blob — which is the real decode path anyway. The helper below does that.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/ResourceDemandTests.swift`:

```swift
//
//  ResourceDemandTests.swift
//  Replicould — DirectiveEngine
//

import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

/// Builds an event whose `progress.options` carry the given requirement lines.
/// Mirrors the live `accounts/events` shape, so the decode under test is the
/// real one.
private func event(
    _ designation: String,
    status: String = "active",
    options: [(name: String, resources: [(String, Int, Int)], devices: [(String, Int, Int)])]
) -> LocationEvent {
    let optionValues: [JSONValue] = options.map { option in
        .object([
            "name": .string(option.name),
            "met": .bool(false),
            "resources": .array(option.resources.map { line in
                .object([
                    "resource_type": .string(line.0),
                    "current": .number(Double(line.1)),
                    "required": .number(Double(line.2)),
                    "met": .bool(line.1 >= line.2),
                ])
            }),
            "devices": .array(option.devices.map { line in
                .object([
                    "device_type": .string(line.0),
                    "current": .number(Double(line.1)),
                    "required": .number(Double(line.2)),
                    "met": .bool(line.1 >= line.2),
                ])
            }),
        ])
    }
    return LocationEvent(
        designation: designation,
        location: "CUHECHIA-4",
        status: status,
        detail: .object([
            "progress": .object(["met": .bool(false), "options": .array(optionValues)])
        ]),
        firstSeenAt: Date(timeIntervalSince1970: 1_750_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
}

private let defenceGrid = ResourceCost(
    silicates: 50, structural: 200, rares: 50, conductive: 100
)

@Suite("ResourceDemand — pricing open events")
struct ResourceDemandTests {
    @Test("a resource line contributes only its unmet remainder")
    func unmetRemainderOnly() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("default", [("conductive", 40, 100)], [])])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total["conductive"] == 60)
    }

    @Test("a met line contributes nothing and never goes negative")
    func metLineContributesNothing() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("default", [("conductive", 150, 100)], [])])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total["conductive"] == nil)
    }

    @Test("a device requirement is priced through its blueprint bill")
    func devicesPricedThroughBills() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("default", [], [("defence_grid", 0, 2)])])],
            bills: ["defence_grid": defenceGrid],
            reserveFloors: [:]
        )
        #expect(demand.total["conductive"] == 200)
        #expect(demand.total["structural"] == 400)
        #expect(demand.total["rares"] == 100)
        #expect(demand.total["silicates"] == 100)
        #expect(demand.total["carbon"] == nil)
    }

    @Test("only the cheapest priceable option of an event contributes")
    func cheapestOptionWins() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [
                ("expensive", [("conductive", 0, 500)], []),
                ("cheap", [("volatiles", 0, 10)], []),
            ])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total["volatiles"] == 10)
        #expect(demand.total["conductive"] == nil)
    }

    @Test("an option needing an unbilled device is unpriceable and skipped")
    func unpriceableOptionSkipped() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [
                ("unknown_device", [], [("shield_generator", 0, 1)]),
                ("known", [("conductive", 0, 100)], []),
            ])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total["conductive"] == 100)
        #expect(demand.pricedEvents["E-1"]?.map(\.name) == ["known"])
    }

    @Test("an event with no priceable option contributes nothing")
    func whollyUnpriceableEvent() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("only", [], [("shield_generator", 0, 1)])])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total.isEmpty)
        #expect(demand.pricedEvents["E-1"] == nil)
    }

    @Test("a closed event contributes nothing")
    func closedEventIgnored() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", status: "completed", options: [("default", [("conductive", 0, 100)], [])])],
            bills: [:],
            reserveFloors: [:]
        )
        #expect(demand.total.isEmpty)
    }

    @Test("reserve floors are folded in as recurring print demand")
    func reserveFloorsFoldedIn() {
        let demand = ResourceDemand.compute(
            events: [event("E-1", options: [("default", [("conductive", 0, 100)], [])])],
            bills: [:],
            reserveFloors: ["conductive": 600, "volatiles": 50]
        )
        #expect(demand.total["conductive"] == 700)
        #expect(demand.total["volatiles"] == 50)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```
swift test --test-product DirectiveEngineTests --filter ResourceDemandTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-ResourceDemandTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-ResourceDemandTests.jsonl
```

Expected: compile failure — `cannot find 'ResourceDemand' in scope`.

- [ ] **Step 3: Write the calculator**

Create `app/Modules/DirectiveEngine/Sources/ResourceDemand.swift`:

```swift
//
//  ResourceDemand.swift
//  Replicould — DirectiveEngine
//
//  What the fleet is being asked for: every open location event priced at its
//  cheapest resolution option, devices translated through their blueprint
//  bills, plus the standing print reserve. Pure — no I/O, no clock.
//

import Foundation
import GameModels

public struct ResourceDemand: Equatable, Sendable {
    /// One resolution option costed in resource units.
    public struct PricedOption: Equatable, Sendable {
        public let name: String
        public let cost: [String: Double]
        public var units: Double { cost.values.reduce(0, +) }

        public init(name: String, cost: [String: Double]) {
            self.name = name
            self.cost = cost
        }
    }

    /// Per-type demand: each open event's cheapest option, plus reserve floors.
    public let total: [String: Double]
    /// Every priceable option per event designation, cheapest first.
    public let pricedEvents: [String: [PricedOption]]

    public init(total: [String: Double], pricedEvents: [String: [PricedOption]]) {
        self.total = total
        self.pricedEvents = pricedEvents
    }

    /// Price `events` against `bills`, fold in `reserveFloors`. An option asking
    /// for a device with no blueprint cannot be fulfilled and is dropped, so
    /// demand under-counts rather than guessing.
    public static func compute(
        events: [LocationEvent],
        bills: [String: ResourceCost],
        reserveFloors: [String: Double]
    ) -> ResourceDemand {
        var total = reserveFloors
        var priced: [String: [PricedOption]] = [:]

        for event in events where event.isActive {
            guard let options = event.quest?.options, !options.isEmpty else { continue }
            let costed = options
                .compactMap { price($0, bills: bills) }
                .sorted { lhs, rhs in
                    lhs.units == rhs.units ? lhs.name < rhs.name : lhs.units < rhs.units
                }
            guard let cheapest = costed.first else { continue }
            priced[event.designation] = costed
            for (type, amount) in cheapest.cost { total[type, default: 0] += amount }
        }
        return ResourceDemand(total: total, pricedEvents: priced)
    }

    /// One option's unmet remainder, or nil when it needs an unbilled device.
    private static func price(
        _ option: LocationEventDetail.Option, bills: [String: ResourceCost]
    ) -> PricedOption? {
        var cost: [String: Double] = [:]
        for line in option.resources {
            let remaining = max(0, line.required - line.current)
            guard remaining > 0 else { continue }
            cost[line.resourceType.lowercased(), default: 0] += Double(remaining)
        }
        for line in option.devices {
            let remaining = max(0, line.required - line.current)
            guard remaining > 0 else { continue }
            guard let bill = bills[line.deviceType] else { return nil }
            for (type, amount) in bill.wireDictionary where amount > 0 {
                cost[type, default: 0] += Double(amount * remaining)
            }
        }
        return PricedOption(name: option.name, cost: cost)
    }
}
```

- [ ] **Step 4: Add `ResourceCost.wireDictionary`**

`ResourceCost` has typed fields and a `init(wire:)` but no way back out. In `app/Modules/GameModels/Sources/Blueprint.swift`, inside `struct ResourceCost` after `init(wire:)`:

```swift
    /// The typed cost back as the sparse `{resource: amount}` shape, zeros
    /// included — callers filter.
    public var wireDictionary: [String: Int] {
        [
            "carbon": carbon, "silicates": silicates, "structural": structural,
            "rares": rares, "conductive": conductive, "volatiles": volatiles,
        ]
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```
swift test --test-product DirectiveEngineTests --filter ResourceDemandTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-ResourceDemandTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-ResourceDemandTests.jsonl
```

Expected: all 8 tests PASS.

- [ ] **Step 6: Check comments and commit**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/ResourceDemand.swift app/Modules/GameModels/Sources/Blueprint.swift
git add app/Modules/DirectiveEngine app/Modules/GameModels
git commit -m "feat(brain): ResourceDemand prices open events through blueprint bills

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: `WorldView.theatreStock`

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldView.swift`
- Test: `app/Modules/DirectiveEngine/Tests/WorldViewStockTests.swift` (create)

**Interfaces:**
- Consumes: `LocationInventory` (Task 1); `Theatre.isOperational`, `Theatre.depot`.
- Produces: `WorldView.theatreStock: [String: Double]`, `WorldView.theatreStockFreshness: Date?`, both with defaults on `init` so every existing construction site keeps compiling.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/WorldViewStockTests.swift`:

```swift
//
//  WorldViewStockTests.swift
//  Replicould — DirectiveEngine
//

import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("WorldView — theatre stock")
struct WorldViewStockTests {
    @Test("stock sums the operational depots' rows and takes the oldest read")
    func sumsOperationalDepots() {
        let older = Date(timeIntervalSince1970: 1_750_000_000)
        let newer = older.addingTimeInterval(600)
        let rows = [
            LocationInventory(location: "A-BELT-1", resourceType: "conductive", quantity: 100, fetchedAt: older),
            LocationInventory(location: "B-BELT-1", resourceType: "conductive", quantity: 50, fetchedAt: newer),
            LocationInventory(location: "B-BELT-1", resourceType: "rares", quantity: 25, fetchedAt: newer),
            LocationInventory(location: "OFF-BELT-1", resourceType: "rares", quantity: 9999, fetchedAt: newer),
        ]
        let stock = WorldView.aggregateStock(rows: rows, depots: ["A-BELT-1", "B-BELT-1"])
        #expect(stock.quantities == ["conductive": 150, "rares": 25])
        #expect(stock.freshness == older)
    }

    @Test("no depot row means empty stock and no freshness")
    func noRowsMeansUnknown() {
        let stock = WorldView.aggregateStock(rows: [], depots: ["A-BELT-1"])
        #expect(stock.quantities.isEmpty)
        #expect(stock.freshness == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```
swift test --test-product DirectiveEngineTests --filter WorldViewStockTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-WorldViewStockTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-WorldViewStockTests.jsonl
```

Expected: compile failure — `type 'WorldView' has no member 'aggregateStock'`.

- [ ] **Step 3: Add the properties and the aggregation**

In `WorldView.swift`, add after `stockpileUnits` (line 71):

```swift
    /// Per-type stock summed over the operational theatres' depots. Empty when
    /// no depot has a per-type reading — absence is unknown, never zero.
    public let theatreStock: [String: Double]
    /// The OLDEST `fetchedAt` among the depot rows read, so a depot that has
    /// stopped refreshing ages the aggregate rather than hiding behind a
    /// livelier sibling.
    public let theatreStockFreshness: Date?
```

Add to `init` (after `stockpileUnits: [String: Int] = [:],`):

```swift
        theatreStock: [String: Double] = [:],
        theatreStockFreshness: Date? = nil,
```

and the two assignments in the body:

```swift
        self.theatreStock = theatreStock
        self.theatreStockFreshness = theatreStockFreshness
```

Add the pure aggregator as a static on `WorldView`. Named `aggregateStock`, not `theatreStock` — a static function sharing a name with the instance property it feeds compiles but reads as one thing:

```swift
    /// The per-type sum over `depots` and the oldest read behind it.
    static func aggregateStock(
        rows: [LocationInventory], depots: Set<String>
    ) -> (quantities: [String: Double], freshness: Date?) {
        let relevant = rows.filter { depots.contains($0.location) }
        var quantities: [String: Double] = [:]
        for row in relevant { quantities[row.resourceType, default: 0] += row.quantity }
        return (quantities, relevant.map(\.fetchedAt).min())
    }
```

- [ ] **Step 4: Wire it into `read(from:now:)`**

In `read(from:now:)`, after the `theatres` are recognised (after `WorldView.swift:162`):

```swift
        let operationalDepots = Set(theatres.filter(\.isOperational).map(\.depot))
        let inventoryRows = operationalDepots.isEmpty ? [] : try LocationInventory
            .where { $0.location.in(Array(operationalDepots)) }
            .fetchAll(db)
        let stock = Self.aggregateStock(rows: inventoryRows, depots: operationalDepots)
```

and pass both into the returned `WorldView(...)`, after `stockpileUnits:`:

```swift
            theatreStock: stock.quantities,
            theatreStockFreshness: stock.freshness,
```

- [ ] **Step 5: Run the tests to verify they pass**

```
swift test --test-product DirectiveEngineTests --filter WorldViewStockTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-WorldViewStockTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-WorldViewStockTests.jsonl
swift test --test-product DirectiveEngineTests --filter DirectiveEngineTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-DirectiveEngineTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-DirectiveEngineTests.jsonl
```

Expected: new tests PASS; `DirectiveEngine` shows no new failures. Note that `theSupervisorAdoptsTheRowTheBrainLaunched` is a known pre-existing failure under whole-package runs — do not attribute it to this change.

- [ ] **Step 6: Check comments and commit**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/WorldView.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(brain): WorldView carries per-type theatre stock and its freshness

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: `ResourceHeadroom` — stock ÷ demand → weights

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/ResourceHeadroom.swift`
- Create: `app/Modules/DirectiveEngine/Tests/ResourceHeadroomTests.swift`

**Interfaces:**
- Consumes: `ResourceDemand.total` (Task 4); `WorldView.theatreStock` / `.theatreStockFreshness` (Task 5).
- Produces:
  - `public struct ResourceHeadroom: Equatable, Sendable` with `weights: [String: Int]`, `coverage: [String: Double]`, `isFallback: Bool`.
  - `public static let staticWeights: [String: Int]` — `["rares": 2, "conductive": 1]`.
  - `public static let stalenessBound: TimeInterval` — `86_400`.
  - `public static func derive(stock: [String: Double], demand: [String: Double], freshness: Date?, now: Date) -> ResourceHeadroom`

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/ResourceHeadroomTests.swift`:

```swift
//
//  ResourceHeadroomTests.swift
//  Replicould — DirectiveEngine
//

import Foundation
import Testing
@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 1_750_000_000)

@Suite("ResourceHeadroom — stock over demand")
struct ResourceHeadroomTests {
    @Test("the two least-covered types take the bonus slots")
    func leastCoveredTakeTheSlots() {
        let headroom = ResourceHeadroom.derive(
            stock: ["silicates": 12777, "conductive": 19161, "volatiles": 6538, "structural": 78590],
            demand: ["silicates": 4140, "conductive": 4450, "volatiles": 590, "structural": 3890],
            freshness: now,
            now: now
        )
        #expect(headroom.weights == ["silicates": 2, "conductive": 1])
        #expect(headroom.isFallback == false)
    }

    @Test("a type with no demand never takes a slot")
    func zeroDemandRanksLast() {
        let headroom = ResourceHeadroom.derive(
            stock: ["rares": 1, "conductive": 1000, "volatiles": 2000],
            demand: ["conductive": 10, "volatiles": 10],
            freshness: now,
            now: now
        )
        #expect(headroom.weights == ["conductive": 2, "volatiles": 1])
    }

    @Test("a type with demand and no stock is the most bound")
    func missingStockIsZeroCoverage() {
        let headroom = ResourceHeadroom.derive(
            stock: ["conductive": 1000],
            demand: ["silicates": 100, "conductive": 10],
            freshness: now,
            now: now
        )
        #expect(headroom.weights["silicates"] == 2)
        #expect(headroom.coverage["silicates"] == 0)
    }

    @Test("empty stock falls back to the static weights")
    func emptyStockFallsBack() {
        let headroom = ResourceHeadroom.derive(
            stock: [:], demand: ["silicates": 100], freshness: now, now: now
        )
        #expect(headroom.weights == ResourceHeadroom.staticWeights)
        #expect(headroom.isFallback)
    }

    @Test("stock older than the bound falls back to the static weights")
    func staleStockFallsBack() {
        let headroom = ResourceHeadroom.derive(
            stock: ["silicates": 10, "conductive": 1000],
            demand: ["silicates": 100, "conductive": 10],
            freshness: now.addingTimeInterval(-ResourceHeadroom.stalenessBound - 1),
            now: now
        )
        #expect(headroom.weights == ResourceHeadroom.staticWeights)
        #expect(headroom.isFallback)
    }

    @Test("stock with no freshness stamp falls back")
    func missingFreshnessFallsBack() {
        let headroom = ResourceHeadroom.derive(
            stock: ["silicates": 10], demand: ["silicates": 100], freshness: nil, now: now
        )
        #expect(headroom.weights == ResourceHeadroom.staticWeights)
        #expect(headroom.isFallback)
    }

    @Test("no demand at all falls back rather than ranking on nothing")
    func noDemandFallsBack() {
        let headroom = ResourceHeadroom.derive(
            stock: ["silicates": 10], demand: [:], freshness: now, now: now
        )
        #expect(headroom.weights == ResourceHeadroom.staticWeights)
        #expect(headroom.isFallback)
    }

    @Test("ties break on the type name so the ranking is stable")
    func tiesBreakOnName() {
        let headroom = ResourceHeadroom.derive(
            stock: ["conductive": 100, "silicates": 100, "rares": 900],
            demand: ["conductive": 10, "silicates": 10, "rares": 10],
            freshness: now,
            now: now
        )
        #expect(headroom.weights == ["conductive": 2, "silicates": 1])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```
swift test --test-product DirectiveEngineTests --filter ResourceHeadroomTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-ResourceHeadroomTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-ResourceHeadroomTests.jsonl
```

Expected: compile failure — `cannot find 'ResourceHeadroom' in scope`.

- [ ] **Step 3: Write the derivation**

Create `app/Modules/DirectiveEngine/Sources/ResourceHeadroom.swift`:

```swift
//
//  ResourceHeadroom.swift
//  Replicould — DirectiveEngine
//
//  Which resource types the fleet is nearest to running short of: stock over
//  demand, least-covered first. Yields the two bonus slots `MineSitePlanner`
//  ranks belts with. Pure — no I/O, `now` is passed in.
//

import Foundation

public struct ResourceHeadroom: Equatable, Sendable {
    /// Resource type → bonus points, at most two entries (+2 and +1).
    public let weights: [String: Int]
    /// Stock ÷ demand per demanded type, for the why-view.
    public let coverage: [String: Double]
    /// Whether `weights` is the static table rather than a derived reading.
    public let isFallback: Bool

    public init(weights: [String: Int], coverage: [String: Double], isFallback: Bool) {
        self.weights = weights
        self.coverage = coverage
        self.isFallback = isFallback
    }

    /// The weights used when stock is unknown or stale — the ranking this
    /// replaced, so degrading changes nothing rather than making it worse.
    public static let staticWeights: [String: Int] = ["rares": 2, "conductive": 1]

    /// How old a stock reading may be and still be ranked on.
    public static let stalenessBound: TimeInterval = 86_400

    /// Weights from `stock` over `demand`. Falls back whenever the reading is
    /// missing, stale, or there is no demand to divide by.
    public static func derive(
        stock: [String: Double], demand: [String: Double], freshness: Date?, now: Date
    ) -> ResourceHeadroom {
        let demanded = demand.filter { $0.value > 0 }
        guard !stock.isEmpty, !demanded.isEmpty,
              let freshness, now.timeIntervalSince(freshness) <= stalenessBound
        else {
            return ResourceHeadroom(weights: staticWeights, coverage: [:], isFallback: true)
        }

        var coverage: [String: Double] = [:]
        for (type, required) in demanded { coverage[type] = (stock[type] ?? 0) / required }

        let ranked = coverage
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
            }
            .prefix(2)
        var weights: [String: Int] = [:]
        for (offset, entry) in ranked.enumerated() { weights[entry.key] = 2 - offset }
        return ResourceHeadroom(weights: weights, coverage: coverage, isFallback: false)
    }

    /// The reading to rank with when there is none: the shipped constants.
    public static let staticFallback = ResourceHeadroom(
        weights: staticWeights, coverage: [:], isFallback: true
    )
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```
swift test --test-product DirectiveEngineTests --filter ResourceHeadroomTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-ResourceHeadroomTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-ResourceHeadroomTests.jsonl
```

Expected: all 8 tests PASS.

- [ ] **Step 5: Check comments and commit**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/ResourceHeadroom.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(brain): ResourceHeadroom derives bonus weights from stock over demand

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: `MineSitePlanner` takes the weights

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MineSitePlanner.swift`
- Modify: `app/Modules/DirectiveEngine/Tests/MineSitePlannerTests.swift`

**Interfaces:**
- Consumes: `ResourceHeadroom` and `ResourceHeadroom.staticFallback` (Task 6).
- Produces:
  - `public static func scarceBonus(richness: [String: String], weights: [String: Int] = ResourceHeadroom.staticWeights) -> Int`
  - `public static func site(view: WorldView, occupiedBelts: Set<String>, headroom: ResourceHeadroom = .staticFallback) -> Candidate?`
  - `Candidate.headroom: ResourceHeadroom` alongside the existing `scarceBonus` — the whole reading (weights, coverage, fallback flag), so the why-view can name the coverage figure behind each boost rather than a bare score.

- [ ] **Step 1: Write the failing test**

Append to `app/Modules/DirectiveEngine/Tests/MineSitePlannerTests.swift`, inside the existing `struct MineSitePlannerTests`:

```swift
    @Test("the bonus follows the supplied weights, not the old constants")
    func bonusFollowsWeights() {
        let weights = ["silicates": 2, "conductive": 1]
        #expect(
            MineSitePlanner.scarceBonus(
                richness: ["silicates": "moderate", "rares": "rich"], weights: weights
            ) == 2
        )
        #expect(
            MineSitePlanner.scarceBonus(
                richness: ["conductive": "high", "rares": "rich"], weights: weights
            ) == 1
        )
        #expect(
            MineSitePlanner.scarceBonus(
                richness: ["silicates": "low", "conductive": "scarce"], weights: weights
            ) == 0
        )
    }

    @Test("a weighted type breaks a same-class tie the constants would miss")
    func weightsDecideTheSite() {
        let view = siteView(
            belts: [
                "NEAR": [BeltInfo(designation: "NEAR-BELT-1", beltClass: .rich, richness: ["rares": "rich"])],
                "FAR": [BeltInfo(designation: "FAR-BELT-1", beltClass: .rich, richness: ["silicates": "moderate"])],
            ],
            meshSystems: ["AINALRAM", "NEAR", "FAR"],
            positions: [
                "AINALRAM": .init(x: 0, y: 0, z: 0),
                "NEAR": .init(x: 1, y: 0, z: 0),
                "FAR": .init(x: 30, y: 0, z: 0),
            ]
        )
        let headroom = ResourceHeadroom(
            weights: ["silicates": 2, "conductive": 1],
            coverage: ["silicates": 3.1, "conductive": 4.3],
            isFallback: false
        )
        let site = MineSitePlanner.site(view: view, occupiedBelts: [], headroom: headroom)
        #expect(site?.belt == "FAR-BELT-1")
        #expect(site?.headroom.weights == ["silicates": 2, "conductive": 1])
        #expect(site?.headroom.coverage["silicates"] == 3.1)
    }

    @Test("the default weights reproduce the shipped ranking")
    func defaultWeightsAreTheOldConstants() {
        #expect(MineSitePlanner.scarceBonus(richness: ["rares": "moderate"]) == 2)
        #expect(MineSitePlanner.scarceBonus(richness: ["conductive": "high"]) == 1)
        #expect(MineSitePlanner.scarceBonus(richness: ["rares": "moderate", "conductive": "moderate"]) == 3)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```
swift test --test-product DirectiveEngineTests --filter MineSitePlannerTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-MineSitePlannerTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-MineSitePlannerTests.jsonl
```

Expected: compile failure — extra argument `weights` in call.

- [ ] **Step 3: Re-aim the bonus**

Replace `scarceBonus` and its doc in `MineSitePlanner.swift:23-30`:

```swift
    /// The belt's score under `weights`: each weighted type present at ≥
    /// moderate adds its points. Unweighted types add nothing.
    public static func scarceBonus(
        richness: [String: String],
        weights: [String: Int] = ResourceHeadroom.staticWeights
    ) -> Int {
        weights.reduce(0) { total, entry in
            atLeastModerate(richness[entry.key]) ? total + entry.value : total
        }
    }
```

Add to `Candidate` (after `distanceLY`):

```swift
        /// The reading the bonus was scored under, for the why-view.
        public let headroom: ResourceHeadroom
```

`Candidate` has no explicit `init`, so the compiler's memberwise one gains the parameter; the single construction site in `site(...)` is updated below.

Update `site(...)`'s signature and the construction:

```swift
    public static func site(
        view: WorldView,
        occupiedBelts: Set<String>,
        headroom: ResourceHeadroom = .staticFallback
    ) -> Candidate? {
```

and inside the belt loop:

```swift
                candidates.append(Candidate(
                    belt: belt.designation,
                    system: system,
                    beltClass: belt.beltClass,
                    scarceBonus: scarceBonus(richness: belt.richness, weights: headroom.weights),
                    distanceLY: originPosition.distance(to: position),
                    headroom: headroom
                ))
```

Keep the file header's second line accurate — it names the rank terms — by changing "a rares/conductive scarcity bonus" to "a demand-weighted scarcity bonus". Keep the header at 6 lines or fewer.

- [ ] **Step 4: Run the tests to verify they pass**

```
swift test --test-product DirectiveEngineTests --filter MineSitePlannerTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-MineSitePlannerTests.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-MineSitePlannerTests.jsonl
```

Expected: all tests PASS, including the pre-existing ones (the defaulted parameter keeps them valid).

- [ ] **Step 5: Check comments and commit**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/MineSitePlanner.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(brain): MineSitePlanner scores belts against supplied weights

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Wire the brain and surface the why

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift`
- Modify: `app/Modules/DirectiveEngine/Tests/BrainMineTests.swift` (verified: the only suite covering `mineReadiness`)

**Interfaces:**
- Consumes: `ResourceDemand.compute(events:bills:reserveFloors:)`, `ResourceHeadroom.derive(stock:demand:freshness:now:)`, `MineSitePlanner.site(view:occupiedBelts:headroom:)`, `BrainCeiling.reserveFloors`.
- Produces: `Brain.siteWeights(view:events:bills:) -> ResourceHeadroom`, consumed inside `mineReadiness`.

**Note on inputs:** `mineReadiness` takes `view: WorldView` and `directives: [Directive]` today. `WorldView` carries neither `LocationEvent` rows nor `Blueprint` rows. Rather than widen `WorldView` (both are read for one goal only), add the two as defaulted parameters on `mineReadiness` and pass them from the caller, which already has a `Snapshot`. Check what the caller (`Brain.ensureMine`, around `Brain.swift:427`) has in hand; if it cannot supply them, widen `WorldView` with `locationEvents: [LocationEvent]` and `blueprintBills: [String: ResourceCost]` read in `read(from:now:)` — `LocationEvent.all` is already fetched there at `WorldView.swift:142`, so reuse that array rather than reading it twice.

- [ ] **Step 1: Write the failing test**

Add to the suite covering `mineReadiness`:

```swift
    @Test("the site ranking uses demand-derived weights when stock is fresh")
    func mineSitingUsesDemandWeights() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let headroom = Brain.siteWeights(
            stock: ["silicates": 12777, "conductive": 19161, "volatiles": 6538],
            events: [],
            bills: [:],
            freshness: now,
            now: now
        )
        #expect(headroom.isFallback == false)
        #expect(headroom.weights.count == 2)
    }

    @Test("no stock reading leaves the shipped constants in force")
    func mineSitingFallsBackWithoutStock() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let headroom = Brain.siteWeights(
            stock: [:], events: [], bills: [:], freshness: nil, now: now
        )
        #expect(headroom.weights == ResourceHeadroom.staticWeights)
        #expect(headroom.isFallback)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```
swift test --test-product DirectiveEngineTests --filter Brain \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-Brain.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-Brain.jsonl
```

Expected: compile failure — `type 'Brain' has no member 'siteWeights'`.

- [ ] **Step 3: Add the derivation to `Brain`**

Next to `mineReadiness` in `Brain.swift`:

```swift
    /// This tick's mine-siting weights: open-event demand plus the standing
    /// print reserve, divided into depot stock.
    static func siteWeights(
        stock: [String: Double],
        events: [LocationEvent],
        bills: [String: ResourceCost],
        freshness: Date?,
        now: Date
    ) -> ResourceHeadroom {
        let demand = ResourceDemand.compute(
            events: events, bills: bills, reserveFloors: BrainCeiling.reserveFloors
        )
        return ResourceHeadroom.derive(
            stock: stock, demand: demand.total, freshness: freshness, now: now
        )
    }
```

- [ ] **Step 4: Use it in `mineReadiness`**

In `mineReadiness`, replace the `MineSitePlanner.site` calls (around `Brain.swift:1346-1347`) with weighted ones:

```swift
        let headroom = siteWeights(
            stock: view.theatreStock, events: events, bills: bills,
            freshness: view.theatreStockFreshness, now: view.now
        )
        guard let site = MineSitePlanner.site(
            view: view, occupiedBelts: occupied, headroom: headroom
        ) else {
            let anyBelt = MineSitePlanner.site(
                view: view, occupiedBelts: depots, headroom: headroom
            ) != nil
            return .idle(reason: anyBelt ? "every candidate belt taken" : "no meshed candidate belt")
        }
```

Thread `events` and `bills` in per the note above — either as defaulted `mineReadiness` parameters supplied by the caller, or off `WorldView` if you widened it. Whichever you pick, keep the signature change to `mineReadiness` alone; do not widen `mineHealth` or `mineFerryController`.

- [ ] **Step 5: Log the applied weights**

At the end of the `.launch` path in `mineReadiness`, before returning:

```swift
        let boosted = headroom.weights
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key)+\($0.value)" }
            .joined(separator: " ")
        logger.debug(
            """
            mine siting: \(site.belt, privacy: .public) \
            boosting \(boosted, privacy: .public)\
            \(headroom.isFallback ? " (static)" : "", privacy: .public)
            """
        )
```

Confirm `Brain.swift` already declares a `logger` at file scope; if the name differs, use the existing one.

- [ ] **Step 6: Run the tests to verify they pass**

```
swift test --test-product DirectiveEngineTests --filter Brain \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events-Brain.jsonl
jq -s '[.[] | select(.kind=="event").payload]
   | {started: map(select(.kind=="testStarted")) | length,
      failed: [.[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique | length}' \
  .build/events-Brain.jsonl
```

Expected: new tests PASS, no new failures.

- [ ] **Step 7: Run the whole package**

From `app/Modules`:

```
swift build --build-tests && ./scripts/link-index-store.sh
rm -f .build/events-*.jsonl   # per-filter runs write events-<Suite>.jsonl, which the glob would sweep in
for p in UniverseModelsTests GameDatabaseTests GameServicesTests GameSyncTests DirectiveEngineTests; do
  swift test --test-product "$p" --disable-xctest --event-stream-version 0 \
    --event-stream-output-path ".build/events-$p.jsonl"
done
cat .build/events-UniverseModelsTests.jsonl .build/events-GameDatabaseTests.jsonl \
    .build/events-GameServicesTests.jsonl .build/events-GameSyncTests.jsonl \
    .build/events-DirectiveEngineTests.jsonl > .build/events-all.jsonl
jq -s '[.[] | select(.kind=="event").payload] as $e
  | {started: ($e | map(select(.kind=="testStarted")) | length),
     ended:   ($e | map(select(.kind=="testEnded")) | length),
     failed:  ([$e[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique),
     crashed: (($e | map(select(.kind=="testStarted").testID))
             - ($e | map(select(.kind=="testEnded" or .kind=="testSkipped").testID)))}' \
  .build/events-all.jsonl
```

Read the results through the `swift-test-event-stream` skill's `jq` recipes — it also covers the multi-target truncation trap, which matters here because several test targets are involved. Expected: no failures other than the known pre-existing `theSupervisorAdoptsTheRowTheBrainLaunched`.

- [ ] **Step 8: Check comments and commit**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/Brain.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(brain): site mines against demand-derived resource weights

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Memory note and index line

**Files:**
- Create: `app/.claude/memory/demand-derived-mine-ranking.md`
- Modify: `app/.claude/memory/MEMORY.md`

**Interfaces:**
- Consumes: everything built above.
- Produces: the durable record. Several facts in this plan exist nowhere in source by policy (the measured demand mix, why volatiles is NOT the binding type, the fallback's rationale), so they must land here.

- [ ] **Step 1: Write the note**

Create `app/.claude/memory/demand-derived-mine-ranking.md` with frontmatter matching the sibling notes' shape (`name`, `description`, `metadata.type: project`). Record:

- The measured 2026-08-12 figures: collections (structural 40,779 · conductive 16,048 · silicates 9,543 · carbon 5,801 · rares 4,805 · volatiles 1,239), hub stock (structural 78,590 · carbon 21,398 · conductive 19,161 · silicates 12,777 · rares 10,917 · volatiles 6,538), and event demand across 47 active events at cheapest option (conductive 4,450 · silicates 4,140 · structural 3,890 · carbon 2,950 · rares 950 · volatiles 590).
- **The correction worth keeping: volatiles being last in collections is the system working.** It has ~11× coverage. Silicates (3.1×) and conductive (4.3×) bind, and silicates scored ZERO under the old constants. Least-collected is the wrong signal; stock ÷ demand is the right one. This is the same absolute-vs-relative-scarcity error recorded in [[brain-relay-reserve-floor]], made a second time in the opposite direction.
- Every option of every active event was priced: volatiles demand is 590 on both the cheapest-option and every-option mixes, so no alternative resolution anywhere asks for more of it.
- The fallback contract: unknown or >24 h-old stock reproduces the shipped static ranking exactly, so degradation is never worse than the previous release.
- The deliberate call to count demand from ALL active events, meshed or not.
- Link `[[brain-relay-reserve-floor]]`, `[[brain-mine-build]]`, `[[theatre-recognition-model]]`, `[[logistics-haul-yields]]`.

- [ ] **Step 2: Add the index line**

Append one line to `app/.claude/memory/MEMORY.md` in the brain cluster (near the `brain-mine-build` line):

```markdown
- [Demand-derived mine ranking](demand-derived-mine-ranking.md) — mine siting now weights belts by stock ÷ demand (open-event criteria priced through blueprint bills + the print reserve), not fixed rares/conductive constants; records why "volatiles is last in collections" was the WRONG signal (~11× covered) and silicates/conductive actually bind.
```

- [ ] **Step 3: Commit**

```bash
git add app/.claude/memory
git commit -m "docs(memory): demand-derived mine ranking and the coverage correction

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Verification Checklist

Run before declaring the plan complete:

- [ ] `cd app/Modules && swift build --build-tests` — clean.
- [ ] `./scripts/link-index-store.sh` — run after the build so LSP reference queries resolve.
- [ ] `rm -f .build/events-*.jsonl   # per-filter runs write events-<Suite>.jsonl, which the glob would sweep in
for p in UniverseModelsTests GameDatabaseTests GameServicesTests GameSyncTests DirectiveEngineTests; do
  swift test --test-product "$p" --disable-xctest --event-stream-version 0 \
    --event-stream-output-path ".build/events-$p.jsonl"
done
cat .build/events-UniverseModelsTests.jsonl .build/events-GameDatabaseTests.jsonl \
    .build/events-GameServicesTests.jsonl .build/events-GameSyncTests.jsonl \
    .build/events-DirectiveEngineTests.jsonl > .build/events-all.jsonl
jq -s '[.[] | select(.kind=="event").payload] as $e
  | {started: ($e | map(select(.kind=="testStarted")) | length),
     ended:   ($e | map(select(.kind=="testEnded")) | length),
     failed:  ([$e[] | select(.kind=="issueRecorded" and .issue.isFailure != false).testID] | unique),
     crashed: (($e | map(select(.kind=="testStarted").testID))
             - ($e | map(select(.kind=="testEnded" or .kind=="testSkipped").testID)))}' \
  .build/events-all.jsonl`, results read through the `swift-test-event-stream` skill. Only the known `theSupervisorAdoptsTheRowTheBrainLaunched` whole-package failure may be red.
- [ ] `./app/scripts/check-comments.sh` over every created and modified source file.
- [ ] `sqlite3` against the live DB confirms `locationInventories` exists after the app next launches and that the hourly sweep has written depot rows (path in the `sqlite-db-location` memory note; needs `dangerouslyDisableSandbox`).
- [ ] The brain's mine-siting log line names the boosted types on a real tick.
