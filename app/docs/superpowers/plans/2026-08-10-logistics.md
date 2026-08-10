# Logistics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record one row per Haul Run pickup — run, source pile, units, per-resource-type breakdown, time collected — and show it in a new Logistics sidebar feature that graphs yields over time and in aggregate.

**Architecture:** One `EventRoute` on `ami.transport.digest` watches `report.cargo_carried` per controller; a rise is a pickup, a fall is a delivery. The rise triggers one `.high` device read whose `cargoItems` give the per-type breakdown. A pure decision function does the deciding, so the state machine tests as a table. The ledger reconstructs its own baseline from its open rows, so nothing is held in memory across a relaunch.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), TCA, SQLiteData + GRDB, Swift Charts, swift-openapi-generator.

**Spec:** `app/docs/superpowers/specs/2026-08-10-logistics-design.md`

## Global Constraints

- **Worktree setup before anything else:** `cd app/Modules && swift build --build-tests`, then `./scripts/link-index-store.sh`. Without both, every LSP reference query silently returns zero.
- **Migrations are append-only.** Append to `GameDatabase.manifest`; never edit, rename, or reorder a shipped `SchemaMigration`.
- **No hard-coded colors, spacing, or font sizes.** Use `DesignSystem.swift` tokens. A missing token gets added to the design system + asset catalog.
- **System and location designations always render monospace** (`.rcMono`, `.rcMonoSmall`, `.rcBodyEmphMono`).
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = module name.
- **Loud test defaults:** a shared client's `testValue` is `unimplemented(...)`, never a quiet stub.
- **Comment budget is hard:** file header ≤ 6 lines, `///` ≤ 3 lines, inline `//` ≤ 2 lines.
- **Tests:** read results from the Swift Testing JSON event stream via the `swift-test-event-stream` skill, never by parsing console text.
- **Resource types are a closed set of six** in `ResourceCost.displayOrder` order: `structural`, `conductive`, `silicates`, `carbon`, `rares`, `volatiles`.
- **No all-pairs categorical chart** may be added — no scatter, bubble, choropleth, or six-colour small multiples. The palette is gated on adjacent pairs only.
- **Commits go to this worktree's branch.** No PRs, no pushing to origin.

## File Structure

| File | Responsibility |
|---|---|
| `GameModels/Sources/HaulYield.swift` | the record, its `BreakdownState`, its migration |
| `GameDatabase/Sources/GameDatabase.swift` | manifest append (1 line) |
| `GameServices/Sources/TransportDigest.swift` | typed read of the digest payload |
| `GameServices/Sources/HaulYieldMachine.swift` | the pure pickup/delivery decision |
| `GameServices/Sources/LogisticsIngestion.swift` | the route: parse → decide → read → write |
| `UI/Sources/Colors.xcassets/Resource*.colorset` | six new categorical tokens |
| `UI/Sources/DesignSystem.swift` | `Color.rcResource(_:)` accessor |
| `LogisticsFeature/Sources/LogisticsFeature.swift` | TCA reducer + state |
| `LogisticsFeature/Sources/LogisticsView.swift` | screen composition |
| `LogisticsFeature/Sources/HaulYieldRow.swift` | ledger row (own file — preview JIT crash) |
| `LogisticsFeature/Sources/YieldSummary.swift` | pure aggregation for KPIs and charts |
| `LogisticsFeature/Sources/YieldCharts.swift` | the stacked column + sequential bars |
| `SidebarFeature/Sources/SidebarItem.swift` | `.logistics` case |
| `macOS/MainFeature.swift` | content-pane branch |
| `macOS/ReplicantApp.swift` | route registration |

**One deviation from the spec's §5:** it lists a separate `HaulYieldClient` for the writes. The writes are three statements used by one caller, so they live in `LogisticsIngestion` and no client is created. Add the seam if a second caller ever appears.

---

### Task 1: `HaulYield` record and migration

**Files:**
- Create: `app/Modules/GameModels/Sources/HaulYield.swift`
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift:76` (append to `manifest`)
- Test: `app/Modules/GameModels/Tests/HaulYieldTests.swift`
- Modify: the `SchemaManifestTests` frozen identifier list; regenerate the `GoldenSchemaTests` fixture

**Interfaces:**
- Consumes: `ResourceCost` (from `Blueprint.swift`), `SchemaMigration`
- Produces: `HaulYield` with fields `id: UUID`, `directiveID: String`, `controllerCode: String`, `deviceCode: String`, `sourceDesignation: String`, `collectedAt: Date`, `unitsCollected: Int`, `perType: ResourceCost`, `breakdownState: HaulYield.BreakdownState`, `destinationDesignation: String?`, `deliveredAt: Date?`, `unitsDelivered: Int?`, `followsGap: Bool`; plus `HaulYield.createHaulYields: SchemaMigration` and `HaulYield.isOpen: Bool`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameDatabase
import SQLiteData
import Testing
@testable import GameModels

/// Deterministic test UUIDs. The house idiom is an explicit `uuidString`;
/// there is no `UUID(Int)` in this package's dependencies.
func testUUID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
}

@Suite struct HaulYieldTests {
    @Test func anOpenPickupHasNoDelivery() {
        let yield = HaulYield(
            id: testUUID(0),
            directiveID: "D1",
            controllerCode: "7D1569BF",
            deviceCode: "F7B455B6",
            sourceDesignation: "ACHERNUR-BELT-1",
            collectedAt: Date(timeIntervalSince1970: 0),
            unitsCollected: 345,
            perType: ResourceCost(structural: 200, rares: 145),
            breakdownState: .exact
        )
        #expect(yield.isOpen)
        #expect(yield.perType.structural == 200)
    }

    @Test func theTableRoundTrips() async throws {
        let database = try GameDatabase.bootstrap()
        let row = HaulYield(
            id: testUUID(1),
            directiveID: "D1",
            controllerCode: "7D1569BF",
            deviceCode: "F7B455B6",
            sourceDesignation: "ACHERNUR-BELT-1",
            collectedAt: Date(timeIntervalSince1970: 0),
            unitsCollected: 100,
            perType: ResourceCost(conductive: 100),
            breakdownState: .exact
        )
        try await database.write { db in try HaulYield.upsert { row }.execute(db) }
        let read = try await database.read { db in try HaulYield.all.fetchAll(db) }
        #expect(read == [row])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter HaulYieldTests --event-stream-output-path /tmp/hy.jsonl`
Expected: FAIL — `cannot find 'HaulYield' in scope`.

- [ ] **Step 3: Write the model**

Create `app/Modules/GameModels/Sources/HaulYield.swift`:

