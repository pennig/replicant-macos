# Location-Event Fulfilment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the automation brain a `fulfillEvent` goal and an `eventRun` convoy executor that prints and delivers a location event's devices and resources, commits the event, plants an FTL beacon, sweeps the reward pile, and flies both hulls home.

**Architecture:** The brain stays a pure selector: it ranks active `LocationEvent` rows each tick and launches one carrier-owned `eventRun` directive. `EventRun` is a composing `MissionStepMachine` in the shape of `RelayRun` (print → load → travel → place → return), with three additions — a commit through `LocationEventsClient`, a reward sweep, and a replicant courier attached to the carrier so the commit's replicant-presence precondition is met. Two additive nullable columns and two new `MissionAction` cases are the whole structural change.

**Tech Stack:** Swift 6, SPM package at `app/Modules`, Swift Testing (`@Test`/`#expect`), SQLiteData/GRDB, `swift-dependencies`. The engine is non-TCA; `DirectiveEngine` is the module.

**Spec:** `docs/superpowers/specs/2026-08-14-brain-event-fulfilment-design.md` — read it before Task 1. The plan argues from the spec and does not restate its rationale.

## Global Constraints

- **Target directory:** all engine work is in `app/Modules/DirectiveEngine/Sources` and `.../Tests`; models in `app/Modules/GameModels/Sources`; the migration manifest in `app/Modules/GameDatabase/Sources/GameDatabase.swift`.
- **Build and test from `app/Modules`.** A fresh worktree needs `swift build --build-tests` then `./scripts/link-index-store.sh` before LSP answers anything.
- **Read test results from the Swift Testing JSON event stream**, never console text. Use the `swift-test-event-stream` skill for the invocation.
- **Migrations are append-only.** A new column is a new `SchemaMigration` appended to `GameDatabase.manifest` — never an edit to a shipped `CREATE TABLE`. `SchemaManifestTests` freezes the identifier list; `GoldenSchemaTests` snapshots the schema and is regenerated only with `RC_REGENERATE_SCHEMA_FIXTURE=1`.
- **Comment budget is hard:** file header ≤ 6 lines, `///` ≤ 3 lines, inline `//` ≤ 2 lines. No history, no rationale, no dated notes, no live device codes in source. Those go to `app/.claude/memory/`.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category `DirectiveEngine`.
- **Loud test defaults:** a client's `testValue` uses `unimplemented(...)`, never a quiet stub.
- **A mission step machine must be pure** — no I/O, no `Date()`, no randomness. Read the clock from `world.now`.
- **Fleet tags reaching the server must be bare.** A per-theatre tag (`auto:event:<depot>`) is local-only; anything sent to `GET devices/tags/{tag}` must go through `RepairFleet.root(of:)`.
- **Commit after every task.** Conventional-commit subject, no PRs, no pushes to a remote.

**Fixture constructors take every parameter.** `Device.init` has nineteen, none defaulted (`GameModels/Sources/Device.swift:50`), and `LocationFootprint.init` has seven (`UniverseModels/Sources/LocationRecords.swift:112`). Every `device(...)` / footprint helper in this plan's tests is shorthand for a full call — write the helper once, with defaults of your own, and let the suites call through it. Do not give a helper a zero-defaults overload: Swift prefers it over a private one needing three arguments, which silently rebound four tests during the survey fleet-repair build.

---

### Task 1: Decode an event's criteria when progress is absent

`LocationEventDetail` builds `options` only from `progress.options`. An event seeded from the `event.discovered` SSE payload carries `criteria` and `rewards` but no `progress`, so it decodes with `options: []` and the brain would read it as costing nothing. Close that before anything ranks on it.

**Files:**
- Modify: `app/Modules/GameModels/Sources/LocationEvent.swift:314-345` (the `init?(_ json:)` options block)
- Test: `app/Modules/GameModels/Tests/LocationEventDetailTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `LocationEventDetail.init?(_ json: JSONValue)` now populates `options` from `criteria` when `progress` is missing, with `current: 0` and `met: false` on every requirement. `LocationEventDetail.optionsAreFromCriteria: Bool` reports which source was used.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import Utils
@testable import GameModels

@Suite("LocationEventDetail criteria fallback")
struct LocationEventDetailCriteriaTests {
    /// A discovery payload: criteria + rewards, no progress block.
    private var discovered: JSONValue {
        .object([
            "criteria": .array([
                .object([
                    "name": .string("default"),
                    "devices": .array([
                        .object(["count": .number(2), "device_type": .string("comm_satellite")])
                    ]),
                    "resources": .object(["conductive": .number(150)]),
                ])
            ]),
            "rewards": .object(["xp": .number(1500)]),
        ])
    }

    @Test("criteria populate options when progress is absent")
    func criteriaFallback() throws {
        let detail = try #require(LocationEventDetail(discovered))
        #expect(detail.optionsAreFromCriteria)
        #expect(detail.options.count == 1)
        let option = try #require(detail.options.first)
        #expect(option.name == "default")
        #expect(option.met == false)
        #expect(option.resources == [
            .init(resourceType: "conductive", current: 0, required: 150, met: false)
        ])
        #expect(option.devices == [
            .init(deviceType: "comm_satellite", current: 0, required: 2, met: false)
        ])
    }

    @Test("progress still wins when both blocks are present")
    func progressWins() throws {
        // `JSONValue`'s subscript is get-only — no setter exists. Compose with
        // the `adding(_:_:)` helper instead.
        let json = discovered.adding("progress", .object([
            "met": .bool(false),
            "replicant_present": .bool(true),
            "options": .array([
                .object([
                    "name": .string("default"),
                    "met": .bool(false),
                    "devices": .array([]),
                    "resources": .array([
                        .object([
                            "resource_type": .string("conductive"),
                            "current": .number(90),
                            "required": .number(150),
                            "met": .bool(false),
                        ])
                    ]),
                ])
            ]),
        ]))
        let detail = try #require(LocationEventDetail(json))
        #expect(detail.optionsAreFromCriteria == false)
        #expect(detail.replicantPresent)
        #expect(detail.options.first?.resources.first?.current == 90)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run from `app/Modules`:
```bash
swift test --filter LocationEventDetailCriteriaTests \
  --event-stream-output-path /tmp/rc-t1.jsonl
```
Expected: FAIL — `value of type 'LocationEventDetail' has no member 'optionsAreFromCriteria'`.

- [ ] **Step 3: Write minimal implementation**

Add the stored property to `LocationEventDetail` beside `met`:

```swift
    /// Whether `options` came from `criteria` rather than live `progress` —
    /// true for a freshly-discovered event, whose counters are all zero.
    public let optionsAreFromCriteria: Bool
```

Replace the `options = …` assignment in `init?` with:

```swift
        if let live = progress?["options"]?.arrayValue, !live.isEmpty {
            optionsAreFromCriteria = false
            options = live.map(Self.option(fromProgress:))
        } else {
            optionsAreFromCriteria = true
            options = (json["criteria"]?.arrayValue ?? []).map(Self.option(fromCriteria:))
        }
```

Add the two builders as private statics on `LocationEventDetail`:

```swift
    private static func option(fromProgress opt: JSONValue) -> Option {
        Option(
            name: opt["name"]?.stringValue ?? "default",
            met: opt["met"]?.boolValue ?? false,
            resources: (opt["resources"]?.arrayValue ?? []).compactMap { r in
                guard let type = r["resource_type"]?.stringValue else { return nil }
                return ResourceRequirement(
                    resourceType: type,
                    current: Int(r["current"]?.numberValue ?? 0),
                    required: Int(r["required"]?.numberValue ?? 0),
                    met: r["met"]?.boolValue ?? false
                )
            },
            devices: (opt["devices"]?.arrayValue ?? []).compactMap { d in
                guard let type = d["device_type"]?.stringValue else { return nil }
                return DeviceRequirement(
                    deviceType: type,
                    current: Int(d["current"]?.numberValue ?? 0),
                    required: Int(d["required"]?.numberValue ?? 0),
                    met: d["met"]?.boolValue ?? false
                )
            }
        )
    }

    /// A criteria entry states requirements only, so every counter reads zero.
    private static func option(fromCriteria opt: JSONValue) -> Option {
        let resources: [ResourceRequirement]
        if case .object(let dict)? = opt["resources"] {
            resources = dict.compactMap { key, value in
                value.numberValue.map {
                    ResourceRequirement(resourceType: key, current: 0, required: Int($0), met: false)
                }
            }.sorted { $0.resourceType < $1.resourceType }
        } else {
            resources = []
        }
        return Option(
            name: opt["name"]?.stringValue ?? "default",
            met: false,
            resources: resources,
            devices: (opt["devices"]?.arrayValue ?? []).compactMap { d in
                guard let type = d["device_type"]?.stringValue else { return nil }
                return DeviceRequirement(
                    deviceType: type,
                    current: 0,
                    required: Int(d["count"]?.numberValue ?? 0),
                    met: false
                )
            }
        )
    }
```

Make `ResourceRequirement` and `DeviceRequirement` conform to `Equatable` if they do not already (both are declared `Equatable` today, so no change is expected — verify rather than assume).

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter LocationEventDetailCriteriaTests \
  --event-stream-output-path /tmp/rc-t1.jsonl
```
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameModels/Sources/LocationEvent.swift \
        app/Modules/GameModels/Tests/LocationEventDetailTests.swift
git commit -m "feat(events): decode criteria when an event carries no progress"
```

---

### Task 2: `EventPlan` — the bill for one event

A pure value type answering: which option is in force, what does it cost, and what is still missing at a location. Every later task reads this rather than re-walking the blob.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/EventPlan.swift`
- Test: `app/Modules/DirectiveEngine/Tests/EventPlanTests.swift`

**Interfaces:**
- Consumes: `LocationEventDetail` from Task 1.
- Produces:
  - `EventPlan.Option` — `{ name: String, devices: [String: Int], resources: [String: Int], deviceUnits: Int, resourceUnits: Int }`
  - `EventPlan.resolve(_ event: LocationEvent, chosenOption: String?, bills: [String: ResourceCost]) -> EventPlan.Resolution`

**Type note — read before writing the test.** The catalogue of build costs on `WorldView` is `blueprintBills: [String: ResourceCost]`, not a flat `[String: Int]`. `ResourceCost` has a `total: Int` (`GameModels/Sources/Blueprint.swift:181`) — sum through that. Every caller in Tasks 3, 8, 13 and 14 passes `view.blueprintBills`.
  - `EventPlan.Resolution` — `.decided(Option)` / `.needsChoice([Option])` / `.undecodable`
  - `EventPlan.beaconDeviceType = "ftl_beacon"`
  - `EventPlan.freighterCargoCapacity = 500`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

@Suite("EventPlan")
struct EventPlanTests {
    private let costs: [String: ResourceCost] = [
        "comm_satellite": ResourceCost(silicates: 100, structural: 100, conductive: 150),
        "signal_booster": ResourceCost(structural: 150, rares: 50, conductive: 200),
        "mesh_relay": ResourceCost(silicates: 30, structural: 50, conductive: 80),
        "climate_processor": ResourceCost(
            carbon: 250, structural: 200, rares: 100, conductive: 250, volatiles: 200
        ),
        "atmospheric_regulator": ResourceCost(
            silicates: 200, structural: 200, conductive: 300, volatiles: 150
        ),
    ]

