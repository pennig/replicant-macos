# Salvage Resource Amounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show real unit amounts for salvage sites in the Locations catalog by holding onto the absolute resource counts that `salvage.discovered` events carry and combining them with the `resources_remaining_pct` the locations endpoint already returns.

**Architecture:** Two stores split by what kind of knowledge each holds. Percentages are catalog state and go on `SalvageSite` inside the existing `StarSystem` blob. Totals are historical event knowledge the catalog payload never carries, so they get their own `SiteAssay` table keyed by site designation, which survives the blob rewrites a re-scan causes. Totals rise monotonically per resource. Display is one formula everywhere: `units = total × pct/100`.

**Tech Stack:** Swift 6.4, SwiftUI (macOS 26+), Composable Architecture, SQLiteData (`@Table`, `@FetchAll`), swift-dependencies, Swift Testing.

**Spec:** `app/docs/superpowers/specs/2026-07-25-salvage-resource-amounts-design.md`

## Global Constraints

- All paths below are relative to the repo root. The SPM package root is `app/Modules/` (where `Package.swift` lives) — run `swift` commands from there.
- **Run tests via the event stream, never by scraping console text.** Canonical invocation, run from `app/Modules/`:
  ```bash
  swift test --test-product <Product> --disable-xctest \
    --event-stream-version 0 --event-stream-output-path .build/events.jsonl
  jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
  ```
  An empty second line means no failures. Always pass `--test-product` — one output path shared by many test processes truncates to the last writer.
- **No hard-coded colors, spacing, or font sizes.** Use `DesignSystem.swift` tokens (`.rcTextPrimary`, `.rcTextSecondary`, `Space.m`, `Font.rcCaption`, …).
- **Designations render in monospace.** Any system/site/body code uses `.rcMono` / `.rcMonoSmall`.
- **List-row structs live in their own file**, never beside a `#Preview` (Xcode 26 preview JIT crash).
- **Logging is `os.Logger` only**, subsystem `name.pennig.replicould`, category = module name.
- **Commits go to the local branch; no PRs, no pushes, origin is not a consideration.** One commit per task.
- **Verify with SourceKit-LSP before signing off** on any task (`goToDefinition` / `findReferences`); treat LSP over text matching. LSP root is `app/Modules/`.
- TCA feature state owns its `@FetchAll` queries; views are pure renderers.

---

### Task 1: `SiteAssay` table and the raise-only merge policy

The durable store for original resource totals, plus the two pure functions that govern every write to it.

**Files:**
- Modify: `app/Modules/UniverseModels/Sources/LocationRecords.swift` (append after `LocationFootprint`, before the `// MARK: - Schema` section, then add a migration in that section)
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift:31-49` (register the migration)
- Modify: `app/macOS/ReplicantApp.swift` (logout clear, alongside the other `registerSessionCleanup()` handlers)
- Create: `app/Modules/UniverseModels/Tests/SiteAssayTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `SiteAssay` (`@Table`) with `id: String`, `body: String`, `system: String`, `siteType: String`, `totals: [String: Double]`, `assayedAt: Date`
  - `SiteAssay.init(id:body:system:siteType:totals:assayedAt:)`
  - `SiteAssay.registerMigrations(_ migrator: inout DatabaseMigrator)`
  - `static func SiteAssay.raising(_ stored: [String: Double], with observed: [String: Double]) -> [String: Double]`
  - `static func SiteAssay.impliedTotal(remaining: Double, percentRemaining: Double) -> Double?`
  - `static func SiteAssay.system(of designation: String) -> String`

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/UniverseModels/Tests/SiteAssayTests.swift`:

```swift
//
//  SiteAssayTests.swift
//  UniverseModels
//
//  The write policy for stored site totals. A site's original capacity is a
//  fixed fact, so an observation may only ever raise a stored total — that
//  invariant is what makes the "discovery counts are originals" inference
//  self-correcting rather than permanent.
//

import Foundation
import Testing
@testable import UniverseModels

@Suite struct SiteAssayTests {
    @Test func raisingSeedsFromEmpty() {
        let out = SiteAssay.raising([:], with: ["conductive": 331, "rares": 99])
        #expect(out == ["conductive": 331, "rares": 99])
    }

    @Test func raisingNeverLowersAStoredTotal() {
        let out = SiteAssay.raising(["conductive": 331], with: ["conductive": 120])
        #expect(out == ["conductive": 331])
    }

    @Test func raisingLiftsAStoredTotalWhenTheObservationIsLarger() {
        let out = SiteAssay.raising(["conductive": 120], with: ["conductive": 331])
        #expect(out == ["conductive": 331])
    }

    /// Per resource key, not per site: an observation naming a subset must
    /// leave the resources it doesn't mention untouched.
    @Test func raisingAppliesPerResourceKey() {
        let out = SiteAssay.raising(
            ["conductive": 331, "rares": 99],
            with: ["conductive": 400]
        )
        #expect(out == ["conductive": 400, "rares": 99])
    }

    /// A zero or negative observation carries no information about capacity.
    @Test func raisingIgnoresNonPositiveObservations() {
        let out = SiteAssay.raising(["conductive": 331], with: ["conductive": 0, "rares": -5])
        #expect(out == ["conductive": 331])
    }

    @Test func impliedTotalDividesRemainingByThePercentage() {
        let total = SiteAssay.impliedTotal(remaining: 132.4, percentRemaining: 40)
        #expect(total == 331)
    }

    /// At 0% the remaining amount is 0 and tells us nothing about capacity —
    /// and dividing by it would produce an infinity.
    @Test func impliedTotalIsNilAtZeroPercent() {
        #expect(SiteAssay.impliedTotal(remaining: 0, percentRemaining: 0) == nil)
        #expect(SiteAssay.impliedTotal(remaining: 10, percentRemaining: -1) == nil)
    }