```swift
//
//  HaulYield.swift
//  Replicould — GameModels
//
//  One Haul Run pickup, reconstructed from digest deltas.
//

import Foundation
import SQLiteData

@Table
public struct HaulYield: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var id: UUID
    /// The `haulRun` directive this pickup belongs to; empty when unresolved.
    public var directiveID: String
    public var controllerCode: String
    public var deviceCode: String
    public var sourceDesignation: String
    public var collectedAt: Date
    /// Digest `cargo_carried` delta — the reliable figure.
    public var unitsCollected: Int
    @Column(as: ResourceCost.JSONRepresentation.self) public var perType: ResourceCost
    public var breakdownState: BreakdownState
    public var destinationDesignation: String?
    public var deliveredAt: Date?
    public var unitsDelivered: Int?
    /// The stream was disconnected between this row and the previous one, so
    /// the interval between them is unobserved rather than empty.
    public var followsGap: Bool

    public enum BreakdownState: String, Codable, QueryBindable, Sendable {
        /// Hold was empty beforehand and the per-type sum matches the delta.
        case exact
        /// A multi-stop load, or the sum disagreed with the delta.
        case partial
        /// The device read failed; `unitsCollected` still holds.
        case unavailable
    }

    public var isOpen: Bool { deliveredAt == nil }

    public init(
        id: UUID,
        directiveID: String,
        controllerCode: String,
        deviceCode: String,
        sourceDesignation: String,
        collectedAt: Date,
        unitsCollected: Int,
        perType: ResourceCost,
        breakdownState: BreakdownState,
        destinationDesignation: String? = nil,
        deliveredAt: Date? = nil,
        unitsDelivered: Int? = nil,
        followsGap: Bool = false
    ) {
        self.id = id
        self.directiveID = directiveID
        self.controllerCode = controllerCode
        self.deviceCode = deviceCode
        self.sourceDesignation = sourceDesignation
        self.collectedAt = collectedAt
        self.unitsCollected = unitsCollected
        self.perType = perType
        self.breakdownState = breakdownState
        self.destinationDesignation = destinationDesignation
        self.deliveredAt = deliveredAt
        self.unitsDelivered = unitsDelivered
        self.followsGap = followsGap
    }
}

extension HaulYield {
    public static let createHaulYields = SchemaMigration("Create 'haulYields' table") { db in
        try #sql(
            """
            CREATE TABLE "haulYields" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "directiveID" TEXT NOT NULL DEFAULT '',
              "controllerCode" TEXT NOT NULL DEFAULT '',
              "deviceCode" TEXT NOT NULL DEFAULT '',
              "sourceDesignation" TEXT NOT NULL DEFAULT '',
              "collectedAt" TEXT NOT NULL,
              "unitsCollected" INTEGER NOT NULL DEFAULT 0,
              "perType" TEXT NOT NULL DEFAULT '{}',
              "breakdownState" TEXT NOT NULL DEFAULT 'unavailable',
              "destinationDesignation" TEXT,
              "deliveredAt" TEXT,
              "unitsDelivered" INTEGER,
              "followsGap" INTEGER NOT NULL DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)
    }
}
```

- [ ] **Step 4: Append the migration to the manifest**

In `app/Modules/GameDatabase/Sources/GameDatabase.swift`, append as the LAST entry of `manifest` (after `Directive.addSourceRelayCode,`):

```swift
        HaulYield.createHaulYields,
```

- [ ] **Step 5: Update the frozen identifier list and golden schema**

Add `"Create 'haulYields' table"` to the end of the frozen list in `SchemaManifestTests`, then regenerate the schema fixture:

Run: `cd app/Modules && RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --filter GoldenSchemaTests`

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter "HaulYieldTests|SchemaManifestTests|GoldenSchemaTests" --event-stream-output-path /tmp/hy.jsonl`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/GameModels/Sources/HaulYield.swift app/Modules/GameModels/Tests/HaulYieldTests.swift app/Modules/GameDatabase app/Modules/GameDatabase/Tests
git commit -m "feat(logistics): HaulYield record and its migration"
```

---

### Task 2: Typed digest read

**Files:**
- Create: `app/Modules/GameServices/Sources/TransportDigest.swift`
- Test: `app/Modules/GameServices/Tests/TransportDigestTests.swift`

**Interfaces:**
- Consumes: `GameEventEnvelope` (from `API`), `JSONValue` (from `Utils`)
- Produces: `TransportDigest` with `controllerCode: String`, `collect: String?`, `deliver: String?`, `cargoCarried: Int`, `cargoCapacity: Int`, `collectedCount: Int`, `deliveredCount: Int`, `activeDeviceCode: String?`, `observedAt: Date`; and `init?(envelope:now:)`.

- [ ] **Step 1: Write the failing test**

```swift
import API
import Foundation
import Testing
import Utils
@testable import GameServices

@Suite struct TransportDigestTests {
    private func envelope(_ payload: [String: JSONValue]) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: "ami",
            event: "ami.transport.digest",
            deviceCode: "8D53C9B1",
            payload: payload
        )
    }

    @Test func itReadsALiveDigest() throws {
        let digest = try #require(
            TransportDigest(
                envelope: envelope([
                    "report": .object([
                        "cargo_capacity": .number(500),
                        "cargo_carried": .number(345),
                        "collect": .string("ACHERNUR-BELT-1"),
                        "deliver": .string("AINALRAM-BELT-1"),
                    ]),
                    "activity": .object([
                        "counts": .object(["transport.collected": .number(1)])
                    ]),
                    "devices": .array([
                        .object([
                            "device_code": .string("F7B455B6"),
                            "last_event": .string("transport.collected"),
                        ])
                    ]),
                ]),
                now: Date(timeIntervalSince1970: 0)
            )
        )
        #expect(digest.controllerCode == "8D53C9B1")
        #expect(digest.cargoCarried == 345)
        #expect(digest.collect == "ACHERNUR-BELT-1")
        #expect(digest.deliver == "AINALRAM-BELT-1")
        #expect(digest.collectedCount == 1)
        #expect(digest.deliveredCount == 0)
        #expect(digest.activeDeviceCode == "F7B455B6")
    }

    @Test func aDigestWithoutAControllerCodeIsRejected() {
        let bare = GameEventEnvelope(id: "1-0", category: "ami", event: "ami.transport.digest")
        #expect(TransportDigest(envelope: bare, now: Date()) == nil)
    }

    @Test func anAbsentCarriedFigureReadsAsZero() throws {
        let digest = try #require(
            TransportDigest(envelope: envelope(["report": .object([:])]), now: Date())
        )
        #expect(digest.cargoCarried == 0)
        #expect(digest.activeDeviceCode == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter TransportDigestTests --event-stream-output-path /tmp/td.jsonl`
Expected: FAIL — `cannot find 'TransportDigest' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
//
//  TransportDigest.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  A typed read of `ami.transport.digest` — an AMI transport's only channel.
//

import API
import Foundation
import Utils

public struct TransportDigest: Equatable, Sendable {
    public let controllerCode: String
    public let collect: String?
    public let deliver: String?
    public let cargoCarried: Int
    public let cargoCapacity: Int
    public let collectedCount: Int
    public let deliveredCount: Int
    /// The device whose `last_event` names a transport action this window.
    public let activeDeviceCode: String?
    public let observedAt: Date

    public init?(envelope: GameEventEnvelope, now: Date) {
        guard let controllerCode = envelope.deviceCode else { return nil }
        let payload = envelope.payload ?? [:]
        let report = payload["report"]
        let counts = payload["activity"]?["counts"]

        self.controllerCode = controllerCode
        self.collect = report?["collect"]?.stringValue
        self.deliver = report?["deliver"]?.stringValue
        self.cargoCarried = report?["cargo_carried"]?.numberValue.map(Int.init) ?? 0
        self.cargoCapacity = report?["cargo_capacity"]?.numberValue.map(Int.init) ?? 0
        self.collectedCount = counts?["transport.collected"]?.numberValue.map(Int.init) ?? 0
        self.deliveredCount = counts?["transport.delivered"]?.numberValue.map(Int.init) ?? 0
        self.activeDeviceCode = payload["devices"]?.arrayValue?.first { entry in
            (entry["last_event"]?.stringValue ?? "").hasPrefix("transport.")
        }?["device_code"]?.stringValue
        self.observedAt = envelope.date ?? now
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app/Modules && swift test --filter TransportDigestTests --event-stream-output-path /tmp/td.jsonl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameServices/Sources/TransportDigest.swift app/Modules/GameServices/Tests/TransportDigestTests.swift
git commit -m "feat(logistics): typed read of ami.transport.digest"
```

---

### Task 3: The pickup/delivery decision

**Files:**
- Create: `app/Modules/GameServices/Sources/HaulYieldMachine.swift`
- Test: `app/Modules/GameServices/Tests/HaulYieldMachineTests.swift`

**Interfaces:**
- Consumes: `TransportDigest`
- Produces: `HaulYieldStep` (`.none`, `.pickup(units:source:deviceCode:)`, `.delivery(units:destination:)`) and `HaulYieldMachine.step(openUnits:digest:)`.

`openUnits` is the sum of `unitsCollected` over that controller's open rows — the ledger's own reconstruction of what the fleet is carrying. `nil` means the ledger has never seen this controller, so the digest only seeds a baseline and decides nothing.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import GameServices