    private func event(_ criteria: JSONValue, designation: String = "X-1-EVT-001") -> LocationEvent {
        LocationEvent(
            designation: designation, location: "X-1", tier: 2, status: "active",
            detail: .object(["criteria": criteria, "rewards": .object(["xp": .number(1500)])]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    private func option(_ name: String, devices: [(Int, String)], resources: [String: Int]) -> JSONValue {
        .object([
            "name": .string(name),
            "devices": .array(devices.map {
                .object(["count": .number(Double($0.0)), "device_type": .string($0.1)])
            }),
            "resources": .object(resources.mapValues { .number(Double($0)) }),
        ])
    }

    @Test("a single-option event is decided without a choice")
    func singleOption() throws {
        let row = event(.array([option("default", devices: [(2, "comm_satellite")], resources: ["conductive": 150])]))
        guard case .decided(let plan) = EventPlan.resolve(row, chosenOption: nil, bills: costs) else {
            Issue.record("expected .decided"); return
        }
        #expect(plan.name == "default")
        #expect(plan.devices == ["comm_satellite": 2])
        #expect(plan.resources == ["conductive": 150])
        #expect(plan.deviceUnits == 700)
        #expect(plan.resourceUnits == 150)
    }

    @Test("a multi-option event needs a choice until one is recorded")
    func multiOption() throws {
        let row = event(.array([
            option("satellite", devices: [(2, "comm_satellite")], resources: ["conductive": 150]),
            option("booster", devices: [(1, "signal_booster")], resources: ["conductive": 150]),
        ]))
        guard case .needsChoice(let offered) = EventPlan.resolve(row, chosenOption: nil, bills: costs) else {
            Issue.record("expected .needsChoice"); return
        }
        #expect(offered.map(\.name) == ["satellite", "booster"])

        guard case .decided(let plan) = EventPlan.resolve(row, chosenOption: "booster", bills: costs) else {
            Issue.record("expected .decided"); return
        }
        #expect(plan.name == "booster")
        #expect(plan.deviceUnits == 400)
    }

    @Test("a recorded choice naming no real option needs a choice again")
    func staleChoice() {
        let row = event(.array([
            option("satellite", devices: [(2, "comm_satellite")], resources: [:]),
            option("booster", devices: [(1, "signal_booster")], resources: [:]),
        ]))
        guard case .needsChoice = EventPlan.resolve(row, chosenOption: "gone", bills: costs) else {
            Issue.record("expected .needsChoice"); return
        }
    }

    @Test("an option over the freighter's hold is still decided, and reports it")
    func oversizedCargo() throws {
        let row = event(.array([
            option("heavy", devices: [(2, "climate_processor")], resources: ["volatiles": 300, "carbon": 400])
        ]))
        guard case .decided(let plan) = EventPlan.resolve(row, chosenOption: nil, bills: costs) else {
            Issue.record("expected .decided"); return
        }
        #expect(plan.resourceUnits == 700)
        #expect(plan.exceedsOneFreighterLoad)
    }

    @Test("an undecodable blob resolves to .undecodable rather than a free event")
    func undecodable() {
        let row = LocationEvent(
            designation: "X-1-EVT-002", location: "X-1", status: "active",
            detail: .object([:]), firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        guard case .undecodable = EventPlan.resolve(row, chosenOption: nil, bills: costs) else {
            Issue.record("expected .undecodable"); return
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventPlanTests --event-stream-output-path /tmp/rc-t2.jsonl
```
Expected: FAIL — `cannot find 'EventPlan' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
//
//  EventPlan.swift
//  Replicould — DirectiveEngine
//
//  What one location event costs: the option in force and its device and
//  resource bill, priced through the blueprint catalogue.
//

import Foundation
import GameModels

public enum EventPlan {
    /// The beacon planted at every fulfilled event so later requests reach us.
    public static let beaconDeviceType = "ftl_beacon"
    /// A `cargo_freighter`'s hold. An option above this needs more than one run.
    public static let freighterCargoCapacity = 500

    /// One way to satisfy an event, priced.
    public struct Option: Equatable, Sendable {
        public let name: String
        public let devices: [String: Int]
        public let resources: [String: Int]
        /// The build cost of every device in `devices`, summed.
        public let deviceUnits: Int
        /// Units of raw resource the event consumes.
        public let resourceUnits: Int

        public var exceedsOneFreighterLoad: Bool {
            resourceUnits > EventPlan.freighterCargoCapacity
        }
    }

    /// Whether an event can be worked without asking the operator.
    public enum Resolution: Equatable, Sendable {
        case decided(Option)
        case needsChoice([Option])
        /// The blob carries no readable option — never treat this as free.
        case undecodable
    }

    /// Resolve `event` against an optional recorded pick. A pick naming no
    /// offered option is ignored, so a stale choice re-asks rather than misfires.
    public static func resolve(
        _ event: LocationEvent, chosenOption: String?, bills: [String: ResourceCost]
    ) -> Resolution {
        guard let detail = LocationEventDetail(event.detail), !detail.options.isEmpty else {
            return .undecodable
        }
        let priced = detail.options.map { price($0, bills) }
        if priced.count == 1, let only = priced.first { return .decided(only) }
        if let name = chosenOption, let picked = priced.first(where: { $0.name == name }) {
            return .decided(picked)
        }
        return .needsChoice(priced)
    }

    private static func price(
        _ option: LocationEventDetail.Option, _ bills: [String: ResourceCost]
    ) -> Option {
        let devices = option.devices.reduce(into: [String: Int]()) { $0[$1.deviceType] = $1.required }
        let resources = option.resources.reduce(into: [String: Int]()) { $0[$1.resourceType] = $1.required }
        return Option(
            name: option.name,
            devices: devices,
            resources: resources,
            deviceUnits: devices.reduce(0) { $0 + (bills[$1.key]?.total ?? 0) * $1.value },
            resourceUnits: resources.values.reduce(0, +)
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter EventPlanTests --event-stream-output-path /tmp/rc-t2.jsonl
```
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/EventPlan.swift \
        app/Modules/DirectiveEngine/Tests/EventPlanTests.swift
git commit -m "feat(brain): price a location event's fulfilment options"
```

---

### Task 3: `EventRanking` — which event the convoy works next

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/EventRanking.swift`
- Test: `app/Modules/DirectiveEngine/Tests/EventRankingTests.swift`

**Interfaces:**
- Consumes: `EventPlan.Resolution` (Task 2), `WorldView.locationEvents`, `WorldView.blueprintBills`, `WorldView.starPositions`.
- Produces:
  - `EventCandidate` — `{ designation: String, location: String, tier: Int, option: EventPlan.Option, alreadyMet: Bool, roundTripSeconds: Double, rationale: String }`
  - `EventRanking.rank(events:chosenOptions:bills:positions:depot:excluding:) -> [EventCandidate]`
  - `EventRanking.pendingChoices(events:chosenOptions:bills:) -> [(LocationEvent, [EventPlan.Option])]`
  - `EventRanking.secondsPerLy = 30.0`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

@Suite("EventRanking")
struct EventRankingTests {
    private let costs = ["defence_grid": 400, "comm_satellite": 350]

    private func event(
        _ designation: String, location: String, tier: Int,
        status: String = "active", met: Bool = false,
        resources: [String: Int] = ["structural": 200], options: Int = 1
    ) -> LocationEvent {
        let criteria = (0..<options).map { index in
            JSONValue.object([
                "name": .string(index == 0 ? "default" : "alt\(index)"),
                "devices": .array([]),
                "resources": .object(resources.mapValues { .number(Double($0)) }),
            ])
        }
        return LocationEvent(
            designation: designation, location: location, tier: tier, status: status,
            objectivesMet: met,
            detail: .object([
                "criteria": .array(criteria),
                "progress": .object([
                    "met": .bool(met), "replicant_present": .bool(false),
                    "options": .array([]),
                ]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    private let positions: [String: Position] = [
        "HUB": Position(x: 0, y: 0, z: 0),
        "NEAR": Position(x: 1, y: 0, z: 0),
        "FAR": Position(x: 10, y: 0, z: 0),
    ]

    @Test("already-met events outrank everything, then tier, then round trip")
    func order() {
        let events = [
            event("FAR-1-EVT-001", location: "FAR-1", tier: 4),
            event("NEAR-1-EVT-001", location: "NEAR-1", tier: 1),
            event("NEAR-2-EVT-001", location: "NEAR-2", tier: 1, met: true),
            event("NEAR-3-EVT-001", location: "NEAR-3", tier: 2),
        ]
        let ranked = EventRanking.rank(
            events: events, chosenOptions: [:], bills: costs,
            positions: positions, depot: "HUB-1", excluding: []
        )
        #expect(ranked.map(\.designation) == [
            "NEAR-2-EVT-001",  // already met
            "FAR-1-EVT-001",   // tier 4
            "NEAR-3-EVT-001",  // tier 2
            "NEAR-1-EVT-001",  // tier 1
        ])
    }

    @Test("a tie on tier breaks on round-trip cost then designation")
    func tieBreak() {
        let events = [
            event("FAR-1-EVT-001", location: "FAR-1", tier: 1),
            event("NEAR-1-EVT-001", location: "NEAR-1", tier: 1),
        ]
        let ranked = EventRanking.rank(
            events: events, chosenOptions: [:], bills: costs,
            positions: positions, depot: "HUB-1", excluding: []
        )
        #expect(ranked.map(\.designation) == ["NEAR-1-EVT-001", "FAR-1-EVT-001"])
        #expect(ranked[0].roundTripSeconds == 2 * 1 * EventRanking.secondsPerLy)
    }

    @Test("inactive, excluded, undecided and undecodable events are not candidates")
    func excluded() {
        let events = [
            event("A-1-EVT-001", location: "NEAR-1", tier: 1, status: "completed"),
            event("B-1-EVT-001", location: "NEAR-1", tier: 1),
            event("C-1-EVT-001", location: "NEAR-1", tier: 1, options: 2),
            LocationEvent(
                designation: "D-1-EVT-001", location: "NEAR-1", status: "active",
                detail: .object([:]), firstSeenAt: .distantPast, updatedAt: .distantPast
            ),
        ]
        let ranked = EventRanking.rank(
            events: events, chosenOptions: [:], bills: costs,
            positions: positions, depot: "HUB-1", excluding: ["B-1-EVT-001"]
        )
        #expect(ranked.isEmpty)
    }

    @Test("a recorded choice makes a multi-option event a candidate")
    func choiceAdmits() {
        let events = [event("C-1-EVT-001", location: "NEAR-1", tier: 1, options: 2)]
        let ranked = EventRanking.rank(
            events: events, chosenOptions: ["C-1-EVT-001": "alt1"], bills: costs,
            positions: positions, depot: "HUB-1", excluding: []
        )
        #expect(ranked.map(\.option.name) == ["alt1"])
    }

    @Test("pendingChoices lists only undecided multi-option active events")
    func pending() {
        let events = [
            event("C-1-EVT-001", location: "NEAR-1", tier: 1, options: 2),
            event("D-1-EVT-001", location: "NEAR-1", tier: 1, options: 3),
            event("E-1-EVT-001", location: "NEAR-1", tier: 1),
        ]
        let pending = EventRanking.pendingChoices(
            events: events, chosenOptions: ["C-1-EVT-001": "alt1"], bills: costs
        )
        #expect(pending.map(\.0.designation) == ["D-1-EVT-001"])
        #expect(pending.first?.1.count == 3)
    }

    @Test("an event whose system the census cannot place still ranks, cost last")
    func unplaceable() {
        let events = [
            event("GHOST-1-EVT-001", location: "GHOST-1", tier: 1),
            event("NEAR-1-EVT-001", location: "NEAR-1", tier: 1),
        ]
        let ranked = EventRanking.rank(
            events: events, chosenOptions: [:], bills: costs,
            positions: positions, depot: "HUB-1", excluding: []
        )
        #expect(ranked.map(\.designation) == ["NEAR-1-EVT-001", "GHOST-1-EVT-001"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventRankingTests --event-stream-output-path /tmp/rc-t3.jsonl
```
Expected: FAIL — `cannot find 'EventRanking' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
//
//  EventRanking.swift
//  Replicould — DirectiveEngine
//
//  Which location event the convoy works next: a lexicographic key over the
//  active ledger, in `GrowRanking`'s shape.
//

import Foundation
import GameModels
import UniverseModels

/// One rankable event, with the option in force and what reaching it costs.
public struct EventCandidate: Equatable, Sendable {
    public let designation: String
    public let location: String
    public let tier: Int
    public let option: EventPlan.Option
    /// Everything is already staged on site; the convoy only has to commit.
    public let alreadyMet: Bool
    /// Depot → event → depot at `EventRanking.secondsPerLy`. `.infinity` when
    /// the census cannot place either end.
    public let roundTripSeconds: Double
    public let rationale: String
}

public enum EventRanking {
    /// Shared with `HaulTargetPlanner.roundTripRank`; still uncalibrated.
    public static let secondsPerLy = 30.0

    /// Rank the events worth working, best first.
    public static func rank(
        events: [LocationEvent],
        chosenOptions: [String: String],
        bills: [String: ResourceCost],
        positions: [String: Position],
        depot: String,
        excluding: Set<String>
    ) -> [EventCandidate] {
        events
            .filter { $0.isActive && !excluding.contains($0.designation) }
            .compactMap { event -> EventCandidate? in
                guard case .decided(let option) = EventPlan.resolve(
                    event, chosenOption: chosenOptions[event.designation], bills: bills
                ) else { return nil }
                let trip = roundTrip(from: depot, to: event.location, positions: positions)
                return EventCandidate(
                    designation: event.designation,
                    location: event.location,
                    tier: event.tier,
                    option: option,
                    alreadyMet: event.objectivesMet,
                    roundTripSeconds: trip,
                    rationale: rationale(event, option, trip)
                )
            }
            .sorted(by: precedes)
    }

    /// The multi-option events waiting on an operator pick.
    public static func pendingChoices(
        events: [LocationEvent],
        chosenOptions: [String: String],
        bills: [String: ResourceCost]
    ) -> [(LocationEvent, [EventPlan.Option])] {
        events
            .filter(\.isActive)
            .compactMap { event in
                guard case .needsChoice(let offered) = EventPlan.resolve(
                    event, chosenOption: chosenOptions[event.designation], bills: bills
                ) else { return nil }
                return (event, offered)
            }
            .sorted { $0.0.designation < $1.0.designation }
    }

    /// met → tier desc → round trip asc → designation asc.
    private static func precedes(_ lhs: EventCandidate, _ rhs: EventCandidate) -> Bool {
        if lhs.alreadyMet != rhs.alreadyMet { return lhs.alreadyMet }
        if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
        if lhs.roundTripSeconds != rhs.roundTripSeconds {
            return lhs.roundTripSeconds < rhs.roundTripSeconds
        }
        return lhs.designation < rhs.designation
    }

    private static func roundTrip(
        from depot: String, to location: String, positions: [String: Position]
    ) -> Double {
        guard let origin = positions[SiteAssay.system(of: depot)],
              let target = positions[SiteAssay.system(of: location)]
        else { return .infinity }
        return 2 * origin.distance(to: target) * secondsPerLy
    }

    private static func rationale(
        _ event: LocationEvent, _ option: EventPlan.Option, _ trip: Double
    ) -> String {
        let bill = option.resourceUnits + option.deviceUnits
        let leg = trip.isFinite ? "\(Int(trip / 60)) min round trip" : "distance unknown"
        return "tier \(event.tier) at \(event.location) — \(bill) units, \(leg)"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter EventRankingTests --event-stream-output-path /tmp/rc-t3.jsonl
```
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/EventRanking.swift \
        app/Modules/DirectiveEngine/Tests/EventRankingTests.swift
git commit -m "feat(brain): rank the location-event backlog"
```

---

### Task 4: Two additive columns

`directives.freighterCode` is the convoy's second lease; `locationEvents.chosenOption` records the operator's pick.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (property, `init`, migration)
- Modify: `app/Modules/GameModels/Sources/LocationEvent.swift` (property, `init`, migration, `merging`)
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift:47-89` (append two manifest entries)
- Test: `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift` (extend the frozen list)

**Interfaces:**
- Consumes: nothing.
- Produces: `Directive.freighterCode: String?`, `Directive.addFreighterCode: SchemaMigration`, `LocationEvent.chosenOption: String?`, `LocationEvent.addChosenOption: SchemaMigration`.

- [ ] **Step 1: Write the failing test**

Append to `app/Modules/DirectiveEngine/Tests/` a new file `EventSchemaTests.swift`:

```swift
import Foundation
import GameModels
import SQLiteData
import Testing
@testable import GameDatabase

@Suite("Event fulfilment schema")
struct EventSchemaTests {
    @Test("the two new columns exist and round-trip")
    func columnsRoundTrip() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 0)
        try await database.write { db in
            try Directive.insert {
                Directive(
                    id: "d1", kind: .eventRun, status: .running, deviceCode: "CARRIER",
                    controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
                    targets: ["X-1-EVT-001"], targetIndex: 0, step: "preflight",
                    stepStartedAt: now, returnToOrigin: true, originDesignation: "HUB",
                    attentionReason: nil, createdAt: now, updatedAt: now,
                    theatreDepot: "HUB-1", freighterCode: "FREIGHT"
                )
            }.execute(db)
            try LocationEvent.insert {
                LocationEvent(
                    designation: "X-1-EVT-001", location: "X-1", status: "active",
                    firstSeenAt: now, updatedAt: now, chosenOption: "booster"
                )
            }.execute(db)
        }
        let (directive, event) = try await database.read { db in
            (try Directive.all.fetchOne(db), try LocationEvent.all.fetchOne(db))
        }
        #expect(directive?.freighterCode == "FREIGHT")
        #expect(event?.chosenOption == "booster")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventSchemaTests --event-stream-output-path /tmp/rc-t4.jsonl
```
Expected: FAIL — `type 'DirectiveKind' has no member 'eventRun'` and `extra argument 'freighterCode'`.

- [ ] **Step 3: Write minimal implementation**

In `Directive.swift`, add the kind case and its title:

```swift
    /// A convoy fulfilling one location event: deliver, commit, plant a beacon.
    case eventRun
```
```swift
        case .eventRun: "Event Run"
```

Add the property beside `claimedRelayCode`:

```swift
    /// The cargo freighter carrying this convoy's resources. A second lease:
    /// the freighter flies itself, so no containment edge holds it.
    public var freighterCode: String?
```

Add `freighterCode: String? = nil` to the memberwise `init` parameter list (after `claimedRelayCode`) and `self.freighterCode = freighterCode` to its body. Add the migration beside `addClaimedRelayCode`:

```swift
    public static let addFreighterCode = SchemaMigration("Add 'freighterCode' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "freighterCode" TEXT
            """
        ).execute(db)
    }
```

In `LocationEvent.swift`, add the property beside `objectivesMet`:

```swift
    /// The criteria option the operator picked for a multi-option event. Nil
    /// until they choose; a name no option carries re-asks rather than misfires.
    public var chosenOption: String?
```

Add `chosenOption: String? = nil` to the `init` and assign it. Add the migration:

```swift
    public static let addChosenOption = SchemaMigration("Add 'chosenOption' to locationEvents") { db in
        try #sql(
            """
            ALTER TABLE "locationEvents" ADD COLUMN "chosenOption" TEXT
            """
        ).execute(db)
    }
```

In `LocationEvent.merging(_:)` (the refresh reconciler), carry `chosenOption` across from the existing row — the server never sends it, so a refresh must not erase it. Find the `merging` function and add:

```swift
        merged.chosenOption = chosenOption
```

Append both migrations to `GameDatabase.manifest`, after `SystemDetail.rebackfillSummaryJSON`:

```swift
        Directive.addFreighterCode,
        LocationEvent.addChosenOption,
```

Extend the frozen identifier list in `SchemaManifestTests` with the two new identifiers, in the same order.

Register the kind in `MissionRegistry.machines` only in Task 11 — leaving it unregistered now means the engine ignores `eventRun` rows, which is the safe interim state.

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter "EventSchemaTests|SchemaManifestTests|GoldenSchemaTests" \
  --event-stream-output-path /tmp/rc-t4.jsonl
```
Expected: `EventSchemaTests` and `SchemaManifestTests` PASS. `GoldenSchemaTests` FAILS on the snapshot — regenerate it deliberately:

```bash
RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --filter GoldenSchemaTests
swift test --filter GoldenSchemaTests --event-stream-output-path /tmp/rc-t4b.jsonl
```
Expected after regeneration: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameModels/Sources/Directive.swift \
        app/Modules/GameModels/Sources/LocationEvent.swift \
        app/Modules/GameDatabase/Sources/GameDatabase.swift \
        app/Modules/GameDatabase/Tests \
        app/Modules/DirectiveEngine/Tests/EventSchemaTests.swift
git commit -m "feat(events): add the eventRun kind, freighterCode and chosenOption"
```

---

### Task 5: `reservedDevices` follows the attach edge

`Brain.reservedDevices` walks `stowedInDeviceCode` in both directions and the controller edges, but never `attachedToDeviceCode`. A courier bolted to a flying carrier is invisible to the sweep, so a second run can commit it.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift:1105-1120` (the `drags` construction)
- Test: `app/Modules/DirectiveEngine/Tests/BrainReservationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Brain.reservedDevices(directives:devices:)` now reserves attached devices transitively, both directions, exactly as it does for stow.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import Testing
@testable import DirectiveEngine

@Suite("Brain device reservation")
struct BrainAttachReservationTests {
    private func device(
        _ code: String, attachedTo: String? = nil, stowedIn: String? = nil
    ) -> Device {
        Device(
            deviceCode: code, deviceType: "surge_carrier", status: "idle", location: "HUB-1",
            stowedInDeviceCode: stowedIn, attachedToDeviceCode: attachedTo,
            features: [], tags: [], updatedAt: .distantPast
        )
    }

    private func directive(on code: String) -> Directive {
        Directive(
            id: "d1", kind: .eventRun, status: .running, deviceCode: code,
            controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
            targets: [], targetIndex: 0, step: "preflight", stepStartedAt: .distantPast,
            returnToOrigin: true, originDesignation: nil, attentionReason: nil,
            createdAt: .distantPast, updatedAt: .distantPast
        )
    }

    @Test("a device attached to a leased carrier is reserved")
    func downward() {
        let devices = [
            "CARRIER": device("CARRIER"),
            "COURIER": device("COURIER", attachedTo: "CARRIER"),
            "BEACON": device("BEACON", attachedTo: "CARRIER"),
            "LOOSE": device("LOOSE"),
        ]
        let reserved = Brain.reservedDevices(
            directives: [directive(on: "CARRIER")], devices: devices
        )
        #expect(reserved == ["CARRIER", "COURIER", "BEACON"])
    }

    @Test("leasing an attached device reserves the hull carrying it")
    func upward() {
        let devices = [
            "CARRIER": device("CARRIER"),
            "COURIER": device("COURIER", attachedTo: "CARRIER"),
        ]
        let reserved = Brain.reservedDevices(
            directives: [directive(on: "COURIER")], devices: devices
        )
        #expect(reserved == ["COURIER", "CARRIER"])
    }

    @Test("an attach edge naming a device the fleet lacks reserves nothing extra")
    func dangling() {
        let devices = ["COURIER": device("COURIER", attachedTo: "GHOST")]
        let reserved = Brain.reservedDevices(
            directives: [directive(on: "COURIER")], devices: devices
        )
        #expect(reserved == ["COURIER"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter BrainAttachReservationTests --event-stream-output-path /tmp/rc-t5.jsonl
```
Expected: FAIL on `downward` (`reserved` is `["CARRIER"]`) and on `upward` (`reserved` is `["COURIER"]`).

- [ ] **Step 3: Write minimal implementation**

In `Brain.reservedDevices`, inside the `for device in devices.values` loop, beside the `stowedInDeviceCode` pair:

```swift
            if let hull = device.attachedToDeviceCode {
                link(hull, device.deviceCode)   // downward: the load on its grid
                link(device.deviceCode, hull)   // upward: the hull carrying it
            }
```

`link` already refuses a target the fleet does not hold, so the dangling case needs no extra guard.

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter "BrainAttachReservationTests|BrainTests" \
  --event-stream-output-path /tmp/rc-t5.jsonl
```
Expected: PASS. The existing `Brain` suites must stay green — widening the reservation set can only make a launch more conservative, never less, so any red here is a fixture asserting an under-reservation and must be read before it is changed.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/Brain.swift \
        app/Modules/DirectiveEngine/Tests/BrainReservationTests.swift
git commit -m "fix(brain): reserve devices across the attach edge"
```

---

### Task 6: `WorldSnapshot` carries the event ledger

A mission cannot see `LocationEvent` rows today, so `EventRun` has nothing to judge `progress.met` against.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift:74-144` (property, `init`, `read`)
- Test: `app/Modules/DirectiveEngine/Tests/WorldSnapshotTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `WorldSnapshot.locationEvents: [String: LocationEvent]` keyed by designation, whole table, plus `WorldSnapshot.event(_ designation: String) -> LocationEvent?` and `WorldSnapshot.replicantHostDevices: Set<String>` (the device codes the replicant roster is hosted in, mirroring `WorldView.replicantHostDevices` — Task 12's courier predicate reads it).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import SQLiteData
import Testing
@testable import DirectiveEngine
@testable import GameDatabase

@Suite("WorldSnapshot events")
struct WorldSnapshotEventTests {
    @Test("the snapshot reads the whole event ledger")
    func readsEvents() async throws {
        let database = try GameDatabase.bootstrap()
        let now = Date(timeIntervalSince1970: 1_000)
        try await database.write { db in
            try LocationEvent.insert {
                LocationEvent(
                    designation: "X-1-EVT-001", location: "X-1", status: "active",
                    firstSeenAt: now, updatedAt: now
                )
            }.execute(db)
            try LocationEvent.insert {
                LocationEvent(
                    designation: "Y-2-EVT-001", location: "Y-2", status: "completed",
                    firstSeenAt: now, updatedAt: now
                )
            }.execute(db)
        }
        let directive = Directive(
            id: "d1", kind: .eventRun, status: .running, deviceCode: "CARRIER",
            controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
            targets: ["X-1-EVT-001"], targetIndex: 0, step: "preflight",
            stepStartedAt: now, returnToOrigin: true, originDesignation: nil,
            attentionReason: nil, createdAt: now, updatedAt: now
        )
        let world = try await WorldSnapshot.read(from: database, now: now, directive: directive)
        #expect(world.locationEvents.count == 2)
        #expect(world.event("X-1-EVT-001")?.location == "X-1")
        #expect(world.event("MISSING") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter WorldSnapshotEventTests --event-stream-output-path /tmp/rc-t6.jsonl
```
Expected: FAIL — `value of type 'WorldSnapshot' has no member 'locationEvents'`.

- [ ] **Step 3: Write minimal implementation**

Add the property after `theatres`:

```swift
    /// The whole location-event ledger by designation, mirroring
    /// `WorldView.locationEvents`. Read whole like `footprints`: it is one small
    /// row per known event, and a convoy must see the row it is committing.
    public let locationEvents: [String: LocationEvent]
```

Add `locationEvents: [String: LocationEvent] = [:],` to the `init` signature (after `theatres`) and assign it. Add the accessor beside `system(_:)`:

```swift
    /// The row for the event `designation` names, or nil when the ledger has none.
    public func event(_ designation: String) -> LocationEvent? { locationEvents[designation] }
```

In `read(from:now:directive:)`, before the `return WorldSnapshot(`:

```swift
            let eventRows = try LocationEvent.all.fetchAll(db)
            let locationEvents = Dictionary(
                eventRows.map { ($0.designation, $0) }, uniquingKeysWith: { _, last in last }
            )
            let replicantHostDevices = Set(
                try Replicant.all.fetchAll(db).compactMap(\.hostedDeviceCode)
            )
```

and pass `locationEvents: locationEvents,` and `replicantHostDevices: replicantHostDevices,` in the initialiser call after `theatres:`. Declare the second property beside the first:

```swift
    /// The devices the replicant roster is hosted in, mirroring
    /// `WorldView.replicantHostDevices`. Hosting is a roster fact, never a
    /// device column — `Device.replicantCode` records ownership instead.
    public let replicantHostDevices: Set<String>
```

Check `Replicant`'s host column name before writing this — `grep -n "hostedDeviceCode\|hosted_device_code" app/Modules/GameModels/Sources/Replicant.swift`. If it is optional, `compactMap` as written; if not, `map`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter "WorldSnapshotEventTests|WorldSnapshotTests" \
  --event-stream-output-path /tmp/rc-t6.jsonl
```
Expected: PASS. Every other suite still compiles because the new parameter is defaulted.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift \
        app/Modules/DirectiveEngine/Tests/WorldSnapshotTests.swift
git commit -m "feat(engine): expose the location-event ledger to missions"
```

---

### Task 7: Two `MissionAction` cases for the event endpoints

Committing an event is not a device command, so `.dispatch` cannot express it. Re-reading one authoritatively is likewise not a device read.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift:17-112` (two cases)
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift` (resolvers, beside `resolveFootprintRefresh`)
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift` (bypass fallbacks, beside the `.refreshFootprint` case)
- Test: `app/Modules/DirectiveEngine/Tests/EventActionTests.swift`

**Interfaces:**
- Consumes: `LocationEventsClient.refresh`, `LocationEventsClient.complete` from `GameServices`.
- Produces:
  - `MissionAction.refreshEvents(nextStep: String, thenStall: DirectiveAttentionReason?)` — re-reads the account ledger, persists, re-asks the machine against the fresh rows.
  - `MissionAction.completeEvent(location: String, designation: String, nextStep: String)` — the empty POST, then a ledger re-read. Best-effort: a rejected commit moves to `nextStep` anyway, where the machine re-judges from the refreshed row.
  - `DirectiveAttentionReason.eventCriteriaUnmet`, `.eventCommitRejected`.

- [ ] **Step 1: Write the failing test**

```swift
import Dependencies
import Foundation
import GameModels
import GameServices
import Testing
@testable import DirectiveEngine

@Suite("Event mission actions")
struct EventActionTests {
    @Test("completeEvent posts once and then re-reads the ledger")
    func commitPostsAndRefreshes() async throws {
        let posted = LockIsolated<[String]>([])
        let refreshed = LockIsolated(0)
        try await withDependencies {
            $0.locationEventsClient = LocationEventsClient(
                refresh: { refreshed.withValue { $0 += 1 }; return 1 },
                complete: { location, designation in
                    posted.withValue { $0.append("\(location)/\(designation)") }
                }
            )
        } operation: {
            @Dependency(\.locationEventsClient) var client
            try await client.complete("X-1", "X-1-EVT-001")
            _ = try await client.refresh()
        }
        #expect(posted.value == ["X-1/X-1-EVT-001"])
        #expect(refreshed.value == 1)
    }

    @Test("the two new reasons classify for the brain")
    func dispositions() {
        #expect(DirectiveAttentionReason.eventCriteriaUnmet.brainDisposition == .escalate)
        #expect(DirectiveAttentionReason.eventCommitRejected.brainDisposition == .retry)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventActionTests --event-stream-output-path /tmp/rc-t7.jsonl
```
Expected: FAIL — `type 'DirectiveAttentionReason' has no member 'eventCriteriaUnmet'`.

- [ ] **Step 3: Write minimal implementation**

Add the two reasons to `DirectiveAttentionReason` with `displayName` and `guidance` entries:

```swift
    /// The convoy delivered its option's devices and resources, but the event's
    /// own progress never reported them met.
    case eventCriteriaUnmet
    /// The server refused the event commit.
    case eventCommitRejected
```
```swift
        case .eventCriteriaUnmet: "Event objectives not met"
        case .eventCommitRejected: "Event commit rejected"
```
```swift
        case .eventCriteriaUnmet:
            "Check the event's requirements against what the convoy delivered, then retry."
        case .eventCommitRejected:
            "The server refused the commit. Retry once a replicant is confirmed on site."
```

Classify both in `Brain.brainDisposition` (find the existing switch mapping reasons to `.retry`/`.escalate`/`.decisionRequest`): `.eventCommitRejected` → `.retry`, `.eventCriteriaUnmet` → `.escalate`.

Add the two `MissionAction` cases:

```swift
    /// Re-read the account's whole event ledger, persist it, then ask the
    /// machine again against the fresh rows. Resolved by the engine.
    case refreshEvents(nextStep: String, thenStall: DirectiveAttentionReason?)
    /// Commit the event with the empty POST, re-read the ledger, then move to
    /// `nextStep` whatever happened — the machine re-judges from the fresh row.
    case completeEvent(location: String, designation: String, nextStep: String)
```

In `DirectiveEngineCore`, add `.events` to the `RefreshKind` enum threaded through `paid`, and a resolver mirroring `resolveFootprintRefresh` exactly — call `locationEventsClient.refresh()`, re-ask the machine, and collapse an unresolved re-ask onto the re-asked action's own reason via the existing `collapse(_:)`. Do not invent a second collapse rule; reuse the one `resolveFootprintRefresh` uses so the four kinds cannot drift.

Add a `completeEvent` resolver beside it that calls `locationEventsClient.complete(location, designation)` inside `withErrorReporting`, then `refresh()`, then returns `.advanceStep(nextStep:)`. A thrown commit is logged at `.notice` and still advances — the machine's next evaluation reads the refreshed row and decides whether to stall `.eventCommitRejected`.

In `DirectiveExecutor.apply`, add both cases as the same "engine already resolved this" bypass fallback the `.refreshFootprint` case uses.

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter EventActionTests --event-stream-output-path /tmp/rc-t7.jsonl
```
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift \
        app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift \
        app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift \
        app/Modules/GameModels/Sources/Directive.swift \
        app/Modules/DirectiveEngine/Tests/EventActionTests.swift
git commit -m "feat(engine): add event refresh and commit mission actions"
```

---

### Task 8: `EventRun` — preflight, printing, loading

The first third of the machine: resolve the convoy, print what is missing, load both hulls.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/EventRun.swift`
- Test: `app/Modules/DirectiveEngine/Tests/EventRunTests.swift`

**Interfaces:**
- Consumes: `EventPlan` (Task 2), `WorldSnapshot.event(_:)` (Task 6), `RelayRun.footprintCensusIsStale`, `RelayRun.printStockIsShort`, `MineFleetPrint.fleetEvidenceIsStale`.
- Produces:
  - `EventRun: MissionStepMachine`, `kind == .eventRun`, `firstStep == Step.preflight`
  - `EventRun.Step` — `preflight`, `printing`, `loading`, `confirmingLoad`, `departing`, `confirmingArrival`, `staging`, `confirmingStage`, `confirmingProgress`, `committing`, `collecting`, `recovering`, `returning`
  - `EventRun.courierDeviceType = "matrix_container"`, `EventRun.carrierDeviceType = "surge_carrier"`, `EventRun.freighterDeviceType = "cargo_freighter"`
  - `EventRun.fleetTag(forTheatre:) -> String`, `EventRun.rootTag = "auto:event"`
  - `EventRun.convoy(of:in:) -> Convoy?` where `Convoy = (carrier: Device, freighter: Device?, courier: Device?)`
  - `EventRun.targetEvent(of:) -> String?` — `directive.targets.first`
  - `EventRun.missingDevices(for:at:in:) -> [String: Int]`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import GameServices
import Testing
import Utils
@testable import DirectiveEngine

@Suite("EventRun — loading")
struct EventRunLoadingTests {
    // Fixtures shared with the later EventRun suites.
    static func device(
        _ code: String, type: String, location: String? = "HUB-1",
        attachedTo: String? = nil, tags: [String] = [], updatedAt: Date = .distantPast
    ) -> Device {
        Device(
            deviceCode: code, deviceType: type, status: "idle", location: location,
            stowedInDeviceCode: nil, attachedToDeviceCode: attachedTo,
            features: [], tags: tags, updatedAt: updatedAt
        )
    }

    static func directive(step: String, now: Date) -> Directive {
        Directive(
            id: "d1", kind: .eventRun, status: .running, deviceCode: "CARRIER",
            controllerCode: nil, roamCentre: nil,
            fleetTag: EventRun.fleetTag(forTheatre: "HUB-1"), sourceRelayCode: nil,
            targets: ["X-1-EVT-001"], targetIndex: 0, step: step,
            stepStartedAt: now, returnToOrigin: true, originDesignation: "HUB",
            attentionReason: nil, createdAt: now, updatedAt: now,
            theatreDepot: "HUB-1", freighterCode: "FREIGHT"
        )
    }

    static func event(resources: [String: Int], devices: [(Int, String)]) -> LocationEvent {
        LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 1, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("default"),
                    "devices": .array(devices.map {
                        .object(["count": .number(Double($0.0)), "device_type": .string($0.1)])
                    }),
                    "resources": .object(resources.mapValues { .number(Double($0)) }),
                ])]),
                "rewards": .object(["xp": .number(500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    static func world(
        devices: [Device], event: LocationEvent, now: Date,
        footprintFresh: Bool = true, stock: Int = 500_000
    ) -> WorldSnapshot {
        WorldSnapshot(
            devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, l in l }),
            openOperations: [:],
            footprints: [
                "HUB-1": LocationFootprint(
                    location: "HUB-1", resources: stock,
                    fetchedAt: footprintFresh ? now : .distantPast
                )
            ],
            theatres: [
                Theatre(depot: "HUB-1", system: "HUB", origin: .derived,
                        readiness: .operational, stock: stock)
            ],
            locationEvents: [event.designation: event],
            now: now
        )
    }

    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("preflight prints the beacon when the location has none")
    func printsBeacon() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.preflight, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.printing))
    }

    @Test("printing enqueues the beacon at the depot printer")
    func enqueuesBeacon() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .print, deviceCode: "PRINTER",
            params: CommandParams(
                deviceType: "ftl_beacon", quantity: 1,
                printTags: [EventRun.fleetTag(forTheatre: "HUB-1")]
            ),
            nextStep: EventRun.Step.printing
        ))
    }

    @Test("a beacon already standing at the event location is not reprinted")
    func skipsExistingBeacon() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory", updatedAt: now),
            Self.device("OLDBEACON", type: "ftl_beacon", location: "X-1"),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.loading))
    }

    @Test("the reserve rail vetoes a print rather than spending")
    func railVetoes() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("PRINTER", type: "autofactory", updatedAt: now),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []),
            now: now, stock: 1
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.printing, now: now), world: world
        )
        #expect(action == .wait)
    }

    @Test("loading attaches the courier first, one attach per round")
    func attachesCourier() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container"),
            Self.device("BEACON", type: "ftl_beacon", tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .attach, deviceCode: "CARRIER",
            params: CommandParams(devices: ["COURIER"]),
            nextStep: EventRun.Step.confirmingLoad
        ))
    }

    @Test("with everything attached, loading fills the freighter and departs")
    func collectsResources() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
            Self.device("COURIER", type: "matrix_container", attachedTo: "CARRIER"),
            Self.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER",
                        tags: [EventRun.fleetTag(forTheatre: "HUB-1")]),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .collect, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["structural": 200]),
            nextStep: EventRun.Step.confirmingLoad
        ))
    }

    @Test("a missing courier idles rather than stalling")
    func noCourierWaits() {
        let devices = [
            Self.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            Self.device("FREIGHT", type: "cargo_freighter"),
        ]
        let world = Self.world(
            devices: devices, event: Self.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: Self.directive(step: EventRun.Step.loading, now: now), world: world
        )
        #expect(action == .refreshFleet(
            tag: EventRun.rootTag, thenStall: .unreachableDevice
        ))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventRunLoadingTests --event-stream-output-path /tmp/rc-t8.jsonl
```
Expected: FAIL — `cannot find 'EventRun' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `EventRun.swift` with the type, the full `Step` vocabulary, the convoy resolver, and the three steps this task covers. The remaining steps route to `.wait` for now and are filled in by Tasks 9–11.

```swift
//
//  EventRun.swift
//  Replicould — DirectiveEngine
//
//  One location event, end to end: print the option's devices and a beacon,
//  load carrier and freighter, deliver, commit, sweep the reward, fly home.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct EventRun: MissionStepMachine {
    public let kind = DirectiveKind.eventRun

    /// The reserve rail, injected as `RelayRun`/`MineFleetPrint` inject it.
    public let reserveFloor: Int?

    public init(reserveFloor: Int? = BrainCeiling.aggregateSpendFloor) {
        self.reserveFloor = reserveFloor
    }

    public enum Step {
        public static let preflight = "preflight"
        public static let printing = "printing"
        public static let loading = "loading"
        public static let confirmingLoad = "confirmingLoad"
        public static let departing = "departing"
        public static let confirmingArrival = "confirmingArrival"
        public static let staging = "staging"
        public static let confirmingStage = "confirmingStage"
        public static let confirmingProgress = "confirmingProgress"
        public static let committing = "committing"
        public static let collecting = "collecting"
        public static let recovering = "recovering"
        public static let returning = "returning"
    }

    public var firstStep: String { Step.preflight }

    public static let carrierDeviceType = "surge_carrier"
    public static let freighterDeviceType = "cargo_freighter"
    public static let courierDeviceType = "matrix_container"
    /// The bare tag every wire-bound query must use.
    public static let rootTag = "auto:event"
    /// The tag the carrier pool wears, shared with `Brain.eventReadiness`.
    public static let carrierTag = "auto:carrier"

    /// Deadlines, all in the shape the sibling runs use.
    public static let printDeadline: TimeInterval = RestockRun.printDeadline
    public static let loadConfirmDeadline: TimeInterval = 5 * 60
    public static let arrivalConfirmDeadline: TimeInterval = 5 * 60
    public static let stageConfirmDeadline: TimeInterval = 5 * 60
    /// Generous: `progress` moves on the server's own schedule after a deposit.
    public static let progressDeadline: TimeInterval = 15 * 60

    /// Local-only, never sent to `GET devices/tags/{tag}`.
    public static func fleetTag(forTheatre depot: String) -> String {
        "\(rootTag):\(depot.lowercased())"
    }

    /// The event this run is working.
    public static func targetEvent(of directive: Directive) -> String? {
        directive.targets.first
    }

    /// The three hulls, resolved off the row rather than re-derived.
    public struct Convoy: Equatable, Sendable {
        public let carrier: Device
        public let freighter: Device?
        public let courier: Device?
    }

    public static func convoy(of directive: Directive, in world: WorldSnapshot) -> Convoy? {
        guard let carrier = world.device(directive.deviceCode) else { return nil }
        let freighter = directive.freighterCode.flatMap { world.device($0) }
        let courier = world.devices.values.first {
            $0.deviceType == courierDeviceType
                && ($0.attachedToDeviceCode == carrier.deviceCode || $0.location == carrier.location)
        }
        return Convoy(carrier: carrier, freighter: freighter, courier: courier)
    }

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let convoy = Self.convoy(of: directive, in: world) else {
            return .stall(.unreachableDevice)
        }
        guard let designation = Self.targetEvent(of: directive),
              let event = world.event(designation)
        else { return .refreshEvents(nextStep: directive.step, thenStall: .unreachableDevice) }

        switch directive.step {
        case Step.printing: return printing(directive, convoy, event, world)
        case Step.loading: return loading(directive, convoy, event, world)
        default: return preflight(directive, convoy, event, world)
        }
    }

    // MARK: - Preflight

    /// Confirm the event is still workable, then start printing.
    private func preflight(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard event.isActive else {
            logger.notice("event run \(directive.id, privacy: .public): \(event.designation, privacy: .public) already closed — recovering")
            return .advanceStep(nextStep: Step.recovering)
        }
        guard world.theatreDepot(for: directive) != nil else {
            if world.theatreWentClaimed(for: directive) { return .wait }
            return .stall(.unreachableDevice)
        }
        return .advanceStep(nextStep: Step.printing)
    }

    // MARK: - Printing

    /// What the option still needs, standing free at `depot` and unclaimed.
    static func missingDevices(
        for option: EventPlan.Option, at depot: String, in world: WorldSnapshot, tag: String
    ) -> [String: Int] {
        var wanted = option.devices
        for device in world.devices.values
        where device.location == depot && device.hasTag(tag) {
            if let outstanding = wanted[device.deviceType] {
                wanted[device.deviceType] = outstanding > 1 ? outstanding - 1 : nil
            }
        }
        return wanted
    }

    /// Whether a beacon already stands at the event's location.
    static func beaconStands(at location: String, in world: WorldSnapshot) -> Bool {
        world.devices.values.contains {
            $0.deviceType == EventPlan.beaconDeviceType && $0.location == location
        }
    }

    private func printing(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let depot = world.theatreDepot(for: directive),
              case .decided(let option) = EventPlan.resolve(
                  event, chosenOption: event.chosenOption, bills: [:]
              )
        else { return .stall(.unreachableDevice) }

        let tag = Self.fleetTag(forTheatre: depot)
        var wanted = Self.missingDevices(for: option, at: depot, in: world, tag: tag)
        if !Self.beaconStands(at: event.location, in: world),
           !world.devices.values.contains(where: {
               $0.deviceType == EventPlan.beaconDeviceType && $0.location == depot && $0.hasTag(tag)
           })
        {
            wanted[EventPlan.beaconDeviceType] = 1
        }
        if wanted.isEmpty { return .advanceStep(nextStep: Step.loading) }

        guard let printer = world.devices.values.first(where: {
            $0.location == depot && $0.deviceType == "autofactory"
        }) else { return .stall(.unreachableDevice) }

        if world.openOperation(for: printer.deviceCode) != nil { return .wait }

        let rail = RelayRun(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.printing, thenStall: nil)
        }
        if rail.printStockIsShort(at: depot, world) { return .wait }
        if MineFleetPrint.fleetEvidenceIsStale(directive, at: depot, in: world) {
            return .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        }

        // Beacon last: the option's devices are the long prints.
        let order = option.devices.keys.sorted() + [EventPlan.beaconDeviceType]
        guard let type = order.first(where: { wanted[$0] != nil }),
              let quantity = wanted[type]
        else { return .wait }

        return .dispatch(
            kind: .print, deviceCode: printer.deviceCode,
            params: CommandParams(deviceType: type, quantity: quantity, printTags: [tag]),
            nextStep: Step.printing
        )
    }

    // MARK: - Loading

    /// Attach the courier, the beacon and the option's devices one per round,
    /// then fill the freighter. `attach` moves one row at a time.
    private func loading(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let depot = world.theatreDepot(for: directive),
              case .decided(let option) = EventPlan.resolve(
                  event, chosenOption: event.chosenOption, bills: [:]
              )
        else { return .stall(.unreachableDevice) }

        guard let courier = convoy.courier else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        guard let freighter = convoy.freighter else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }

        let carrier = convoy.carrier
        let tag = Self.fleetTag(forTheatre: depot)
        var payload = [courier]
        payload += world.devices.values
            .filter {
                $0.hasTag(tag) && $0.location == depot
                    && ($0.deviceType == EventPlan.beaconDeviceType || option.devices[$0.deviceType] != nil)
            }
            .sorted { $0.deviceCode < $1.deviceCode }

        if let next = payload.first(where: { $0.attachedToDeviceCode != carrier.deviceCode }) {
            return .dispatch(
                kind: .attach, deviceCode: carrier.deviceCode,
                params: CommandParams(devices: [next.deviceCode]),
                nextStep: Step.confirmingLoad
            )
        }

        if option.resources.isEmpty { return .advanceStep(nextStep: Step.departing) }
        if (freighter.cargoUsed ?? 0) > 0 { return .advanceStep(nextStep: Step.departing) }
        if world.openOperation(for: freighter.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .collect, deviceCode: freighter.deviceCode,
            params: CommandParams(resources: option.resources),
            nextStep: Step.confirmingLoad
        )
    }

    /// The run never roams.
    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
```

If `Device` has no `cargoUsed` column, read it from the device detail blob the same way sibling code does, or drop that guard and rely on `confirmingLoad` (Task 9) to prove the load landed. Check before writing: `grep -n "cargoUsed\|cargo_used" app/Modules/GameModels/Sources/Device.swift`.

Add `.collect` and `.deposit` to `OperationKind` if they are absent — check with `grep -rn "case collect\|case deposit" app/Modules/GameModels/Sources/`. If absent, add them beside `.attach`/`.detach` and map them in whatever command-verb table `CommandClient` uses.

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter EventRunLoadingTests --event-stream-output-path /tmp/rc-t8.jsonl
```
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/EventRun.swift \
        app/Modules/DirectiveEngine/Tests/EventRunTests.swift
git commit -m "feat(engine): EventRun preflight, printing and loading"
```

---

### Task 9: `EventRun` — departing, arrival, staging

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/EventRun.swift` (four steps + the `nextAction` switch)
- Test: `app/Modules/DirectiveEngine/Tests/EventRunDeliveryTests.swift`

**Interfaces:**
- Consumes: `EventRunLoadingTests` fixtures (import them via the shared helpers on that suite, or lift them into a `EventRunFixtures` enum — do the lift, since three suites now need them).
- Produces: `EventRun` handles `Step.confirmingLoad`, `.departing`, `.confirmingArrival`, `.staging`, `.confirmingStage`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import GameServices
import Testing
@testable import DirectiveEngine

@Suite("EventRun — delivery")
struct EventRunDeliveryTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("departing flies both hulls to the event location")
    func departs() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.departing, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .travel, deviceCode: "CARRIER",
            params: CommandParams(destination: "X-1"),
            nextStep: EventRun.Step.departing
        ))
    }

    @Test("with the carrier away, departing moves the freighter next")
    func freighterFollows() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.departing, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .travel, deviceCode: "FREIGHT",
            params: CommandParams(destination: "X-1"),
            nextStep: EventRun.Step.confirmingArrival
        ))
    }

    @Test("arrival needs rows read since the step began")
    func arrivalNeedsFreshRows() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingArrival, now: now), world: world
        )
        // Rows predate the step, so the machine buys evidence rather than trusting them.
        #expect(action != .advanceStep(nextStep: EventRun.Step.staging))
    }

    @Test("both hulls confirmed on site advances to staging")
    func arrivalConfirmed() {
        let fresh = now.addingTimeInterval(1)
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1", updatedAt: fresh),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1", updatedAt: fresh),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1", updatedAt: fresh),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []),
            now: fresh
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingArrival, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.staging))
    }

    @Test("staging detaches the whole load in one command, courier excluded")
    func stagingDetaches() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", attachedTo: "CARRIER", location: "X-1"),
            EventRunFixtures.device("GRID", type: "defence_grid", attachedTo: "CARRIER", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: [(1, "defence_grid")]), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.staging, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .detach, deviceCode: "CARRIER",
            params: CommandParams(devices: ["BEACON", "GRID"]),
            nextStep: EventRun.Step.confirmingStage
        ))
    }

    @Test("with the load down, staging deposits the freighter's hold")
    func stagingDeposits() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: ["structural": 200], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.staging, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .deposit, deviceCode: "FREIGHT",
            params: CommandParams(resources: ["structural": 200]),
            nextStep: EventRun.Step.confirmingStage
        ))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventRunDeliveryTests --event-stream-output-path /tmp/rc-t9.jsonl
