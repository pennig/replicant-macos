# FTL Mesh Direct Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the galaxy map drawing an edge between every pair of relay systems — persist the backend's mesh closure with its distance/range metrics, and draw only the links that are physically real.

**Architecture:** The backend's per-relay network view reports the *closure* of a subgraph (every peer, however far), not its topology. We keep persisting that closure — now with `distance_ly` and both endpoints' `range_ly` — and classify rows in the read path: a direct link is `distanceLy <= max(rangeA, rangeB)`. A parity repair guarantees the drawn components always equal the server's components. Ingest and read reduction are both pure functions with the I/O at the edges.

**Tech Stack:** Swift 6 / SPM (`app/Modules`), SQLiteData + StructuredQueries (GRDB), swift-openapi-generator, Swift Testing, Metal (renderer untouched).

**Spec:** `app/docs/superpowers/specs/2026-08-01-ftl-mesh-direct-links-design.md`

## Global Constraints

- **Database migrations are append-only.** Never edit, rename, or reorder a shipped `SchemaMigration`. A new column means a new `ALTER TABLE` migration appended to `GameDatabase.manifest`.
- **`SchemaManifestTests` freezes the identifier list** — a new migration must be appended there too, in the same order.
- **`GoldenSchemaTests` snapshots the schema** — regenerate only with `RC_REGENERATE_SCHEMA_FIXTURE=1`, which rewrites the fixture *and still fails*, so the change lands in a reviewable diff.
- **Read test results from the Swift Testing JSON event stream**, never by grepping console text. Use the repo's `swift-test-event-stream` skill for `jq` recipes. Always pass `--test-product` to avoid the multi-target truncation trap.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = module name.
- **Loud test defaults:** a shared client's `testValue` uses `unimplemented(...)`, never a quiet stub.
- **Package root is `app/Modules`** (where `Package.swift` lives). Run all `swift build` / `swift test` from there.
- **Worktree LSP setup, before anything else:** `cd app/Modules && swift build --build-tests`, then `./scripts/link-index-store.sh`. Without the symlink every LSP reference query silently returns zero.

## File Structure

| File | Responsibility |
| --- | --- |
| `GameModels/Sources/FTLLink.swift` (modify) | `FTLLinkRecord` gains `distanceLy` / `rangeA` / `rangeB`, the metrics migration, and `replace(rows:into:)` |
| `GameModels/Sources/RelayNetworkView.swift` (create) | The ingest-side value type + `FTLLinkRecord.rows(from:now:)` pure resolver |
| `GameModels/Sources/DirectFTLLinks.swift` (create) | The read-side query: direct filter, closure components, parity repair |
| `GameModels/Tests/FTLLinkResolutionTests.swift` (create) | Tests for both pure resolvers |
| `GameDatabase/Sources/GameDatabase.swift` (modify) | Manifest entry for the new migration |
| `GameDatabase/Tests/SchemaManifestTests.swift` (modify) | Frozen identifier list |
| `GameServices/Sources/DevicesClient.swift` (modify) | `relayLinks` → `relayNetworks`, returning views instead of bare pairs |
| `GameServices/Sources/FTLMeshRefresher.swift` (modify) | Roster by relay *feature*; persist metric-bearing rows |
| `NewStarMapFeature/Sources/NewStarMapView.swift` (modify) | Read `@Fetch(DirectFTLLinks())` instead of `@FetchAll(FTLLinkRecord.all)` |

---

### Task 1: Schema — link metrics columns

**Files:**
- Modify: `app/Modules/GameModels/Sources/FTLLink.swift`
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift:64`
- Modify: `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift:43`

**Interfaces:**
- Consumes: nothing.
- Produces: `FTLLinkRecord.distanceLy: Double?`, `.rangeA: Double?`, `.rangeB: Double?`; `FTLLinkRecord.addLinkMetrics: SchemaMigration`.

- [ ] **Step 1: Add the failing manifest expectation**

In `SchemaManifestTests.swift`, append to `frozenIdentifiers` after `"Add 'depleted' to 'siteAssays'"`:

```swift
        "Add link metrics to 'ftlLinks'",
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd app/Modules && swift test --disable-xctest --test-product GameDatabaseTests \
  --filter 'manifestMatchesTheFrozenList' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL — the manifest has 22 identifiers, the frozen list now expects 23.

- [ ] **Step 3: Add the columns to the model**

In `FTLLink.swift`, inside `FTLLinkRecord`, after `public var updatedAt: Date`:

```swift
    /// The server's `distance_ly` for this pair, as reported on the connection.
    /// Nil when the read failed or the field was absent — see the fail-open rule.
    public var distanceLy: Double?
    /// Relay range at endpoint `a`, merged in from that relay's own network view.
    public var rangeA: Double?
    /// Relay range at endpoint `b`.
    public var rangeB: Double?
```