@Suite struct HaulYieldMachineTests {
    private func digest(
        carried: Int,
        collected: Int = 0,
        delivered: Int = 0,
        device: String? = "F7B455B6"
    ) -> TransportDigest {
        TransportDigest(
            controllerCode: "8D53C9B1",
            collect: "ACHERNUR-BELT-1",
            deliver: "AINALRAM-BELT-1",
            cargoCarried: carried,
            cargoCapacity: 500,
            collectedCount: collected,
            deliveredCount: delivered,
            activeDeviceCode: device,
            observedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func theFirstDigestOnlySeedsABaseline() {
        #expect(HaulYieldMachine.step(openUnits: nil, digest: digest(carried: 345)) == .none)
    }

    @Test func aRiseIsAPickup() {
        #expect(
            HaulYieldMachine.step(openUnits: 0, digest: digest(carried: 345, collected: 1))
                == .pickup(units: 345, source: "ACHERNUR-BELT-1", deviceCode: "F7B455B6")
        )
    }

    @Test func aFallIsADelivery() {
        #expect(
            HaulYieldMachine.step(openUnits: 345, digest: digest(carried: 0, delivered: 1))
                == .delivery(units: 345, destination: "AINALRAM-BELT-1")
        )
    }

    @Test func anUnchangedCarriedFigureDecidesNothing() {
        #expect(HaulYieldMachine.step(openUnits: 345, digest: digest(carried: 345)) == .none)
    }

    @Test func aSecondStopIsAPickupOfTheIncrementOnly() {
        #expect(
            HaulYieldMachine.step(openUnits: 400, digest: digest(carried: 500, collected: 1))
                == .pickup(units: 100, source: "ACHERNUR-BELT-1", deviceCode: "F7B455B6")
        )
    }

    @Test func aPartialDeliveryReportsOnlyWhatLeftTheHold() {
        #expect(
            HaulYieldMachine.step(openUnits: 500, digest: digest(carried: 100, delivered: 1))
                == .delivery(units: 400, destination: "AINALRAM-BELT-1")
        )
    }

    @Test func aPickupWithNoNamedSourceIsNotRecorded() {
        var d = digest(carried: 345, collected: 1)
        d = TransportDigest(
            controllerCode: d.controllerCode,
            collect: nil,
            deliver: d.deliver,
            cargoCarried: d.cargoCarried,
            cargoCapacity: d.cargoCapacity,
            collectedCount: d.collectedCount,
            deliveredCount: d.deliveredCount,
            activeDeviceCode: d.activeDeviceCode,
            observedAt: d.observedAt
        )
        #expect(HaulYieldMachine.step(openUnits: 0, digest: d) == .none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter HaulYieldMachineTests --event-stream-output-path /tmp/hym.jsonl`
Expected: FAIL — `cannot find 'HaulYieldMachine' in scope`, and `TransportDigest` has no memberwise init.

- [ ] **Step 3: Add the memberwise init to `TransportDigest`**

The tests construct digests directly. Append to `TransportDigest`:

```swift
    public init(
        controllerCode: String,
        collect: String?,
        deliver: String?,
        cargoCarried: Int,
        cargoCapacity: Int,
        collectedCount: Int,
        deliveredCount: Int,
        activeDeviceCode: String?,
        observedAt: Date
    ) {
        self.controllerCode = controllerCode
        self.collect = collect
        self.deliver = deliver
        self.cargoCarried = cargoCarried
        self.cargoCapacity = cargoCapacity
        self.collectedCount = collectedCount
        self.deliveredCount = deliveredCount
        self.activeDeviceCode = activeDeviceCode
        self.observedAt = observedAt
    }
```

- [ ] **Step 4: Write the machine**

```swift
//
//  HaulYieldMachine.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The pickup/delivery decision, pure over the fleet's carried total.
//

import Foundation

public enum HaulYieldStep: Equatable, Sendable {
    case none
    case pickup(units: Int, source: String, deviceCode: String)
    case delivery(units: Int, destination: String)
}

public enum HaulYieldMachine {
    /// `openUnits == nil` means this controller has no ledger history, so the
    /// digest establishes a baseline and decides nothing.
    public static func step(openUnits: Int?, digest: TransportDigest) -> HaulYieldStep {
        guard let openUnits else { return .none }
        let delta = digest.cargoCarried - openUnits
        if delta > 0 {
            guard let source = digest.collect, let deviceCode = digest.activeDeviceCode else {
                return .none
            }
            return .pickup(units: delta, source: source, deviceCode: deviceCode)
        }
        if delta < 0 {
            guard let destination = digest.deliver else { return .none }
            return .delivery(units: -delta, destination: destination)
        }
        return .none
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter "HaulYieldMachineTests|TransportDigestTests" --event-stream-output-path /tmp/hym.jsonl`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/GameServices/Sources/HaulYieldMachine.swift app/Modules/GameServices/Sources/TransportDigest.swift app/Modules/GameServices/Tests/HaulYieldMachineTests.swift
git commit -m "feat(logistics): pure pickup/delivery decision over carried deltas"
```

---

### Task 4: The ingestion route

**Files:**
- Create: `app/Modules/GameServices/Sources/LogisticsIngestion.swift`
- Test: `app/Modules/GameServices/Tests/LogisticsIngestionTests.swift`
- Modify: `app/macOS/ReplicantApp.swift:96` (register the route)

**Interfaces:**
- Consumes: `TransportDigest`, `HaulYieldMachine`, `HaulYield`, `EventRoute`, `@Dependency(\.deviceRefresher)`, `@Dependency(\.defaultDatabase)`, `@Dependency(\.uuid)`, `@Dependency(\.date)`
- Produces: `LogisticsIngestion` (a final class, one instance) with `eventRoutes: [EventRoute]`.

Behaviour, in order, on each matching digest:

1. Parse to `TransportDigest`; a nil parse is dropped with a debug log.
2. Read the controller's open rows; `openUnits` is their `unitsCollected` sum, or `nil` when the controller has no rows at all.
3. `HaulYieldMachine.step`. On `.none`, stop.
4. On `.pickup`: resolve the directive (a `haulRun` whose `deviceCode` is the controller), read the device `.high` for `cargoItems`, subtract the previous hold composition, and insert. On `.delivery`: stamp every open row for that controller.
5. Clear the pending-gap flag once one row has carried it.

- [ ] **Step 1: Write the failing test**

```swift
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils
@testable import GameServices

@Suite struct LogisticsIngestionTests {
    private func digestEvent(carried: Int, collected: Int = 0, delivered: Int = 0) -> GameEventEnvelope {
        GameEventEnvelope(
            id: "1-0",
            category: "ami",
            event: "ami.transport.digest",
            deviceCode: "8D53C9B1",
            payload: [
                "report": .object([
                    "cargo_carried": .number(Double(carried)),
                    "cargo_capacity": .number(500),
                    "collect": .string("ACHERNUR-BELT-1"),
                    "deliver": .string("AINALRAM-BELT-1"),
                ]),
                "activity": .object([
                    "counts": .object([
                        "transport.collected": .number(Double(collected)),
                        "transport.delivered": .number(Double(delivered)),
                    ])
                ]),
                "devices": .array([
                    .object([
                        "device_code": .string("F7B455B6"),
                        "last_event": .string(collected > 0 ? "transport.collected" : "transport.delivered"),
                    ])
                ]),
            ]
        )
    }

    private func testUUID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    /// The freighter, holding whatever `cargo` the case needs.
    private func freighter(cargo: [(String, Int)]) -> Device {
        Device(
            deviceCode: "F7B455B6", deviceType: "cargo_freighter", replicantCode: "R1",
            status: "idle", location: "ACHERNUR-BELT-1", locationName: nil,
            operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
            controllerDeviceCode: "8D53C9B1", attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [],
            detail: .object([
                "cargo": .array(cargo.map { entry in
                    .object([
                        "resource_type": .string(entry.0),
                        "quantity": .number(Double(entry.1)),
                    ])
                })
            ]),
            updatedAt: Date(timeIntervalSince1970: 100),
            firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func seedDirectiveAndBaseline(_ database: any DatabaseWriter) async throws {
        try await database.write { db in
            try Directive.upsert {
                Directive(
                    id: "D1", kind: .haulRun, status: .running,
                    deviceCode: "8D53C9B1", fleetTag: "auto:mine:ACHERNUR-BELT-1",
                    targets: ["ACHERNUR-BELT-1"], targetIndex: 0, step: "hauling",
                    stepStartedAt: Date(timeIntervalSince1970: 0),
                    returnToOrigin: false, originDesignation: nil, attentionReason: nil,
                    createdAt: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
            }
            .execute(db)
            // One CLOSED row: it gives the controller a history (so the machine
            // decides rather than seeds) with an open total of zero.
            try HaulYield.upsert {
                HaulYield(
                    id: self.testUUID(9), directiveID: "D1", controllerCode: "8D53C9B1",
                    deviceCode: "F7B455B6", sourceDesignation: "SEED",
                    collectedAt: Date(timeIntervalSince1970: 0), unitsCollected: 10,
                    perType: ResourceCost(), breakdownState: .exact,
                    destinationDesignation: "AINALRAM-BELT-1",
                    deliveredAt: Date(timeIntervalSince1970: 1), unitsDelivered: 10
                )
            }
            .execute(db)
            // The controller's single freighter — the count the two-freighter
            // degradation check reads.
            try Device.upsert { self.freighter(cargo: []) }.execute(db)
        }
    }

    @Test func aRiseWritesAPickupWithItsBreakdown() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.deviceRefresher = DeviceRefreshClient { code, priority in
                #expect(code == "F7B455B6")
                #expect(priority == .high)
                return self.freighter(cargo: [("structural", 200), ("rares", 145)])
            }
        } operation: {
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 345, collected: 1))
        }

        let rows = try await database.read { db in
            try HaulYield.where { $0.sourceDesignation.eq("ACHERNUR-BELT-1") }.fetchAll(db)
        }
        #expect(rows.count == 1)
        #expect(rows[0].unitsCollected == 345)
        #expect(rows[0].perType == ResourceCost(structural: 200, rares: 145))
        #expect(rows[0].breakdownState == .exact)
        #expect(rows[0].directiveID == "D1")
        #expect(rows[0].isOpen)
    }

    @Test func aFailedDeviceReadStillRecordsTheTotal() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.deviceRefresher = DeviceRefreshClient { _, _ in nil }
        } operation: {
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 345, collected: 1))
        }

        let rows = try await database.read { db in
            try HaulYield.where { $0.sourceDesignation.eq("ACHERNUR-BELT-1") }.fetchAll(db)
        }
        #expect(rows[0].unitsCollected == 345)
        #expect(rows[0].breakdownState == .unavailable)
        #expect(rows[0].perType == ResourceCost())
    }

    @Test func aSumThatDisagreesWithTheDeltaIsPartial() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.deviceRefresher = DeviceRefreshClient { _, _ in
                self.freighter(cargo: [("structural", 11)])
            }
        } operation: {
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 345, collected: 1))
        }

        let rows = try await database.read { db in
            try HaulYield.where { $0.sourceDesignation.eq("ACHERNUR-BELT-1") }.fetchAll(db)
        }
        #expect(rows[0].unitsCollected == 345)
        #expect(rows[0].breakdownState == .partial)
    }

    @Test func aFallClosesEveryOpenRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        try await database.write { db in
            for (index, units) in [(0, 400), (1, 100)] {
                try HaulYield.upsert {
                    HaulYield(
                        id: testUUID(100 + index), directiveID: "D1", controllerCode: "8D53C9B1",
                        deviceCode: "F7B455B6", sourceDesignation: "ACHERNUR-BELT-1",
                        collectedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        unitsCollected: units, perType: ResourceCost(), breakdownState: .exact
                    )
                }
                .execute(db)
            }
        }
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 200))
            $0.deviceRefresher = DeviceRefreshClient { _, _ in nil }
        } operation: {
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 0, delivered: 1))
        }

        let open = try await database.read { db in
            try HaulYield.where { $0.deliveredAt.isNot(nil).not() }.fetchAll(db)
        }
        #expect(open.isEmpty)
    }

    @Test func aSecondFreighterOnOneControllerDegradesToPartial() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        try await database.write { db in
            var second = self.freighter(cargo: [])
            second.deviceCode = "AAAA1111"
            try Device.upsert { second }.execute(db)
        }
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.deviceRefresher = DeviceRefreshClient { _, _ in
                self.freighter(cargo: [("structural", 200), ("rares", 145)])
            }
        } operation: {
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 345, collected: 1))
        }

        let rows = try await database.read { db in
            try HaulYield.where { $0.sourceDesignation.eq("ACHERNUR-BELT-1") }.fetchAll(db)
        }
        // The per-type sum matches the delta exactly, and it is STILL partial —
        // a matching sum proves nothing once two holds feed one figure.
        #expect(rows[0].perType.total == 345)
        #expect(rows[0].breakdownState == .partial)
    }

    @Test func theRowAfterAReconnectCarriesTheGapFlag() async throws {
        let database = try GameDatabase.bootstrap()
        try await seedDirectiveAndBaseline(database)
        let ingestion = LogisticsIngestion()

        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 100))
            $0.deviceRefresher = DeviceRefreshClient { _, _ in nil }
        } operation: {
            await ingestion.eventRoutes[0].gapRepair()
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 345, collected: 1))
            await ingestion.eventRoutes[0].apply(digestEvent(carried: 500, collected: 1))
        }

        let rows = try await database.read { db in
            try HaulYield.where { $0.sourceDesignation.eq("ACHERNUR-BELT-1") }
                .order { $0.collectedAt }
                .fetchAll(db)
        }
        #expect(rows.count == 2)
        #expect(rows[0].followsGap)
        #expect(!rows[1].followsGap)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter LogisticsIngestionTests --event-stream-output-path /tmp/li.jsonl`