```
Expected: FAIL — `cannot find 'EventRunFixtures' in scope`, then failures on every step routing to `.wait`.

- [ ] **Step 3: Write minimal implementation**

Lift the fixtures out of `EventRunTests.swift` into `app/Modules/DirectiveEngine/Tests/EventRunFixtures.swift` as a `enum EventRunFixtures` with the same `device`/`directive`/`event`/`world` statics, and update `EventRunLoadingTests` to call through it. Keep the helpers `fileprivate`-free but do NOT give any of them default-argument-free overloads that could capture another suite's call sites — the shared-helper trap from the survey fleet-repair build.

Add the five steps to `EventRun`, and route them in `nextAction`:

```swift
        case Step.confirmingLoad: return confirmLoad(directive, convoy, event, world)
        case Step.departing: return departing(directive, convoy, event, world)
        case Step.confirmingArrival: return confirmArrival(directive, convoy, event, world)
        case Step.staging: return staging(directive, convoy, event, world)
        case Step.confirmingStage: return confirmStage(directive, convoy, event, world)
```

```swift
    /// Judge the attach or collect just ordered, looping back for the next.
    /// The dispatch's own confirm-read lands BEFORE the step stamp, so the
    /// loop's round count proves it landed, not row freshness.
    private func confirmLoad(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        if world.openOperation(for: convoy.carrier.deviceCode) != nil { return .wait }
        if let freighter = convoy.freighter, world.openOperation(for: freighter.deviceCode) != nil {
            return .wait
        }
        return .advanceStep(nextStep: Step.loading)
    }

    /// Move the carrier first, then the freighter. Each leg is its own dispatch:
    /// two hulls cannot share one travel command.
    private func departing(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        let destination = event.location
        if convoy.carrier.location != destination {
            if world.openOperation(for: convoy.carrier.deviceCode) != nil { return .wait }
            if let unconfirmed = SalvageRun.travelPositionUnconfirmed(convoy.carrier, world) {
                return unconfirmed
            }
            return .dispatch(
                kind: .travel, deviceCode: convoy.carrier.deviceCode,
                params: CommandParams(destination: destination), nextStep: Step.departing
            )
        }
        guard let freighter = convoy.freighter else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        if freighter.location != destination {
            if world.openOperation(for: freighter.deviceCode) != nil { return .wait }
            if let unconfirmed = SalvageRun.travelPositionUnconfirmed(freighter, world) {
                return unconfirmed
            }
            return .dispatch(
                kind: .travel, deviceCode: freighter.deviceCode,
                params: CommandParams(destination: destination), nextStep: Step.confirmingArrival
            )
        }
        return .advanceStep(nextStep: Step.confirmingArrival)
    }

    /// Both hulls placed at the event, on rows read since the step began.
    private func confirmArrival(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        var rows = [convoy.carrier]
        if let freighter = convoy.freighter { rows.append(freighter) }
        let placed = rows.allSatisfy {
            $0.updatedAt >= directive.stepStartedAt && $0.location == event.location
        }
        if placed { return .advanceStep(nextStep: Step.staging) }
        if rows.contains(where: { world.openOperation(for: $0.deviceCode) != nil }) { return .wait }
        return Self.confirmLadder(
            rows, directive, world,
            deadline: Self.arrivalConfirmDeadline, thenStall: .vesselPositionUnconfirmed
        )
    }

    /// Set the load down and empty the hold. The courier stays attached — it is
    /// the convoy's replicant and comes home with the carrier.
    private func staging(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard case .decided(let option) = EventPlan.resolve(
            event, chosenOption: event.chosenOption, bills: [:]
        ) else { return .stall(.unreachableDevice) }

        let courierCode = convoy.courier?.deviceCode
        let aboard = world.devices.values
            .filter { $0.attachedToDeviceCode == convoy.carrier.deviceCode && $0.deviceCode != courierCode }
            .sorted { $0.deviceCode < $1.deviceCode }
        if !aboard.isEmpty {
            return .dispatch(
                kind: .detach, deviceCode: convoy.carrier.deviceCode,
                params: CommandParams(devices: aboard.map(\.deviceCode)),
                nextStep: Step.confirmingStage
            )
        }

        guard !option.resources.isEmpty else { return .advanceStep(nextStep: Step.confirmingProgress) }
        guard let freighter = convoy.freighter else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        if world.openOperation(for: freighter.deviceCode) != nil { return .wait }
        if (freighter.cargoUsed ?? 0) == 0 { return .advanceStep(nextStep: Step.confirmingProgress) }
        return .dispatch(
            kind: .deposit, deviceCode: freighter.deviceCode,
            params: CommandParams(resources: option.resources),
            nextStep: Step.confirmingStage
        )
    }

    private func confirmStage(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        if world.openOperation(for: convoy.carrier.deviceCode) != nil { return .wait }
        if let freighter = convoy.freighter, world.openOperation(for: freighter.deviceCode) != nil {
            return .wait
        }
        return .advanceStep(nextStep: Step.staging)
    }