    @Test func systemIsTheLeadingSegmentOfADesignation() {
        #expect(SiteAssay.system(of: "TAANSI-6-5-SAL-1") == "TAANSI")
        #expect(SiteAssay.system(of: "TAANSI") == "TAANSI")
        #expect(SiteAssay.system(of: "") == "")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `app/Modules/`:
```bash
swift test --test-product UniverseModelsTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — `cannot find 'SiteAssay' in scope`.

- [ ] **Step 3: Add the `SiteAssay` type**

In `app/Modules/UniverseModels/Sources/LocationRecords.swift`, insert after the `LocationFootprint` type (before `// MARK: - Schema`):

```swift
// MARK: - SiteAssay

/// The original resource totals of one site, in absolute units.
///
/// Percentages (`resources_remaining_pct`) are catalog state and live on the
/// site inside the `StarSystem` blob; these totals are *historical event
/// knowledge* the catalog payload never carries. They arrive only on a
/// `salvage.discovered` (or a `scan.completed` salvage block) and must survive
/// the blob rewrites that `mergingScan` / `applying(_:)` perform on every
/// re-scan — hence a table of their own, keyed by site designation rather than
/// a field on `SalvageSite`.
///
/// `siteType` distinguishes salvage from mining so mining assays need no
/// schema change when they land.
@Table
public struct SiteAssay: Identifiable, Equatable, Sendable {
    /// Site designation, e.g. `TAANSI-6-SAL-1` — the natural primary key.
    @Column(primaryKey: true) public var id: String
    /// The body hosting the site, e.g. `TAANSI-6`. Always taken from the event
    /// PAYLOAD: the envelope's `location` names the acting device's position,
    /// not the site's.
    public var body: String
    /// Leading designation segment, denormalized so a system's assays are one
    /// indexed read rather than a scan-and-parse.
    public var system: String
    /// `"salvage"` or `"mining"`, matching the backend's `site_type`.
    public var siteType: String
    /// Resource name → original unit count.
    @Column(as: [String: Double].JSONRepresentation.self) public var totals: [String: Double]
    /// When `totals` was last raised.
    public var assayedAt: Date

    public init(
        id: String, body: String, system: String, siteType: String,
        totals: [String: Double], assayedAt: Date
    ) {
        self.id = id
        self.body = body
        self.system = system
        self.siteType = siteType
        self.totals = totals
        self.assayedAt = assayedAt
    }
}

extension SiteAssay {
    /// Merge an observation into stored totals. A site's original capacity is
    /// fixed and absolute remaining is always ≤ total, so a write may only ever
    /// raise a value — applied **per resource key**, so an observation naming a
    /// subset leaves the rest alone. Non-positive observations say nothing
    /// about capacity and are ignored.
    public static func raising(
        _ stored: [String: Double], with observed: [String: Double]
    ) -> [String: Double] {
        var out = stored
        for (resource, amount) in observed where amount > 0 {
            out[resource] = max(out[resource] ?? 0, amount)
        }
        return out
    }

    /// The original total implied by an absolute remaining amount and the
    /// percentage still present — how a `scan.completed` observation is turned
    /// into a capacity figure. Nil when the percentage is unusable (≤ 0): the
    /// remaining amount is then 0 and reveals nothing, and the division would
    /// overflow to infinity.
    public static func impliedTotal(remaining: Double, percentRemaining: Double) -> Double? {
        guard percentRemaining > 0 else { return nil }
        return remaining / (percentRemaining / 100)
    }

    /// The star system a designation belongs to — its leading segment
    /// (`TAANSI-6-5-SAL-1` → `TAANSI`).
    public static func system(of designation: String) -> String {
        String(designation.split(separator: "-").first ?? "")
    }
}
```

Then add the migration in the `// MARK: - Schema` section at the end of the same file:

```swift
extension SiteAssay {
    /// Registers the `siteAssays` table. Call from `GameDatabase.migrator()`
    /// alongside the other tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'siteAssays' table") { db in
            try #sql(
                """
                CREATE TABLE "siteAssays" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "body" TEXT NOT NULL DEFAULT '',
                  "system" TEXT NOT NULL DEFAULT '',
                  "siteType" TEXT NOT NULL DEFAULT 'salvage',
                  "totals" TEXT NOT NULL DEFAULT '{}',
                  "assayedAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run from `app/Modules/`:
```bash
swift test --test-product UniverseModelsTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: PASS, empty jq output.

- [ ] **Step 5: Register the migration**

In `app/Modules/GameDatabase/Sources/GameDatabase.swift`, add the registration immediately after the `LocationFootprint` line:

```swift
        LocationFootprint.registerMigrations(&migrator)
        SiteAssay.registerMigrations(&migrator)
```

- [ ] **Step 6: Register the logout clear**

`SiteAssay` is account-scoped knowledge — a second account on this machine must not inherit the first's assays. In `app/macOS/ReplicantApp.swift`, inside `registerSessionCleanup()`, add a handler alongside the existing ones (place it after the `stars` handler, since it clears the same tier of knowledge):

```swift
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "siteAssays", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in try SiteAssay.delete().execute(db) }
            })
        )
```

Confirm `ReplicantApp.swift` already has `import UniverseModels`; add it if not.

- [ ] **Step 7: Verify the whole package still builds**

Run from `app/Modules/`:
```bash
swift build --build-tests 2>&1 | tail -3
```
Expected: `Build complete!`

- [ ] **Step 8: Commit**

```bash
git add app/Modules/UniverseModels app/Modules/GameDatabase app/macOS/ReplicantApp.swift
git commit -m "Add SiteAssay table for original site resource totals

Percentages are catalog state and belong with the site; original totals are
historical event knowledge the catalog payload never carries, so they get a
table keyed by site designation that survives the blob rewrites a re-scan
performs. Writes raise per resource key and never lower, which is what makes
the discovery-counts-are-originals inference self-correcting."
```

---

### Task 2: `ResourceAmount` and the `SiteAmounts` resolver

The pure join between a site's percentages and its stored totals. This is the keystone — every display surface goes through it, and it is SwiftUI-free so it is safely testable (see the `swiftui-view-statics-trap-in-tests` memory note).

**Files:**
- Create: `app/Modules/UniverseModels/Sources/SiteAmounts.swift`
- Create: `app/Modules/UniverseModels/Tests/SiteAmountsTests.swift`

**Interfaces:**
- Consumes: nothing (pure values).
- Produces:
  - `ResourceAmount` with `resource: String`, `percentRemaining: Double`, `total: Double?`, computed `remaining: Double?`, `id: String`
  - `ResourceAmount.init(resource:percentRemaining:total:)`
  - `static func SiteAmounts.amounts(remainingPct: [String: Double], totals: [String: Double]?) -> [ResourceAmount]`
  - `static func SiteAmounts.totalRemaining(_ amounts: [ResourceAmount]) -> Double?`

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/UniverseModels/Tests/SiteAmountsTests.swift`:

```swift
//
//  SiteAmountsTests.swift
//  UniverseModels
//
//  The one formula the whole feature displays: units = total × pct/100. The
//  live catalog drives the output — an assay can only supply denominators for
//  resources the site still reports.
//

import Foundation
import Testing
@testable import UniverseModels

@Suite struct SiteAmountsTests {
    @Test func amountsJoinPercentagesWithTotals() {
        let out = SiteAmounts.amounts(
            remainingPct: ["conductive": 40],
            totals: ["conductive": 331]
        )
        #expect(out.count == 1)
        #expect(out[0].resource == "conductive")
        #expect(out[0].percentRemaining == 40)
        #expect(out[0].total == 331)
        #expect(out[0].remaining == 132.4)
    }

    /// No assay yet: the percentage still renders, the amount is unknown.
    @Test func amountsWithoutAnAssayHaveNoRemaining() {
        let out = SiteAmounts.amounts(remainingPct: ["conductive": 40], totals: nil)
        #expect(out.count == 1)
        #expect(out[0].total == nil)
        #expect(out[0].remaining == nil)
    }

    /// A partial assay covers what it covers; the rest degrade to percentages.
    @Test func amountsSupportAPartialAssay() {
        let out = SiteAmounts.amounts(
            remainingPct: ["conductive": 40, "rares": 12],
            totals: ["conductive": 331]
        )
        #expect(out.map(\.resource) == ["conductive", "rares"])
        #expect(out[0].remaining == 132.4)
        #expect(out[1].remaining == nil)
    }

    /// The live catalog decides what exists. A resource the assay remembers but
    /// the site no longer reports is dropped, not resurrected.
    @Test func amountsDropResourcesTheSiteNoLongerReports() {
        let out = SiteAmounts.amounts(
            remainingPct: ["conductive": 40],
            totals: ["conductive": 331, "silicates": 248]
        )
        #expect(out.map(\.resource) == ["conductive"])
    }

    @Test func amountsAreSortedByResourceName() {
        let out = SiteAmounts.amounts(
            remainingPct: ["silicates": 10, "conductive": 20, "rares": 30],
            totals: nil
        )
        #expect(out.map(\.resource) == ["conductive", "rares", "silicates"])
    }

    @Test func amountsAreEmptyWhenTheSiteReportsNothing() {
        #expect(SiteAmounts.amounts(remainingPct: [:], totals: ["conductive": 331]).isEmpty)
    }

    @Test func aDepletedResourceRemainsZero() {
        let out = SiteAmounts.amounts(remainingPct: ["conductive": 0], totals: ["conductive": 331])
        #expect(out[0].remaining == 0)
    }

    @Test func totalRemainingSumsTheKnownAmounts() {
        let out = SiteAmounts.amounts(
            remainingPct: ["conductive": 40, "rares": 50],
            totals: ["conductive": 331, "rares": 100]
        )
        #expect(SiteAmounts.totalRemaining(out) == 182.4)
    }

    /// Unassayed resources are omitted from the sum, which is why the UI marks
    /// the figure approximate — but a sum of nothing is unknown, not zero.
    @Test func totalRemainingIsNilWhenNothingIsAssayed() {
        let out = SiteAmounts.amounts(remainingPct: ["conductive": 40], totals: nil)
        #expect(SiteAmounts.totalRemaining(out) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `app/Modules/`:
```bash
swift test --test-product UniverseModelsTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — `cannot find 'SiteAmounts' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Modules/UniverseModels/Sources/SiteAmounts.swift`:

```swift
//
//  SiteAmounts.swift
//  UniverseModels
//
//  Joins a site's live percentages with its stored original totals to produce
//  absolute amounts. One formula — `units = total × pct/100` — is used by every
//  display surface, so there is no "which source was fresher" branch: the
//  percentage always comes from the catalog row being rendered and the total is
//  a fixed constant from `SiteAssay`.
//
//  Deliberately free of SwiftUI so it can be unit-tested (pure logic hung off a
//  SwiftUI View traps under `swift test` — see the swiftui-view-statics-trap
//  memory note).
//

import Foundation

/// One resource at a site: how much of it is left, in percent and — when the
/// site has been assayed — in absolute units.
public struct ResourceAmount: Identifiable, Equatable, Sendable {
    public var resource: String
    /// 0…100, straight from `resources_remaining_pct`.
    public var percentRemaining: Double
    /// Original unit count. Nil when no assay covers this resource.
    public var total: Double?
    public var id: String { resource }

    /// Absolute units still present. Nil when the total is unknown — an honest
    /// "we don't know", never a zero standing in for missing data.
    public var remaining: Double? {
        total.map { $0 * percentRemaining / 100 }
    }

    public init(resource: String, percentRemaining: Double, total: Double? = nil) {
        self.resource = resource
        self.percentRemaining = percentRemaining
        self.total = total
    }
}

public enum SiteAmounts {
    /// Join a site's percentages with assay totals.
    ///
    /// The **live catalog drives the output**: one entry per key in
    /// `remainingPct`, sorted by resource name for deterministic rendering. A
    /// resource the assay remembers but the site no longer reports is dropped —
    /// the site is the authority on what exists.
    public static func amounts(
        remainingPct: [String: Double], totals: [String: Double]?
    ) -> [ResourceAmount] {
        remainingPct.keys.sorted().map { resource in
            ResourceAmount(
                resource: resource,
                percentRemaining: remainingPct[resource] ?? 0,
                total: totals?[resource]
            )
        }
    }

    /// Sum of the *known* remaining units. Unassayed resources are omitted, so
    /// the result is a floor — callers mark it approximate. Nil when nothing is
    /// assayed at all, which is unknown rather than zero.
    public static func totalRemaining(_ amounts: [ResourceAmount]) -> Double? {
        let known = amounts.compactMap(\.remaining)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run from `app/Modules/`:
```bash
swift test --test-product UniverseModelsTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: PASS, empty jq output.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/UniverseModels
git commit -m "Add SiteAmounts resolver joining percentages with stored totals

One formula for every surface: units = total x pct/100. The live catalog drives
the output, so a resource the assay remembers but the site no longer reports is
dropped rather than resurrected, and an unknown total renders as a bare
percentage instead of a zero."
```

---

### Task 3: Stop discarding salvage percentages

`RawResourceSite.salvageDomain` currently keeps only `.keys.sorted()` from `resources_remaining_pct`, throwing away the values. This restores them onto `SalvageSite` — with a tolerant decode, because `SalvageSite` is persisted inside the `StarSystem` blob and synthesized `Decodable` throws `keyNotFound` on a missing key even when the property has a default (verified on this toolchain).

**Files:**
- Modify: `app/Modules/UniverseModels/Sources/LocationModels.swift:93-130` (the `SalvageSite` struct)
- Modify: `app/Modules/UniverseModels/Sources/LocationDTOs.swift:371-384` (`salvageDomain`)
- Create: `app/Modules/UniverseModels/Tests/SalvageSiteDecodeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `SalvageSite.remainingPct: [String: Double]` (new stored property, defaults to `[:]`)
  - `SalvageSite.init(designation:name:salvageType:location:resourcesAvailable:depleted:remainingPct:)` — `remainingPct` is the last parameter and defaults to `[:]`, so all existing call sites keep compiling unchanged.

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/UniverseModels/Tests/SalvageSiteDecodeTests.swift`:

```swift
//
//  SalvageSiteDecodeTests.swift
//  UniverseModels
//
//  `SalvageSite` is persisted inside the `StarSystem` blob in `systemDetails`,
//  so adding a stored property is a data-compatibility change: synthesized
//  Decodable ignores property defaults and throws `keyNotFound`, which would
//  make every blob written before this change undecodable.
//

import Foundation
import Testing
@testable import UniverseModels

@Suite struct SalvageSiteDecodeTests {
    /// A blob written before `remainingPct` existed must still decode.
    @Test func decodesABlobWrittenWithoutRemainingPct() throws {
        let json = """
        { "designation": "TAANSI-6-SAL-1", "name": "Derelict Survey Probe",
          "salvageType": "derelict_probe", "location": "TAANSI-6",
          "resourcesAvailable": ["conductive", "rares"], "depleted": false }
        """
        let site = try JSONDecoder().decode(SalvageSite.self, from: Data(json.utf8))
        #expect(site.designation == "TAANSI-6-SAL-1")
        #expect(site.resourcesAvailable == ["conductive", "rares"])
        #expect(site.remainingPct == [:])
    }

    @Test func decodesABlobCarryingRemainingPct() throws {
        let json = """
        { "designation": "TAANSI-6-SAL-1", "resourcesAvailable": ["conductive"],
          "depleted": false, "remainingPct": { "conductive": 40 } }
        """
        let site = try JSONDecoder().decode(SalvageSite.self, from: Data(json.utf8))
        #expect(site.remainingPct == ["conductive": 40])
    }

    @Test func roundTripsThroughEncodeAndDecode() throws {
        let site = SalvageSite(
            designation: "TAANSI-6-SAL-1", name: "Derelict Survey Probe",
            salvageType: "derelict_probe", location: "TAANSI-6",
            resourcesAvailable: ["conductive"], depleted: false,
            remainingPct: ["conductive": 40]
        )
        let data = try JSONEncoder().encode(site)
        #expect(try JSONDecoder().decode(SalvageSite.self, from: data) == site)
    }

    /// The live API returns salvage inside `resource_sites` with
    /// `site_type: "salvage"`; the percentages must survive, not just the keys.
    @Test func salvageTypedResourceSiteKeepsItsPercentages() throws {
        let json = """
        {
          "location": "SHERATANON-6-1", "location_type": "moon",
          "moon": { "designation": "SHERATANON-6-1", "type": "Rocky" },
          "resource_sites": [
            { "site_index": 1, "designation": "SHERATANON-6-1-SAL-1",
              "name": "Abandoned Habitat Module", "site_type": "salvage",
              "resources_remaining_pct": { "conductive": 40, "rares": 12 } }
          ],
          "devices": [], "inventory": []
        }
        """
        let raw = try LocationDecoding.decoder.decode(RawLocation.self, from: Data(json.utf8))
        let detail = try #require(raw.bodyDetail())
        guard case .moon(let moon) = detail else { Issue.record("expected a moon"); return }
        let site = try #require(moon.salvage.first)
        #expect(site.designation == "SHERATANON-6-1-SAL-1")
        #expect(site.remainingPct == ["conductive": 40, "rares": 12])
        #expect(site.resourcesAvailable == ["conductive", "rares"])
        #expect(site.depleted == false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `app/Modules/`:
```bash
swift test --test-product UniverseModelsTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — `value of type 'SalvageSite' has no member 'remainingPct'`.

(`LocationDecoding.decoder` and `RawLocation.bodyDetail()` are both internal and reachable through `@testable import UniverseModels` — this matches the decode idiom the existing `salvageMoonJSON` test already uses.)

- [ ] **Step 3: Add the property and the tolerant decode**

In `app/Modules/UniverseModels/Sources/LocationModels.swift`, replace the `SalvageSite` struct's stored properties and `init` with:

```swift
public struct SalvageSite: Identifiable, Equatable, Sendable, Codable {
    public var designation: String
    public var name: String?
    public var salvageType: String?
    public var location: String?
    public var resourcesAvailable: [String]
    public var depleted: Bool
    /// Resource name → percent still present (0…100), from
    /// `resources_remaining_pct`. Empty when the site came from the `salvage[]`
    /// roster block, which carries names but no percentages. Combine with a
    /// `SiteAssay`'s totals via `SiteAmounts.amounts` for absolute units.
    public var remainingPct: [String: Double]
    public var id: String { designation }

    public init(
        designation: String, name: String? = nil, salvageType: String? = nil,
        location: String? = nil, resourcesAvailable: [String] = [], depleted: Bool = false,
        remainingPct: [String: Double] = [:]
    ) {
        self.designation = designation
        self.name = name
        self.salvageType = salvageType
        self.location = location
        self.resourcesAvailable = resourcesAvailable
        self.depleted = depleted
        self.remainingPct = remainingPct
    }

    /// Hand-written so a `StarSystem` blob persisted before `remainingPct`
    /// existed still decodes. Synthesized `Decodable` ignores stored-property
    /// defaults and throws `keyNotFound` for an absent key, which would make
    /// every pre-existing `systemDetails` row unreadable.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        designation = try c.decode(String.self, forKey: .designation)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        salvageType = try c.decodeIfPresent(String.self, forKey: .salvageType)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        resourcesAvailable = try c.decodeIfPresent([String].self, forKey: .resourcesAvailable) ?? []
        depleted = try c.decodeIfPresent(Bool.self, forKey: .depleted) ?? false
        remainingPct = try c.decodeIfPresent([String: Double].self, forKey: .remainingPct) ?? [:]
    }
}
```

Keep the existing `bodyDesignation` computed property below it, unchanged.

- [ ] **Step 4: Populate it from the DTO**

In `app/Modules/UniverseModels/Sources/LocationDTOs.swift`, replace `RawResourceSite.salvageDomain`:

```swift
    /// Reinterpret a salvage-typed resource site as a `SalvageSite`. Its
    /// `resources_remaining_pct` keys are the yieldable resources and its values
    /// are how much of each is left; all-zero (or empty) remaining means spent.
    var salvageDomain: SalvageSite? {
        guard let designation else { return nil }
        let remaining = resourcesRemainingPct ?? [:]
        return SalvageSite(
            designation: designation, name: name,
            resourcesAvailable: remaining.keys.sorted(),
            depleted: !remaining.isEmpty && remaining.values.allSatisfy { $0 <= 0 },
            remainingPct: remaining
        )
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run from `app/Modules/`:
```bash
swift test --test-product UniverseModelsTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: PASS, empty jq output.

- [ ] **Step 6: Verify no consumer broke**

`SalvageSite` gains a stored property, which changes the layout of `Planet` and `StarSystem`. Run the full package build plus the two feature suites that consume those types:

```bash
swift build --build-tests 2>&1 | tail -3
swift test --test-product LocationsFeatureTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/loc.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/loc.jsonl | sort -u
swift test --test-product NewStarMapFeatureTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/map.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/map.jsonl | sort -u
```
Expected: build succeeds, both jq outputs empty. (No `rm -rf .build` needed — that ritual was retested and retired on 2026-07-25; see the `spm-stale-layout-crash` memory note.)

- [ ] **Step 7: Commit**

```bash
git add app/Modules/UniverseModels
git commit -m "Keep salvage percentages instead of just resource names

salvageDomain kept only the keys of resources_remaining_pct, so a salvage site
could report which resources it holds but never how depleted it was. The values
now land on SalvageSite.remainingPct.

The decode is hand-written because SalvageSite lives inside the persisted
StarSystem blob and synthesized Decodable throws keyNotFound on an absent key
even with a property default -- without it, every systemDetails row written
before this change would stop decoding."
```

---

### Task 4: Payload-keyed salvage event targeting

Fixes a live bug found while probing. The envelope's `location` names the *acting device's* position (`TAANSI-5-L4`, where the survey controller sits), not the site's body (`TAANSI-6`). `catalogRoute` prefers the envelope, and `salvage.depleted` keys its target as `site`, so today's handler is fed the controller's location — and `mutateSalvage(atBody:)` would spend every sibling site on a body when one depletes.

**Files:**
- Create: `app/Modules/GameServices/Sources/SalvageEventPayload.swift`
- Modify: `app/Modules/GameServices/Sources/LocationsClient.swift:186-224` (`markSalvageDepleted`, `mutateSalvage`)
- Modify: `app/Modules/GameServices/Sources/LocationsIngestion.swift:141-165` (`catalogRoute`)
- Create: `app/Modules/GameServices/Tests/SalvageEventPayloadTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `struct SalvageEventPayload` with `designation: String`, `body: String`, `name: String?`, `salvageType: String?`, `resources: [String: Double]`
  - `static func SalvageEventPayload.discovery(from payload: [String: JSONValue]) -> SalvageEventPayload?`
  - `static func SalvageEventPayload.depletedSite(from payload: [String: JSONValue]) -> String?`
  - `LocationsClient.markSalvageDepleted(site: String) async throws -> Bool` (replaces `markSalvageDepleted(location:)`)

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/GameServices/Tests/SalvageEventPayloadTests.swift`:

```swift
//
//  SalvageEventPayloadTests.swift
//  GameServices
//
//  Salvage events are targeted by their PAYLOAD, never the envelope: the
//  envelope's `location` is the acting device's position. Captured from live
//  `salvage.discovered` events on 2026-07-25.
//

import API
import Foundation
import Testing
import Utils
@testable import GameServices

@Suite struct SalvageEventPayloadTests {
    private func payload(_ json: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case .object(let object) = value else {
            Issue.record("expected an object"); return [:]
        }
        return object
    }

    /// A real `salvage.discovered` payload. Note `location` is the BODY
    /// (`TAANSI-6`) — the envelope on this event said `TAANSI-5-L4`.
    @Test func discoveryParsesTheLivePayload() throws {
        let p = try payload("""
        { "salvage_type": "derelict_probe",
          "resources": { "conductive": 331, "rares": 99, "silicates": 248 },
          "designation": "TAANSI-6-SAL-1", "location": "TAANSI-6",
          "name": "Derelict Survey Probe" }
        """)
        let d = try #require(SalvageEventPayload.discovery(from: p))
        #expect(d.designation == "TAANSI-6-SAL-1")
        #expect(d.body == "TAANSI-6")
        #expect(d.name == "Derelict Survey Probe")
        #expect(d.salvageType == "derelict_probe")
        #expect(d.resources == ["conductive": 331, "rares": 99, "silicates": 248])
    }

    /// Without an explicit `location`, the body is derived by dropping `-SAL-N`.
    @Test func discoveryDerivesTheBodyFromTheDesignation() throws {
        let p = try payload("""
        { "designation": "TAANSI-6-5-SAL-1", "resources": { "carbon": 119 } }
        """)
        let d = try #require(SalvageEventPayload.discovery(from: p))
        #expect(d.body == "TAANSI-6-5")
    }

    @Test func discoveryIsNilWithoutADesignation() throws {
        let p = try payload(#"{ "resources": { "carbon": 119 } }"#)
        #expect(SalvageEventPayload.discovery(from: p) == nil)
    }

    @Test func discoveryToleratesAMissingResourcesMap() throws {
        let p = try payload(#"{ "designation": "TAANSI-6-SAL-1", "location": "TAANSI-6" }"#)
        let d = try #require(SalvageEventPayload.discovery(from: p))
        #expect(d.resources.isEmpty)
    }

    /// The documented key is `site`.
    @Test func depletedSiteReadsTheSiteKey() throws {
        let p = try payload(#"{ "site": "TAANSI-6-SAL-1" }"#)
        #expect(SalvageEventPayload.depletedSite(from: p) == "TAANSI-6-SAL-1")
    }

    /// Tolerant, because that key came from the docs catalogue rather than a
    /// live probe: accept `designation` and `location` as fallbacks, in order.
    @Test func depletedSiteFallsBackToDesignationThenLocation() throws {
        #expect(SalvageEventPayload.depletedSite(
            from: try payload(#"{ "designation": "TAANSI-6-SAL-1" }"#)) == "TAANSI-6-SAL-1")
        #expect(SalvageEventPayload.depletedSite(
            from: try payload(#"{ "location": "TAANSI-6-SAL-1" }"#)) == "TAANSI-6-SAL-1")
        #expect(SalvageEventPayload.depletedSite(from: try payload("{}")) == nil)
    }

    @Test func depletedSitePrefersSiteOverTheOtherKeys() throws {
        let p = try payload("""
        { "site": "TAANSI-6-SAL-1", "designation": "WRONG", "location": "TAANSI-5-L4" }
        """)
        #expect(SalvageEventPayload.depletedSite(from: p) == "TAANSI-6-SAL-1")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `app/Modules/`:
```bash
swift test --test-product GameServicesTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — `cannot find 'SalvageEventPayload' in scope`.

- [ ] **Step 3: Write the payload parser**

Create `app/Modules/GameServices/Sources/SalvageEventPayload.swift`:

```swift
//
//  SalvageEventPayload.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Reads the salvage event family's targets out of the event PAYLOAD.
//
//  This is deliberately not `event.location ?? payload["location"]`. On a live
//  `salvage.discovered` the envelope's `location` is `TAANSI-5-L4` — where the
//  AMI survey controller that found the site is parked — while the payload's
//  `location` is `TAANSI-6`, the body actually holding the wreck. Preferring the
//  envelope targets the wrong body.
//

import API
import Foundation
import Utils

/// A `salvage.discovered` payload: which site, on which body, and how much of
/// each resource was found (absolute units, at 100% remaining).
public struct SalvageEventPayload: Equatable, Sendable {
    public let designation: String
    public let body: String
    public let name: String?
    public let salvageType: String?
    /// Resource name → absolute unit count.
    public let resources: [String: Double]

    public init(
        designation: String, body: String, name: String? = nil,
        salvageType: String? = nil, resources: [String: Double] = [:]
    ) {
        self.designation = designation
        self.body = body
        self.name = name
        self.salvageType = salvageType
        self.resources = resources
    }

    /// Parse a `salvage.discovered` payload. Nil without a site designation —
    /// there is nothing to key an assay on.
    public static func discovery(from payload: [String: JSONValue]) -> SalvageEventPayload? {
        guard let designation = payload["designation"]?.stringValue, !designation.isEmpty else {
            return nil
        }
        var resources: [String: Double] = [:]
        if case .object(let map)? = payload["resources"] {
            for (resource, value) in map {
                if let amount = value.numberValue { resources[resource] = amount }
            }
        }
        return SalvageEventPayload(
            designation: designation,
            body: payload["location"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.body(ofSite: designation),
            name: payload["name"]?.stringValue,
            salvageType: payload["salvage_type"]?.stringValue,
            resources: resources
        )
    }

    /// The site a `salvage.depleted` event names. The documented key is `site`;
    /// `designation` and `location` are accepted as fallbacks because that key
    /// comes from the docs catalogue rather than a live capture.
    public static func depletedSite(from payload: [String: JSONValue]) -> String? {
        for key in ["site", "designation", "location"] {
            if let value = payload[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    /// The body hosting a site, by dropping the trailing `-SAL-N`
    /// (`TAANSI-6-5-SAL-1` → `TAANSI-6-5`).
    static func body(ofSite designation: String) -> String {
        var parts = designation.split(separator: "-")
        if let i = parts.lastIndex(of: "SAL") { parts = Array(parts[..<i]) }
        return parts.joined(separator: "-")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run from `app/Modules/`:
```bash
swift test --test-product GameServicesTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: PASS, empty jq output.

- [ ] **Step 5: Make depletion site-keyed**

In `app/Modules/GameServices/Sources/LocationsClient.swift`, replace `markSalvageDepleted`, `markSalvageResourceDepleted`, and `mutateSalvage` with:

```swift
    /// Mark ONE salvage site as fully spent (a `salvage.depleted` event). Keyed
    /// by site designation, not by body: a body can host several sites, and
    /// spending one must not spend its siblings. No-op if the system isn't
    /// cached or nothing matches. Returns whether a row changed.
    @discardableResult
    public func markSalvageDepleted(site: String) async throws -> Bool {
        try await mutateSalvage(atSite: site) {
            $0.depleted = true
            $0.resourcesAvailable = []
            $0.remainingPct = $0.remainingPct.mapValues { _ in 0 }
        }
    }

    /// Drop one depleted resource from a site (a resource-level depletion
    /// event). Full depletion arrives separately as `salvage.depleted`, so this
    /// only prunes that resource.
    @discardableResult
    public func markSalvageResourceDepleted(site: String, resource: String) async throws -> Bool {
        try await mutateSalvage(atSite: site) {
            $0.resourcesAvailable.removeAll { $0 == resource }
            $0.remainingPct[resource] = 0
        }
    }

    /// Shared body: load the cached system, apply the transform to the ONE site
    /// with this designation, and persist only if something actually changed.
    private func mutateSalvage(
        atSite site: String, _ transform: @Sendable (inout SalvageSite) -> Void
    ) async throws -> Bool {
        let system = SiteAssay.system(of: site)
        guard !system.isEmpty else { return false }
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        return try await database.write { db in
            guard
                let cached = try SystemDetail.where({ $0.designation.eq(system) }).fetchOne(db),
                let starSystem = try? cached.system()
            else { return false }
            let body = SalvageEventPayload.body(ofSite: site)
            let updated = starSystem.updatingSalvage(at: body) { salvage in
                guard salvage.designation == site else { return }
                transform(&salvage)
            }
            guard updated != starSystem else { return false }
            let row = try SystemDetail(system: updated, hydratedAt: now)
            try SystemDetail.upsert { row }.execute(db)
            return true
        }
    }
```

- [ ] **Step 6: Route the events by payload**

In `app/Modules/GameServices/Sources/LocationsIngestion.swift`, replace the `catalogRoute()` body's `switch` (and drop the now-stale `location` line above it — the envelope must not be consulted for this family):

```swift
    private func catalogRoute() -> EventRoute {
        EventRoute(id: "locations.catalog", match: .all) { event in
            @Dependency(\.locationsClient) var locationsClient
            guard let payload = event.payload else { return }
            // Targets come from the PAYLOAD, never `event.location` — that names
            // the acting device's position (an AMI controller parked at a
            // Lagrange point), not the body holding the salvage.
            switch event.event {
            case "scan.completed":
                // Full scanned body (physical, salvage, sites, inventory).
                _ = try? await locationsClient.ingestScanResult(payload: payload)
            case "salvage.depleted":
                if let site = SalvageEventPayload.depletedSite(from: payload) {
                    _ = try? await locationsClient.markSalvageDepleted(site: site)
                }
            default:
                break
            }
        }
    }
```

- [ ] **Step 7: Run the full GameServices and LocationsFeature suites**

Run from `app/Modules/`:
```bash
swift build --build-tests 2>&1 | tail -3
swift test --test-product GameServicesTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/gs.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/gs.jsonl | sort -u
```
Expected: build succeeds, empty jq output. If any existing test calls `markSalvageDepleted(location:)`, update it to `markSalvageDepleted(site:)` with a full site designation (e.g. `"BETSU-3-SAL-1"` rather than `"BETSU-3"`).

- [ ] **Step 8: Commit**

```bash
git add app/Modules/GameServices
git commit -m "Target salvage events by payload, and deplete one site not a body

Probing salvage.discovered showed the envelope's location is the acting
device's position -- an AMI controller at TAANSI-5-L4 -- while the payload names
the body actually holding the wreck. catalogRoute preferred the envelope, so
depletion was being applied to the wrong place or nowhere at all.

salvage.depleted also keys on `site`, a site designation, so the handler is now
site-keyed: a body can host several sites and spending one must not spend its
siblings. Key extraction accepts designation/location fallbacks since `site`
comes from the docs catalogue rather than a live capture."
```

---

### Task 5: Record discoveries — `salvage.discovered` → assay + catalog

**Files:**
- Modify: `app/Modules/GameServices/Sources/LocationsClient.swift` (add `recordSalvageDiscovery`, and declare it on the client struct if `LocationsClient` exposes methods via an extension — follow whichever shape `markSalvageDepleted` uses)
- Modify: `app/Modules/GameServices/Sources/LocationsIngestion.swift` (add the `salvage.discovered` case to `catalogRoute`)
- Create: `app/Modules/GameServices/Tests/SalvageDiscoveryTests.swift`

**Interfaces:**
- Consumes: `SiteAssay`, `SiteAssay.raising`, `SiteAssay.system(of:)` (Task 1); `SalvageEventPayload.discovery(from:)` (Task 4); `SalvageSite.remainingPct` (Task 3).
- Produces: `LocationsClient.recordSalvageDiscovery(payload: [String: JSONValue]) async throws -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/GameServices/Tests/SalvageDiscoveryTests.swift`:

```swift
//
//  SalvageDiscoveryTests.swift
//  GameServices
//
//  `salvage.discovered` is the only source of a site's original resource
//  totals, so recording it does two things: write the durable assay, and fold
//  the site into the catalog so a discovery is visible without waiting for the
//  next scan.
//

import API
import Dependencies
import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import GameServices

@Suite struct SalvageDiscoveryTests {
    private func payload(_ json: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case .object(let object) = value else {
            Issue.record("expected an object"); return [:]
        }
        return object
    }

    private var livePayload: String {
        """
        { "salvage_type": "derelict_probe",
          "resources": { "conductive": 331, "rares": 99, "silicates": 248 },
          "designation": "TAANSI-6-SAL-1", "location": "TAANSI-6",
          "name": "Derelict Survey Probe" }
        """
    }

    @Test func discoveryWritesTheAssay() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(livePayload)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            _ = try await LocationsClient.liveValue.recordSalvageDiscovery(payload: p)
        }

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("TAANSI-6-SAL-1") }.fetchOne(db)
        }
        let row = try #require(assay)
        #expect(row.body == "TAANSI-6")
        #expect(row.system == "TAANSI")
        #expect(row.siteType == "salvage")
        #expect(row.totals == ["conductive": 331, "rares": 99, "silicates": 248])
    }

    /// Events replay on catch-up, so a second delivery must be a no-op — and
    /// must never lower a total already raised by a later observation.
    @Test func discoveryIsIdempotentAndNeverLowersTotals() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(livePayload)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            _ = try await LocationsClient.liveValue.recordSalvageDiscovery(payload: p)
            // A larger total observed in between (as scan ingestion would write).
            try await database.write { db in
                try SiteAssay.where { $0.id.eq("TAANSI-6-SAL-1") }
                    .update { $0.totals = #bind(["conductive": 500.0]) }
                    .execute(db)
            }
            _ = try await LocationsClient.liveValue.recordSalvageDiscovery(payload: p)
        }

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("TAANSI-6-SAL-1") }.fetchOne(db)
        }
        #expect(try #require(assay).totals["conductive"] == 500)
        let count = try await database.read { db in try SiteAssay.all.fetchCount(db) }
        #expect(count == 1)
    }

    /// The discovery is folded into the catalog so it shows up immediately,
    /// even when the system has never been hydrated.
    @Test func discoverySeedsTheCatalogWhenTheSystemIsUncached() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(livePayload)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            _ = try await LocationsClient.liveValue.recordSalvageDiscovery(payload: p)
        }

        let detail = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("TAANSI") }.fetchOne(db)
        }
        let system = try #require(detail).system()
        let site = try #require(system.knownSalvageSites.first { $0.designation == "TAANSI-6-SAL-1" })
        #expect(site.name == "Derelict Survey Probe")
        #expect(site.salvageType == "derelict_probe")
        #expect(site.resourcesAvailable == ["conductive", "rares", "silicates"])
        // Percentages are NOT synthesised — they are observed data, and the
        // site reads as discovered totals until the first hydrate supplies them.
        #expect(site.remainingPct.isEmpty)
    }

    /// The bug this whole targeting change exists for, at the level it actually
    /// occurs: an envelope whose `location` is the survey controller's parking
    /// spot must not be mistaken for the body holding the salvage.
    @Test func theRouteTargetsThePayloadBodyNotTheEnvelopeLocation() async throws {
        let database = try GameDatabase.bootstrap()
        let ingestion = LocationsIngestion()
        let route = try #require(ingestion.eventRoutes.first { $0.id == "locations.catalog" })
        let envelope = GameEventEnvelope(
            id: "1784995249445-0",
            category: "salvage",
            event: "salvage.discovered",
            deviceCode: "B2CBDEC6",
            deviceType: "ami_survey_controller",
            star: "TAANSI",
            location: "TAANSI-5-L4",          // the CONTROLLER's location
            payload: try payload(livePayload)  // the SITE is on TAANSI-6
        )

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.locationsClient = .liveValue
        } operation: {
            await route.apply(envelope)
        }

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("TAANSI-6-SAL-1") }.fetchOne(db)
        }
        #expect(try #require(assay).body == "TAANSI-6")
        #expect(try #require(assay).system == "TAANSI")
    }

    @Test func aPayloadWithoutADesignationIsANoOp() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(#"{ "resources": { "carbon": 10 } }"#)

        let wrote = try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await LocationsClient.liveValue.recordSalvageDiscovery(payload: p)
        }
        #expect(wrote == false)
        let count = try await database.read { db in try SiteAssay.all.fetchCount(db) }
        #expect(count == 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `app/Modules/`:
```bash
swift test --test-product GameServicesTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — `value of type 'LocationsClient' has no member 'recordSalvageDiscovery'`.

- [ ] **Step 3: Write the implementation**

In `app/Modules/GameServices/Sources/LocationsClient.swift`, add alongside `ingestScanResult` (same extension):

```swift
    /// Record a `salvage.discovered` event.
    ///
    /// Two writes in one transaction. The **assay** is the durable half: this
    /// event is the only place absolute resource counts appear, and the catalog
    /// payload never carries them. The **catalog fold-in** is convenience: the
    /// payload has everything `SalvageSite` needs, so a discovery is visible
    /// immediately instead of waiting for the next scan.
    ///
    /// `remainingPct` is deliberately left empty rather than synthesised as
    /// 100%. Live sites do read 100% right after discovery, but writing that in
    /// would present an inference as observed data; the site reads as discovered
    /// totals until a hydrate supplies real percentages.
    ///
    /// Best-effort and idempotent. Returns whether an assay was written.
    @discardableResult
    public func recordSalvageDiscovery(payload: [String: JSONValue]) async throws -> Bool {
        guard let discovery = SalvageEventPayload.discovery(from: payload) else { return false }
        let system = SiteAssay.system(of: discovery.designation)
        guard !system.isEmpty else { return false }

        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        try await database.write { db in
            let stored = try SiteAssay.where { $0.id.eq(discovery.designation) }.fetchOne(db)
            let assay = SiteAssay(
                id: discovery.designation,
                body: discovery.body,
                system: system,
                siteType: "salvage",
                totals: SiteAssay.raising(stored?.totals ?? [:], with: discovery.resources),
                assayedAt: now
            )
            try SiteAssay.upsert { assay }.execute(db)

            let cached = try SystemDetail.where { $0.designation.eq(system) }.fetchOne(db)
            let base = (try? cached?.system()) ?? StarSystem(designation: system, recon: .visited)
            let site = SalvageSite(
                designation: discovery.designation,
                name: discovery.name,
                salvageType: discovery.salvageType,
                location: discovery.body,
                resourcesAvailable: discovery.resources.keys.sorted(),
                depleted: false
            )
            guard let merged = base.insertingSalvage(site) else { return }
            let row = try SystemDetail(system: merged, hydratedAt: now)
            try SystemDetail.upsert { row }.execute(db)
        }
        return true
    }
```

- [ ] **Step 4: Add the `insertingSalvage` helper**

`recordSalvageDiscovery` needs a way to attach a site to the tree, seeding the host body if the roster doesn't have it. In `app/Modules/UniverseModels/Sources/LocationModels.swift`, add to the `extension StarSystem` that holds `updatingSalvage` (just below it):

```swift
    /// Attach a discovered salvage site to the tree, seeding its host body if
    /// the roster doesn't know it yet (a discovery can arrive long before the
    /// body is scanned). Matches the host by designation, planet then moon.
    /// Returns nil when the site is already present unchanged, so callers can
    /// skip a pointless blob rewrite.
    public func insertingSalvage(_ site: SalvageSite) -> StarSystem? {
        let body = site.bodyDesignation
        guard !body.isEmpty else { return nil }
        var copy = self

        func upsert(into salvage: inout [SalvageSite]) -> Bool {
            if let i = salvage.firstIndex(where: { $0.designation == site.designation }) {
                // Preserve observed percentages; the discovery carries none.
                var merged = site
                merged.remainingPct = salvage[i].remainingPct
                merged.depleted = salvage[i].depleted
                guard salvage[i] != merged else { return false }
                salvage[i] = merged
                return true
            }
            salvage.append(site)
            return true
        }

        for pi in copy.planets.indices {
            if copy.planets[pi].designation == body {
                return upsert(into: &copy.planets[pi].salvage) ? copy : nil
            }
            for mi in copy.planets[pi].moons.indices where copy.planets[pi].moons[mi].designation == body {
                return upsert(into: &copy.planets[pi].moons[mi].salvage) ? copy : nil
            }
        }

        // Unknown body: seed a minimal planet so the site isn't lost. A later
        // hydrate replaces this stub with the real roster entry.
        copy.planets.append(Planet(designation: body, salvage: [site]))
        return copy
    }
```

(`Planet.init` defaults every parameter after `designation`, so `Planet(designation:salvage:)` compiles as written — `LocationModels.swift:509`.)

- [ ] **Step 5: Wire the route case**

In `app/Modules/GameServices/Sources/LocationsIngestion.swift`, add to `catalogRoute`'s switch, above `case "salvage.depleted"`:

```swift
            case "salvage.discovered":
                // The only source of a site's absolute resource totals.
                _ = try? await locationsClient.recordSalvageDiscovery(payload: payload)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run from `app/Modules/`:
```bash
swift build --build-tests 2>&1 | tail -3
swift test --test-product GameServicesTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: PASS, empty jq output.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/GameServices app/Modules/UniverseModels
git commit -m "Record salvage.discovered as a durable site assay

The event is the only place a salvage site's absolute resource counts appear --
the locations endpoint reports percentages and nothing else -- so the counts go
into SiteAssay, raised rather than overwritten.

The site is also folded into the catalog so a discovery is visible without
waiting for the next scan, seeding its host body when the roster doesn't know
it yet. Percentages are left empty rather than synthesised as 100%: live sites
do read 100% right after discovery, but writing that in would present an
inference as observed data."
```

---

### Task 6: Raise totals from `scan.completed`

`scan.completed`'s salvage block carries absolute `resources_remaining` (`{structural: 339, conductive: 226, carbon: 113}`) which `RawSalvage.domain` currently discards. Feeding it back keeps totals correct when a discovery event is missed, and lets a stored total self-correct upward.

**Files:**
- Modify: `app/Modules/UniverseModels/Sources/LocationDTOs.swift` (expose the observations)
- Modify: `app/Modules/UniverseModels/Sources/LocationModels.swift` (the `SalvageObservation` value)
- Modify: `app/Modules/GameServices/Sources/LocationsClient.swift:167-185` (`ingestScanResult`)
- Create: `app/Modules/GameServices/Tests/SalvageScanAssayTests.swift`

**Interfaces:**
- Consumes: `SiteAssay.raising`, `SiteAssay.impliedTotal`, `SiteAssay.system(of:)` (Task 1); `SalvageSite.remainingPct` (Task 3).
- Produces:
  - `struct SalvageObservation` with `designation: String`, `body: String`, `resourcesRemaining: [String: Double]`
  - `static func LocationDecoding.salvageObservations(fromScanResult result: JSONValue) -> [SalvageObservation]`

- [ ] **Step 1: Write the failing test**

Create `app/Modules/GameServices/Tests/SalvageScanAssayTests.swift`:

```swift
//
//  SalvageScanAssayTests.swift
//  GameServices
//
//  scan.completed carries absolute `resources_remaining` per salvage site. That
//  is a second, self-refreshing source of capacity: combined with the site's
//  known percentage it implies the original total, which keeps assays correct
//  when a discovery event is missed.
//

import API
import Dependencies
import Foundation
import GameDatabase
import SQLiteData
import Testing
import UniverseModels
import Utils
@testable import GameServices

@Suite struct SalvageScanAssayTests {
    private func payload(_ json: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case .object(let object) = value else {
            Issue.record("expected an object"); return [:]
        }
        return object
    }

    /// A real `scan.completed` result block (moon scan).
    private var scanPayload: String {
        """
        { "result": { "moon": {
            "designation": "SHERATANON-6-26", "type": "Rocky",
            "salvage": [
              { "designation": "SHERATANON-6-26-SAL-1", "salvage_type": "crashed_vessel",
                "name": "Crashed Vessel", "location": "SHERATANON-6-26",
                "resources_remaining": { "structural": 339, "conductive": 226 },
                "depleted": false }
            ] } } }
        """
    }

    /// With no percentage known, the absolute remaining is a floor on capacity.
    @Test func scanSeedsAnAssayFromAbsoluteRemaining() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(scanPayload)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            _ = try await LocationsClient.liveValue.ingestScanResult(payload: p)
        }

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("SHERATANON-6-26-SAL-1") }.fetchOne(db)
        }
        let row = try #require(assay)
        #expect(row.body == "SHERATANON-6-26")
        #expect(row.system == "SHERATANON")
        #expect(row.totals == ["structural": 339, "conductive": 226])
    }

    /// With a percentage known, remaining ÷ pct implies the original capacity —
    /// 339 units at 30% means the site started with 1130.
    @Test func scanImpliesTheOriginalTotalFromAKnownPercentage() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload(scanPayload)

        let moon = Moon(
            designation: "SHERATANON-6-26",
            salvage: [
                SalvageSite(
                    designation: "SHERATANON-6-26-SAL-1", location: "SHERATANON-6-26",
                    resourcesAvailable: ["structural", "conductive"],
                    remainingPct: ["structural": 30, "conductive": 100]
                )
            ]
        )
        let system = StarSystem(
            designation: "SHERATANON", recon: .visited,
            planets: [Planet(designation: "SHERATANON-6", moons: [moon])]
        )

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            try await database.write { db in
                try SystemDetail.upsert {
                    try SystemDetail(system: system, hydratedAt: Date(timeIntervalSince1970: 0))
                }.execute(db)
            }
            _ = try await LocationsClient.liveValue.ingestScanResult(payload: p)
        }

        let assay = try await database.read { db in
            try SiteAssay.where { $0.id.eq("SHERATANON-6-26-SAL-1") }.fetchOne(db)
        }
        let totals = try #require(assay).totals
        #expect(totals["structural"] == 1130)
        #expect(totals["conductive"] == 226)
    }