Give the memberwise init defaults so existing call sites keep compiling:

```swift
    public init(
        a: String,
        b: String,
        updatedAt: Date,
        distanceLy: Double? = nil,
        rangeA: Double? = nil,
        rangeB: Double? = nil
    ) {
        self.id = "\(a)|\(b)"
        self.a = a
        self.b = b
        self.updatedAt = updatedAt
        self.distanceLy = distanceLy
        self.rangeA = rangeA
        self.rangeB = rangeB
    }
```

- [ ] **Step 4: Add the migration**

In `FTLLink.swift`, in the `// MARK: - Schema` extension, after `createFTLLinks`:

```swift
    /// Adds the metrics that let the read path tell a real link from a closure
    /// pair. Existing rows carry no metrics and would all classify as direct
    /// under the fail-open rule — reproducing the very hairball this change
    /// removes — so the migration clears the table. The mesh is a wholesale
    /// -rebuilt cache, so dropping it costs only an empty overlay until the
    /// next refresh fires.
    public static let addLinkMetrics = SchemaMigration("Add link metrics to 'ftlLinks'") { db in
        try #sql(
            """
            ALTER TABLE "ftlLinks" ADD COLUMN "distanceLy" REAL
            """
        )
        .execute(db)
        try #sql(
            """
            ALTER TABLE "ftlLinks" ADD COLUMN "rangeA" REAL
            """
        )
        .execute(db)
        try #sql(
            """
            ALTER TABLE "ftlLinks" ADD COLUMN "rangeB" REAL
            """
        )
        .execute(db)
        try #sql(
            """
            DELETE FROM "ftlLinks"
            """
        )
        .execute(db)
    }
```

- [ ] **Step 5: Register it in the manifest**

In `GameDatabase.swift`, append to `manifest` after `SiteAssay.addDepleted,`:

```swift
        FTLLinkRecord.addLinkMetrics,
```

- [ ] **Step 6: Run the manifest test — expect pass, golden schema fail**

```bash
cd app/Modules && swift test --disable-xctest --test-product GameDatabaseTests \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: `manifestMatchesTheFrozenList` PASSES; `GoldenSchemaTests` FAILS because the schema dump changed. This is correct — the fixture is regenerated deliberately in the next step.

- [ ] **Step 7: Regenerate the golden schema fixture**

```bash
cd app/Modules && RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --disable-xctest \
  --test-product GameDatabaseTests --filter 'GoldenSchema' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

This rewrites the fixture **and still fails on purpose**. Inspect `git diff` on the fixture: it must show exactly three added columns on `ftlLinks` and nothing else. Then re-run without the flag and confirm it passes.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/GameModels/Sources/FTLLink.swift \
        app/Modules/GameDatabase/Sources/GameDatabase.swift \
        app/Modules/GameDatabase/Tests/SchemaManifestTests.swift \
        app/Modules/GameDatabase/Tests/__Fixtures__
git commit -m "FTL mesh: add distance/range metrics to ftlLinks rows"
```

---

### Task 2: Ingest resolver — `RelayNetworkView` → rows

**Files:**
- Create: `app/Modules/GameModels/Sources/RelayNetworkView.swift`
- Create: `app/Modules/GameModels/Tests/FTLLinkResolutionTests.swift`

**Interfaces:**
- Consumes: `FTLLinkRecord` with metrics columns (Task 1).
- Produces: `RelayNetworkView(star:rangeLy:connections:)`, `RelayNetworkView.Connection(star:distanceLy:)`, and `FTLLinkRecord.rows(from views: [RelayNetworkView], now: Date) -> [FTLLinkRecord]`.

- [ ] **Step 1: Write the failing tests**

Create `FTLLinkResolutionTests.swift`:

```swift
import Foundation
import Testing

@testable import GameModels

@Suite("FTL link ingest resolution")
struct FTLLinkIngestTests {
    let now = Date(timeIntervalSince1970: 0)

    /// A relay's view knows its OWN range but not its peer's, so ranges must be
    /// merged across every view before rows are stamped.
    @Test func mergesRangesFromBothEndpointViews() {
        let views = [
            RelayNetworkView(
                star: "A", rangeLy: 7.5,
                connections: [.init(star: "B", distanceLy: 10)]),
            RelayNetworkView(
                star: "B", rangeLy: 12.5,
                connections: [.init(star: "A", distanceLy: 10)]),
        ]

        let rows = FTLLinkRecord.rows(from: views, now: now)

        #expect(rows.count == 1)
        #expect(rows[0].a == "A")
        #expect(rows[0].b == "B")
        #expect(rows[0].distanceLy == 10)
        #expect(rows[0].rangeA == 7.5)
        #expect(rows[0].rangeB == 12.5)
    }