Expected: FAIL — `cannot find 'LogisticsIngestion' in scope`.

- [ ] **Step 3: Write the ingestion**

```swift
//
//  LogisticsIngestion.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Ingestion policy: a pickup is a rise in the digest's carried total.
//

import Dependencies
import Foundation
import GameModels
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "LogisticsIngestion")

public final class LogisticsIngestion: Sendable {
    /// Raised by `gapRepair`, lowered by the first row that carries it.
    private let pendingGap = LockIsolated(false)

    public init() {}

    public var eventRoutes: [EventRoute] {
        [
            EventRoute(
                id: "logistics.transportDigest",
                match: .event("ami.transport.digest"),
                apply: { [weak self] envelope in await self?.ingest(envelope) },
                gapRepair: { [weak self] in self?.pendingGap.setValue(true) }
            )
        ]
    }

    private func ingest(_ envelope: GameEventEnvelope) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date.now) var now
        guard let digest = TransportDigest(envelope: envelope, now: now) else { return }

        let open: [HaulYield]
        let hasHistory: Bool
        do {
            (open, hasHistory) = try await database.read { db in
                let all = try HaulYield
                    .where { $0.controllerCode.eq(digest.controllerCode) }
                    .fetchAll(db)
                return (all.filter(\.isOpen), !all.isEmpty)
            }
        } catch {
            logger.error("ledger read failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let openUnits = hasHistory ? open.reduce(0) { $0 + $1.unitsCollected } : nil
        switch HaulYieldMachine.step(openUnits: openUnits, digest: digest) {
        case .none:
            return
        case let .pickup(units, source, deviceCode):
            await recordPickup(digest: digest, units: units, source: source, deviceCode: deviceCode, open: open)
        case let .delivery(units, destination):
            await recordDelivery(digest: digest, units: units, destination: destination, open: open)
        }
    }

    private func recordPickup(
        digest: TransportDigest,
        units: Int,
        source: String,
        deviceCode: String,
        open: [HaulYield]
    ) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.deviceRefresher) var deviceRefresher
        @Dependency(\.uuid) var uuid

        let device = await deviceRefresher.refresh(deviceCode, .high)
        let hold = device.map { ResourceCost(wire: Dictionary($0.cargoItems.map { ($0.resourceType, $0.quantity) }, uniquingKeysWith: +)) }
        let previousHold = open.reduce(into: ResourceCost()) { $0.add($1.perType) }

        // `cargo_carried` sums the controller's whole fleet, so a second
        // freighter nets two devices into one figure. Degrade rather than
        // report it as measured.
        let fleetSize = (try? await database.read { db in
            try Device
                .where { $0.controllerDeviceCode.eq(digest.controllerCode) }
                .fetchCount(db)
        }) ?? 1

        let breakdown: ResourceCost
        let state: HaulYield.BreakdownState
        if let hold {
            let taken = hold.subtracting(previousHold)
            breakdown = taken
            state = (taken.total == units && fleetSize <= 1) ? .exact : .partial
        } else {
            breakdown = ResourceCost()
            state = .unavailable
        }

        // Attribute on `deviceCode`, never `controllerCode` or `fleetTag`.
        // `ensureMineFerries` stamps `controllerCode` only at LAUNCH, so a
        // pinned row created earlier still carries nil; `deviceCode` holds the
        // controller on every haul row regardless of vintage.
        //
        // `kind` is a `DirectiveKind`, not a String — it is `QueryBindable`, so
        // bind the case rather than its raw value.
        let directiveID = (try? await database.read { db in
            try Directive
                .where { $0.kind.eq(DirectiveKind.haulRun).and($0.deviceCode.eq(digest.controllerCode)) }
                .fetchOne(db)?
                .id
        }) ?? nil

        let row = HaulYield(
            id: uuid(),
            directiveID: directiveID ?? "",
            controllerCode: digest.controllerCode,
            deviceCode: deviceCode,
            sourceDesignation: source,
            collectedAt: digest.observedAt,
            unitsCollected: units,
            perType: breakdown,
            breakdownState: state,
            followsGap: pendingGap.value
        )
        do {
            try await database.write { db in try HaulYield.upsert { row }.execute(db) }
            pendingGap.setValue(false)
            logger.notice("pickup \(units) at \(source, privacy: .public) [\(state.rawValue, privacy: .public)]")
        } catch {
            logger.error("pickup write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordDelivery(
        digest: TransportDigest,
        units: Int,
        destination: String,
        open: [HaulYield]
    ) async {
        @Dependency(\.defaultDatabase) var database
        guard !open.isEmpty else {
            logger.notice("delivery of \(units) with no open pickup — discarded")
            return
        }
        let reconciles = open.reduce(0) { $0 + $1.unitsCollected } == units
        do {
            try await database.write { db in
                for var row in open {
                    row.destinationDesignation = destination
                    row.deliveredAt = digest.observedAt
                    row.unitsDelivered = row.unitsCollected
                    if !reconciles { row.breakdownState = .partial }
                    try HaulYield.upsert { row }.execute(db)
                }
            }
        } catch {
            logger.error("delivery write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 4: Add the `ResourceCost` arithmetic the ingestion needs**

Append to `ResourceCost` in `app/Modules/GameModels/Sources/Blueprint.swift`:

```swift
    /// Sum across the six fields.
    public var total: Int {
        carbon + silicates + structural + rares + conductive + volatiles
    }

    public mutating func add(_ other: ResourceCost) {
        carbon += other.carbon; silicates += other.silicates; structural += other.structural
        rares += other.rares; conductive += other.conductive; volatiles += other.volatiles
    }

    /// Per-field difference, floored at zero so a shrunk hold never reads negative.
    public func subtracting(_ other: ResourceCost) -> ResourceCost {
        ResourceCost(
            carbon: Swift.max(0, carbon - other.carbon),
            silicates: Swift.max(0, silicates - other.silicates),
            structural: Swift.max(0, structural - other.structural),
            rares: Swift.max(0, rares - other.rares),
            conductive: Swift.max(0, conductive - other.conductive),
            volatiles: Swift.max(0, volatiles - other.volatiles)
        )
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter LogisticsIngestionTests --event-stream-output-path /tmp/li.jsonl`
Expected: PASS, 6 tests.

- [ ] **Step 6: Register the route in the composition root**

In `app/macOS/ReplicantApp.swift`, after line 96 (`for route in locationsIngestion.eventRoutes { … }`):

```swift
        // The haul-yield ledger. An AMI-controlled transport emits no events of
        // its own, so the controller's digest is the only channel that sees a
        // pickup at all.
        let logisticsIngestion = LogisticsIngestion()
        for route in logisticsIngestion.eventRoutes { gameSync.registerRoute(route) }
```

- [ ] **Step 7: Build the app target to confirm the shell compiles**

Run: `cd app && xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/GameServices app/Modules/GameModels/Sources/Blueprint.swift app/macOS/ReplicantApp.swift
git commit -m "feat(logistics): ingest haul yields from the transport digest"
```

---

### Task 5: The categorical palette

**Files:**
- Create: six colorsets under `app/Modules/UI/Sources/Colors.xcassets/` — `ResourceStructural`, `ResourceConductive`, `ResourceSilicates`, `ResourceCarbon`, `ResourceRares`, `ResourceVolatiles`
- Modify: `app/Modules/UI/Sources/DesignSystem.swift` (accessors, after the status block ending at line 97)
- Test: `app/Modules/UI/Tests/ResourcePaletteTests.swift`

**Interfaces:**
- Produces: `Color.rcResource(_ key: String) -> Color`, keyed on the `ResourceCost.displayOrder` keys.

The hexes are already validated against `ContentBackground` in both modes. **Do not reorder the mapping** — the two greens must not become adjacent in `displayOrder`.

| Colorset | Light | Dark |
|---|---|---|
| `ResourceStructural` | `#2a78d6` | `#3987e5` |
| `ResourceConductive` | `#eb6834` | `#d95926` |
| `ResourceSilicates` | `#1baf7a` | `#199e70` |
| `ResourceCarbon` | `#4a3aa7` | `#9085e9` |
| `ResourceRares` | `#e87ba4` | `#d55181` |
| `ResourceVolatiles` | `#008300` | `#008300` |

- [ ] **Step 1: Write the failing test**

```swift
import SwiftUI
import Testing
@testable import UI

@Suite struct ResourcePaletteTests {
    @Test func everyResourceKeyResolvesToItsOwnToken() {
        let keys = ["structural", "conductive", "silicates", "carbon", "rares", "volatiles"]
        let colors = keys.map { Color.rcResource($0) }
        #expect(Set(colors.map(\.description)).count == keys.count)
    }

    @Test func anUnknownKeyFallsBackToTheMutedInk() {
        #expect(Color.rcResource("unobtainium").description == Color.rcTextTertiary.description)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter ResourcePaletteTests --event-stream-output-path /tmp/pal.jsonl`
Expected: FAIL — `type 'Color' has no member 'rcResource'`.

- [ ] **Step 3: Create the six colorsets**

One file per row: `app/Modules/UI/Sources/Colors.xcassets/<Name>.colorset/Contents.json`. `ResourceStructural` in full — the other five are the same file with their own two hexes:

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "blue" : "0xD6", "green" : "0x78", "red" : "0x2A" }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "blue" : "0xE5", "green" : "0x87", "red" : "0x39" }
      },
      "idiom" : "universal"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