    /// A scan of a site with no salvage must not create empty assay rows.
    @Test func aScanWithoutSalvageWritesNoAssay() async throws {
        let database = try GameDatabase.bootstrap()
        let p = try payload("""
        { "result": { "moon": { "designation": "SHERATANON-6-27", "type": "Rocky" } } }
        """)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        } operation: {
            _ = try await LocationsClient.liveValue.ingestScanResult(payload: p)
        }

        let count = try await database.read { db in try SiteAssay.all.fetchCount(db) }
        #expect(count == 0)
    }
}
```

(`Moon.init` — `LocationModels.swift:421` — and `StarSystem.init` — `:604` — both default every parameter after `designation`, so these construction forms compile as written.)

- [ ] **Step 2: Run the test to verify it fails**

Run from `app/Modules/`:
```bash
swift test --test-product GameServicesTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: FAIL — `scanSeedsAnAssayFromAbsoluteRemaining` finds no `SiteAssay` row.

- [ ] **Step 3: Add the observation value type**

In `app/Modules/UniverseModels/Sources/LocationModels.swift`, add beside `SalvageSite`:

```swift
/// A salvage site's absolute remaining amounts as one payload reported them.
/// Distinct from `SalvageSite` (which is catalog state) because these are raw
/// unit counts destined for a `SiteAssay`, not for the tree.
public struct SalvageObservation: Equatable, Sendable {
    public var designation: String
    public var body: String
    /// Resource name → absolute units still present.
    public var resourcesRemaining: [String: Double]

    public init(designation: String, body: String, resourcesRemaining: [String: Double]) {
        self.designation = designation
        self.body = body
        self.resourcesRemaining = resourcesRemaining
    }
}
```