    /// A relay whose network read failed contributes no view. Its range is then
    /// unknown — but the edge its peer reported must survive, with a nil range.
    @Test func absentViewLeavesNilRangeRatherThanDroppingTheEdge() {
        let views = [
            RelayNetworkView(
                star: "A", rangeLy: 7.5,
                connections: [.init(star: "GHOST", distanceLy: 3)])
        ]

        let rows = FTLLinkRecord.rows(from: views, now: now)

        #expect(rows.count == 1)
        #expect(rows[0].rangeA == 7.5)
        #expect(rows[0].rangeB == nil)
    }

    /// Both relays report the same connection; the canonical pair collapses them.
    @Test func reciprocalReportsCollapseToOneRow() {
        let views = [
            RelayNetworkView(star: "B", rangeLy: 7.5, connections: [.init(star: "A", distanceLy: 4)]),
            RelayNetworkView(star: "A", rangeLy: 7.5, connections: [.init(star: "B", distanceLy: 4)]),
        ]

        #expect(FTLLinkRecord.rows(from: views, now: now).count == 1)
    }

    @Test func selfReferentialConnectionIsIgnored() {
        let views = [
            RelayNetworkView(star: "A", rangeLy: 7.5, connections: [.init(star: "A", distanceLy: 0)])
        ]

        #expect(FTLLinkRecord.rows(from: views, now: now).isEmpty)
    }