The remaining five, as `red`/`green`/`blue` byte pairs (light then dark):

| File | Light R,G,B | Dark R,G,B |
|---|---|---|
| `ResourceConductive` | `0xEB, 0x68, 0x34` | `0xD9, 0x59, 0x26` |
| `ResourceSilicates` | `0x1B, 0xAF, 0x7A` | `0x19, 0x9E, 0x70` |
| `ResourceCarbon` | `0x4A, 0x3A, 0xA7` | `0x90, 0x85, 0xE9` |
| `ResourceRares` | `0xE8, 0x7B, 0xA4` | `0xD5, 0x51, 0x81` |
| `ResourceVolatiles` | `0x00, 0x83, 0x00` | `0x00, 0x83, 0x00` |

- [ ] **Step 4: Add the accessor**

In `DesignSystem.swift`, after the status-color block:

```swift
    // Data-viz categorical slots, one per resource type. Validated for
    // adjacent-pair separation in `ResourceCost.displayOrder`; reordering the
    // mapping breaks that, so keep the pairing as written.
    static var rcResourceStructural: Color { Color("ResourceStructural", bundle: rcBundle) }
    static var rcResourceConductive: Color { Color("ResourceConductive", bundle: rcBundle) }
    static var rcResourceSilicates:  Color { Color("ResourceSilicates",  bundle: rcBundle) }
    static var rcResourceCarbon:     Color { Color("ResourceCarbon",     bundle: rcBundle) }
    static var rcResourceRares:      Color { Color("ResourceRares",      bundle: rcBundle) }
    static var rcResourceVolatiles:  Color { Color("ResourceVolatiles",  bundle: rcBundle) }

    /// The categorical slot for a resource key, muted ink for anything unknown.
    static func rcResource(_ key: String) -> Color {
        switch key {
        case "structural": .rcResourceStructural
        case "conductive": .rcResourceConductive
        case "silicates":  .rcResourceSilicates
        case "carbon":     .rcResourceCarbon
        case "rares":      .rcResourceRares
        case "volatiles":  .rcResourceVolatiles
        default:           .rcTextTertiary
        }
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd app/Modules && swift test --filter ResourcePaletteTests --event-stream-output-path /tmp/pal.jsonl`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/UI
git commit -m "feat(ui): validated categorical palette for the six resource types"
```

---

### Task 6: `LogisticsFeature` module and the ledger table

**Files:**
- Create: `app/Modules/LogisticsFeature/Sources/LogisticsFeature.swift`, `LogisticsView.swift`, `HaulYieldRow.swift`
- Create: `app/Modules/LogisticsFeature/Tests/LogisticsFeatureTests.swift`
- Modify: `app/Modules/Package.swift` (library + target + test target, alphabetical — `LogisticsFeature` sorts between `LoginFeature` and `MessagesFeature`)

**Interfaces:**
- Consumes: `HaulYield`, `ResourceCost`, UI tokens
- Produces: `LogisticsFeature` (`@Reducer`) with `State.yields: [HaulYield]` and `State.range: TimeRange`; `LogisticsView(store:)`.

Follow `list-feature-query-in-state`: the `@FetchAll` lives in `@ObservableState`, the view is a pure renderer.

- [ ] **Step 1: Add the SPM targets**

In `app/Modules/Package.swift`, add the product (alphabetical in `products`):

```swift
        .library(name: "LogisticsFeature", targets: ["LogisticsFeature"]),