- [ ] **Step 4: Surface the observations from the scan payload**

In `app/Modules/UniverseModels/Sources/LocationDTOs.swift`, add to the `LocationDecoding` facade (beside `scanResultBody`):

```swift
    /// The absolute salvage amounts inside a `scan.completed` result. A second
    /// decode over the same payload rather than a field on `SalvageSite`: these
    /// are raw counts bound for `SiteAssay`, and the domain type deliberately
    /// carries percentages, not units.
    public static func salvageObservations(fromScanResult result: JSONValue) -> [SalvageObservation] {
        guard
            let data = try? JSONEncoder().encode(result),
            let raw = try? decoder.decode(RawScanResultSalvage.self, from: data)
        else { return [] }
        let blocks = [raw.planet?.salvage, raw.moon?.salvage, raw.salvage].compactMap { $0 }.flatMap { $0 }
        return blocks.compactMap { entry -> SalvageObservation? in
            guard
                let designation = entry.designation,
                let remaining = entry.resourcesRemaining, !remaining.isEmpty
            else { return nil }
            var parts = designation.split(separator: "-")
            if let i = parts.lastIndex(of: "SAL") { parts = Array(parts[..<i]) }
            return SalvageObservation(
                designation: designation,
                body: entry.location ?? parts.joined(separator: "-"),
                resourcesRemaining: remaining
            )
        }
    }
```

