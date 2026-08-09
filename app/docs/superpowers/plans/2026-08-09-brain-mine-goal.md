# Brain Mine Goal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The brain's `mine` goal: an operator-invoked `mineFleetPrint` directive prints an eleven-device mine fleet at the hub, and a brain-launched `mineRun` directive sites the best belt, ferries nine devices there on a surge carrier, installs them, and terminates — after which per-tick liveness keeps each installed mine's ferry standing.

**Architecture:** Two new `MissionStepMachine`s (`MineFleetPrint`, `MineRun`) plus two pure helpers (`MineRecipe`, `MineSitePlanner`), three `Brain` liveness additions in the shipped `ensureOne` idiom, a pinned-source mode on the shipped `HaulRun`, and a why-view row. No schema change — both new kinds ride the existing `directives` table.

**Tech Stack:** Swift 6 SPM package at `app/Modules`; Swift Testing (`@Test`/`@Suite`); the `DirectiveEngine` module's existing engine, `CommandGovernor`, and `WorldView`/`WorldSnapshot`.

**Spec:** `app/docs/superpowers/specs/2026-08-07-brain-mine-goal-design.md`. Read it first.

## Global Constraints

- Comment budget is hard: file header ≤ 6 lines, `///` ≤ 3 lines, inline `//` ≤ 2 lines. No history, no rationale, no device codes in source (see `app/CLAUDE.md` §Comments).
- Every regression test must be demonstrated FAILING before its fix lands ("a guard nobody has seen fail is not a guard").
- Test results are read from Swift Testing's JSON event stream, never console text. Invocation (run from `app/Modules/`):
  `swift test --test-product DirectiveEngineTests --filter '<SuiteName>' --disable-xctest --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl`
  then check `jq -s '[.[] | select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isFailure != false))] | length' .build/events.jsonl` is 0 AND `runEnded` exists AND started == ended.
- Commits go to the current branch (`worktree-brain-salvage-goal`); commit after every green task. No PRs, no origin.
- Test-file fixture helpers are `private` — an internal helper with fewer defaulted parameters captures other suites' call sites (see memory `survey-fleet-repair-build`).
- Missions are pure: no I/O, no `Date()` (use `world.now`), one `MissionAction` per evaluation.
- A step that dispatches a `.simple` (untracked) verb must NOT name itself as `nextStep` — no `Operation` row means the re-dispatch guard never fires (memory `same-step-dispatch-needs-tracked-op`). Dispatch/confirm pairs.
- A confirm step judging a local device row must first prove `updatedAt >= stepStartedAt`, with the deadline check BEFORE the staleness guard (memory `confirm-steps-need-fresh-evidence`).
- Worktree LSP setup once before starting: `cd app/Modules && swift build --build-tests && ./scripts/link-index-store.sh`.

## File Structure

Create:
- `app/Modules/DirectiveEngine/Sources/MineRecipe.swift` — the recipe as data + fleet-membership queries
- `app/Modules/DirectiveEngine/Sources/MineSitePlanner.swift` — the siting key (pure)
- `app/Modules/DirectiveEngine/Sources/MineFleetPrint.swift` — the operator-invoked print machine
- `app/Modules/DirectiveEngine/Sources/MineRun.swift` — the delivery/install machine
- `app/Modules/DirectiveEngine/Tests/MineRecipeTests.swift`
- `app/Modules/DirectiveEngine/Tests/MineSitePlannerTests.swift`
- `app/Modules/DirectiveEngine/Tests/MineFleetPrintTests.swift`
- `app/Modules/DirectiveEngine/Tests/MineRunTests.swift`
- `app/Modules/DirectiveEngine/Tests/BrainMineTests.swift`
- `app/Modules/DirectiveEngine/Tests/BrainMineSeamTests.swift`

Modify:
- `app/Modules/GameModels/Sources/Directive.swift` — two `DirectiveKind` cases, one `DirectiveAttentionReason` case
- `app/Modules/GameServices/Sources/CommandParams.swift` + `CommandClient+Printing.swift` — `quantity`/`tags` on `enqueue_print`
- `app/Modules/DirectiveEngine/Sources/MeshValue.swift` — `BeltInfo.richness`
- `app/Modules/DirectiveEngine/Sources/WorldView.swift` — thread richness into `beltsBySystem`
- `app/Modules/DirectiveEngine/Sources/HaulRun.swift` — pinned-source mode
- `app/Modules/DirectiveEngine/Sources/MissionRegistry.swift` — register the two machines
- `app/Modules/DirectiveEngine/Sources/Brain.swift` — `mineReadiness`, `ensureMine`, `ensureMineFerries`, `mineStatus`, `brainManagedKinds`
- `app/Modules/DirectiveEngine/Sources/BrainReport.swift` — `mine` + `mines` fields
- `app/Modules/DirectivesFeature/Sources/BrainWhyGoal.swift` + `BrainWhyView.swift` — mine rows
- `app/Modules/DirectivesFeature/Sources/DirectivesFeature.swift` + `DirectivesListView.swift` — the Print Mine Fleet launcher

## Planned deviations from the spec (read before objecting to a task)