```

Add `confirmLadder` to `EventRun` as a `static` copy of `MineRun`'s — or, better, promote `MineRun.confirmLadder` to an internal free function both call. Do the promotion: two copies of a confirm ladder will drift. Put it in `MissionLogBudget.swift` as `MissionConfirm.ladder(...)` and update `MineRun`'s call sites.

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter "EventRun|MineRunTests" --event-stream-output-path /tmp/rc-t9.jsonl
```
Expected: PASS. `MineRunTests` must stay green after the `confirmLadder` promotion.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources app/Modules/DirectiveEngine/Tests
git commit -m "feat(engine): EventRun delivery legs and staging"
```

---

### Task 10: `EventRun` — progress, commit, reward sweep

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/EventRun.swift`
- Test: `app/Modules/DirectiveEngine/Tests/EventRunCommitTests.swift`

**Interfaces:**
- Consumes: `MissionAction.refreshEvents` / `.completeEvent` (Task 7), `WorldSnapshot.footprints`.
- Produces: `EventRun` handles `Step.confirmingProgress`, `.committing`, `.collecting`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import GameServices
import Testing
import Utils
@testable import DirectiveEngine

@Suite("EventRun — commit")
struct EventRunCommitTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func onSite(_ updatedAt: Date) -> [Device] {
        [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1", updatedAt: updatedAt),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1", updatedAt: updatedAt),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1", updatedAt: updatedAt),
        ]
    }

    /// An event whose live progress reports met and a replicant present.
    private func metEvent(met: Bool, replicant: Bool, status: String = "active") -> LocationEvent {
        LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 1, status: status,
            objectivesMet: met,
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("default"), "devices": .array([]),
                    "resources": .object(["structural": .number(200)]),
                ])]),
                "progress": .object([
                    "met": .bool(met), "replicant_present": .bool(replicant),
                    "options": .array([.object([
                        "name": .string("default"), "met": .bool(met), "devices": .array([]),
                        "resources": .array([.object([
                            "resource_type": .string("structural"),
                            "current": .number(met ? 200 : 0), "required": .number(200),
                            "met": .bool(met),
                        ])]),
                    ])]),
                ]),
                "rewards": .object(["xp": .number(500), "resources": .object(["rares": .number(400)])]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }

    @Test("met plus a replicant on site commits")
    func commits() {
        let world = EventRunFixtures.world(
            devices: onSite(now), event: metEvent(met: true, replicant: true), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingProgress, now: now),
            world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.committing))
    }

    @Test("unmet progress buys a fresh ledger read before the deadline")
    func waitsForProgress() {
        let world = EventRunFixtures.world(
            devices: onSite(now), event: metEvent(met: false, replicant: true), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingProgress, now: now),
            world: world
        )
        #expect(action == .refreshEvents(nextStep: EventRun.Step.confirmingProgress, thenStall: nil))
    }

    @Test("unmet past the deadline stalls eventCriteriaUnmet")
    func stallsOnUnmet() {
        let late = now.addingTimeInterval(EventRun.progressDeadline + 1)
        let world = EventRunFixtures.world(
            devices: onSite(late), event: metEvent(met: false, replicant: true), now: late
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingProgress, now: now),
            world: world
        )
        #expect(action == .stall(.eventCriteriaUnmet, detail: "X-1-EVT-001"))
    }

    @Test("an event closed by another path aborts to recovering, no stall")
    func abortsOnAlreadyCompleted() {
        let world = EventRunFixtures.world(
            devices: onSite(now),
            event: metEvent(met: true, replicant: true, status: "completed"), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.confirmingProgress, now: now),
            world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.recovering))
    }

    @Test("committing posts the empty POST")
    func posts() {
        let world = EventRunFixtures.world(
            devices: onSite(now), event: metEvent(met: true, replicant: true), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.committing, now: now),
            world: world
        )
        #expect(action == .completeEvent(
            location: "X-1", designation: "X-1-EVT-001", nextStep: EventRun.Step.collecting
        ))
    }

    @Test("a commit that left the event open stalls eventCommitRejected")
    func commitRejected() {
        let late = now.addingTimeInterval(EventRun.progressDeadline + 1)
        let world = EventRunFixtures.world(
            devices: onSite(late), event: metEvent(met: true, replicant: true), now: late
        )
        var directive = EventRunFixtures.directive(step: EventRun.Step.collecting, now: now)
        directive.targets = ["X-1-EVT-001"]
        let action = EventRun().nextAction(directive: directive, world: world)
        #expect(action == .stall(.eventCommitRejected, detail: "X-1-EVT-001"))
    }

    @Test("collecting sweeps a reward pile into the empty freighter")
    func sweepsReward() {
        var world = EventRunFixtures.world(
            devices: onSite(now),
            event: metEvent(met: true, replicant: true, status: "completed"), now: now
        )
        world = WorldSnapshot(
            devices: world.devices, openOperations: [:],
            footprints: world.footprints.merging([
                "X-1": LocationFootprint(location: "X-1", resources: 400, fetchedAt: now)
            ]) { _, new in new },
            theatres: world.theatres, locationEvents: world.locationEvents, now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.collecting, now: now),
            world: world
        )
        #expect(action == .dispatch(
            kind: .collect, deviceCode: "FREIGHT",
            params: CommandParams(resources: nil), nextStep: EventRun.Step.recovering
        ))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventRunCommitTests --event-stream-output-path /tmp/rc-t10.jsonl