And add the minimal DTO it decodes, beside `RawSalvage`:

```swift
/// Just enough of a `scan.completed` result to reach its salvage blocks.
struct RawScanResultSalvage: Decodable {
    struct Body: Decodable { var salvage: [RawSalvage]? }
    var planet: Body?
    var moon: Body?
    var salvage: [RawSalvage]?
}
```

Confirm `LocationDecoding.decoder` is visible at that scope (the existing `scanResultBody` uses it) and that `RawSalvage.resourcesRemaining` exists — it does, at `LocationDTOs.swift:236`.

- [ ] **Step 5: Raise totals during scan ingestion**

In `app/Modules/GameServices/Sources/LocationsClient.swift`, extend `ingestScanResult`'s write block. Replace its body with:

```swift
    @discardableResult
    public func ingestScanResult(payload: [String: JSONValue]) async throws -> Bool {
        guard
            let result = payload["result"],
            let detail = ((try? LocationDecoding.scanResultBody(from: result)) ?? nil)
        else { return false }
        let system = String(detail.designation.split(separator: "-").first ?? "")
        guard !system.isEmpty else { return false }
        let observations = LocationDecoding.salvageObservations(fromScanResult: result)

        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        try await database.write { db in
            let cached = try SystemDetail.where { $0.designation.eq(system) }.fetchOne(db)
            let base = (try? cached?.system()) ?? StarSystem(designation: system, recon: .visited)
            let merged = base.seedingParent(of: detail).applying(detail)
            let row = try SystemDetail(system: merged, hydratedAt: now)
            try SystemDetail.upsert { row }.execute(db)

            // The scan's absolute remaining is a second source of capacity.
            // With a known percentage it implies the original total; without
            // one it is at least a floor. Read the percentage from the system
            // as it stood BEFORE this scan's merge, since `applying` may have
            // replaced the site wholesale.
            let knownPct = base.knownSalvageSites.reduce(into: [String: [String: Double]]()) {
                $0[$1.designation] = $1.remainingPct
            }
            for observation in observations {
                let stored = try SiteAssay.where { $0.id.eq(observation.designation) }.fetchOne(db)
                var observed: [String: Double] = [:]
                for (resource, remaining) in observation.resourcesRemaining {
                    if let pct = knownPct[observation.designation]?[resource],
                       let implied = SiteAssay.impliedTotal(remaining: remaining, percentRemaining: pct) {
                        observed[resource] = implied
                    } else {
                        observed[resource] = remaining
                    }
                }
                let assay = SiteAssay(
                    id: observation.designation,
                    body: observation.body,
                    system: SiteAssay.system(of: observation.designation),
                    siteType: "salvage",
                    totals: SiteAssay.raising(stored?.totals ?? [:], with: observed),
                    assayedAt: now
                )
                try SiteAssay.upsert { assay }.execute(db)
            }
        }
        return true
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run from `app/Modules/`:
```bash
swift build --build-tests 2>&1 | tail -3
swift test --test-product GameServicesTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/gs.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/gs.jsonl | sort -u
swift test --test-product UniverseModelsTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/um.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/um.jsonl | sort -u
```
Expected: PASS, both jq outputs empty.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/GameServices app/Modules/UniverseModels
git commit -m "Raise site assays from scan.completed's absolute salvage amounts

The scan payload has carried absolute resources_remaining all along and the DTO
kept only the resource names. Feeding the values back gives assays a second,
self-refreshing source: with a known percentage the remaining amount implies the
original capacity, and without one it is still a floor. This is what keeps
totals right when a discovery event is missed."
```