1. **Siting happens at launch, not in a `siting` step.** The brain writes the winning belt into `directive.targets` when it inserts the `mineRun` row. `WorldSnapshot` carries no belt data (the blob decode is deliberately confined to `WorldView` — see `WorldView.swift`'s header), so ranking inside the mission would mean widening the per-directive snapshot for one consumer. The brain ranking targets is also literally its job (robustness clause 1). `MineRun.preflight` re-validates the belt (still meshed, still unmined) against device rows, which ARE in the snapshot.
2. **`mineFleetPrint` enqueues serially, one job at a time, confirmed by device count.** The spec split jobs across the two autofactory queues for a ~1h24m wall time. A print op settles on the FIRST `print_complete` of a multi-quantity job, and the window between an op closing and the product row syncing would let a parallel dispatcher over-print. One job in flight, confirmed by counting tagged products, is provably duplicate-free with the existing op machinery. Cost: full serial print (~2h47m), unattended either way.
3. **Post-install directive lapses are surfaced, not auto-repaired.** The ferry is kept in force by a standing per-mine `haulRun` row (that machine already re-issues `set_directive`). The mining/survey/service directives have no owning row once `mineRun` terminates, and `gather_evenly`/`belt_search`/`service` cannot complete themselves — a lapse implies outside interference, which is operator territory (the operator tears mines down by hand, per the spec's non-goals). The why-view shows a lapsed mine as needs-attention; nothing re-arms it.

---

### Task 1: Directive vocabulary — two kinds, one attention reason

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift`
- Test: `app/Modules/GameModels/Tests/DirectiveTests.swift` (add to the existing file; create alongside its siblings if absent)

**Interfaces:**
- Produces: `DirectiveKind.mineFleetPrint` (title "Mine Fleet Print"), `DirectiveKind.mineRun` (title "Mine Run"), `DirectiveAttentionReason.mineFleetIncomplete` with `brainDisposition == .escalate`.

- [ ] **Step 1: Write the failing test**

In the GameModels test target (match the neighbouring suite style):

```swift
@Suite("Mine directive vocabulary")
struct MineDirectiveVocabularyTests {
    @Test("the two mine kinds carry list-row titles")
    func titles() {
        #expect(DirectiveKind.mineFleetPrint.title == "Mine Fleet Print")
        #expect(DirectiveKind.mineRun.title == "Mine Run")
    }

    @Test("an incomplete mine fleet escalates rather than auto-retrying")
    func disposition() {
        #expect(DirectiveAttentionReason.mineFleetIncomplete.brainDisposition == .escalate)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run (from `app/Modules/`): `swift test --test-product GameModelsTests --filter 'MineDirectiveVocabularyTests' --disable-xctest --event-stream-version "6.3" --event-stream-output-path .build/events.jsonl`
Expected: compile failure — `mineFleetPrint` not a member.

- [ ] **Step 3: Implement**

In `Directive.swift`:
- Add `case mineFleetPrint` and `case mineRun` to `DirectiveKind` (after `restockRun`), and their `title` lines: `case .mineFleetPrint: "Mine Fleet Print"`, `case .mineRun: "Mine Run"`.
- Add to `DirectiveAttentionReason`:

```swift
/// The mine fleet the run was launched for is no longer complete at the hub —
/// a member was taken, lost, or re-tasked between siting and attachment.
case mineFleetIncomplete
```

- `displayName`: `case .mineFleetIncomplete: "Mine fleet incomplete"`.
- `guidance`: `case .mineFleetIncomplete: "The auto:mine fleet at the hub is missing members. Re-run Mine Fleet Print to top it up, or re-tag the missing devices, then retry."`
- `brainDisposition`: add `.mineFleetIncomplete` to the `.escalate` list.
- Chase every non-exhaustive-switch compile error the two new kinds produce across the package (`swift build --build-tests` from `app/Modules/` finds them all). Expected sites: `DirectiveKind` switches in `DirectivesFeature` row rendering. Give each a sensible arm (mine kinds render like the other runs).

- [ ] **Step 4: Run the test to verify it passes**, plus `swift build --build-tests` clean.
- [ ] **Step 5: Commit** — `feat(models): mineFleetPrint + mineRun directive kinds`

---

### Task 2: `enqueue_print` gains quantity and tags

**Files:**
- Modify: `app/Modules/GameServices/Sources/CommandParams.swift`
- Modify: `app/Modules/GameServices/Sources/CommandClient+Printing.swift`
- Test: `app/Modules/GameServices/Tests/CommandClientBodyTests.swift` (add beside existing body tests; if none exist for printing, create the suite in the GameServices test target)

**Interfaces:**
- Produces: `CommandParams(deviceType:quantity:printTags:)` — new optional fields `quantity: Int?`, `printTags: [String]?` (named `printTags` because `tags` would shadow the device-row concept; the wire key is `tags`).

- [ ] **Step 1: Write the failing test**

```swift
@Suite("enqueue_print body")
struct EnqueuePrintBodyTests {
    @Test("quantity and tags ride the enqueue body when set")
    func quantityAndTags() throws {
        let params = CommandParams(deviceType: "mining_drone", quantity: 3, printTags: ["auto:mine"])
        #expect(params.json["quantity"]?.intValue == 3)
        #expect(params.json["tags"]?.arrayValue?.compactMap(\.stringValue) == ["auto:mine"])
    }

    @Test("absent quantity and tags stay off the wire")
    func defaultsOmitted() throws {
        let params = CommandParams(deviceType: "ftl_relay")
        #expect(params.json["quantity"] == nil)
        #expect(params.json["tags"] == nil)
    }
}
```

If `CommandParams.json` is not visible to the test target (it is `var json` at internal scope in `GameServices`), the test lives in the GameServices test target where internal is visible — put it there.

- [ ] **Step 2: Run to verify it fails** (`--test-product GameServicesTests --filter 'EnqueuePrintBodyTests'`). Expected: compile failure, no `quantity` parameter.

- [ ] **Step 3: Implement**

`CommandParams.swift`: add `public var quantity: Int?` and `public var printTags: [String]?`, both defaulted nil in the init (keep parameter order: insert after `index`). In `json`: `if let quantity { dict["quantity"] = .integer(quantity) }` and `if let printTags { dict["tags"] = .array(printTags.map(JSONValue.string)) }` (match the file's existing `JSONValue` case names — check how `devices` is encoded there and mirror it).

`CommandClient+Printing.swift` — thread them into the generated schema:

```swift
static func printBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
    guard let deviceType = params.deviceType else { throw CommandError.missingParameter("device_type") }
    return .json(.enqueuePrint(.init(
        command: "enqueue_print", deviceType: deviceType,
        quantity: params.quantity, tags: params.printTags
    )))
}
```

The generated `EnqueuePrintSchema` already carries `quantity`/`tags` (openapi lines for `app_schemas_device_commands_EnqueuePrintSchema`); if the generated init's argument labels differ, follow the compiler.

- [ ] **Step 4: Run to verify green.**
- [ ] **Step 5: Commit** — `feat(services): quantity + tags on enqueue_print`

---

### Task 3: `BeltInfo` carries raw richness

The siting key's scarce-type bonus needs each belt's `rares`/`conductive` qualifiers; `BeltInfo` currently keeps only the classified class.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MeshValue.swift` (the `BeltInfo` struct)
- Modify: `app/Modules/DirectiveEngine/Sources/WorldView.swift` (`beltsBySystem(in:)` construction)
- Test: `app/Modules/DirectiveEngine/Tests/MineSitePlannerTests.swift` (created next task — this task is compile-driven; the one behavioural assertion lands here)

**Interfaces:**
- Produces: `BeltInfo(designation:beltClass:richness:)` with `richness: [String: String] = [:]` — raw qualifier strings keyed by resource type, exactly as the wire carries them.

- [ ] **Step 1: Add the field**

```swift
public struct BeltInfo: Equatable, Sendable {
    public let designation: String
    public let beltClass: BeltClass
    /// Raw per-type richness qualifiers (`scarce`…`rich`), as the wire carries them.
    public let richness: [String: String]

    public init(designation: String, beltClass: BeltClass, richness: [String: String] = [:]) {
        self.designation = designation
        self.beltClass = beltClass
        self.richness = richness
    }
}
```

The default keeps every existing call site compiling.

- [ ] **Step 2: Thread it through `WorldView.beltsBySystem(in:)`**

In the `classified` map: `BeltInfo(designation: belt.designation, beltClass: $0, richness: belt.richness)`.

- [ ] **Step 3: `swift build --build-tests` clean, full `DirectiveEngineTests` still green.**
- [ ] **Step 4: Commit** — `feat(brain): BeltInfo carries raw richness qualifiers`

---

### Task 4: `MineRecipe` — the recipe as data, and the fleet queries

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/MineRecipe.swift`
- Test: `app/Modules/DirectiveEngine/Tests/MineRecipeTests.swift`

**Interfaces:**
- Produces:
  - `MineRecipe.fleetTag = "auto:mine"`, `MineRecipe.carrierTag = "auto:carrier"`, `MineRecipe.carrierDeviceType = "surge_carrier"`
  - `MineRecipe.carried: [(deviceType: String, quantity: Int)]` — the nine that ride
  - `MineRecipe.selfMoving: [(deviceType: String, quantity: Int)]` — transport controller + freighter
  - `MineRecipe.all: [(deviceType: String, quantity: Int)]`
  - `MineRecipe.isUnassigned(_ device: Device, hub: String) -> Bool`
  - `MineRecipe.unassignedFleet(at hub: String, in devices: some Sequence<Device>) -> [String: [Device]]` (type → members, each type capped at its recipe quantity, lowest-coded first)
  - `MineRecipe.shortfall(at hub: String, in devices: some Sequence<Device>) -> [String: Int]` (type → count still missing; empty means complete)
  - `MineRecipe.installedBelts(in devices: some Sequence<Device>, hub: String?) -> Set<String>`
  - `MineRecipe.idleCarrier(at hub: String, in devices: some Sequence<Device>) -> Device?`

- [ ] **Step 1: Write the failing tests**

Private fixture helper in the test file (copy the `salvageDevice` shape from `BrainSalvageTests.swift`, extended with `location`, `attachedTo`, `directive` (name, status), and `status`):

```swift
private let mineFixtureNow = Date(timeIntervalSince1970: 1_750_000_000)

private func mineDevice(
    _ code: String, type: String, tags: [String] = [], location: String? = nil,
    status: String = "idle", stowedIn: String? = nil, attachedTo: String? = nil,
    controllerDeviceCode: String? = nil,
    directive: (name: String, status: String, config: [String: JSONValue])? = nil,
    directives: [String] = [], commands: [String] = []
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !directives.isEmpty { detail["available_directives"] = .array(directives.map(JSONValue.string)) }
    if let directive {
        detail["ami_directive"] = .object([
            "name": .string(directive.name), "config": .object(directive.config),
        ])
        detail["ami_directive_status"] = .string(directive.status)
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controllerDeviceCode,
        attachedToDeviceCode: attachedTo, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: commands, features: [], tags: tags, detail: .object(detail),
        updatedAt: mineFixtureNow, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private let hub = "AINALRAM-BELT-1"

/// A complete unassigned mine fleet standing at the hub — one row per recipe slot.
private func printedFleet() -> [Device] {
    var out: [Device] = []
    var n = 0
    for (type, qty) in MineRecipe.all {
        for _ in 0..<qty {
            n += 1
            out.append(mineDevice("M\(String(format: "%02d", n))", type: type, tags: [MineRecipe.fleetTag], location: hub))
        }
    }
    return out
}
```

Tests:

```swift
@Suite("MineRecipe — the recipe and the fleet queries")
struct MineRecipeTests {
    @Test("the recipe is eleven devices, nine of which ride the carrier")
    func recipeCounts() {
        #expect(MineRecipe.carried.reduce(0) { $0 + $1.quantity } == 9)
        #expect(MineRecipe.all.reduce(0) { $0 + $1.quantity } == 11)
    }

    @Test("a complete printed fleet has no shortfall")
    func completeFleet() {
        #expect(MineRecipe.shortfall(at: hub, in: printedFleet()).isEmpty)
    }

    @Test("a missing drone shows as that type's shortfall")
    func missingDrone() {
        let fleet = printedFleet().filter { $0.deviceCode != "M02" }  // a mining_drone
        #expect(MineRecipe.shortfall(at: hub, in: fleet) == ["mining_drone": 1])
    }

    @Test("an installed mine's ferry controller at the hub is not unassigned")
    func ferryControllerExcluded() {
        var fleet = printedFleet()
        let tc = fleet.firstIndex { $0.deviceType == "ami_transport_controller" }!
        fleet[tc] = mineDevice(
            fleet[tc].deviceCode, type: "ami_transport_controller",
            tags: [MineRecipe.fleetTag], location: hub, status: "coordinating",
            directive: (name: "ferry", status: "active", config: [:])
        )
        #expect(MineRecipe.shortfall(at: hub, in: fleet) == ["ami_transport_controller": 1])
    }

    @Test("a device away from the hub, stowed, attached, or adopted is not unassigned")
    func locationAndOwnershipGates() {
        let away = mineDevice("A1", type: "mining_drone", tags: [MineRecipe.fleetTag], location: "ELSEWHERE-1")
        let attached = mineDevice("A2", type: "mining_drone", tags: [MineRecipe.fleetTag], location: hub, attachedTo: "CARRIER")
        let adopted = mineDevice("A3", type: "mining_drone", tags: [MineRecipe.fleetTag], location: hub, controllerDeviceCode: "AMI")
        for d in [away, attached, adopted] {
            #expect(!MineRecipe.isUnassigned(d, hub: hub))
        }
    }

    @Test("installed belts are auto:mine mining controllers standing away from the hub")
    func installedBelts() {
        let installed = mineDevice(
            "MC1", type: "ami_mining_controller", tags: [MineRecipe.fleetTag],
            location: "AMEDIOHA-BELT-1", status: "coordinating",
            directive: (name: "gather_evenly", status: "active", config: [:])
        )
        let atHub = mineDevice("MC2", type: "ami_mining_controller", tags: [MineRecipe.fleetTag], location: hub)
        let belts = MineRecipe.installedBelts(in: [installed, atHub], hub: hub)
        #expect(belts == ["AMEDIOHA-BELT-1"])
    }

    @Test("the idle carrier is the lowest-coded tagged surge carrier at the hub")
    func idleCarrier() {
        let a = mineDevice("CB", type: MineRecipe.carrierDeviceType, tags: [MineRecipe.carrierTag], location: hub)
        let b = mineDevice("CA", type: MineRecipe.carrierDeviceType, tags: [MineRecipe.carrierTag], location: hub)
        let busy = mineDevice("AA", type: MineRecipe.carrierDeviceType, tags: [MineRecipe.carrierTag], location: hub, status: "travelling")
        #expect(MineRecipe.idleCarrier(at: hub, in: [a, b, busy])?.deviceCode == "CA")
    }
}
```

- [ ] **Step 2: Run to verify failure** (`--filter 'MineRecipeTests'`). Expected: `MineRecipe` unresolved.

- [ ] **Step 3: Implement `MineRecipe.swift`**

```swift
//
//  MineRecipe.swift
//  Replicould — DirectiveEngine
//
//  The mine-fleet recipe as data, and the fleet-membership queries the print
//  run, the mine run, and the brain's readiness verdicts share.
//

import Foundation
import GameModels

/// The eleven-device mine fleet: what to print, what rides the carrier, and
/// how to recognise the pieces in device rows.
public enum MineRecipe {
    public static let fleetTag = "auto:mine"
    public static let carrierTag = "auto:carrier"
    public static let carrierDeviceType = "surge_carrier"

    /// The nine that ride the carrier to the belt.
    public static let carried: [(deviceType: String, quantity: Int)] = [
        ("ami_mining_controller", 1),
        ("mining_drone", 3),
        ("ami_survey_controller", 1),
        ("survey_drone", 2),
        ("service_bot", 2),
    ]

    /// The two that stay at the hub or move themselves.
    public static let selfMoving: [(deviceType: String, quantity: Int)] = [
        ("ami_transport_controller", 1),
        ("cargo_freighter", 1),
    ]

    public static var all: [(deviceType: String, quantity: Int)] { carried + selfMoving }

    /// Whether `device` is a free recipe member standing at `hub`: tagged, idle,
    /// unadopted, unattached, unstowed, and running no AMI directive.
    public static func isUnassigned(_ device: Device, hub: String) -> Bool {
        device.hasTag(fleetTag)
            && device.location == hub
            && device.stowedInDeviceCode == nil
            && device.attachedToDeviceCode == nil
            && device.controllerDeviceCode == nil
            && device.currentDirective == nil
    }

    /// Free recipe members at `hub` by type, lowest-coded first, capped at each
    /// type's recipe quantity so a surplus never inflates the fleet.
    public static func unassignedFleet(
        at hub: String, in devices: some Sequence<Device>
    ) -> [String: [Device]] {
        let free = devices.filter { isUnassigned($0, hub: hub) }
        var out: [String: [Device]] = [:]
        for (type, quantity) in all {
            out[type] = free
                .filter { $0.deviceType == type }
                .sorted { $0.deviceCode < $1.deviceCode }
                .prefix(quantity)
                .map { $0 }
        }
        return out
    }

    /// Recipe slots not yet standing free at `hub`. Empty means a full fleet.
    public static func shortfall(
        at hub: String, in devices: some Sequence<Device>
    ) -> [String: Int] {
        let fleet = unassignedFleet(at: hub, in: devices)
        var missing: [String: Int] = [:]
        for (type, quantity) in all {
            let have = fleet[type]?.count ?? 0
            if have < quantity { missing[type] = quantity - have }
        }
        return missing
    }

    /// Belts holding an installed mine: locations of tagged mining controllers
    /// standing away from the hub.
    public static func installedBelts(
        in devices: some Sequence<Device>, hub: String?
    ) -> Set<String> {
        Set(
            devices
                .filter { $0.deviceType == "ami_mining_controller" && $0.hasTag(fleetTag) }
                .compactMap(\.location)
                .filter { $0 != hub }
        )
    }

    /// The delivery vehicle: lowest-coded idle tagged surge carrier at `hub`.
    public static func idleCarrier(
        at hub: String, in devices: some Sequence<Device>
    ) -> Device? {
        devices
            .filter {
                $0.deviceType == carrierDeviceType && $0.hasTag(carrierTag)
                    && $0.location == hub && $0.status == "idle"
            }
            .min { $0.deviceCode < $1.deviceCode }
    }
}
```

- [ ] **Step 4: Run to verify green.**
- [ ] **Step 5: Commit** — `feat(brain): MineRecipe — the eleven-device recipe and fleet queries`

---

### Task 5: `MineSitePlanner` — the siting key

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/MineSitePlanner.swift`
- Test: `app/Modules/DirectiveEngine/Tests/MineSitePlannerTests.swift`

**Interfaces:**
- Consumes: `BeltInfo.richness` (Task 3), `WorldView.beltsBySystem`, `WorldView.meshSystems`, `WorldView.starPositions`, `WorldView.hubLocation`.
- Produces:

```swift
public enum MineSitePlanner {
    public struct Candidate: Equatable, Sendable {
        public let belt: String
        public let system: String
        public let beltClass: BeltClass
        public let scarceBonus: Int
        public let distanceLY: Double
    }
    public static func scarceBonus(richness: [String: String]) -> Int
    public static func site(view: WorldView, occupiedBelts: Set<String>) -> Candidate?
}
```

- [ ] **Step 1: Write the failing tests**

Reuse the private `mineDevice` fixture (repeat it in this file — private helpers do not cross files) plus a `WorldView` builder:

```swift
private func siteView(
    belts: [String: [BeltInfo]],
    meshSystems: Set<String>,
    positions: [String: Position],
    hub: String? = "AINALRAM-BELT-1"
) -> WorldView {
    WorldView(
        devices: [:], starPositions: positions, meshSystems: meshSystems,
        salvageUnits: [:], eventSystems: [], hubLocation: hub,
        beltsBySystem: belts, now: Date(timeIntervalSince1970: 1_750_000_000)
    )
}

private func belt(_ des: String, _ cls: BeltClass, rares: String = "scarce", conductive: String = "scarce") -> BeltInfo {
    BeltInfo(designation: des, beltClass: cls, richness: ["rares": rares, "conductive": conductive])
}
```

```swift
@Suite("MineSitePlanner — the siting key")
struct MineSitePlannerTests {
    @Test("a far rich belt beats a near sparse one")
    func classDominatesDistance() {
        let view = siteView(
            belts: ["NEAR": [belt("NEAR-BELT-1", .sparse)], "FAR": [belt("FAR-BELT-1", .rich)]],
            meshSystems: ["AINALRAM", "NEAR", "FAR"],
            positions: ["AINALRAM": .init(x: 0, y: 0, z: 0), "NEAR": .init(x: 1, y: 0, z: 0), "FAR": .init(x: 30, y: 0, z: 0)]
        )
        #expect(MineSitePlanner.site(view: view, occupiedBelts: [])?.belt == "FAR-BELT-1")
    }

    @Test("rares at moderate outranks conductive at high")
    func raresOutranksConductive() {
        #expect(MineSitePlanner.scarceBonus(richness: ["rares": "moderate", "conductive": "scarce"]) == 2)
        #expect(MineSitePlanner.scarceBonus(richness: ["rares": "scarce", "conductive": "high"]) == 1)
        #expect(MineSitePlanner.scarceBonus(richness: ["rares": "moderate", "conductive": "moderate"]) == 3)
    }

    @Test("the bonus breaks a same-class tie whatever the distances")
    func bonusBreaksClassTie() {
        let view = siteView(
            belts: [
                "NEAR": [belt("NEAR-BELT-1", .rich)],
                "FAR": [belt("FAR-BELT-1", .rich, rares: "moderate")],
            ],
            meshSystems: ["AINALRAM", "NEAR", "FAR"],
            positions: ["AINALRAM": .init(x: 0, y: 0, z: 0), "NEAR": .init(x: 1, y: 0, z: 0), "FAR": .init(x: 30, y: 0, z: 0)]
        )
        #expect(MineSitePlanner.site(view: view, occupiedBelts: [])?.belt == "FAR-BELT-1")
    }

    @Test("an unmeshed system's belt is never a candidate")
    func unmeshedFiltered() {
        let view = siteView(
            belts: ["OFFMESH": [belt("OFFMESH-BELT-1", .rich)]],
            meshSystems: ["AINALRAM"],
            positions: ["AINALRAM": .init(x: 0, y: 0, z: 0), "OFFMESH": .init(x: 5, y: 0, z: 0)]
        )
        #expect(MineSitePlanner.site(view: view, occupiedBelts: []) == nil)
    }

    @Test("an occupied belt is filtered while its unoccupied twin survives")
    func occupiedFiltered() {
        let view = siteView(
            belts: ["S": [belt("S-BELT-1", .rich), belt("S-BELT-2", .moderate)]],
            meshSystems: ["AINALRAM", "S"],
            positions: ["AINALRAM": .init(x: 0, y: 0, z: 0), "S": .init(x: 5, y: 0, z: 0)]
        )
        #expect(MineSitePlanner.site(view: view, occupiedBelts: ["S-BELT-1"])?.belt == "S-BELT-2")
    }

    @Test("no hub or no placeable position yields no site")
    func noHubNoSite() {
        let noHub = siteView(
            belts: ["S": [belt("S-BELT-1", .rich)]], meshSystems: ["S"],
            positions: ["S": .init(x: 5, y: 0, z: 0)], hub: nil
        )
        #expect(MineSitePlanner.site(view: noHub, occupiedBelts: []) == nil)
    }

    @Test("designation is the stable last tie-break")
    func stableTieBreak() {
        let view = siteView(
            belts: ["S": [belt("S-BELT-2", .rich), belt("S-BELT-1", .rich)]],
            meshSystems: ["AINALRAM", "S"],
            positions: ["AINALRAM": .init(x: 0, y: 0, z: 0), "S": .init(x: 5, y: 0, z: 0)]
        )
        #expect(MineSitePlanner.site(view: view, occupiedBelts: [])?.belt == "S-BELT-1")
    }
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `MineSitePlanner.swift`**

```swift
//
//  MineSitePlanner.swift
//  Replicould — DirectiveEngine
//
//  Ranks candidate belts for a new permanent mine: class, then a rares/conductive
//  scarcity bonus, then distance from the hub, then designation.
//

import Foundation
import GameModels
import UniverseModels

public enum MineSitePlanner {
    /// One rankable belt, with the rank terms exposed for the why-view.
    public struct Candidate: Equatable, Sendable {
        public let belt: String
        public let system: String
        public let beltClass: BeltClass
        public let scarceBonus: Int
        public let distanceLY: Double
    }

    /// Rares ≥ moderate scores 2, conductive ≥ moderate scores 1 — weighted by
    /// how rare each is across charted belts, per the design spec.
    public static func scarceBonus(richness: [String: String]) -> Int {
        var bonus = 0
        if atLeastModerate(richness["rares"]) { bonus += 2 }
        if atLeastModerate(richness["conductive"]) { bonus += 1 }
        return bonus
    }

    private static func atLeastModerate(_ qualifier: String?) -> Bool {
        switch qualifier {
        case "moderate", "high", "rich": true
        default: false
        }
    }

    /// The best belt for a new mine, or nil when nothing passes the hard
    /// filters: meshed system, not in `occupiedBelts`, classifiable, placeable.
    public static func site(view: WorldView, occupiedBelts: Set<String>) -> Candidate? {
        guard let hub = view.hubLocation,
              let hubPosition = view.starPositions[SiteAssay.system(of: hub)]
        else { return nil }

        var candidates: [Candidate] = []
        for (system, belts) in view.beltsBySystem {
            guard view.meshSystems.contains(system),
                  let position = view.starPositions[system]
            else { continue }
            for belt in belts where !occupiedBelts.contains(belt.designation) {
                candidates.append(Candidate(
                    belt: belt.designation,
                    system: system,
                    beltClass: belt.beltClass,
                    scarceBonus: scarceBonus(richness: belt.richness),
                    distanceLY: hubPosition.distance(to: position)
                ))
            }
        }
        return candidates.min { lhs, rhs in
            if lhs.beltClass != rhs.beltClass { return lhs.beltClass > rhs.beltClass }
            if lhs.scarceBonus != rhs.scarceBonus { return lhs.scarceBonus > rhs.scarceBonus }
            if lhs.distanceLY != rhs.distanceLY { return lhs.distanceLY < rhs.distanceLY }
            return lhs.belt < rhs.belt
        }
    }
}
```

Note the "unclassifiable yields no target" filter needs no code here: `WorldView.beltsBySystem` only ever contains belts `BeltClass.classify` resolved — assert that inherited property in a comment-free test if you like, but do not re-filter.

- [ ] **Step 4: Run to verify green.**
- [ ] **Step 5: Commit** — `feat(brain): MineSitePlanner — class, scarcity bonus, distance`

---

### Task 6: `MineFleetPrint` — the operator-invoked print machine

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/MineFleetPrint.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/MissionRegistry.swift`
- Test: `app/Modules/DirectiveEngine/Tests/MineFleetPrintTests.swift`

**Interfaces:**
- Consumes: `MineRecipe` (Task 4), `CommandParams(deviceType:quantity:printTags:)` (Task 2), `RelayRun.hubLocation(in:)`, `RelayRun(reserveFloor:).footprintCensusIsStale(_:)` / `printStockIsShort(at:_:)` (shipped — `RestockRun` shows the exact call shape).
- Produces: `MineFleetPrint: MissionStepMachine` with `kind == .mineFleetPrint`, steps `Step.stocking` / `Step.printing`, `firstStep == Step.stocking`. Registered in `MissionRegistry.machines`.

Behaviour (mirrors `RestockRun` — read that file first, it is the template):

- `stocking`: hub row = `world.device(directive.deviceCode)`; stall `.unreachableDevice` if missing or location-less. Compute `remaining` = `MineRecipe.shortfall(at: hub, in: world.devices.values)` plus `["surge_carrier": 1]` when `MineRecipe.idleCarrier` finds none AND no untagged idle `surge_carrier` exists at the hub. If `remaining` empty → `.done` (the run's product is the standing fleet; the row completes). One print op in flight: `world.openOperation(for:)` non-nil on the hub device → `.wait`. Census stale → `.refreshFootprint(nextStep: Step.stocking, thenStall: nil)`; `printStockIsShort` → `.wait` (short stock idles, never stalls — the hub buffer refills from salvage). Otherwise dispatch ONE job: the first `(type, missing)` pair in `MineRecipe.all` order (carrier job last), `params: CommandParams(deviceType: type, quantity: missing, printTags: [type == MineRecipe.carrierDeviceType ? MineRecipe.carrierTag : MineRecipe.fleetTag])`, `kind: .print`, `nextStep: Step.printing`.
- `printing`: recompute `remaining`. Type of the last job satisfied (or all satisfied) → `.advanceStep(nextStep: Step.stocking)` (re-decide; `stocking` finishes with `.done` when nothing remains). Open op on the hub → `.wait`. No open op and shortfall unmoved past `RestockRun.printDeadline` → `.advanceStep(nextStep: Step.stocking)` with a notice log (the RestockRun `printing` shape verbatim — count-based, so a superseded op cannot strand it).
- `plan(_:)` → `.exhausted` (not a roaming run).

- [ ] **Step 1: Write the failing tests**

Repeat the private `mineDevice`/`printedFleet` fixtures. Build `WorldSnapshot` fixtures the way `RestockRunTests` does (find that file and copy its snapshot builder — it constructs `WorldSnapshot` with devices + footprints + operations; reuse the invocation shape exactly, private to this file). Cases:

```swift
@Suite("MineFleetPrint — the operator-invoked print run")
struct MineFleetPrintTests {
    // 1. hub gone → .stall(.unreachableDevice)
    // 2. fleet complete + carrier idle → .done
    // 3. fleet complete, NO carrier anywhere → dispatches a surge_carrier print tagged auto:carrier
    // 4. shortfall of mining_drone 3 → dispatches .print with deviceType "mining_drone",
    //    quantity 3, printTags ["auto:mine"], nextStep printing
    // 5. open op on the hub → .wait (no double dispatch)
    // 6. stale census → .refreshFootprint(nextStep: stocking, thenStall: nil)
    // 7. printStockIsShort → .wait — assert it is NOT a .stall (the idle-not-stall clause)
    // 8. printing step, shortfall satisfied → .advanceStep(stocking)
    // 9. printing step, open op → .wait
}
```

Write all nine as real `#expect` assertions against `MineFleetPrint().nextAction(directive:world:)` — the verdict-table style of `BrainSalvageTests`. For case 7, drive `printStockIsShort` true the way `RestockRunTests` does (a footprint row below the floor at the hub location).

- [ ] **Step 2: Run to verify failure** (type unresolved).
- [ ] **Step 3: Implement** the machine as specified above, then register: `MissionRegistry.machines` gains `MineFleetPrint()` (and `MineRun()` arrives in Task 8 — leave registry room).
- [ ] **Step 4: Run to verify green; run the full `DirectiveEngineTests` product for fallout.**
- [ ] **Step 5: Commit** — `feat(brain): MineFleetPrint — hub-owned recipe printing`

---

### Task 7: `HaulRun` pinned-source mode

A `haulRun` row whose `targets` is non-empty is a per-mine ferry keeper: it drives exactly its own `deviceCode` controller at exactly `targets[0]`, skipping the planner. The general drainer (empty `targets`) is untouched.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/HaulRun.swift`
- Test: `app/Modules/DirectiveEngine/Tests/HaulRunTests.swift` (append a new suite)

**Interfaces:**
- Consumes: `Directive.targets` (existing column; `HaulRun.plan` returns `.idle` so the engine never appends to it).
- Produces: `HaulRun.pinnedSource(of directive: Directive) -> String?` (`directive.targets.first`), used by `assign`/`dispatchAssignment`/`preflight`.

- [ ] **Step 1: Write the failing tests** (append to `HaulRunTests.swift`, private fixtures local to the new suite):

```swift
@Suite("HaulRun — pinned-source mode")
struct HaulRunPinnedTests {
    // 1. a pinned run in `assigning` pins ITS OWN deviceCode controller
    //    (assignController(deviceCode: directive.deviceCode)) even when the planner
    //    would prefer a richer pile elsewhere — build a world with a bigger
    //    footprint at another meshed location and assert the pinned belt wins.
    // 2. a pinned run in `dispatching` dispatches setDirective with
    //    configuration collect == targets[0], deliver == deliverySink(in: world).
    // 3. a pinned run whose controller already runs that exact ferry config
    //    advances to hauling (isInForce short-circuit).
    // 4. REGRESSION PAIR: a general run (targets: []) over the same world still
    //    follows the planner — assert its dispatch names the planner's pile,
    //    not the pinned belt. This is the guard that the branch is scoped.
    // 5. a pinned run in `preflight` whose controller row is stale refreshes
    //    THAT DEVICE (.refreshDevices([deviceCode], thenStall: .noHaulControllerTagged)),
    //    not the whole tag.
}
```

Write them as real assertions; copy fixture shapes from the existing suites in the same file (keep the new helpers private and differently named — the internal-helper capture trap).

- [ ] **Step 2: Run to verify the new suite fails** (behaviour not yet present: case 1 currently follows the planner). Cases 1, 2, 5 must fail against shipped code; case 4 must PASS against shipped code (it is the scoping guard, demonstrated meaningful by cases 1–2 failing).

- [ ] **Step 3: Implement**

In `HaulRun`:

```swift
/// The one collect location a per-mine row is pinned to, or nil for the
/// general drainer. Pinned rows drive only their own `deviceCode` controller.
static func pinnedSource(of directive: Directive) -> String? {
    directive.targets.first
}
```

- `preflight`: when pinned, check the single `world.device(directive.deviceCode)` for existence + freshness (`stagingFreshness`); stale/missing → `.refreshDevices(deviceCodes: [directive.deviceCode], thenStall: .noHaulControllerTagged)`; fresh → advance to `surveying` as today.
- `assign`: when pinned, skip `plans(_:_:)` — the single assignment is `HaulTargetPlanner.Assignment(controllerCode: directive.deviceCode, directive: HaulTargetPlanner.ferry, location: pinned)` (check `Assignment`'s exact memberwise init in `HaulTargetPlanner.swift` and match it). If `isInForce` already → `.advanceStep(Step.hauling)`; else `.assignController(deviceCode: directive.deviceCode, nextStep: Step.dispatching)`.
- `dispatchAssignment`: when pinned, build the same single assignment instead of consulting `plans`. Everything downstream (attempt budget, confirm, `isInForce`) is unchanged.

- [ ] **Step 4: Run the WHOLE `HaulRunTests` file to verify green** — the shipped suites must stay green; they are the general-mode regression net.
- [ ] **Step 5: Commit** — `feat(brain): pinned-source mode on HaulRun for per-mine ferries`

---

### Task 8: `MineRun` part 1 — preflight, attach, travel, detach

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/MineRun.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/MissionRegistry.swift` (register `MineRun()`)
- Test: `app/Modules/DirectiveEngine/Tests/MineRunTests.swift`

**Interfaces:**
- Consumes: `MineRecipe` (Task 4); `SalvageRun.travelPositionUnconfirmed` (module-internal — reuse, do not copy); `DirectiveAttentionReason.mineFleetIncomplete` (Task 1).
- Produces: `MineRun: MissionStepMachine`, `kind == .mineRun`, `firstStep == Step.preflight`. Steps (bare strings on `MineRun.Step`): `preflight`, `attaching`, `confirmingAttach`, `travelling`, `confirmingArrival`, `detaching`, `confirmingDetach`, `adopting`, `confirmingAdopt`, `arming`, `confirmingArm` (Task 9 fills the last four). Plus:
  - `MineRun.members(of directive: Directive, in world: WorldSnapshot) -> [String: [Device]]` — the nine carried members: rows attached to the carrier count first, topped up from `MineRecipe.unassignedFleet` at the carrier's location, per type, capped at recipe quantity, lowest-coded — a stable choice as attachment proceeds.
  - Deadlines: `attachConfirmDeadline: TimeInterval = 5 * 60`, `arrivalConfirmDeadline = SalvageRun.arrivalConfirmDeadline`, `confirmReadInterval: TimeInterval = 30`.
  - `targetBelt(of directive: Directive) -> String?` = `directive.targets.first`.

Step behaviour:

- `preflight`: carrier = `world.device(directive.deviceCode)` else `.stall(.unreachableDevice)`. `targetBelt` nil → `.stall(.unreachableDevice)` (a row born without a target is malformed). Belt's system (`SiteAssay.system(of: belt)`) not in `SalvageTargetPlanner.meshSystems(in: Array(world.devices.values))` → `.stall(.unreachableDevice)` — the belt genuinely cannot be commanded, its guidance text already says cancel-or-retry, and `.mineFleetIncomplete` is reserved for fleet gaps only. Fleet check: any member type short per `MineRun.members` → freshness-gated `.refreshFleet(tag: MineRecipe.fleetTag, thenStall: .mineFleetIncomplete)` (the tag scope sees attached/stowed rows). Belt already mined (`MineRecipe.installedBelts` contains belt) → `.done` (the goal is satisfied; the row retires without spending the carrier). All good → `.advanceStep(Step.attaching)`.
- `attaching`: `attached` = members with `attachedToDeviceCode == carrier`. All nine attached → `.advanceStep(Step.travelling)`. Else dispatch ONE: `.dispatch(kind: .attach, deviceCode: carrier.deviceCode, params: CommandParams(devices: [nextUnattached.deviceCode]), nextStep: Step.confirmingAttach)` (attach rides `params.devices` under the wire key `targets` — `CommandClient+Topology.swift`).
- `confirmingAttach`: fresh-evidence idiom on the device just attached (the newest member with `attachedToDeviceCode != carrier`, same deterministic order): row fresh (`updatedAt >= directive.stepStartedAt`) and attached → `.advanceStep(Step.attaching)`. Deadline first, then staleness: past `attachConfirmDeadline` → `.refreshDevices(deviceCodes: [member.deviceCode], thenStall: .commandRejected)`; stale beyond `confirmReadInterval` → `.refreshDevices(..., thenStall: nil)`; else `.wait`.
- `travelling`: `if let unconfirmed = SalvageRun.travelPositionUnconfirmed(carrier, world) { return unconfirmed }` (the arrival watermark — REQUIRED, see memory `confirm-steps-need-fresh-evidence` half three), then `.dispatch(kind: .travel, deviceCode: carrier.deviceCode, params: CommandParams(destination: belt), nextStep: Step.confirmingArrival)`.
- `confirmingArrival`: carrier fresh and `location == belt` → `.advanceStep(Step.detaching)`. Open travel op → `.wait`. Deadline/staleness ladder as in `confirmingAttach` with `arrivalConfirmDeadline`, stall `.vesselPositionUnconfirmed`.
- `detaching`: dispatch ONE `detach` naming all nine attached codes: `.dispatch(kind: .detach, deviceCode: carrier.deviceCode, params: CommandParams(devices: attachedCodes), nextStep: Step.confirmingDetach)`.
- `confirmingDetach`: all nine rows fresh, `attachedToDeviceCode == nil`, `location == belt` → `.advanceStep(Step.adopting)`. Ladder as above, stall `.commandRejected`.
- `plan(_:)` → `.exhausted`.

- [ ] **Step 1: Write the failing tests** — verdict tables per step, private fixtures (repeat `mineDevice`; build `WorldSnapshot`s the way `SalvageRunTests` does — copy its snapshot construction shape). Minimum set:

```
preflight: missing carrier → unreachableDevice · no target → unreachableDevice ·
  de-meshed belt → unreachableDevice · short fleet → refreshFleet(auto:mine, mineFleetIncomplete) ·
  belt already mined → done · staged+meshed → advance(attaching)
attaching: 0 of 9 attached → dispatch attach [lowest-coded member] to carrier, next confirmingAttach ·
  9 attached → advance(travelling) · choice is stable: with 4 attached, the dispatched code
  is the same one a re-evaluation picks
confirmingAttach: fresh+attached → advance(attaching) · stale row → refreshDevices(nil) after
  interval · past deadline → refreshDevices(thenStall: commandRejected) · pre-deadline fresh-but-
  unattached → wait
travelling: dispatches travel(destination: belt) next confirmingArrival · an unresolved arrival
  watermark defers the dispatch (drive travelPositionUnconfirmed non-nil the way
  SalvageRunTests does)
confirmingArrival: carrier fresh at belt → advance(detaching) · open op → wait
detaching: dispatches detach naming ALL nine codes, next confirmingDetach
confirmingDetach: nine fresh, detached, at belt → advance(adopting)
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** `MineRun.swift` through `confirmingDetach` (later steps return `.wait` for now with a `// Task 9` marker comment REMOVED before that task's commit), register `MineRun()` in `MissionRegistry.machines`.
- [ ] **Step 4: Run to verify green; full product run for fallout.**
- [ ] **Step 5: Commit** — `feat(brain): MineRun — attach, ferry, detach (part 1)`

---

### Task 9: `MineRun` part 2 — adopt, arm, confirm, done

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MineRun.swift`
- Test: `app/Modules/DirectiveEngine/Tests/MineRunTests.swift` (extend)

**Interfaces:**
- Consumes: `HaulRun.deliverySink(in:)`, `HaulTargetPlanner.ferry`, the `set_directive`/`activate` split (`SalvageRun.configure` at `SalvageRun.swift:522` is the template; `isMining`/`isPaused` at `:225` show the active-status predicate shape).
- Produces: the run completes — `.done` — with all five directives in force and active.

Arming plan, derived fresh each tick (a value array, not state):

```swift
/// The five arm targets, in dependency order. Adoption happens strictly before
/// arming: an armed controller with no adopted drones coordinates nothing.
struct ArmTarget: Equatable {
    let deviceCode: String
    let directive: String
    let configuration: [String: JSONValue]?
}
```

- `adopting`: three adoptions, one dispatch per tick, derived from rows:
  1. mining controller (the member) adopts the 3 member drones: any drone with `controllerDeviceCode != miningController.deviceCode` → `.dispatch(kind: .adopt, deviceCode: miningController.deviceCode, params: CommandParams(devices: unadoptedDroneCodes), nextStep: Step.confirmingAdopt)` (one command, the full list).
  2. survey controller adopts the 2 survey drones — same shape.
  3. transport controller adopts the freighter. The transport controller and freighter are the `MineRecipe.selfMoving` members — resolve them via `MineRecipe.unassignedFleet(at: hubLocation, ...)` where `hubLocation = HaulRun.deliverySink(in: world)`; once adopted/armed they stop being "unassigned", so ALSO accept a tagged transport controller at the hub whose `currentDirectiveConfig?["collect"] == belt` (re-entrant identification).
  All adopted → `.advanceStep(Step.arming)`.
- `confirmingAdopt`: the just-adopted rows fresh and `controllerDeviceCode` set → `.advanceStep(Step.adopting)`. Deadline/staleness ladder, stall `.commandRejected`.
- `arming`: five targets in order — mining controller (`gather_evenly`, config nil), survey controller (`belt_search`, config nil), each service bot (`service`, config nil), transport controller (`ferry`, config `["collect": .string(belt), "deliver": .string(HaulRun.deliverySink(in: world))]`). For the first target not in force: wrong directive/config → dispatch `.setDirective` with the target's params, `nextStep: Step.confirmingArm`; right directive but `currentDirectiveStatus != "active"` → dispatch `OperationKind.simple("activate")`, `nextStep: Step.confirmingArm` (the `SalvageRun.configure` split). All five in force and active → `.done`.
- `confirmingArm`: the pending target's row fresh and (directive+config in force AND status active) → `.advanceStep(Step.arming)`. Ladder; past-deadline stall `.serviceBotNotArmed` when the pending target is a bot, `.commandRejected` otherwise.
- "In force" for the ferry config compares `collect` to the belt and `deliver` to `HaulRun.deliverySink(in: world)` OR `HaulRun.deliveryLocation` (the derived-sink flicker tolerance `hasTakenSomeHaulConfig` encodes — mirror it).

- [ ] **Step 1: Write the failing tests** — verdict tables:

```
adopting: unadopted mining drones → one adopt command naming all three, to the mining
  controller · survey pair next once mining trio adopted · freighter last · all adopted →
  advance(arming)
arming: nothing armed → setDirective gather_evenly on the mining controller ·
  gather_evenly in force but paused → activate on the mining controller (NOT a re-send
  of set_directive) · four armed, transport pending → setDirective ferry with
  collect == belt, deliver == sink · all five active → .done
confirmingArm: fresh row, ferry active → advance(arming) · fresh row, service directive
  wrong, past deadline → stall(serviceBotNotArmed)
gather_resources is never dispatched: assert no arm target's directive == "gather_resources"
  by construction (a unit test over the ArmTarget builder with a full fixture).
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Green + full product run.**
- [ ] **Step 5: Commit** — `feat(brain): MineRun — adopt, arm, complete (part 2)`

---

### Task 10: Brain — readiness, `ensureMine`, `ensureMineFerries`, managed stalls

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift`
- Test: `app/Modules/DirectiveEngine/Tests/BrainMineTests.swift`

**Interfaces:**
- Consumes: `ensureOne(_:matching:snapshot:database:build:)` (Brain.swift:224), `MineSitePlanner`, `MineRecipe`, `HaulRun` pinned mode (Task 7), `Brain.owningStatuses`, `Brain.isGeneralHaul` (:1082).
- Produces:

```swift
enum MineReadiness: Equatable {
    case launch(carrier: String, belt: String)
    case idle(reason: String)
}
static func mineReadiness(view: WorldView, directives: [Directive]) -> MineReadiness
static func mineFerryController(for belt: String, view: WorldView, directives: [Directive]) -> String?
```

Behaviour:

- `mineReadiness`: hub nil → `.idle("no recognised hub")`. `MineRecipe.shortfall(at: hub, ...)` non-empty → `.idle("no printed mine fleet")` (distinguish "nothing printed" from "partially printed" in the reason string: `"mine fleet incomplete — missing <type>×<n>"` when some members exist). `MineRecipe.idleCarrier` nil → `.idle("no idle auto:carrier surge carrier")`. Occupied = `MineRecipe.installedBelts(in:hub:)` ∪ targets of live `mineRun` rows (`owningStatuses`). `MineSitePlanner.site(view:occupiedBelts:)` nil → `.idle("no meshed candidate belt")`. Else `.launch(carrier:belt:)`.
- `ensureMine(snapshot:database:)`: guard `.launch`; `ensureOne(.mineRun, snapshot:database:)` building the row exactly as `ensureSalvage` does (Brain.swift:301 is the template) with `deviceCode: carrier`, `targets: [belt]`, `fleetTag: MineRecipe.fleetTag`, `roamCentre: nil`, `step: MineRun().firstStep`, `originDesignation: snapshot.view.hubLocation.map { SiteAssay.system(of: $0) }`.
- `mineFerryController(for:view:directives:)`: prefer the tagged transport controller at the hub whose `currentDirectiveConfig?["collect"]?.stringValue == belt`; else the lowest-coded tagged, un-reserved (`reservedDevices`), unclaimed-by-another-ferry transport controller at the hub; nil when none.
- `ensureMineFerries(snapshot:database:)`: for each belt in `MineRecipe.installedBelts(in: snapshot.view.devices.values, hub: snapshot.view.hubLocation)` sorted (determinism): `ensureOne(.haulRun, matching: { $0.targets.first == belt }, ...)` building `deviceCode: controller`, `targets: [belt]`, `fleetTag: MineRecipe.fleetTag`, `step: HaulRun().firstStep`. `build` returns nil when `mineFerryController` finds none.
- Call both from `evaluateOnce` after `ensureHaul` (Brain.swift:123): `await ensureMine(...)`, `await ensureMineFerries(...)`.
- `brainManagedKinds` (:692) gains `.mineRun` — its retry-classified stalls get the bounded auto-retry. `mineFleetPrint` stays out: operator-invoked, operator-resolved.

- [ ] **Step 1: Write the failing tests**

Verdict tables over `mineReadiness` (idle reasons for each gate, launch when all pass), plus DB-backed `ensureOne` tests copying the shape of the salvage build's liveness suite (`BrainSalvageTests` — seed a database, run `evaluateOnce`, assert the row):

```
1. full board → a mineRun row appears with targets == [best belt], deviceCode == carrier,
   fleetTag auto:mine
2. a live mineRun row → second tick inserts nothing (liveness)
3. the belt a live mineRun targets is excluded from siting (two candidate belts:
   the live row targets the better one; readiness launches at the second)
4. an installed mine with no pinned haulRun → a haulRun row appears with
   targets == [belt], and the GENERAL haul row (empty targets) is untouched beside it —
   assert both rows coexist and isGeneralHaul distinguishes them
5. brainManagedKinds contains .mineRun and not .mineFleetPrint
6. a reserved carrier (held by another directive) → readiness idles, not launches
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Green + full product run** (the widened `brainManagedKinds` may move existing stall-table tests — if `aStalledHolderReadsDifferentlyFromAHealthyOne`-style assertions break, the fix is the assertion, as in the salvage build).
- [ ] **Step 5: Commit** — `feat(brain): mine readiness, ensureMine, per-mine ferries`

---### Task 11: Report and why-view — the mine goal made legible

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift` (`mineStatus`, `mineHealth`)
- Modify: `app/Modules/DirectiveEngine/Sources/BrainReport.swift`
- Modify: `app/Modules/DirectivesFeature/Sources/BrainWhyGoal.swift`, `BrainWhyView.swift`
- Test: `app/Modules/DirectiveEngine/Tests/BrainMineTests.swift` (extend), `app/Modules/DirectivesFeature/Tests/` why-view suite (extend the existing one that covers salvage/haul lines)

**Interfaces:**
- Produces:
  - `BrainReport.mine: BrainGoalStatus` (default `.idle(reason: "not evaluated")`, like `salvage`/`haul` at BrainReport.swift:297)
  - `public struct BrainMineHealth: Equatable, Sendable { public let belt: String; public let miningActive: Bool; public let surveyActive: Bool; public let ferryInForce: Bool }`
  - `BrainReport.mines: [BrainMineHealth]` (default `[]`)
  - `Brain.mineStatus(directives:view:)` mirroring `haulStatus` (:1124): a live `mineRun` → `.launched(vessel:focus:status:)` with `focus` = the target belt; else readiness → `.ready`/`.idle`.
  - `Brain.mineHealth(view:)` — per installed belt: mining controller `currentDirective == "gather_evenly" && currentDirectiveStatus == "active"`; survey likewise for `belt_search`; ferry = some tagged transport controller's config collects the belt.
  - `BrainWhyGoal.Goal.mine` ("Mine") and per-mine rows rendered in `BrainWhyView.goalLine`'s idiom; a mine with any `false` health flag renders as `.halted` kind (status + static fact phrasing — "halted — mining directive inactive at `<belt>`" violates the card rule; use "mining directive inactive at `<belt>`" under the halted kind, per `brain-survey-goal-build`'s phrasing rule: a status and a static fact, never a status and an active verb).

- [ ] **Step 1: Failing tests** — `mineStatus` verdicts (launched/ready/idle mirror the `haulStatus` tests), `mineHealth` truth table (all-active, lapsed mining, lapsed ferry), report defaults, one render test per new row kind in the feature suite.
- [ ] **Step 2: Verify failure.** **Step 3: Implement.** **Step 4: Green — run `DirectiveEngineTests` AND `DirectivesFeatureTests`.**
- [ ] **Step 5: Commit** — `feat(brain): mine goal status + per-mine health in the why-view`

---

### Task 12: The Print Mine Fleet launcher

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/DirectivesFeature.swift`
- Modify: `app/Modules/DirectivesFeature/Sources/DirectivesListView.swift`
- Test: `app/Modules/DirectivesFeature/Tests/DirectivesFeatureTests.swift` (append a suite)

**Interfaces:**
- Consumes: `DirectiveKind.mineFleetPrint`, `MineFleetPrint().firstStep`, the feature's existing `database` dependency and `uuid`/`date` dependencies (see `NewSalvageRunFeature.swift:170` for the exact `Directive(...)` construction idiom).
- Produces: a `printMineFleetTapped` action presenting a TCA `ConfirmationDialogState`, whose confirm action inserts one `mineFleetPrint` directive.

Behaviour:
- `State`: `@Presents var printMineFleetDialog: ConfirmationDialogState<Action.PrintMineFleet>?`
- `printMineFleetTapped`: if a live `mineFleetPrint` row exists (query `directives` for kind + `Brain.owningStatuses`-equivalent statuses — the feature has the directives in state already; check how the list state holds rows and filter there), present a dialog saying one is already running (single button, no insert). Else present: title "Print a mine fleet?", message "Eleven devices, 3,455 units from hub stock, plus a surge carrier if none is idle. The brain sites and delivers it when complete." with a `.confirm` button.
- `.printMineFleetDialog(.presented(.confirm))`: effect reads the device table (`database.read`), picks the print host — lowest-coded device where `isPrintHub && deviceType != "heaven_vessel" && deviceType != "racing_vessel" && location != nil` — and inserts:

```swift
Directive(
    id: uuid().uuidString, kind: .mineFleetPrint, status: .running,
    deviceCode: host.deviceCode, controllerCode: nil, roamCentre: nil,
    fleetTag: MineRecipe.fleetTag, sourceRelayCode: nil,
    targets: [], targetIndex: 0,
    step: MineFleetPrint().firstStep, stepStartedAt: date.now,
    returnToOrigin: false, originDesignation: nil,
    attentionReason: nil, createdAt: date.now, updatedAt: date.now
)
```

No print host found → present an error dialog ("No autofactory found at the hub."), insert nothing.
- The toolbar button sits beside the existing New Salvage Run button in `DirectivesListView.swift` (find `newSalvageRunTapped`'s button and mirror it): label "Print Mine Fleet", sends `printMineFleetTapped`.
- `DirectivesFeature` needs `import DirectiveEngine` for `MineRecipe`/`MineFleetPrint` if not already imported — check the module's existing imports (it renders `BrainReport`, so likely yes).

- [ ] **Step 1: Failing TestStore test** — tapping presents the dialog; confirming inserts exactly one row of kind `.mineFleetPrint` on the expected host (seed two print-capable devices, assert lowest-coded non-vessel wins); confirming with a live print row inserts nothing.
- [ ] **Step 2: Verify failure.** **Step 3: Implement.** **Step 4: Green — `DirectivesFeatureTests` product.**
- [ ] **Step 5: Commit** — `feat(directives): Print Mine Fleet launcher`

---

### Task 13: The clause-5 seam test

**Files:**
- Create: `app/Modules/DirectiveEngine/Tests/BrainMineSeamTests.swift`

**Interfaces:**
- Consumes: the whole stack. Template: `BrainSalvageSeamTests.swift` — copy its harness shape (seeded database, `evaluateOnce()` through the real `report()`), private fixtures.

- [ ] **Step 1: Write the test + two negative twins**

```
POSITIVE: seed a complete printed auto:mine fleet + idle tagged carrier at the hub,
  a meshed candidate belt (systemDetails row with a classifiable dense belt,
  star positions, a relaying relay device in that system), hub footprint above the
  floor → evaluateOnce() → a .mineRun directive row exists, targets == [the belt],
  and report.mine reads .launched.
NEGATIVE TWIN 1: same world, NO printed fleet → no row, report.mine reads
  .idle("no printed mine fleet").
NEGATIVE TWIN 2: same world, belt's system unmeshed (no relaying relay) → no row,
  report.mine .idle("no meshed candidate belt").
```

- [ ] **Step 2: Run — the positive must PASS against the finished stack; the twins guard the gates.**
- [ ] **Step 3: Mutation-check** (the house rule for seam tests): temporarily force `mineReadiness` to return `.idle` unconditionally, re-run — the positive must go RED and both twins stay GREEN. Revert. Record the check in the task's commit message body.
- [ ] **Step 4: Commit** — `test(brain): mine goal end-to-end seam with negative twins`

---

### Task 14: Full verification, memory, sign-off

- [ ] **Step 1: Full per-product event-stream runs** (one output path each): `DirectiveEngineTests`, `DirectivesFeatureTests`, `GameServicesTests`, `GameModelsTests`, `BobnetFeatureTests`. Zero failures, zero crashes (started == ended, `runEnded` present per product).
- [ ] **Step 2: Comment check** — `./app/scripts/check-comments.sh` over every touched file (repo-root relative paths), plus a hand pass against the budget (header ≤6, `///` ≤3, `//` ≤2, no history/rationale).
- [ ] **Step 3: LSP pass** — build, then `findReferences` on `MineRecipe.shortfall`, `HaulRun.pinnedSource`, `MineSitePlanner.site` to confirm the call graph matches this plan (index is only as fresh as the last build).
- [ ] **Step 4: Write the memory note** `app/.claude/memory/brain-mine-build.md` (build record: what shipped, plan-vs-reality corrections, deferred items — the three planned deviations at the top of this plan graduate to "carried forward" entries if they survived) + one `MEMORY.md` index line.
- [ ] **Step 5: Commit** — `docs(memory): the brain mine goal build record`

## Self-review notes (already applied)

- The spec's `siting`/`releasing` steps and split-queue printing are deliberately reshaped; see "Planned deviations" — reviewers should check tasks against that section before flagging spec drift.
- `gather_resources` never appears in any arm target (Task 9's construction test freezes this).
- Type names cross-checked: `CommandParams.devices` carries attach/detach `targets` (Topology builder), `printTags` avoids colliding with device tags, `HaulTargetPlanner.Assignment`'s memberwise init must be read from source in Task 7 (its field order is not guessed here).