```
Expected: FAIL — every case routes to `preflight`'s `.advanceStep(nextStep: "printing")`.

- [ ] **Step 3: Write minimal implementation**

Route the three steps in `nextAction` and add:

```swift
    /// The event's own live progress is the authority: met, and a replicant on
    /// site. A row read before the deposit landed proves nothing, so a stale
    /// ledger buys one read per cycle until the deadline.
    private func confirmProgress(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard event.isActive else { return .advanceStep(nextStep: Step.recovering) }
        let detail = LocationEventDetail(event.detail)
        if detail?.met == true, detail?.replicantPresent == true {
            return .advanceStep(nextStep: Step.committing)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.progressDeadline {
            return .stall(.eventCriteriaUnmet, detail: event.designation)
        }
        return .refreshEvents(nextStep: Step.confirmingProgress, thenStall: nil)
    }

    /// The commit: an empty POST, then the ledger re-read the engine folds in.
    private func committing(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard event.isActive else { return .advanceStep(nextStep: Step.collecting) }
        return .completeEvent(
            location: event.location, designation: event.designation, nextStep: Step.collecting
        )
    }

    /// Take the reward pile home. The freighter is on site with a hold it just
    /// emptied, so a nil resource map lifts whatever is there.
    private func collecting(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        if event.isActive {
            if world.now.timeIntervalSince(directive.stepStartedAt) > Self.progressDeadline {
                return .stall(.eventCommitRejected, detail: event.designation)
            }
            return .refreshEvents(nextStep: Step.collecting, thenStall: nil)
        }
        guard let freighter = convoy.freighter else { return .advanceStep(nextStep: Step.recovering) }
        if world.openOperation(for: freighter.deviceCode) != nil { return .wait }
        guard let pile = world.footprints[event.location], pile.resources > 0 else {
            return .advanceStep(nextStep: Step.recovering)
        }
        return .dispatch(
            kind: .collect, deviceCode: freighter.deviceCode,
            params: CommandParams(resources: nil), nextStep: Step.recovering
        )
    }
```

Note the deliberate asymmetry: `collecting` re-enters itself while the event is still `active`, because the engine's `completeEvent` resolver advances unconditionally and this step is where a refused commit is noticed.

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter EventRunCommitTests --event-stream-output-path /tmp/rc-t10.jsonl
```
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/EventRun.swift \
        app/Modules/DirectiveEngine/Tests/EventRunCommitTests.swift
git commit -m "feat(engine): EventRun progress gate, commit and reward sweep"
```

---

### Task 11: `EventRun` — recovery, return, registration

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/EventRun.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/MissionRegistry.swift:17-20`
- Test: `app/Modules/DirectiveEngine/Tests/EventRunReturnTests.swift`

**Interfaces:**
- Consumes: `WorldSnapshot.theatreDepot(for:)`, `world.theatreWentClaimed(for:)`.
- Produces: `EventRun` handles `Step.recovering`, `.returning`, and returns `.done`. `MissionRegistry.machines` includes `EventRun()`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import GameServices
import Testing
@testable import DirectiveEngine

@Suite("EventRun — recovery and return")
struct EventRunReturnTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("recovering re-attaches a detached courier before departing")
    func reattachesCourier() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.recovering, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .attach, deviceCode: "CARRIER",
            params: CommandParams(devices: ["COURIER"]),
            nextStep: EventRun.Step.recovering
        ))
    }

    @Test("a beacon left on site is never recovered")
    func leavesBeacon() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
            EventRunFixtures.device("BEACON", type: "ftl_beacon", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.recovering, now: now), world: world
        )
        #expect(action == .advanceStep(nextStep: EventRun.Step.returning))
    }

    @Test("returning flies both hulls to the theatre depot")
    func returnsHome() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", location: "X-1"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter", location: "X-1"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER", location: "X-1"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.returning, now: now), world: world
        )
        #expect(action == .dispatch(
            kind: .travel, deviceCode: "CARRIER",
            params: CommandParams(destination: "HUB-1"),
            nextStep: EventRun.Step.returning
        ))
    }

    @Test("both hulls home finishes the run")
    func finishes() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier"),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("COURIER", type: "matrix_container", attachedTo: "CARRIER"),
        ]
        let world = EventRunFixtures.world(
            devices: devices,
            event: EventRunFixtures.event(resources: [:], devices: []), now: now
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: EventRun.Step.returning, now: now), world: world
        )
        #expect(action == .done)
    }

    @Test("EventRun is registered")
    func registered() {
        #expect(MissionRegistry.machine(for: .eventRun) != nil)
        #expect(MissionRegistry.firstStep(for: .eventRun) == EventRun.Step.preflight)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventRunReturnTests --event-stream-output-path /tmp/rc-t11.jsonl
```
Expected: FAIL on all five.

- [ ] **Step 3: Write minimal implementation**

Route both steps and add:

```swift
    /// Take the courier back aboard. Never depart while it stands loose — a
    /// convoy that leaves its replicant behind loses the capability, not a hull.
    private func recovering(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let courier = convoy.courier else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        if courier.attachedToDeviceCode == convoy.carrier.deviceCode {
            return .advanceStep(nextStep: Step.returning)
        }
        if world.openOperation(for: convoy.carrier.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .attach, deviceCode: convoy.carrier.deviceCode,
            params: CommandParams(devices: [courier.deviceCode]),
            nextStep: Step.recovering
        )
    }

    /// Both hulls to the depot, resolved through the row's own theatre.
    private func returning(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let depot = world.theatreDepot(for: directive) else {
            if world.theatreWentClaimed(for: directive) { return .wait }
            logger.notice("event run \(directive.id, privacy: .public): no depot to return to — leaving the convoy where it stands")
            return .done
        }
        for hull in [convoy.carrier, convoy.freighter].compactMap({ $0 })
        where hull.location != depot {
            if world.openOperation(for: hull.deviceCode) != nil { return .wait }
            if let unconfirmed = SalvageRun.travelPositionUnconfirmed(hull, world) { return unconfirmed }
            return .dispatch(
                kind: .travel, deviceCode: hull.deviceCode,
                params: CommandParams(destination: depot), nextStep: Step.returning
            )
        }
        return .done
    }
```

Register the machine:

```swift
        SurveyRun(), SalvageRun(), HaulRun(), RelayRun(), RestockRun(), MineFleetPrint(),
        MineRun(), EventRun(),
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter "EventRun|MissionRegistry" --event-stream-output-path /tmp/rc-t11.jsonl
```
Expected: PASS across all four `EventRun` suites.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources app/Modules/DirectiveEngine/Tests
git commit -m "feat(engine): EventRun courier recovery, return leg, registration"
```

---

### Task 12: The courier bootstrap

An operator-invoked print that stands a `matrix_container` up and replicates a new replicant into the account's spare `empty_replicant_matrix`.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/EventCourierPrint.swift`
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (add `.eventCourierPrint` kind + title)
- Modify: `app/Modules/DirectiveEngine/Sources/MissionRegistry.swift`
- Test: `app/Modules/DirectiveEngine/Tests/EventCourierPrintTests.swift`

**Interfaces:**
- Consumes: `RelayRun.printStockIsShort`, `MineFleetPrint.fleetEvidenceIsStale`.
- Produces:
  - `EventCourierPrint: MissionStepMachine`, `kind == .eventCourierPrint`
  - `EventCourierPrint.Step` — `printing`, `awaitingClone`, `replicating`, `stowing`
  - `EventCourierPrint.courierStands(at:in:) -> Bool` — reads `world.replicantHostDevices` — the readiness predicate `Brain` reads
  - `EventCourierPrint.replicationSource(in:) -> Device?`

**Two corrections to make before writing this — both cost a rewrite if found later.**

`Device.replicantCode` is a **non-optional `String` recording which replicant owns the device**, not which one it hosts. The account's spare matrix carries an owner code like every other row, so `replicantCode == nil` and `replicantCode.isEmpty` are both wrong tests for "can still replicate". The predicate that actually works is the device's own command list: a matrix that has been replicated into loses the `matrix` feature, and with it the verb. So:

```swift
$0.features.contains("matrix") && $0.availableCommands.contains("replicate")
```

Hosting is likewise not a device column — it lives on the replicant roster (`Replicant.hostedDeviceCode`). `WorldView` already derives `replicantHostDevices: Set<String>` from it, and Task 6 puts the same set on `WorldSnapshot`. `courierStands` takes that set rather than inspecting rows.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import GameServices
import Testing
@testable import DirectiveEngine

@Suite("EventCourierPrint")
struct EventCourierPrintTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func directive(step: String) -> Directive {
        Directive(
            id: "c1", kind: .eventCourierPrint, status: .running, deviceCode: "PRINTER",
            controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
            targets: [], targetIndex: 0, step: step, stepStartedAt: now,
            returnToOrigin: false, originDesignation: nil, attentionReason: nil,
            createdAt: now, updatedAt: now, theatreDepot: "HUB-1"
        )
    }

    private func world(_ devices: [Device], hosts: Set<String> = []) -> WorldSnapshot {
        WorldSnapshot(
            devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, l in l }),
            openOperations: [:],
            footprints: ["HUB-1": LocationFootprint(location: "HUB-1", resources: 500_000, fetchedAt: now)],
            theatres: [Theatre(depot: "HUB-1", system: "HUB", origin: .derived,
                               readiness: .operational, stock: 500_000)],
            replicantHostDevices: hosts,
            now: now
        )
    }

    @Test("with no container at the depot, it prints one")
    func printsContainer() {
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.printing),
            world: world([EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now)])
        )
        #expect(action == .dispatch(
            kind: .print, deviceCode: "PRINTER",
            params: CommandParams(
                deviceType: "matrix_container", quantity: 1, printTags: [EventRun.rootTag]
            ),
            nextStep: EventCourierPrint.Step.awaitingClone
        ))
    }

    @Test("with a container standing, it replicates into the spare matrix")
    func replicates() {
        var matrix = EventRunFixtures.device("MATRIX", type: "empty_replicant_matrix", location: nil)
        matrix.features = ["stow", "matrix"]
        let devices = [
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
            EventRunFixtures.device("BOX", type: "matrix_container", tags: [EventRun.rootTag], updatedAt: now),
            matrix,
        ]
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating), world: world(devices)
        )
        #expect(action == .dispatch(
            kind: .replicate, deviceCode: "MATRIX",
            params: CommandParams(), nextStep: EventCourierPrint.Step.stowing
        ))
    }

    @Test("a hosted courier finishes the run")
    func finishes() {
        var matrix = EventRunFixtures.device("MATRIX", type: "replicant_matrix", location: nil)
        matrix.features = ["stow", "matrix"]
        matrix.stowedInDeviceCode = "BOX"
        let devices = [
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
            EventRunFixtures.device("BOX", type: "matrix_container", tags: [EventRun.rootTag], updatedAt: now),
            matrix,
        ]
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.stowing),
            world: world(devices, hosts: ["BOX"])
        )
        #expect(action == .done)
        #expect(EventCourierPrint.courierStands(at: "HUB-1", in: world(devices, hosts: ["BOX"])))
    }

    @Test("no spare matrix stalls rather than printing a 14,400s one silently")
    func noSpareMatrix() {
        let devices = [
            EventRunFixtures.device("PRINTER", type: "autofactory", updatedAt: now),
            EventRunFixtures.device("BOX", type: "matrix_container", tags: [EventRun.rootTag], updatedAt: now),
        ]
        let action = EventCourierPrint().nextAction(
            directive: directive(step: EventCourierPrint.Step.replicating), world: world(devices)
        )
        #expect(action == .stall(.unreachableDevice, detail: "no empty replicant matrix at HUB-1"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventCourierPrintTests --event-stream-output-path /tmp/rc-t12.jsonl
```
Expected: FAIL — `cannot find 'EventCourierPrint' in scope`.

- [ ] **Step 3: Write minimal implementation**

Add `case eventCourierPrint` and its title `"Event Courier Print"` to `DirectiveKind`. Add `.replicate` to `OperationKind` if absent (check first: `grep -rn "case replicate" app/Modules/GameModels/Sources/`). Create the machine:

```swift
//
//  EventCourierPrint.swift
//  Replicould — DirectiveEngine
//
//  Stands up the event convoy's replicant courier: print a matrix container,
//  replicate into the account's spare matrix, stow the matrix aboard.
//

import Foundation
import GameModels
import GameServices
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct EventCourierPrint: MissionStepMachine {
    public let kind = DirectiveKind.eventCourierPrint
    public let reserveFloor: Int?

    public init(reserveFloor: Int? = BrainCeiling.aggregateSpendFloor) {
        self.reserveFloor = reserveFloor
    }

    public enum Step {
        public static let printing = "printing"
        public static let awaitingClone = "awaitingClone"
        public static let replicating = "replicating"
        public static let stowing = "stowing"
    }

    public var firstStep: String { Step.printing }

    /// A courier is a container at `depot` that hosts a replicant.
    public static func courierStands(at depot: String, in world: WorldSnapshot) -> Bool {
        world.devices.values.contains {
            $0.deviceType == EventRun.courierDeviceType && $0.location == depot
                && world.replicantHostDevices.contains($0.deviceCode)
        }
    }

    /// The one device that may still replicate. A matrix loses the `matrix`
    /// feature once used, and the verb with it, so the command list is the test.
    public static func replicationSource(in world: WorldSnapshot) -> Device? {
        world.devices.values
            .filter { $0.features.contains("matrix") && $0.availableCommands.contains("replicate") }
            .sorted { $0.deviceCode < $1.deviceCode }
            .first
    }

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let depot = world.theatreDepot(for: directive) else { return .stall(.unreachableDevice) }
        if Self.courierStands(at: depot, in: world) { return .done }

        switch directive.step {
        case Step.awaitingClone: return awaitingClone(directive, depot, world)
        case Step.replicating: return replicating(directive, depot, world)
        case Step.stowing: return stowing(directive, depot, world)
        default: return printing(directive, depot, world)
        }
    }

    private func container(at depot: String, in world: WorldSnapshot) -> Device? {
        world.devices.values.first {
            $0.deviceType == EventRun.courierDeviceType && $0.location == depot
        }
    }

    private func printing(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        if container(at: depot, in: world) != nil {
            return .advanceStep(nextStep: Step.replicating)
        }
        guard let printer = world.device(directive.deviceCode) else { return .stall(.unreachableDevice) }
        if world.openOperation(for: printer.deviceCode) != nil { return .wait }
        let rail = RelayRun(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.printing, thenStall: nil)
        }
        if rail.printStockIsShort(at: depot, world) { return .wait }
        if MineFleetPrint.fleetEvidenceIsStale(directive, at: depot, in: world) {
            return .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        }
        return .dispatch(
            kind: .print, deviceCode: printer.deviceCode,
            params: CommandParams(
                deviceType: EventRun.courierDeviceType, quantity: 1, printTags: [EventRun.rootTag]
            ),
            nextStep: Step.awaitingClone
        )
    }

    private func awaitingClone(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        if container(at: depot, in: world) != nil { return .advanceStep(nextStep: Step.replicating) }
        if world.openOperation(for: directive.deviceCode) != nil { return .wait }
        if world.now.timeIntervalSince(directive.stepStartedAt) <= RestockRun.printDeadline {
            return .wait
        }
        return .advanceStep(nextStep: Step.printing)
    }

    private func replicating(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        guard container(at: depot, in: world) != nil else {
            return .advanceStep(nextStep: Step.printing)
        }
        guard let source = Self.replicationSource(in: world) else {
            return .stall(.unreachableDevice, detail: "no empty replicant matrix at \(depot)")
        }
        if world.openOperation(for: source.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .replicate, deviceCode: source.deviceCode,
            params: CommandParams(), nextStep: Step.stowing
        )
    }

    private func stowing(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let box = container(at: depot, in: world) else {
            return .advanceStep(nextStep: Step.printing)
        }
        let hosted = world.devices.values.first {
            world.replicantHostDevices.contains($0.deviceCode)
                && $0.stowedInDeviceCode != box.deviceCode
        }
        guard let matrix = hosted else { return .wait }
        if world.openOperation(for: matrix.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .stow, deviceCode: matrix.deviceCode,
            params: CommandParams(target: box.deviceCode), nextStep: Step.stowing
        )
    }

    public func plan(_ context: RoamContext) -> RoamPlan { .exhausted }
}
```

Register it in `MissionRegistry.machines`. Hosting comes from `world.replicantHostDevices` (Task 6), never from a device column — see this task's type note.

Confirm the `stow` command's target parameter name against `CommandClient` before relying on `CommandParams(target:)` — `target` is documented as a mine site. If `stow` uses a different key, add a dedicated field rather than overloading `target`.

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter EventCourierPrintTests --event-stream-output-path /tmp/rc-t12.jsonl
```
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources app/Modules/GameModels/Sources/Directive.swift \
        app/Modules/DirectiveEngine/Tests/EventCourierPrintTests.swift