---

### Task 7: Show the amounts in the Locations inspectors

**Files:**
- Modify: `app/Modules/LocationsFeature/Sources/LocationsFeature.swift:28-55` (add the assay query + lookup to `State`)
- Modify: `app/Modules/LocationsFeature/Sources/LocationDetailView.swift` (thread the lookup through the inspectors; replace the salvage and resource-site `detail:` strings)
- Create: `app/Modules/LocationsFeature/Sources/ResourceAmountRows.swift` (the row views — their own file, per the list-row-preview-crash rule)

**Interfaces:**
- Consumes: `SiteAssay` (Task 1), `SiteAmounts.amounts`, `SiteAmounts.totalRemaining`, `ResourceAmount` (Task 2), `SalvageSite.remainingPct` (Task 3).
- Produces: `LocationsFeature.State.assayTotals: [String: [String: Double]]`, `SiteAmountsRow`, `ResourceAmountLine`.

- [ ] **Step 1: Add the query to feature state**

In `app/Modules/LocationsFeature/Sources/LocationsFeature.swift`, add to `State` beside the other `@FetchAll` properties:

```swift
        /// Stored original resource totals per site designation. Queried in
        /// state (not the view) per the list-query-in-state standard, so the
        /// inspector re-renders when a discovery event lands.
        @ObservationStateIgnored
        @FetchAll(SiteAssay.all) public var siteAssays: [SiteAssay]
```