```

and the two targets (alphabetical in `targets`):

```swift
        .target(
            name: "LogisticsFeature",
            dependencies: [
                "GameModels",
                "GameServices",
                "UI",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "LogisticsFeature/Sources"
        ),
        .testTarget(
            name: "LogisticsFeatureTests",
            dependencies: [
                "GameDatabase",
                "GameModels",
                "LogisticsFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "LogisticsFeature/Tests"
        ),
```

Run: `cd app/Modules && swift package resolve`
Expected: resolves without error.

- [ ] **Step 2: Write the failing test**

```swift
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import LogisticsFeature

@Suite struct LogisticsFeatureTests {
    @Test func theLedgerLoadsNewestFirst() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for index in 0..<3 {
                try HaulYield.upsert {
                    HaulYield(
                        id: UUID(index), directiveID: "D1", controllerCode: "C",
                        deviceCode: "F", sourceDesignation: "ACHERNUR-BELT-1",
                        collectedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        unitsCollected: 100 * (index + 1),
                        perType: ResourceCost(structural: 100 * (index + 1)),
                        breakdownState: .exact
                    )
                }
                .execute(db)
            }
        }
        // `@FetchAll` fetches at init, so the ordering is assertable without
        // sending anything.
        let state = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            LogisticsFeature.State()
        }
        #expect(state.yields.map(\.unitsCollected) == [300, 200, 100])
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter LogisticsFeatureTests --event-stream-output-path /tmp/lf.jsonl`
Expected: FAIL — no such module `LogisticsFeature`.

- [ ] **Step 4: Write the reducer**

```swift
//
//  LogisticsFeature.swift
//  Replicould — Logistics feature
//
//  The haul-yield ledger: every Haul Run pickup and the charts over it.
//

import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData

@Reducer
public struct LogisticsFeature {
    @ObservableState
    public struct State: Equatable {
        @ObservationStateIgnored
        @FetchAll(HaulYield.order { $0.collectedAt.desc() }) public var yields: [HaulYield]
        public var range: TimeRange = .month
        public init() {}
    }

    public enum TimeRange: String, CaseIterable, Equatable, Sendable {
        case week, month, all
        public var title: String {
            switch self {
            case .week: "7 days"
            case .month: "30 days"
            case .all: "All"
            }
        }
        public var days: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .all: nil
            }
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
    }

    public init() {}

    // `@FetchAll` loads and stays live on its own, so there is no load action
    // and no `.task` — adding one would be a no-op the view still called.
    public var body: some ReducerOf<Self> {
        BindingReducer()
    }
}
```

- [ ] **Step 5: Write the row and the screen**

`HaulYieldRow.swift` — its own file, never beside a `#Preview`:

```swift
//
//  HaulYieldRow.swift
//  Replicould — Logistics feature
//

import GameModels
import SwiftUI
import UI

struct HaulYieldRow: View {
    let yield: HaulYield

    var body: some View {
        HStack(spacing: Space.m) {
            Text(yield.collectedAt, format: .dateTime.month().day().hour().minute())
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
            Text(yield.sourceDesignation).font(.rcBodyEmphMono)
            Spacer()
            ForEach(ResourceCost.displayOrder, id: \.key) { slot in
                let amount = yield.perType.amount(forKey: slot.key)
                if amount > 0 {
                    HStack(spacing: Space.xs) {
                        Circle().fill(Color.rcResource(slot.key)).frame(width: 8, height: 8)
                        Text("\(amount)").font(.rcMonoSmall)
                    }
                }
            }
            Text("\(yield.unitsCollected)").font(.rcBodyEmph).monospacedDigit()
            if yield.breakdownState != .exact {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.rcTextTertiary)
                    .help(yield.breakdownState == .partial ? "Breakdown reconstructed" : "Breakdown unavailable")
            }
        }
        .padding(.vertical, Space.xs)
    }
}
```

`LogisticsView.swift`. The chart stack arrives in Tasks 7–8; this task lands the shell and the ledger:

```swift
//
//  LogisticsView.swift
//  Replicould — Logistics feature
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

public struct LogisticsView: View {
    @Bindable var store: StoreOf<LogisticsFeature>

    public init(store: StoreOf<LogisticsFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            RCSectionHeader("Haul Yields")
            RCSegmentedControl(
                options: LogisticsFeature.TimeRange.allCases,
                selection: $store.range,
                title: \.title
            )
            if store.yields.isEmpty {
                RCContentUnavailableView(
                    "No Yields Yet",
                    systemImage: "shippingbox",
                    description: "A Haul Run's pickups appear here as they are observed."
                )
            } else {
                List {
                    ForEach(store.yields) { yield in
                        HaulYieldRow(yield: yield)
                    }
                }
                .rcListStyle()
            }
        }
        .padding(Space.m)
        .navigationTitle("Logistics")
    }
}
```

Confirm `RCSegmentedControl`'s actual generic signature and `rcListStyle()`'s name against `Controls.swift` and `ListStyles.swift` before writing — adapt the call sites if they differ, keeping the structure above.

Add `ResourceCost.amount(forKey:)` to `Blueprint.swift`:

```swift
    /// The field for a `displayOrder` key; zero for anything unknown.
    public func amount(forKey key: String) -> Int {
        switch key {
        case "structural": structural
        case "conductive": conductive
        case "silicates": silicates
        case "carbon": carbon
        case "rares": rares
        case "volatiles": volatiles
        default: 0
        }
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd app/Modules && swift test --filter LogisticsFeatureTests --event-stream-output-path /tmp/lf.jsonl`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/LogisticsFeature app/Modules/Package.swift app/Modules/GameModels/Sources/Blueprint.swift
git commit -m "feat(logistics): LogisticsFeature module and the yield ledger"
```

---

### Task 7: Aggregation and the KPI row

**Files:**
- Create: `app/Modules/LogisticsFeature/Sources/YieldSummary.swift`
- Test: `app/Modules/LogisticsFeature/Tests/YieldSummaryTests.swift`

**Interfaces:**
- Produces: `YieldSummary` with `init(yields:range:now:)`, `totalUnits: Int`, `tripCount: Int`, `unitsPerDay: Double`, `byResource: [(key: String, units: Int)]` (in `displayOrder`), `bySource: [(designation: String, units: Int)]` (descending), `byDay: [(day: Date, perType: ResourceCost)]` (ascending), `gapCount: Int`.

Pure over its inputs — no database, no clock beyond the injected `now`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import Testing
@testable import LogisticsFeature

@Suite struct YieldSummaryTests {
    private func yield(day: Int, units: Int, cost: ResourceCost, source: String = "A-1") -> HaulYield {
        HaulYield(
            id: UUID(day), directiveID: "D", controllerCode: "C", deviceCode: "F",
            sourceDesignation: source,
            collectedAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
            unitsCollected: units, perType: cost, breakdownState: .exact
        )
    }

    @Test func itTotalsUnitsAndTrips() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 100, cost: ResourceCost(structural: 100)),
                yield(day: 1, units: 200, cost: ResourceCost(rares: 200)),
            ],
            range: .all,
            now: Date(timeIntervalSince1970: 86_400)
        )
        #expect(summary.totalUnits == 300)
        #expect(summary.tripCount == 2)
    }

    @Test func itRanksSourcesByUnitsDescending() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 100, cost: ResourceCost(), source: "SMALL-1"),
                yield(day: 1, units: 900, cost: ResourceCost(), source: "BIG-1"),
            ],
            range: .all,
            now: Date(timeIntervalSince1970: 86_400)
        )
        #expect(summary.bySource.first?.designation == "BIG-1")
    }

    @Test func resourceTotalsKeepDisplayOrder() {
        let summary = YieldSummary(
            yields: [yield(day: 0, units: 300, cost: ResourceCost(structural: 100, rares: 200))],
            range: .all,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(summary.byResource.map(\.key) == ResourceCost.displayOrder.map(\.key))
        #expect(summary.byResource.first { $0.key == "rares" }?.units == 200)
    }

    @Test func theRangeExcludesOlderRows() {
        let summary = YieldSummary(
            yields: [
                yield(day: 0, units: 100, cost: ResourceCost()),
                yield(day: 40, units: 500, cost: ResourceCost()),
            ],
            range: .month,
            now: Date(timeIntervalSince1970: 40 * 86_400)
        )
        #expect(summary.totalUnits == 500)
    }

    @Test func gapsAreCountedSoTheChartCanSayItDoesNotKnow() {
        var gapped = yield(day: 0, units: 100, cost: ResourceCost())
        gapped.followsGap = true
        let summary = YieldSummary(yields: [gapped], range: .all, now: Date(timeIntervalSince1970: 0))
        #expect(summary.gapCount == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter YieldSummaryTests --event-stream-output-path /tmp/ys.jsonl`
Expected: FAIL — `cannot find 'YieldSummary' in scope`.

- [ ] **Step 3: Write `YieldSummary`**

```swift
//
//  YieldSummary.swift
//  Replicould — Logistics feature
//
//  Every figure the screen shows, folded from the ledger rows in one pass.
//

import Foundation
import GameModels

struct YieldSummary {
    let totalUnits: Int
    let tripCount: Int
    let unitsPerDay: Double
    let byResource: [(key: String, units: Int)]
    let bySource: [(designation: String, units: Int)]
    let byDay: [(day: Date, perType: ResourceCost)]
    let gapCount: Int

    init(yields: [HaulYield], range: LogisticsFeature.TimeRange, now: Date, calendar: Calendar = .current) {
        let cutoff = range.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let rows = cutoff.map { limit in yields.filter { $0.collectedAt >= limit } } ?? yields

        totalUnits = rows.reduce(0) { $0 + $1.unitsCollected }
        tripCount = rows.count
        gapCount = rows.count(where: \.followsGap)

        let summed = rows.reduce(into: ResourceCost()) { $0.add($1.perType) }
        byResource = ResourceCost.displayOrder.map { ($0.key, summed.amount(forKey: $0.key)) }

        var sources: [String: Int] = [:]
        for row in rows { sources[row.sourceDesignation, default: 0] += row.unitsCollected }
        bySource = sources
            .map { (designation: $0.key, units: $0.value) }
            .sorted { lhs, rhs in
                lhs.units == rhs.units ? lhs.designation < rhs.designation : lhs.units > rhs.units
            }

        var days: [Date: ResourceCost] = [:]
        for row in rows {
            days[calendar.startOfDay(for: row.collectedAt), default: ResourceCost()].add(row.perType)
        }
        byDay = days.map { (day: $0.key, perType: $0.value) }.sorted { $0.day < $1.day }

        // Span the observed window, never the requested range: a 30-day filter
        // over two days of data must not divide by 30.
        let span: Double
        if let first = rows.map(\.collectedAt).min(), let last = rows.map(\.collectedAt).max() {
            span = Swift.max(1, last.timeIntervalSince(first) / 86_400)
        } else {
            span = 1
        }
        unitsPerDay = Double(totalUnits) / span
    }
}
```

`YieldSummary` is deliberately NOT `Equatable`. It is a computed property on `State`, never stored, so `State`'s own `Equatable` does not reach it — and a hand-written `==` over tuple arrays would have to compare a subset of the fields, which is a broken `Equatable` rather than a convenient one.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter YieldSummaryTests --event-stream-output-path /tmp/ys.jsonl`
Expected: PASS, 5 tests.

- [ ] **Step 5: Add the KPI row to `LogisticsView`**

Create `app/Modules/LogisticsFeature/Sources/YieldKPIRow.swift` (its own file — never beside a `#Preview`):

```swift
//
//  YieldKPIRow.swift
//  Replicould — Logistics feature
//

import GameModels
import SwiftUI
import UI

struct YieldKPIRow: View {
    let summary: YieldSummary

    private var topResource: (key: String, units: Int)? {
        summary.byResource.filter { $0.units > 0 }.max { $0.units < $1.units }
    }

    var body: some View {
        HStack(spacing: Space.m) {
            RCReadoutCard {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Units Hauled").font(.rcSectionLabel).foregroundStyle(.rcTextSecondary)
                    Text("\(summary.totalUnits)").font(.rcDisplay).monospacedDigit()
                }
            }
            RCReadoutCard {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Trips").font(.rcSectionLabel).foregroundStyle(.rcTextSecondary)
                    Text("\(summary.tripCount)").font(.rcDisplay).monospacedDigit()
                }
            }
            RCReadoutCard {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Units / Day").font(.rcSectionLabel).foregroundStyle(.rcTextSecondary)
                    Text(summary.unitsPerDay, format: .number.precision(.fractionLength(0)))
                        .font(.rcDisplay).monospacedDigit()
                }
            }
            RCReadoutCard {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Most Hauled").font(.rcSectionLabel).foregroundStyle(.rcTextSecondary)
                    if let topResource {
                        HStack(spacing: Space.xs) {
                            // The mark carries identity; the text stays ink.
                            Circle()
                                .fill(Color.rcResource(topResource.key))
                                .frame(width: 10, height: 10)
                            Text(topResource.key.capitalized).font(.rcHeadline)
                        }
                    } else {
                        Text("—").font(.rcHeadline).foregroundStyle(.rcTextTertiary)
                    }
                }
            }
        }
    }
}
```

Insert `YieldKPIRow(summary: store.summary)` into `LogisticsView` above the range picker, and add a computed `summary` to `LogisticsFeature.State`:

```swift
        public var summary: YieldSummary {
            YieldSummary(yields: yields, range: range, now: Date())
        }
```

- [ ] **Step 6: Commit**

```bash
git add app/Modules/LogisticsFeature
git commit -m "feat(logistics): yield aggregation and the KPI row"
```

---

### Task 8: The charts

**Files:**
- Create: `app/Modules/LogisticsFeature/Sources/YieldCharts.swift`
- Modify: `app/Modules/LogisticsFeature/Sources/LogisticsView.swift`

**Interfaces:**
- Consumes: `YieldSummary`, `Color.rcResource(_:)`
- Produces: `YieldOverTimeChart(summary:)` and `YieldBreakdownChart(summary:)`.

Three rules from the spec that are not negotiable here:

- **One axis.** Never two y-scales.
- **Direct labels are mandatory** on the stacked column — the palette clears its CVD gate only in the 6–9 floor band, which is legal only with secondary encoding.
- **No all-pairs categorical form.** The composition chart is a stacked column and nothing else.

- [ ] **Step 1: Write the charts**

```swift
//
//  YieldCharts.swift
//  Replicould — Logistics feature
//
//  Composition over time, and the two magnitude breakdowns.
//

import Charts
import GameModels
import SwiftUI
import UI

/// One stacked segment: a day, a resource, and its units.
private struct YieldPoint: Identifiable {
    let day: Date
    let key: String
    let units: Int
    /// Stable across reloads — the pair is unique within the series.
    var id: String { "\(day.timeIntervalSince1970)-\(key)" }
}

struct YieldOverTimeChart: View {
    let summary: YieldSummary

    private var points: [YieldPoint] {
        summary.byDay.flatMap { entry in
            ResourceCost.displayOrder.compactMap { slot in
                let units = entry.perType.amount(forKey: slot.key)
                return units > 0 ? YieldPoint(day: entry.day, key: slot.key, units: units) : nil
            }
        }
    }

    /// The largest segment of each day — the only one direct-labelled. A number
    /// on every point is noise; none at all leaves the CVD gate unrelieved.
    private var labelledIDs: Set<String> {
        Set(
            Dictionary(grouping: points, by: \.day)
                .compactMap { $0.value.max { $0.units < $1.units }?.id }
        )
    }

    var body: some View {
        Chart(points) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Units", point.units)
            )
            .foregroundStyle(by: .value("Resource", point.key))
            .cornerRadius(2)
            .annotation(position: .overlay) {
                if labelledIDs.contains(point.id) {
                    Text("\(point.units)")
                        .font(.rcMicroMono)
                        .foregroundStyle(.rcTextPrimary)
                }
            }
        }
        .chartForegroundStyleScale(
            domain: ResourceCost.displayOrder.map(\.key),
            range: ResourceCost.displayOrder.map { Color.rcResource($0.key) }
        )
        .chartLegend(position: .bottom)
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(minHeight: 200)
        .overlay(alignment: .topTrailing) {
            if summary.gapCount > 0 {
                Text("\(summary.gapCount) gap\(summary.gapCount == 1 ? "" : "s") — unobserved, not empty")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
    }
}

struct YieldBreakdownChart: View {
    let title: String
    /// Sequential single hue: this compares magnitude, not identity.
    let rows: [(label: String, units: Int)]
    let monospacedLabels: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(.rcSectionLabel).foregroundStyle(.rcTextSecondary)
            Chart(rows.filter { $0.units > 0 }, id: \.label) { row in
                BarMark(
                    x: .value("Units", row.units),
                    y: .value("Label", row.label)
                )
                .foregroundStyle(Color.rcAccent)
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text("\(row.units)").font(.rcMonoSmall).foregroundStyle(.rcTextSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(monospacedLabels ? .rcMonoSmall : .rcCaption)
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(minHeight: 160)
        }
    }
}
```

- [ ] **Step 2: Compose into `LogisticsView`**

Between the range picker and the ledger `List`:

```swift
            YieldOverTimeChart(summary: store.summary)
            HStack(alignment: .top, spacing: Space.m) {
                YieldBreakdownChart(
                    title: "By Resource",
                    rows: store.summary.byResource.map { ($0.key.capitalized, $0.units) },
                    monospacedLabels: false
                )
                YieldBreakdownChart(
                    title: "By Source",
                    rows: store.summary.bySource.map { ($0.designation, $0.units) },
                    monospacedLabels: true
                )
            }
```

Wrap the whole `VStack` in a `ScrollView` so the charts and ledger scroll together, and give each chart's container `.overflow`-equivalent behaviour by letting the `Chart` size to its frame rather than its content.

- [ ] **Step 4: Verify both color schemes**

Add `#Preview` blocks in their own file (`LogisticsView+Previews.swift`) with `.preferredColorScheme(.dark)` and `.preferredColorScheme(.light)`, seeded from `previewValue` fixtures. Open both and confirm no label collisions, no horizontal overflow, and that every segment separates.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/LogisticsFeature
git commit -m "feat(logistics): yield-over-time and breakdown charts"
```

---

### Task 9: Sidebar wiring

**Files:**
- Modify: `app/Modules/SidebarFeature/Sources/SidebarItem.swift` (case, title, symbol, group)
- Modify: `app/macOS/MainFeature.swift:361` (content branch)
- Test: `app/Modules/SidebarFeature/Tests/SidebarItemTests.swift`

**Interfaces:**
- Consumes: `LogisticsView`, `LogisticsFeature`
- Produces: `SidebarItem.logistics`

**This task needs a manual step you cannot perform:** linking the `LogisticsFeature` product to the app target must be done by the user in Xcode (`pbxproj` edits are blocked). Stop and ask before Step 3.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SidebarFeature

@Suite struct SidebarItemTests {
    @Test func logisticsSitsInOperationsAndHasNoDetailPane() {
        #expect(SidebarItem.logistics.title == "Logistics")
        #expect(!SidebarItem.logistics.hasDetail)
        let operations = SidebarItem.groups.first { $0.id == "Operations" }
        #expect(operations?.items.contains(.logistics) == true)
    }
}
```

- [ ] **Step 2: Add the case**

In `SidebarItem.swift`: add `logistics` to the Operations case list (line 17), `case .logistics: "Logistics"` to `title`, `case .logistics: "shippingbox"` to `symbol`, `.logistics` to `hasDetail`'s false branch beside `.operationsLog` and `.stars`, and `.logistics` to the Operations `Group`.

Run: `cd app/Modules && swift test --filter SidebarItemTests --event-stream-output-path /tmp/si.jsonl`
Expected: PASS.

- [ ] **Step 3: Ask the user to link the module**

Stop here. Ask the user to add `LogisticsFeature` to the Replicould app target's linked libraries in Xcode, and wait for confirmation before continuing.

- [ ] **Step 4: Wire the content pane**

In `MainFeature.swift`, add a `logisticsStore` beside the existing scoped stores and a branch before the fallback:

```swift
        } else if store.sidebar.category == .logistics {
            LogisticsView(store: logisticsStore)
```

- [ ] **Step 5: Build and run**

Run: `cd app && xcodebuild -project Replicould.xcodeproj -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

Then launch the app, select Logistics, and confirm the ledger populates as digests arrive. The live fleet collects roughly every ten minutes, so allow one cycle before judging it empty.

- [ ] **Step 6: Run the full suite**

Run: `cd app/Modules && swift test --event-stream-output-path /tmp/all.jsonl`

Read results through the `swift-test-event-stream` skill. `theSupervisorAdoptsTheRowTheBrainLaunched` is a known pre-existing whole-package failure — do not attribute it to this work.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/SidebarFeature app/macOS/MainFeature.swift
git commit -m "feat(logistics): Logistics sidebar category"
```

---

## Post-Implementation

- [ ] Run `./app/scripts/check-comments.sh` over every touched path from the repo root.
- [ ] Write the memory note `logistics-haul-yields.md` plus its `MEMORY.md` index line, recording the digest-suppression constraint and the adjacent-pairs palette gate.
- [ ] Merge the worktree branch to local `main`. No PR.