git commit -m "feat(brain): print and replicate the event convoy's courier"
```

---

### Task 13: `Brain.eventReadiness` and `ensureEvent`

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift` (readiness enum, `ensureEvent`, the tick's call list)
- Test: `app/Modules/DirectiveEngine/Tests/BrainEventTests.swift`

**Interfaces:**
- Consumes: `EventRanking.rank` (Task 3), `EventCourierPrint.courierStands` (Task 12), `Brain.reservedDevices` (Task 5).
- Produces:
  - `Brain.EventReadiness` — `.idle(String)` / `.launch(carrier: String, freighter: String, candidate: EventCandidate)`
  - `Brain.eventReadiness(view:directives:theatre:) -> EventReadiness`
  - `Brain.ensureEvent(snapshot:database:)` called from the tick beside `ensureMine`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Brain event goal")
struct BrainEventTests {
    private let theatre = Theatre(
        depot: "HUB-1", system: "HUB", origin: .derived, readiness: .operational, stock: 500_000
    )

    private func view(devices: [Device], events: [LocationEvent], hosts: Set<String> = ["BOX"]) -> WorldView {
        WorldView(
            devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, l in l }),
            starPositions: ["HUB": Position(x: 0, y: 0, z: 0), "X": Position(x: 1, y: 0, z: 0)],
            meshSystems: ["HUB", "X"],
            salvageUnits: [:],
            eventSystems: Set(events.filter(\.isActive).map { SiteAssay.system(of: $0.location) }),
            theatres: [theatre],
            replicantHostDevices: hosts,
            locationEvents: events,
            blueprintBills: [:],
            now: .distantPast
        )
    }

    @Test("no courier is idle, never a stall")
    func noCourierIsIdle() {
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
        ]
        let readiness = Brain.eventReadiness(
            view: view(devices: devices, events: [EventRunFixtures.event(resources: ["structural": 200], devices: [])]),
            directives: [], theatre: theatre
        )
        guard case .idle(let reason) = readiness else { Issue.record("expected .idle"); return }
        #expect(reason.contains("courier"))
    }

    @Test("a staged convoy and a ranked event launches")
    func launches() {
        var matrix = EventRunFixtures.device("MATRIX", type: "replicant_matrix", location: nil)
        matrix.features = ["stow", "matrix"]
        matrix.stowedInDeviceCode = "BOX"
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("BOX", type: "matrix_container"),
            matrix,
        ]
        let readiness = Brain.eventReadiness(
            view: view(devices: devices, events: [EventRunFixtures.event(resources: ["structural": 200], devices: [])]),
            directives: [], theatre: theatre
        )
        guard case .launch(let carrier, let freighter, let candidate) = readiness else {
            Issue.record("expected .launch"); return
        }
        #expect(carrier == "CARRIER")
        #expect(freighter == "FREIGHT")
        #expect(candidate.designation == "X-1-EVT-001")
    }

    @Test("an event a live run already targets is not re-launched")
    func excludesLiveTarget() {
        var matrix = EventRunFixtures.device("MATRIX", type: "replicant_matrix", location: nil)
        matrix.features = ["stow", "matrix"]
        matrix.stowedInDeviceCode = "BOX"
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("BOX", type: "matrix_container"),
            matrix,
        ]
        let live = EventRunFixtures.directive(step: EventRun.Step.departing, now: .distantPast)
        let readiness = Brain.eventReadiness(
            view: view(devices: devices, events: [EventRunFixtures.event(resources: ["structural": 200], devices: [])]),
            directives: [live], theatre: theatre
        )
        guard case .idle = readiness else { Issue.record("expected .idle"); return }
    }

    @Test("a carrier another directive holds is not spent")
    func respectsReservation() {
        var matrix = EventRunFixtures.device("MATRIX", type: "replicant_matrix", location: nil)
        matrix.features = ["stow", "matrix"]
        matrix.stowedInDeviceCode = "BOX"
        let devices = [
            EventRunFixtures.device("CARRIER", type: "surge_carrier", tags: ["auto:carrier"]),
            EventRunFixtures.device("FREIGHT", type: "cargo_freighter"),
            EventRunFixtures.device("BOX", type: "matrix_container"),
            matrix,
        ]
        var holder = EventRunFixtures.directive(step: "x", now: .distantPast)
        holder.kind = .relayRun
        holder.targets = []
        let readiness = Brain.eventReadiness(
            view: view(devices: devices, events: [EventRunFixtures.event(resources: ["structural": 200], devices: [])]),
            directives: [holder], theatre: theatre
        )
        guard case .idle = readiness else { Issue.record("expected .idle"); return }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter BrainEventTests --event-stream-output-path /tmp/rc-t13.jsonl
```
Expected: FAIL — `type 'Brain' has no member 'eventReadiness'`.

- [ ] **Step 3: Write minimal implementation**

Add beside `MineReadiness`:

```swift
    /// Whether this theatre can start an event convoy. No stall case: a missing
    /// courier or an empty backlog is idle, so this can never escalate.
    enum EventReadiness: Equatable, Sendable {
        case idle(String)
        case launch(carrier: String, freighter: String, candidate: EventCandidate)
    }

    static func eventReadiness(
        view: WorldView, directives: [Directive], theatre: Theatre
    ) -> EventReadiness {
        let snapshot = WorldSnapshot(
            devices: view.devices, openOperations: [:],
            theatres: view.theatres,
            replicantHostDevices: view.replicantHostDevices,
            now: .distantPast
        )
        guard EventCourierPrint.courierStands(at: theatre.depot, in: snapshot) else {
            return .idle("no event courier at \(theatre.depot)")
        }

        let working = Set(directives
            .filter { $0.kind == .eventRun && owningStatuses.contains($0.status) }
            .compactMap { EventRun.targetEvent(of: $0) })
        let chosen = view.locationEvents.reduce(into: [String: String]()) { picks, event in
            picks[event.designation] = event.chosenOption
        }
        let ranked = EventRanking.rank(
            events: view.locationEvents, chosenOptions: chosen,
            bills: view.blueprintBills, positions: view.starPositions,
            depot: theatre.depot, excluding: working
        )
        guard let candidate = ranked.first else { return .idle("no event worth working") }

        let reserved = reservedDevices(directives: directives, devices: view.devices)
        let free = { (type: String, tag: String?) -> Device? in
            view.devices.values
                .filter {
                    $0.deviceType == type && $0.location == theatre.depot
                        && !reserved.contains($0.deviceCode)
                        && (tag.map { tag in $0.hasTag(tag) } ?? true)
                }
                .sorted { $0.deviceCode < $1.deviceCode }
                .first
        }
        guard let carrier = free(EventRun.carrierDeviceType, EventRun.carrierTag) else {
            return .idle("no free surge carrier at \(theatre.depot)")
        }
        guard let freighter = free(EventRun.freighterDeviceType, nil) else {
            return .idle("no free cargo freighter at \(theatre.depot)")
        }
        return .launch(
            carrier: carrier.deviceCode, freighter: freighter.deviceCode, candidate: candidate
        )
    }
```

Add `ensureEvent` in `ensureMine`'s shape, stamping both leases:

```swift
    /// Keep at most one event convoy running per operational theatre.
    private func ensureEvent(snapshot: Snapshot, database: any DatabaseWriter) async {
        @Dependency(\.uuid) var uuid
        for theatre in snapshot.view.theatres.filter(\.isOperational) {
            guard case let .launch(carrier, freighter, candidate) = Self.eventReadiness(
                view: snapshot.view, directives: snapshot.directives, theatre: theatre
            ) else { continue }
            await ensureOne(.eventRun, theatre: theatre, snapshot: snapshot, database: database) {
                Directive(
                    id: uuid().uuidString,
                    kind: .eventRun,
                    status: .running,
                    deviceCode: carrier,
                    controllerCode: nil,
                    roamCentre: nil,
                    fleetTag: EventRun.fleetTag(forTheatre: theatre.depot),
                    sourceRelayCode: nil,
                    targets: [candidate.designation], targetIndex: 0,
                    step: EventRun().firstStep,
                    stepStartedAt: now,
                    returnToOrigin: true,
                    originDesignation: theatre.system,
                    attentionReason: nil,
                    createdAt: now, updatedAt: now,
                    theatreDepot: theatre.depot,
                    freighterCode: freighter
                )
            }
        }
    }
```

`ensureOne` guards only `directive.deviceCode` against the reservation set. Extend its in-transaction check to also refuse a directive whose `freighterCode` is reserved — one extra guard clause in the same `write` block:

```swift
                if let freighter = directive.freighterCode, reserved.contains(freighter) {
                    logger.notice(
                        """
                        \(kind.rawValue, privacy: .public) declined: \
                        \(freighter, privacy: .public) is already committed
                        """
                    )
                    return
                }
```

Call `ensureEvent` from the tick, after `ensureMineFerries`. Add `.eventRun` to `brainManagedStall`'s kind set so the retry-classified reasons get the bounded auto-retry.

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter "BrainEventTests|BrainTests" --event-stream-output-path /tmp/rc-t13.jsonl
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/Brain.swift \
        app/Modules/DirectiveEngine/Tests/BrainEventTests.swift
git commit -m "feat(brain): rank and launch location-event convoys"
```

---

### Task 14: Surface the pending choices

The ~6 multi-option events need an operator pick, shown in the brain's why-view and written back to `locationEvents.chosenOption`.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/BrainReport.swift` (a `pendingEventChoices` section)
- Modify: `app/Modules/LocationEventsFeature/Sources/LocationEventsFeature.swift` (a `chooseOption` action)
- Create: `app/Modules/LocationEventsFeature/Sources/EventOptionPicker.swift`
- Test: `app/Modules/DirectiveEngine/Tests/BrainReportEventTests.swift`

**Interfaces:**
- Consumes: `EventRanking.pendingChoices` (Task 3), `LocationEvent.chosenOption` (Task 4).
- Produces:
  - `BrainEventChoice` — `{ designation: String, location: String, tier: Int, options: [BrainEventChoice.Option] }` where `Option` is `{ name, deviceUnits, resourceUnits, exceedsOneFreighterLoad, missingDevices: [String] }`
  - `BrainReport.pendingEventChoices: [BrainEventChoice]`
  - `LocationEventsFeature.Action.chooseOption(designation: String, name: String)`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import GameModels
import Testing
import Utils
@testable import DirectiveEngine

@Suite("Brain report — event choices")
struct BrainReportEventTests {
    @Test("a multi-option event surfaces with both options priced")
    func surfacesChoice() {
        let event = LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 2, status: "active",
            detail: .object([
                "criteria": .array([
                    .object([
                        "name": .string("satellite"),
                        "devices": .array([.object([
                            "count": .number(2), "device_type": .string("comm_satellite"),
                        ])]),
                        "resources": .object(["conductive": .number(150)]),
                    ]),
                    .object([
                        "name": .string("booster"),
                        "devices": .array([.object([
                            "count": .number(1), "device_type": .string("signal_booster"),
                        ])]),
                        "resources": .object(["conductive": .number(150)]),
                    ]),
                ]),
                "rewards": .object(["xp": .number(1500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        let choices = BrainReport.eventChoices(
            events: [event], bills: ["comm_satellite": ResourceCost(conductive: 350), "signal_booster": ResourceCost(conductive: 400)],
            devices: [:]
        )
        #expect(choices.count == 1)
        #expect(choices[0].options.map(\.name) == ["satellite", "booster"])
        #expect(choices[0].options[0].deviceUnits == 700)
        #expect(choices[0].options[1].deviceUnits == 400)
        #expect(choices[0].options.allSatisfy { $0.resourceUnits == 150 })
        #expect(choices[0].options.allSatisfy { !$0.exceedsOneFreighterLoad })
    }

    @Test("an event whose option is already picked is no longer offered")
    func decidedEventDropsOut() {
        var event = LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 2, status: "active",
            detail: .object([
                "criteria": .array([
                    .object(["name": .string("a"), "devices": .array([]), "resources": .object([:])]),
                    .object(["name": .string("b"), "devices": .array([]), "resources": .object([:])]),
                ]),
                "rewards": .object(["xp": .number(1500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        #expect(BrainReport.eventChoices(events: [event], bills: [:], devices: [:]).count == 1)
        event.chosenOption = "b"
        #expect(BrainReport.eventChoices(events: [event], bills: [:], devices: [:]).isEmpty)
    }

    @Test("an option we already hold the devices for reports nothing missing")
    func reportsHeldDevices() {
        let event = LocationEvent(
            designation: "X-1-EVT-001", location: "X-1", tier: 2, status: "active",
            detail: .object([
                "criteria": .array([
                    .object([
                        "name": .string("a"),
                        "devices": .array([.object([
                            "count": .number(1), "device_type": .string("signal_booster"),
                        ])]),
                        "resources": .object([:]),
                    ]),
                    .object([
                        "name": .string("b"),
                        "devices": .array([.object([
                            "count": .number(1), "device_type": .string("comm_satellite"),
                        ])]),
                        "resources": .object([:]),
                    ]),
                ]),
                "rewards": .object(["xp": .number(1500)]),
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        let held = EventRunFixtures.device("BOOST", type: "signal_booster")
        let choices = BrainReport.eventChoices(
            events: [event], bills: ["comm_satellite": ResourceCost(conductive: 350), "signal_booster": ResourceCost(conductive: 400)],
            devices: ["BOOST": held]
        )
        #expect(choices[0].options[0].missingDevices.isEmpty)
        #expect(choices[0].options[1].missingDevices == ["comm_satellite"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter BrainReportEventTests --event-stream-output-path /tmp/rc-t14.jsonl
```
Expected: FAIL — `type 'BrainReport' has no member 'eventChoices'`.

- [ ] **Step 3: Write minimal implementation**

Add to `BrainReport.swift`:

```swift
/// A multi-option event waiting on the operator's pick, with each option priced
/// against what the fleet already holds.
public struct BrainEventChoice: Equatable, Sendable, Identifiable {
    public struct Option: Equatable, Sendable, Identifiable {
        public let name: String
        public let deviceUnits: Int
        public let resourceUnits: Int
        public let exceedsOneFreighterLoad: Bool
        /// Device types this option needs that no free row supplies.
        public let missingDevices: [String]
        public var id: String { name }
    }

    public let designation: String
    public let location: String
    public let tier: Int
    public let options: [Option]
    public var id: String { designation }
}
```

```swift
    /// The pending event choices, best-priced first within each event.
    public static func eventChoices(
        events: [LocationEvent], bills: [String: ResourceCost], devices: [String: Device]
    ) -> [BrainEventChoice] {
        let held = devices.values.reduce(into: [String: Int]()) { counts, device in
            counts[device.deviceType, default: 0] += 1
        }
        // The picks come off the events, exactly as `Brain.eventReadiness`
        // reads them — an empty map would re-offer a decided event forever.
        let chosen = events.reduce(into: [String: String]()) { picks, event in
            picks[event.designation] = event.chosenOption
        }
        return EventRanking
            .pendingChoices(events: events, chosenOptions: chosen, bills: bills)
            .map { event, options in
                BrainEventChoice(
                    designation: event.designation,
                    location: event.location,
                    tier: event.tier,
                    options: options.map { option in
                        BrainEventChoice.Option(
                            name: option.name,
                            deviceUnits: option.deviceUnits,
                            resourceUnits: option.resourceUnits,
                            exceedsOneFreighterLoad: option.exceedsOneFreighterLoad,
                            missingDevices: option.devices
                                .filter { (held[$0.key] ?? 0) < $0.value }
                                .keys.sorted()
                        )
                    }
                )
            }
    }
```

Add `pendingEventChoices: [BrainEventChoice]` to the report struct the why-view renders, populated from this call on the same tick that builds the rest of the report.

In `LocationEventsFeature`, add the action and its reducer case:

```swift
        case let .chooseOption(designation, name):
            return .run { _ in
                try await database.write { db in
                    try LocationEvent
                        .where { $0.designation.eq(designation) }
                        .update { $0.chosenOption = name }
                        .execute(db)
                }
            }
```

Create `EventOptionPicker.swift` as the detail-pane control that offers each option and sends `.chooseOption`. It renders each option's device bill, resource bill, and a badge when `exceedsOneFreighterLoad`. Use design tokens only — `Space.*`, `Radius.card`, `Font.rc*`, `Color.rc*` — and render `location`/`designation` in a mono token per the project rule. Put the row struct in its own file if it grows one; keep `#Preview` out of any file holding a row struct.

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter "BrainReportEventTests|LocationEventsFeature" \
  --event-stream-output-path /tmp/rc-t14.jsonl
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine app/Modules/LocationEventsFeature
git commit -m "feat(events): surface pending fulfilment choices and record the pick"
```

---

### Task 15: End-to-end through the real engine

Every `RelayRun` test was a pure-function table and the engine path was untested, which is how the `paid`-set regression shipped. `EventRun` does not repeat that.

**Files:**
- Create: `app/Modules/DirectiveEngine/Tests/EventRunEngineTests.swift`
- Modify: whatever the run needs to survive the real seam.

**Interfaces:**
- Consumes: `DirectiveEngineCore`, `GameDatabase.bootstrap()`, the stubbed `LocationEventsClient`.
- Produces: no new production API. This task proves the machine terminates through the engine.

- [ ] **Step 1: Write the failing test**

```swift
import Dependencies
import Foundation
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import DirectiveEngine
@testable import GameDatabase

@Suite("EventRun through the engine")
struct EventRunEngineTests {
    /// A ledger read that never satisfies the machine must still terminate.
    @Test("a permanently unmet event stalls, bounded, rather than looping")
    func boundedUnmetProgress() async throws {
        let database = try GameDatabase.bootstrap()
        let refreshes = LockIsolated(0)
        let now = Date(timeIntervalSince1970: 10_000)

        try await seed(database, now: now, step: EventRun.Step.confirmingProgress)

        try await withDependencies {
            $0.locationEventsClient = LocationEventsClient(
                refresh: { refreshes.withValue { $0 += 1 }; return 0 },
                complete: { _, _ in }
            )
            $0.date = .constant(now.addingTimeInterval(EventRun.progressDeadline + 60))
        } operation: {
            let core = DirectiveEngineCore(database: database)
            for _ in 0..<5 { await core.evaluateOnce() }
        }

        let row = try await database.read { db in try Directive.all.fetchOne(db) }
        #expect(row?.status == .needsAttention)
        #expect(row?.attentionReason == .eventCriteriaUnmet)
        // Bounded: the refresh is not re-bought on every tick after the stall.
        #expect(refreshes.value <= 2)
    }

    @Test("a met event commits exactly once and finishes")
    func commitsOnce() async throws {
        let database = try GameDatabase.bootstrap()
        let posts = LockIsolated<[String]>([])
        let now = Date(timeIntervalSince1970: 10_000)

        try await seed(database, now: now, step: EventRun.Step.committing, met: true)

        try await withDependencies {
            $0.locationEventsClient = LocationEventsClient(
                refresh: { 0 },
                complete: { location, designation in
                    posts.withValue { $0.append("\(location)/\(designation)") }
                    try await database.write { db in
                        try LocationEvent
                            .where { $0.designation.eq(designation) }
                            .update { $0.status = "completed" }
                            .execute(db)
                    }
                }
            )
            $0.date = .constant(now)
        } operation: {
            let core = DirectiveEngineCore(database: database)
            for _ in 0..<6 { await core.evaluateOnce() }
        }

        #expect(posts.value == ["X-1/X-1-EVT-001"])
        let row = try await database.read { db in try Directive.all.fetchOne(db) }
        #expect(row?.status != .needsAttention)
    }

    /// Seed a convoy standing on site with the row on `step`.
    private func seed(
        _ database: any DatabaseWriter, now: Date, step: String, met: Bool = false
    ) async throws {
        try await database.write { db in
            for device in EventRunFixtures.onSiteConvoy(updatedAt: now) {
                try Device.insert { device }.execute(db)
            }
            try LocationEvent.insert {
                EventRunFixtures.progressEvent(met: met, replicant: true)
            }.execute(db)
            try Directive.insert {
                EventRunFixtures.directive(step: step, now: now)
            }.execute(db)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventRunEngineTests --event-stream-output-path /tmp/rc-t15.jsonl
```
Expected: FAIL — `EventRunFixtures` has no `onSiteConvoy`/`progressEvent`, then real failures from the engine path.

- [ ] **Step 3: Write minimal implementation**

Add `onSiteConvoy(updatedAt:)` and `progressEvent(met:replicant:)` to `EventRunFixtures`, mirroring the inline fixtures Task 10's suite already builds. Then fix whatever the engine surfaces. Expect at least these, and read each failure rather than patching the test:

- The `.refreshEvents` resolver must be reachable from `DirectiveExecutor` without falling into the bypass stall, and its `paid` kind must be `.events` so it cannot collapse onto another kind's reason.
- `confirmProgress` must not re-buy a ledger read after it has stalled — the stall ends evaluation, so the bound is structural, but the test pins it.
- The `Directive` insert needs every non-null column the schema now has, `freighterCode` included.

If a device row must carry a theatre for `theatreDepot(for:)` to resolve, seed a `TheatrePin` rather than hand-setting a theatre — the recognition path is what production uses.

- [ ] **Step 4: Run the whole suite**

```bash
swift test --event-stream-output-path /tmp/rc-full.jsonl
jq -r 'select(.kind == "testCaseEnded") | select(.payload.status == "failed") |
       .payload.testCase.displayName' /tmp/rc-full.jsonl | sort -u
```
Expected: empty output, apart from the known pre-existing whole-package failure `theSupervisorAdoptsTheRowTheBrainLaunched` (green per-product and in isolation — do not attribute it to this work).

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine
git commit -m "test(engine): drive EventRun end-to-end through DirectiveEngineCore"
```

---

## Robustness

`brain-robustness-bar` requires every build plan to answer its eight clauses, verified in review with evidence. The task that supplies each:

| Clause | Answered by | Evidence |
|---|---|---|
| 1 · Selector, not enactor | Task 13 | `Brain.eventReadiness` returns a verdict; only `ensureOne` writes, and every command still leaves through `EventRun` → `CommandGovernor`. |
| 2 · Stateless between ticks | Tasks 3, 13 | `EventRanking.rank` takes the ledger and the live rows as arguments and holds nothing; the operator's pick lives on `locationEvents.chosenOption`, not in the brain. |
| 3 · API vetoes, never chooses | Task 8 | `RelayRun.printStockIsShort` can stop a print; `BrainEventTests.respectsReservation` shows a reservation can stop a launch. Neither picks the event. |
| 4 · Three-tier snapshot fidelity | Tasks 6, 10 | Ranking reads local rows; `confirmProgress` buys a `.refreshEvents` before committing. A stale row costs a trip, never a wrong commit. |
| 5 · End-to-end through the real seam | Task 15 | `EventRunEngineTests` drives `DirectiveEngineCore`, not a fixture table. |
| 6 · Safe degradation | Tasks 12, 13, 10 | No courier → `.idle`, which has no stall case and so cannot escalate. Unmet criteria → `.eventCriteriaUnmet`, escalate. Already-completed → clean abort, no stall. |
| 7 · Bounded blast radius | Tasks 4, 5, 11 | Two additive nullable columns; the attach edge closes the reservation hole; `recovering` refuses to depart without the courier; the reserve rail bounds spend. |
| 8 · Live derived why-view | Task 14 | `BrainReport.eventChoices` renders the pending picks with each option priced against held stock. |

Two clauses have evidence narrower than the claim, and the review should say so rather than tick them:

- **Clause 4's "no new poller" leg is structural, not tested.** `EventRun` adds `.refreshEvents`, which spends a read on the shared budget; nothing proves it stays bounded outside `EventRunEngineTests`'s single stall case.
- **Clause 7's don't-strand holds for the courier, not the load.** A convoy that aborts mid-`staging` leaves detached devices on site; `recovering` re-attaches only the courier. Recovering the rest is a deliberate omission — the devices are the event's to consume, and a partial delivery is worth leaving for the retry rather than flying twice.

---

## After the plan

Two things this plan deliberately does not do, both recorded in the spec's §12 and §13:

1. ~~Prove that a `matrix_container` can be attached to a `surge_carrier`.~~ **Settled live by the operator, 2026-08-14 — it attaches.** Task 8 no longer waits on anything, and the courier rides the attach grid as the spec designed.
2. **Write the build record.** When the capability ships, add `app/.claude/memory/brain-event-fulfilment-build.md` with its `MEMORY.md` index line, in the shape of `brain-mine-build.md`: what the plan got wrong, what the first live run surfaced, and the residuals.

---