And a computed lookup below the stored properties:

```swift
        /// Site designation → original totals, the denominator half of every
        /// amount the inspector renders.
        public var assayTotals: [String: [String: Double]] {
            siteAssays.reduce(into: [:]) { $0[$1.id] = $1.totals }
        }
```

- [ ] **Step 2: Write the row views**

Create `app/Modules/LocationsFeature/Sources/ResourceAmountRows.swift`:

```swift
//
//  ResourceAmountRows.swift
//  LocationsFeature
//
//  The per-resource readout for a site. In its own file because a row struct
//  beside a `#Preview` crashes the Xcode 26 preview JIT (see the
//  list-row-preview-crash memory note).
//

import SwiftUI
import UI
import UniverseModels

/// One site, with its resources broken out. The header carries the site's name
/// and designation; each line reports one resource's remaining amount.
struct SiteAmountsRow: View {
    let title: String
    let code: String
    let amounts: [ResourceAmount]
    /// Rendered before the summary, e.g. "Depleted".
    let status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.rcMono).foregroundStyle(.rcTextPrimary)
                    Text(code).font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
                }
                Spacer()
                if let summary {
                    Text(summary).font(.rcCaption).foregroundStyle(.rcTextSecondary)
                }
            }
            ForEach(amounts) { amount in
                ResourceAmountLine(amount: amount)
            }
        }
    }

    /// The collapsed figure: total units still present, summed across resources.
    /// Unassayed resources are omitted, so it is a floor — the `~` says so.
    /// Falls back to the resource names when nothing is assayed at all, which is
    /// what the row showed before assays existed.
    private var summary: String? {
        var parts: [String] = []
        if let status, !status.isEmpty { parts.append(status) }
        if let units = SiteAmounts.totalRemaining(amounts) {
            parts.append("~\(units.formatted(.number.precision(.fractionLength(0)))) units")
        } else if !amounts.isEmpty {
            parts.append(amounts.map(\.resource).joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One resource line: `conductive   132 / 331   40%`.
struct ResourceAmountLine: View {
    let amount: ResourceAmount

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(amount.resource.capitalized)
                .font(.rcCaption).foregroundStyle(.rcTextSecondary)
            Spacer()
            if let remaining = amount.remaining, let total = amount.total {
                Text("\(format(remaining)) / \(format(total))")
                    .font(.rcMonoSmall).foregroundStyle(.rcTextPrimary)
            }
            Text("\(format(amount.percentRemaining))%")
                .font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}
```

Check `Space.xs` and `Space.s` exist in `app/Modules/UI/Sources/DesignSystem.swift`; if a needed spacing token is missing, add it there rather than inlining a number.

- [ ] **Step 3: Render salvage with amounts**

In `app/Modules/LocationDetailView.swift`, change `SiteSalvageSections` to take the lookup and use the new rows:

```swift
private struct SiteSalvageSections: View {
    let sites: [ResourceSite]
    let salvage: [SalvageSite]
    let assayTotals: [String: [String: Double]]
    var body: some View {
        if !sites.isEmpty {
            RCReadoutCard("Resource Sites", count: sites.count) {
                ForEach(sites) { site in
                    SiteAmountsRow(
                        title: site.name ?? site.designation, code: site.designation,
                        amounts: SiteAmounts.amounts(
                            remainingPct: site.remaining, totals: assayTotals[site.designation]
                        ),
                        status: nil
                    )
                }
            }
        }
        if !salvage.isEmpty {
            RCReadoutCard("Salvage", count: salvage.count) {
                ForEach(salvage) { s in
                    SiteAmountsRow(
                        title: s.name ?? s.designation, code: s.designation,
                        amounts: Self.salvageAmounts(s, totals: assayTotals[s.designation]),
                        status: s.depleted ? "Depleted" : nil
                    )
                }
            }
        }
    }

    /// A site from the `salvage[]` roster block has resource names but no
    /// percentages. Map those to zero-percent entries so the row can still list
    /// what's there — `SiteAmountsRow` falls back to a name summary when no
    /// amount is known — instead of rendering an empty card.
    static func salvageAmounts(
        _ site: SalvageSite, totals: [String: Double]?
    ) -> [ResourceAmount] {
        guard site.remainingPct.isEmpty else {
            return SiteAmounts.amounts(remainingPct: site.remainingPct, totals: totals)
        }
        return site.resourcesAvailable.map { ResourceAmount(resource: $0, percentRemaining: 0) }
    }
}
```

- [ ] **Step 4: Thread the lookup through every call site**

Add `let assayTotals: [String: [String: Double]]` as a stored property to `SystemInspector`, `PlanetInspector`, `MoonInspector`, and `BeltInspector`, and pass `assayTotals: store.assayTotals` at each construction site in `LocationDetailView.body`. `PlanetInspector` and `MoonInspector` forward it: `SiteSalvageSections(sites: planet.sites, salvage: planet.salvage, assayTotals: assayTotals)` and the same for `moon`.

In `SystemInspector`, replace the "Resource Sites" and "Salvage" cards (`LocationDetailView.swift:179-197`) with:

```swift
            let sites = system.allResourceSites
            if !sites.isEmpty {
                RCReadoutCard("Resource Sites", count: sites.count) {
                    ForEach(sites) { site in
                        SiteAmountsRow(
                            title: site.name ?? site.designation, code: site.designation,
                            amounts: SiteAmounts.amounts(
                                remainingPct: site.remaining, totals: assayTotals[site.designation]
                            ),
                            status: nil
                        )
                    }
                }
            }

            let salvage = system.allSalvageSites
            if !salvage.isEmpty {
                RCReadoutCard("Salvage", count: salvage.count) {
                    ForEach(salvage) { s in
                        SiteAmountsRow(
                            title: s.name ?? s.designation, code: s.designation,
                            amounts: SiteSalvageSections.salvageAmounts(
                                s, totals: assayTotals[s.designation]
                            ),
                            status: s.depleted ? "Depleted" : nil
                        )
                    }
                }
            }
```

In `BeltInspector`, replace the "Resource Sites" card (`LocationDetailView.swift:295-305`) with:

```swift
            if !belt.sites.isEmpty {
                RCReadoutCard("Resource Sites", count: belt.sites.count) {
                    ForEach(belt.sites) { site in
                        SiteAmountsRow(
                            title: site.name ?? site.designation, code: site.designation,
                            amounts: SiteAmounts.amounts(
                                remainingPct: site.remaining, totals: assayTotals[site.designation]
                            ),
                            status: nil
                        )
                    }
                }
            }
```

Delete the now-unused `remainingSummary(_:)` helper (`LocationDetailView.swift:228-232`) — the averaged percentage it produced is exactly what this task replaces.

- [ ] **Step 5: Build and run the suite**

Run from `app/Modules/`:
```bash
swift build --build-tests 2>&1 | tail -3
swift test --test-product LocationsFeatureTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: build succeeds, empty jq output. If `BubbleRow` is now unused, delete it; if other cards still use it, leave it.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/LocationsFeature
git commit -m "Show per-resource amounts on site and salvage rows

Sites reported an average percentage across their resources, which is
meaningless the moment they deplete unevenly, and salvage reported only which
resources it held. Both now break out per resource as units / total (pct), with
the row summarising total units still present.

Mining sites use the same row and currently show percentages only -- when mining
assays land they become a data change rather than a UI one."
```

---

### Task 8: Rank the `gather_salvage` picker by units

**Files:**
- Modify: `app/Modules/UniverseModels/Sources/LocationModels.swift:133-146` (`SalvageBody`) and `:662-671` (`StarSystem.salvageBodies`)
- Modify: `app/Modules/DirectiveComposerFeature/Sources/DirectiveComposer.swift:100-160` (state query + `salvageBodies`)
- Modify: `app/Modules/DirectiveComposerFeature/Sources/DirectiveComposerSheet.swift:170-172` (`salvageBodyLabel`)
- Create: `app/Modules/UniverseModels/Tests/SalvageBodyUnitsTests.swift`

**Interfaces:**
- Consumes: `SiteAmounts` (Task 2), `SalvageSite.remainingPct` (Task 3), `SiteAssay` (Task 1).
- Produces:
  - `SalvageBody.unitsRemaining: Double?`
  - `StarSystem.salvageBodies(totals: [String: [String: Double]]) -> [SalvageBody]` (the existing no-argument `salvageBodies` property stays, delegating with `[:]`)

- [ ] **Step 1: Write the failing test**

Create `app/Modules/UniverseModels/Tests/SalvageBodyUnitsTests.swift`:

```swift
//
//  SalvageBodyUnitsTests.swift
//  UniverseModels
//
//  The gather_salvage picker offers bodies, so a body's worth is the sum of
//  every live site on it.
//

import Foundation
import Testing
@testable import UniverseModels

@Suite struct SalvageBodyUnitsTests {
    private func system() -> StarSystem {
        var system = StarSystem(designation: "TAANSI", recon: .visited)
        var planet = Planet(designation: "TAANSI-6")
        planet.salvage = [
            SalvageSite(
                designation: "TAANSI-6-SAL-1", location: "TAANSI-6",
                resourcesAvailable: ["conductive"], remainingPct: ["conductive": 50]
            ),
            SalvageSite(
                designation: "TAANSI-6-SAL-2", location: "TAANSI-6",
                resourcesAvailable: ["rares"], remainingPct: ["rares": 100]
            ),
        ]
        system.planets = [planet]
        return system
    }

    @Test func bodyUnitsSumEveryLiveSiteOnIt() {
        let bodies = system().salvageBodies(
            totals: ["TAANSI-6-SAL-1": ["conductive": 400], "TAANSI-6-SAL-2": ["rares": 100]]
        )
        #expect(bodies.count == 1)
        #expect(bodies[0].designation == "TAANSI-6")
        #expect(bodies[0].siteCount == 2)
        #expect(bodies[0].unitsRemaining == 300)   // 400×50% + 100×100%
    }

    @Test func bodyUnitsAreNilWithoutAnyAssay() {
        let bodies = system().salvageBodies(totals: [:])
        #expect(bodies[0].unitsRemaining == nil)
    }

    /// A partial assay still yields a figure — a floor, which the UI marks `~`.
    @Test func bodyUnitsCountOnlyTheAssayedSites() {
        let bodies = system().salvageBodies(totals: ["TAANSI-6-SAL-1": ["conductive": 400]])
        #expect(bodies[0].unitsRemaining == 200)
    }

    /// The no-argument form keeps working for callers that don't have assays.
    @Test func theArgumentlessFormStillWorks() {
        #expect(system().salvageBodies.first?.unitsRemaining == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `app/Modules/`:
```bash
swift test --test-product UniverseModelsTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — no `salvageBodies(totals:)`.

- [ ] **Step 3: Add the field and the join**

In `app/Modules/UniverseModels/Sources/LocationModels.swift`, add to `SalvageBody` (after `siteCount`) and extend its init:

```swift
    /// Total units still present across the body's live sites, when assayed.
    /// Nil when no site on the body has a stored total — unknown, not zero.
    public var unitsRemaining: Double?
```

```swift
    public init(
        designation: String, name: String? = nil, siteCount: Int = 1,
        unitsRemaining: Double? = nil
    ) {
        self.designation = designation
        self.name = name
        self.siteCount = siteCount
        self.unitsRemaining = unitsRemaining
    }
```

Then replace `StarSystem.salvageBodies` with the delegating pair:

```swift
    /// Bodies holding at least one live (non-depleted) salvage site, each with
    /// its site count — the targets the `gather_salvage` directive picker
    /// offers. Pass stored `SiteAssay` totals (site designation → totals) to
    /// have each body report the units still on it.
    public func salvageBodies(totals: [String: [String: Double]] = [:]) -> [SalvageBody] {
        var counts: [String: Int] = [:]
        var units: [String: Double] = [:]
        for site in knownSalvageSites where !site.depleted {
            let body = site.bodyDesignation
            guard !body.isEmpty else { continue }
            counts[body, default: 0] += 1
            let amounts = SiteAmounts.amounts(
                remainingPct: site.remainingPct, totals: totals[site.designation]
            )
            if let siteUnits = SiteAmounts.totalRemaining(amounts) {
                units[body, default: 0] += siteUnits
            }
        }
        return counts.keys.sorted().map {
            SalvageBody(
                designation: $0, name: bodyName(for: $0),
                siteCount: counts[$0]!, unitsRemaining: units[$0]
            )
        }
    }

    /// Salvage-bearing bodies with no assay data joined in.
    public var salvageBodies: [SalvageBody] { salvageBodies() }
```

- [ ] **Step 4: Run the test to verify it passes**

Run from `app/Modules/`:
```bash
swift test --test-product UniverseModelsTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: PASS, empty jq output.

- [ ] **Step 5: Feed assays into the composer**

In `app/Modules/DirectiveComposerFeature/Sources/DirectiveComposer.swift`, add to `State` beside the existing `systemDetails` query:

```swift
        /// Stored site totals, so the picker can rank bodies by what's on them.
        @ObservationStateIgnored
        @FetchAll(SiteAssay.all) public var siteAssays: [SiteAssay]
```

And change the `salvageBodies` computed property's final line:

```swift
        public var salvageBodies: [SalvageBody] {
            guard
                let system = controllerSystem,
                let row = systemDetails.first(where: { $0.designation == system }),
                let starSystem = try? row.system()
            else { return [] }
            return starSystem.salvageBodies(
                totals: siteAssays.reduce(into: [:]) { $0[$1.id] = $1.totals }
            )
        }
```

Confirm `DirectiveComposerFeature` imports `UniverseModels` and `SQLiteData` (it already uses `SalvageBody` and `SystemDetail`, so both should be present).

- [ ] **Step 6: Show the units in the label**

In `app/Modules/DirectiveComposerFeature/Sources/DirectiveComposerSheet.swift`, replace `salvageBodyLabel`:

```swift
    private func salvageBodyLabel(_ body: SalvageBody) -> String {
        var parts = [body.displayName]
        if body.siteCount > 1 { parts.append("\(body.siteCount) sites") }
        if let units = body.unitsRemaining {
            parts.append("~\(units.formatted(.number.precision(.fractionLength(0)))) units")
        }
        return parts.joined(separator: " · ")
    }
```

- [ ] **Step 7: Build and run both suites**

Run from `app/Modules/`:
```bash
swift build --build-tests 2>&1 | tail -3
swift test --test-product DirectiveComposerFeatureTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/dc.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/dc.jsonl | sort -u
swift test --test-product UniverseModelsTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/um.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/um.jsonl | sort -u
```
Expected: build succeeds, both jq outputs empty. If the composer test product has a different name, list products with `swift package describe --type json | jq -r '.targets[] | select(.type=="test").name'`.

- [ ] **Step 8: Full-suite regression and commit**

Run the whole package one product at a time (the shared event-stream path truncates otherwise):

```bash
for p in $(swift package describe --type json | jq -r '.targets[] | select(.type=="test").name'); do
  swift test --test-product "$p" --disable-xctest --event-stream-version 0 \
    --event-stream-output-path ".build/$p.jsonl" > /dev/null 2>&1
  fails=$(jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' ".build/$p.jsonl" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  echo "$p: $fails failing"
done
```
Expected: every product reports `0 failing`.

```bash
git add app/Modules/UniverseModels app/Modules/DirectiveComposerFeature
git commit -m "Rank the gather_salvage picker by units available

The picker listed bodies by name and site count, which says nothing about
whether a target is worth the trip. Each body now reports the units still on it,
summed across its live sites. Bodies with no assay omit the figure rather than
showing a zero."
```

---

## Notes for the implementer

- **Do not add the ten missing `Package.swift` dependency declarations.** They were investigated on 2026-07-25 and are transitively reachable through declared deps — harmless under the default `swiftbuild` engine. Explicitly out of scope.
- **Do not `rm -rf Modules/.build`** when a layout change lands. That workaround was retested and retired the same day; see the `spm-stale-layout-crash` memory note.
- **Mining site assays are out of scope.** The storage carries `siteType` and the UI already routes mining sites through `SiteAmounts`, so that work is ingestion only — `scan.completed`'s report block and `search.completed`'s totals, neither probed live yet.
- After the final task, update `app/.claude/memory/` with a note covering the assay store and the payload-vs-envelope rule for salvage events, and add its index line to `MEMORY.md`.