    @Test func emptyInputProducesNoRows() {
        #expect(FTLLinkRecord.rows(from: [], now: now).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd app/Modules && swift test --disable-xctest --test-product GameModelsTests \
  --filter 'FTL link ingest resolution' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL to compile — `RelayNetworkView` and `rows(from:now:)` do not exist.

- [ ] **Step 3: Write the implementation**

Create `RelayNetworkView.swift`:

```swift
//
//  RelayNetworkView.swift
//  Replicould — shared game models
//
//  One relay's live network view, reduced to what mesh resolution needs. The
//  backend reports the CLOSURE of a relay's subgraph — every peer, however
//  distant — so the distance and range carried here are what later let the read
//  path tell a real link from a closure pair. See `DirectFTLLinks`.
//

import Foundation

/// One relay's `GET /v1/devices/{code}/network` response, in domain terms.
public struct RelayNetworkView: Equatable, Sendable {
    /// The star system this relay sits in.
    public let star: String
    /// This relay's own edge range. Nil when the field was absent.
    public let rangeLy: Double?
    /// Every peer the backend reports — the closure, not just direct links.
    public let connections: [Connection]

    public struct Connection: Equatable, Sendable {
        public let star: String
        public let distanceLy: Double?

        public init(star: String, distanceLy: Double?) {
            self.star = star
            self.distanceLy = distanceLy
        }
    }

    public init(star: String, rangeLy: Double?, connections: [Connection]) {
        self.star = star
        self.rangeLy = rangeLy
        self.connections = connections
    }
}

extension FTLLinkRecord {
    /// Resolve every relay's network view into the persistable closure.
    ///
    /// A single view knows its own range but not its peer's, so ranges are
    /// merged across ALL views first and then stamped onto each canonical pair.
    /// A peer with no view of its own (read failed, or it is not in the roster)
    /// leaves a nil range, which the read path treats as fail-open.
    public static func rows(from views: [RelayNetworkView], now: Date) -> [FTLLinkRecord] {
        let rangeByStar = Dictionary(
            views.map { ($0.star, $0.rangeLy) },
            uniquingKeysWith: { first, second in first ?? second })

        var byID: [String: FTLLinkRecord] = [:]
        for view in views {
            for connection in view.connections where connection.star != view.star {
                let link = FTLLink(view.star, connection.star)
                let row = FTLLinkRecord(
                    a: link.a,
                    b: link.b,
                    updatedAt: now,
                    distanceLy: connection.distanceLy,
                    rangeA: rangeByStar[link.a] ?? nil,
                    rangeB: rangeByStar[link.b] ?? nil)

                // Both endpoints report the same pair. Prefer whichever report
                // actually carried a distance.
                if let existing = byID[row.id], existing.distanceLy != nil, row.distanceLy == nil {
                    continue
                }
                byID[row.id] = row
            }
        }
        // Deterministic order so a rebuild that resolves the same set writes the
        // same rows — mirrors the ordering `relayLinks` used to guarantee.
        return byID.values.sorted { $0.id < $1.id }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd app/Modules && swift test --disable-xctest --test-product GameModelsTests \
  --filter 'FTL link ingest resolution' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameModels/Sources/RelayNetworkView.swift \
        app/Modules/GameModels/Tests/FTLLinkResolutionTests.swift
git commit -m "FTL mesh: resolve relay network views into metric-bearing rows"
```

---

### Task 3: Read reduction — `DirectFTLLinks`

**Files:**
- Create: `app/Modules/GameModels/Sources/DirectFTLLinks.swift`
- Modify: `app/Modules/GameModels/Tests/FTLLinkResolutionTests.swift`

**Interfaces:**
- Consumes: `FTLLinkRecord` with metrics (Task 1).
- Produces: `DirectFTLLinks()` (a `FetchKeyRequest`), `DirectFTLLinks.Value.links: [FTLLink]`, and `DirectFTLLinks.reduce(rows:) -> [FTLLink]`.

- [ ] **Step 1: Write the failing tests**

Append to `FTLLinkResolutionTests.swift`:

```swift
@Suite("FTL direct-link reduction")
struct DirectFTLLinksTests {
    /// Helper: a closure row with explicit metrics.
    func row(_ a: String, _ b: String, _ distance: Double?, _ rangeA: Double?, _ rangeB: Double?)
        -> FTLLinkRecord
    {
        let link = FTLLink(a, b)
        return FTLLinkRecord(
            a: link.a, b: link.b, updatedAt: Date(timeIntervalSince1970: 0),
            distanceLy: distance,
            rangeA: link.a == a ? rangeA : rangeB,
            rangeB: link.a == a ? rangeB : rangeA)
    }

    /// The core case: a 3-clique closure where only two pairs are in range.
    @Test func dropsClosurePairsBeyondRange() {
        let rows = [
            row("A", "B", 4, 7.5, 7.5),
            row("B", "C", 5, 7.5, 7.5),
            row("A", "C", 9, 7.5, 7.5),   // closure only — 9 > 7.5
        ]

        let links = DirectFTLLinks.reduce(rows: rows)

        #expect(Set(links) == [FTLLink("A", "B"), FTLLink("B", "C")])
    }

    /// A 12.5 ly hub reaches a 7.5 ly relay 10 ly away. Union semantics: the
    /// larger of the two ranges decides.
    @Test func longerRangedEndpointKeepsTheEdge() {
        let rows = [row("HUB", "RELAY", 10, 12.5, 7.5)]

        #expect(DirectFTLLinks.reduce(rows: rows) == [FTLLink("HUB", "RELAY")])
    }

    /// If filtering would split a component the server reports as whole, the
    /// shortest closure edge is added back until parity is restored.
    @Test func repairsAComponentTheFilterWouldSplit() {
        let rows = [
            row("A", "B", 4, 7.5, 7.5),     // direct
            row("B", "C", 20, 7.5, 7.5),    // closure only
            row("A", "C", 30, 7.5, 7.5),    // closure only, longer
        ]

        let links = DirectFTLLinks.reduce(rows: rows)

        // One component, and the repair chose the SHORTER of the two candidates.
        #expect(Set(links) == [FTLLink("A", "B"), FTLLink("B", "C")])
    }

    /// When the direct set already matches, the repair adds nothing.
    @Test func repairIsANoOpWhenParityAlreadyHolds() {
        let rows = [row("A", "B", 4, 7.5, 7.5), row("B", "C", 5, 7.5, 7.5)]

        #expect(DirectFTLLinks.reduce(rows: rows).count == 2)
    }

    /// Two genuinely separate networks must stay separate — the repair must not
    /// merge across components the server never joined.
    @Test func doesNotMergeGenuinelySeparateComponents() {
        let rows = [
            row("A", "B", 4, 7.5, 7.5),
            row("C", "D", 4, 7.5, 7.5),
        ]

        let links = DirectFTLLinks.reduce(rows: rows)

        #expect(Set(links) == [FTLLink("A", "B"), FTLLink("C", "D")])
    }

    /// Fail-open: a row missing any metric is treated as a real link.
    @Test func missingMetricsKeepTheEdge() {
        #expect(DirectFTLLinks.reduce(rows: [row("A", "B", nil, 7.5, 7.5)]).count == 1)
        #expect(DirectFTLLinks.reduce(rows: [row("A", "B", 99, nil, 7.5)]).count == 1)
        #expect(DirectFTLLinks.reduce(rows: [row("A", "B", 99, 7.5, nil)]).count == 1)
    }

    @Test func emptyInputProducesNoLinks() {
        #expect(DirectFTLLinks.reduce(rows: []).isEmpty)
    }

    /// Regression fixture from the real 11-relay mesh (2026-08-01): 55 closure
    /// pairs reduce to the 22 in-range edges, and all 11 systems stay in ONE
    /// component — so the map's reachability read is unchanged.
    @Test func realMeshReducesTo22EdgesInOneComponent() {
        let stars = [
            "AINALRAM", "ALPHERATOZ", "ARCTURUSAN", "ATIANFU", "BARNARIDS", "MAHOSATI",
            "MENKENTAN", "PIPIROMA", "SANSUNU", "SHERATANON", "TENEGSHE",
        ]
        // Distances measured from the live census positions (world unit == 1 ly).
        let distance: [String: Double] = [
            "MENKENTAN|SANSUNU": 2.94, "MAHOSATI|TENEGSHE": 3.56, "SANSUNU|TENEGSHE": 3.95,
            "AINALRAM|TENEGSHE": 4.34, "AINALRAM|SANSUNU": 4.93, "AINALRAM|ATIANFU": 5.32,
            "ATIANFU|SHERATANON": 5.48, "ARCTURUSAN|BARNARIDS": 5.76, "ATIANFU|SANSUNU": 5.87,
            "ARCTURUSAN|PIPIROMA": 5.96, "MAHOSATI|SANSUNU": 6.01, "BARNARIDS|PIPIROMA": 6.13,
            "SHERATANON|TENEGSHE": 6.20, "ALPHERATOZ|ATIANFU": 6.46, "ATIANFU|TENEGSHE": 6.59,
            "BARNARIDS|SANSUNU": 6.84, "MENKENTAN|TENEGSHE": 6.86, "AINALRAM|SHERATANON": 6.88,
            "AINALRAM|BARNARIDS": 6.96, "BARNARIDS|MENKENTAN": 7.06, "ATIANFU|MENKENTAN": 7.25,
            "AINALRAM|MENKENTAN": 7.28, "MAHOSATI|SHERATANON": 7.51, "MENKENTAN|PIPIROMA": 7.59,
            "AINALRAM|MAHOSATI": 7.89, "PIPIROMA|SANSUNU": 7.97, "MAHOSATI|MENKENTAN": 8.35,
            "SANSUNU|SHERATANON": 8.44, "BARNARIDS|TENEGSHE": 8.57, "ATIANFU|MAHOSATI": 8.99,
            "ALPHERATOZ|MENKENTAN": 9.57, "PIPIROMA|TENEGSHE": 9.65, "ALPHERATOZ|SANSUNU": 10.18,
            "MAHOSATI|PIPIROMA": 10.31, "ARCTURUSAN|MENKENTAN": 10.63, "AINALRAM|ALPHERATOZ": 10.71,
            "AINALRAM|PIPIROMA": 10.76, "ATIANFU|BARNARIDS": 10.76, "MENKENTAN|SHERATANON": 10.90,
            "BARNARIDS|MAHOSATI": 11.16, "ARCTURUSAN|SANSUNU": 11.44, "ALPHERATOZ|SHERATANON": 11.49,
            "ALPHERATOZ|TENEGSHE": 12.53, "AINALRAM|ARCTURUSAN": 12.68, "ARCTURUSAN|TENEGSHE": 13.51,
            "BARNARIDS|SHERATANON": 13.54, "ATIANFU|PIPIROMA": 13.69, "ALPHERATOZ|BARNARIDS": 13.75,
            "ALPHERATOZ|MAHOSATI": 14.65, "ARCTURUSAN|MAHOSATI": 15.27, "PIPIROMA|SHERATANON": 15.71,
            "ARCTURUSAN|ATIANFU": 16.09, "ALPHERATOZ|PIPIROMA": 16.87, "ALPHERATOZ|ARCTURUSAN": 18.06,
            "ARCTURUSAN|SHERATANON": 19.03,
        ]

        var rows: [FTLLinkRecord] = []
        for i in stars.indices {
            for j in stars.indices where j > i {
                let link = FTLLink(stars[i], stars[j])
                rows.append(
                    FTLLinkRecord(
                        a: link.a, b: link.b, updatedAt: Date(timeIntervalSince1970: 0),
                        distanceLy: distance["\(link.a)|\(link.b)"], rangeA: 7.5, rangeB: 7.5))
            }
        }

        #expect(rows.count == 55)

        let links = DirectFTLLinks.reduce(rows: rows)

        #expect(links.count == 22)
        // All 11 systems still reachable from one another.
        var seen: Set<String> = ["AINALRAM"]
        var changed = true
        while changed {
            changed = false
            for link in links {
                if seen.contains(link.a), !seen.contains(link.b) { seen.insert(link.b); changed = true }
                if seen.contains(link.b), !seen.contains(link.a) { seen.insert(link.a); changed = true }
            }
        }
        #expect(seen.count == 11)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd app/Modules && swift test --disable-xctest --test-product GameModelsTests \
  --filter 'FTL direct-link reduction' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL to compile — `DirectFTLLinks` does not exist.

- [ ] **Step 3: Write the implementation**

Create `DirectFTLLinks.swift`:

```swift
//
//  DirectFTLLinks.swift
//  Replicould — shared game models
//
//  The mesh read path. `ftlLinks` stores the backend's CLOSURE: within a
//  connected subgraph there are no hops, so every relay reports every peer in
//  its subgraph however distant — pairs up to 19 ly against a 7.5 ly edge range.
//  Drawing those as links is what made the galaxy map a hairball.
//
//  A direct link is `distanceLy <= max(rangeA, rangeB)`. The max (rather than
//  the min) is union semantics: a 12.5 ly `system_hub` reaches a 7.5 ly relay
//  that cannot reach back. It is the safe direction — a union can never split a
//  component the server considers whole — and it is one word to change if hub
//  behaviour proves otherwise.
//

import Foundation
import SQLiteData

/// The direct-link view of the persisted mesh, computed once per database change
/// rather than per SwiftUI body evaluation.
public struct DirectFTLLinks: FetchKeyRequest {
    public struct Value: Equatable, Sendable {
        public var links: [FTLLink] = []
        public init(links: [FTLLink] = []) { self.links = links }
    }

    public init() {}

    public func fetch(_ db: Database) throws -> Value {
        Value(links: Self.reduce(rows: try FTLLinkRecord.all.fetchAll(db)))
    }

    /// Fail-open: a row missing any metric counts as a real link. A slightly
    /// noisy map beats a missing link, and it keeps the repair below from
    /// misfiring on rows it cannot judge.
    static func isDirect(_ row: FTLLinkRecord) -> Bool {
        guard let distance = row.distanceLy, let rangeA = row.rangeA, let rangeB = row.rangeB
        else { return true }
        return distance <= max(rangeA, rangeB)
    }

    /// Closure rows in, drawable links out.
    ///
    /// The invariant this enforces: **drawn components always equal server
    /// components.** Filtering could in principle split a network the server
    /// reports as whole (a relay whose view failed to read, an unexpected range
    /// asymmetry), which would have the map lying in the opposite direction. So
    /// after filtering, the shortest closure edges are added back — Kruskal-wise
    /// — until the component count matches the closure's.
    static func reduce(rows: [FTLLinkRecord]) -> [FTLLink] {
        guard !rows.isEmpty else { return [] }

        var closure = UnionFind()
        for row in rows { closure.union(row.a, row.b) }
        let closureComponents = closure.componentCount()

        var direct = UnionFind()
        for row in rows { direct.add(row.a); direct.add(row.b) }
        var kept = rows.filter(isDirect)
        for row in kept { direct.union(row.a, row.b) }

        if direct.componentCount() != closureComponents {
            let candidates = rows
                .filter { !isDirect($0) }
                .sorted { ($0.distanceLy ?? .infinity) < ($1.distanceLy ?? .infinity) }
            for candidate in candidates {
                if direct.union(candidate.a, candidate.b) {
                    kept.append(candidate)
                    if direct.componentCount() == closureComponents { break }
                }
            }
        }

        return kept.map(\.link)
    }
}

/// Minimal union-find over star designations, for component parity.
private struct UnionFind {
    private var parent: [String: String] = [:]

    mutating func add(_ x: String) {
        if parent[x] == nil { parent[x] = x }
    }

    mutating func find(_ x: String) -> String {
        add(x)
        var root = x
        while let next = parent[root], next != root { root = next }
        var cursor = x
        while cursor != root {
            let next = parent[cursor]!
            parent[cursor] = root
            cursor = next
        }
        return root
    }

    /// Returns true when the two were in different components (i.e. a merge happened).
    @discardableResult
    mutating func union(_ a: String, _ b: String) -> Bool {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return false }
        parent[rootA] = rootB
        return true
    }

    mutating func componentCount() -> Int {
        var roots: Set<String> = []
        // `Array(...)` is load-bearing: `find` path-compresses, which mutates
        // `parent`, and iterating the live `keys` view while mutating is invalid.
        for key in Array(parent.keys) { roots.insert(find(key)) }
        return roots.count
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd app/Modules && swift test --disable-xctest --test-product GameModelsTests \
  --filter 'FTL direct-link reduction' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: 8 tests PASS, including the 55→22 regression fixture.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameModels/Sources/DirectFTLLinks.swift \
        app/Modules/GameModels/Tests/FTLLinkResolutionTests.swift
git commit -m "FTL mesh: reduce the stored closure to direct links on read"
```

---

### Task 4: Ingest wiring — `relayNetworks` and metric-bearing writes

**Files:**
- Modify: `app/Modules/GameServices/Sources/DevicesClient.swift:87` (declaration) and `:173` (live implementation)
- Modify: `app/Modules/GameModels/Sources/FTLLink.swift` (the `replace` helper)
- Modify: `app/Modules/GameServices/Sources/FTLMeshRefresher.swift:76-80`

**Interfaces:**
- Consumes: `RelayNetworkView` and `FTLLinkRecord.rows(from:now:)` (Task 2).
- Produces: `DevicesClient.relayNetworks: @Sendable ([RelayNode]) async throws -> [RelayNetworkView]`; `FTLLinkRecord.replace(rows:into:)`.

- [ ] **Step 1: Replace the persistence helper**

In `FTLLink.swift`, replace `replace(with:into:now:)` wholesale:

```swift
extension FTLLinkRecord {
    /// Replace the whole persisted mesh with a freshly-resolved row set. The mesh
    /// is always rebuilt in full (it's small and recomputed from every relay's live
    /// network view), so this clears the table and reinserts in one write — an
    /// empty `rows` correctly leaves no edges (e.g. no relays, or all inactive).
    public static func replace(rows: [FTLLinkRecord], into db: Database) throws {
        try FTLLinkRecord.delete().execute(db)
        for row in rows {
            try FTLLinkRecord.insert { row }.execute(db)
        }
    }
}
```

- [ ] **Step 2: Change the client's declaration**

In `DevicesClient.swift`, replace the `relayLinks` property (line 87) — keeping the surrounding doc comment style:

```swift
    /// Each relay's live network view (`GET /v1/devices/{code}/network`). The
    /// backend reports the CLOSURE of the relay's subgraph, so this returns the
    /// raw views — distance and range included — and leaves classification to
    /// `DirectFTLLinks` on the read side. A relay whose read fails is skipped,
    /// not an error: one unreachable relay must not drop the mesh.
    public var relayNetworks: @Sendable (_ relays: [RelayNode]) async throws -> [RelayNetworkView]
```

- [ ] **Step 3: Change the live implementation**

Replace the `relayLinks:` closure (line 173) with:

```swift
        relayNetworks: { relays in
            guard !relays.isEmpty else { return [] }
            @Dependency(\.gameClient) var gameClient
            // Resolve the client once and reuse it across the per-relay reads (the
            // governor is process-shared, but one client per walk is still the
            // clean shape — mirrors `fetchAll`).
            let client = gameClient()
            var views: [RelayNetworkView] = []
            for relay in relays {
                // A relay may briefly be undeployed / recalled, or the read may be
                // refused (a beacon returns 400 "Device does not support relay").
                // Skip it — a single unreachable relay shouldn't drop the mesh.
                guard let output = try? await client.getV1DevicesDeviceCodeNetwork(
                    path: .init(deviceCode: relay.deviceCode)),
                      case let .ok(ok) = output,
                      let body = try? ok.body.json
                else { continue }
                views.append(
                    RelayNetworkView(
                        star: relay.star,
                        rangeLy: body.rangeLy,
                        connections: (body.connections ?? []).compactMap { connection in
                            guard let peer = connection.star, !peer.isEmpty else { return nil }
                            return RelayNetworkView.Connection(
                                star: peer, distanceLy: connection.distanceLy)
                        }))
            }
            return views
        },
```

Confirm the generated property names with the LSP (`body.rangeLy`, `connection.distanceLy`) — generated names are camelCased from `range_ly` / `distance_ly`, and every generated property is optional.

- [ ] **Step 4: Update the refresher**

In `FTLMeshRefresher.swift`, replace lines 75-80:

```swift
            // Resolve off each relay's backend network view (a failed/refused read is
            // skipped inside `relayNetworks`), then replace the whole persisted mesh
            // with the closure plus its metrics. Classification into drawable links
            // happens on the read side — see `DirectFTLLinks`.
            let views = (try? await devicesClient.relayNetworks(nodes)) ?? []
            let now = date.now
            let rows = FTLLinkRecord.rows(from: views, now: now)
            try? await database.write { db in
                try FTLLinkRecord.replace(rows: rows, into: db)
            }
            logger.debug("mesh rebuilt: \(nodes.count) relay(s) → \(rows.count) closure row(s)")
```

- [ ] **Step 5: Build and run the whole suite**

```bash
cd app/Modules && swift build --build-tests && swift test --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: PASS. `relayLinks` had exactly one caller and no test stubs, so nothing else should need updating — but a clean `swift build --build-tests` is what type-checks every cross-module call site.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/GameServices/Sources/DevicesClient.swift \
        app/Modules/GameServices/Sources/FTLMeshRefresher.swift \
        app/Modules/GameModels/Sources/FTLLink.swift
git commit -m "FTL mesh: persist the closure with its distance and range metrics"
```

---

### Task 5: Roster by relay feature, not device type

**Files:**
- Modify: `app/Modules/GameServices/Sources/FTLMeshRefresher.swift:66-73`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new — a behavioural fix.

**Why:** `SalvageTargetPlanner.meshSystems` (`SalvageTargetPlanner.swift:52`) already matches `features.contains("relay")` and documents that "a `system_hub` contains an integrated relay and genuinely does mesh its system." The refresher matches `deviceType == "ftl_relay"`, so a hub is invisible to the map's mesh entirely. Make them agree.

- [ ] **Step 1: Change the roster query**

Replace the roster read:

```swift
            // The relay roster, straight from the persisted fleet. Matched on the
            // relay CAPABILITY rather than the device type: a `system_hub` carries
            // an integrated relay and genuinely meshes its system, so a type match
            // would leave every hub off the map. This is the same predicate
            // `SalvageTargetPlanner.meshSystems` uses — the two must not diverge.
            //
            // A deactivated relay stays in the roster; its network view simply
            // returns no connections (verified live), so it drops out of the
            // resolved edge set naturally — no status filter needed here.
            let relays = (try? await database.read { db in
                try Device.all.fetchAll(db)
            })?.filter { $0.features.contains("relay") } ?? []
```

- [ ] **Step 2: Build and run the suite**

```bash
cd app/Modules && swift build --build-tests && swift test --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add app/Modules/GameServices/Sources/FTLMeshRefresher.swift
git commit -m "FTL mesh: roster relays by capability so a system_hub is not invisible"
```

---

### Task 6: Star map reads direct links

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift:86` and `:137`

**Interfaces:**
- Consumes: `DirectFTLLinks` (Task 3).
- Produces: nothing — the renderer and `StarMapOverlays` are unchanged.

- [ ] **Step 1: Swap the query**

Replace line 86 and its doc comment:

```swift
    /// The drawable FTL mesh. `ftlLinks` stores the backend's closure — every
    /// pair in a subgraph, however distant — so this query reduces it to the
    /// links that are physically real, once per database change rather than per
    /// body evaluation. See `DirectFTLLinks`.
    @Fetch(DirectFTLLinks()) private var directFTLLinks = DirectFTLLinks.Value()
```

- [ ] **Step 2: Feed the overlays from it**

Replace the body of `overlays` (line 137):

```swift
        StarMapOverlays(ftlLinks: directFTLLinks.links, ships: ships)
```

- [ ] **Step 3: Build and run the full suite**

```bash
cd app/Modules && swift build --build-tests && swift test --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: PASS.

- [ ] **Step 4: Compile-check the app target**

The star map is linked into the app shell, which SPM does not cover:

```bash
cd app && xcodebuild -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift
git commit -m "Star map: draw direct FTL links instead of the closure"
```

---

### Task 7: Verify against live data

**Files:** none — a verification pass.

- [ ] **Step 1: Run the app and confirm the mesh redraws**

Launch the app. The metrics migration clears `ftlLinks`, so the mesh overlay starts empty and repopulates on the next refresh (relay roster change or relay liveness event). Toggle the FTL mesh overlay on.

Expected: a sparse network. ALPHERATOZ should show **one** link (to ATIANFU), not ten.

- [ ] **Step 2: Confirm the stored rows carry metrics**

```bash
DB=~/Library/Containers/name.pennig.replicould/Data/Library/Application\ Support/SQLiteData.db
sqlite3 -header -column "$DB" \
  "SELECT count(*) AS closure_rows,
          sum(CASE WHEN distanceLy <= max(rangeA, rangeB) THEN 1 ELSE 0 END) AS direct_rows
   FROM ftlLinks;"
```

Expected: `closure_rows` 55, `direct_rows` 22 (at the current 11-relay roster).

- [ ] **Step 3: Update the memory note**

`app/.claude/memory/ftl-authority-rule.md` says `ftlLinks` "reads as a 7-clique" and warns not to mistake those rows for links. Add that the rows now carry `distanceLy`/`rangeA`/`rangeB`, that the closure is still what is stored, and that `DirectFTLLinks` is the one blessed way to read it. Update the index line in `app/.claude/memory/MEMORY.md` if the hook sentence changes.

- [ ] **Step 4: Commit**

```bash
git add app/.claude/memory/
git commit -m "Memory: record the closure-stored / direct-drawn split for ftlLinks"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
| --- | --- |
| Storage model: keep the closure, filter on read | 1, 3, 4 |
| §1 Ingest keeps the metrics (`RelayNetworkView`, `rows(from:)`) | 2, 4 |
| §2 Schema: three columns, append-only, clears table | 1 |
| §3 Read path: one `FetchKeyRequest`, one reduction | 3, 6 |
| §4 Union semantics (`max(rangeA, rangeB)`) | 3 |
| §5 Component-parity repair | 3 |
| §6 Roster fix: relay feature not device type | 5 |
| Fail-open on nil fields | 3 |
| Testing (ingest, reduction, schema) | 1, 2, 3 |

**Type consistency:** `RelayNetworkView(star:rangeLy:connections:)` and `.Connection(star:distanceLy:)` are defined in Task 2 and consumed identically in Task 4. `FTLLinkRecord.rows(from:now:)` is defined in Task 2, consumed in Task 4. `FTLLinkRecord.replace(rows:into:)` is defined in Task 4 and consumed there. `DirectFTLLinks.reduce(rows:)` and `.Value.links` are defined in Task 3 and consumed in Task 6.

**Note on Task 1 → Task 4 ordering:** Task 1 keeps `replace(with:into:now:)` compiling by giving the new `FTLLinkRecord` init parameters defaults. Task 4 then replaces that helper. This is deliberate — it keeps every task's tree green.
