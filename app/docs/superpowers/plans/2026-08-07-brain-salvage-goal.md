# The brain's salvage goal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The automation brain keeps one Salvage Run and one general Haul Run alive, answers their retryable stalls, and the Salvage Run stops planting relays so `tendMesh` is the sole mesh authority.

**Architecture:** Two new pure readiness verdicts on `Brain`, both launched through one extracted `ensureOne` liveness helper that also absorbs the two shipped call sites. `Brain.brainManagedStall` widens from one directive kind to three, reusing the already-built retry machinery untouched. Then the surgery: four relay steps come out of `SalvageRun`, `SalvageTargetPlanner` narrows to meshed-only systems, and two `AINALRAM` constants become hub-derived.

**Tech Stack:** Swift 6, SwiftPM package at `app/Modules`, Swift Testing (`@Test`/`@Suite`), GRDB via SQLiteData, swift-dependencies.

## Global Constraints

- **Comment budget is hard:** file header ≤ 6 lines, `///` doc ≤ 3 lines, inline `//` ≤ 2 lines. History goes to `.claude/memory/`, never source. Run `./app/scripts/check-comments.sh <paths>` from the repo root.
- **No new tables, no new columns, no migration.** This whole plan is additive-in-behaviour and schema-neutral.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category `Brain` in `Brain.swift`/`WorldView.swift`, `DirectiveEngine` in the mission machines.
- **Read test results from the JSON event stream**, never console text. Use the `swift-test-event-stream` skill. One `--event-stream-output-path` per test product, or output is truncated.
- **Worktree setup before any LSP query:** `cd app/Modules && swift build --build-tests`, then `./scripts/link-index-store.sh`. Without the symlink every reference query silently returns zero.
- **A guard nobody has seen fail is not a guard.** Every regression test in this plan must be demonstrated failing against the pre-fix state before the fix lands. The steps say where.
- **`Device.location` is a SITE, not a system.** Use `SiteAssay.system(of:)` to project. A location handed to a roam-centre slot, or a system handed to a ferry config, is a live bug that most assertions still pass through.
- Test commands run from `app/Modules`.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `DirectiveEngine/Sources/Brain.swift` | The plan loop: verdicts, liveness, stall response | Modify |
| `DirectiveEngine/Sources/BrainReport.swift` | The why-view's value types | Modify (two cases) |
| `DirectiveEngine/Sources/SalvageRun.swift` | The salvage mission machine | Modify (remove four steps) |
| `DirectiveEngine/Sources/SalvageTargetPlanner.swift` | Where a Salvage Run goes next | Modify (meshed-only) |
| `DirectiveEngine/Sources/HaulRun.swift` | The haul mission machine | Modify (derived sink) |
| `DirectivesFeature/Sources/BrainWhySalvage.swift` | The salvage + haul why-view rows | Create |
| `DirectiveEngine/Tests/BrainSalvageGoalTests.swift` | Verdicts, liveness, adoption | Create |
| `DirectiveEngine/Tests/BrainSalvageSeamTests.swift` | The clause-5 e2e and its negative twin | Create |
| `DirectiveEngine/Tests/SalvageRunRelayRemovalTests.swift` | Surgery regressions + step remap | Create |

**Staging.** Tasks 1–8 are additive and mergeable on their own — the brain gains owners without any executor changing behaviour. Tasks 9–13 are the surgery. Stop between 8 and 9 for a live observation window if you want one.

---

### Task 1: Extract the `ensureOne` liveness helper

The in-transaction re-check is the invariant this exists to hold in one place. `tendRestock` and `ensureSurvey` each carry their own copy today.

**Files:**
- Modify: `DirectiveEngine/Sources/Brain.swift:138-257`
- Test: `DirectiveEngine/Tests/BrainSalvageGoalTests.swift` (create)

**Interfaces:**
- Produces: `Brain.ensureOne(_ kind: DirectiveKind, matching: (Directive) -> Bool, snapshot: Snapshot, database: any DatabaseWriter, build: () -> Directive?) async` — `matching` narrows liveness beyond kind (Task 4 needs it for the haul fleet tag); pass `{ _ in true }` where kind alone is the rule.

- [ ] **Step 1: Write the failing test**

```swift
import Dependencies
import Foundation
import GameModels
import SQLiteData
import Testing
@testable import DirectiveEngine

@Suite("Brain salvage goal")
struct BrainSalvageGoalTests {
    @Test("a second tick against a lagging read still inserts exactly one row")
    func ensureOneIsIdempotentAcrossTicks() async throws {
        try await withDependencies {
            $0.defaultDatabase = try GameDatabase.bootstrap()
            $0.uuid = .incrementing
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let now = Date(timeIntervalSince1970: 1_000)

            // Both ticks read a snapshot holding NO live row — the second tick's
            // read predates the first tick's insert, which is the real race.
            let stale = Brain.Snapshot(
                view: WorldView(
                    devices: [:], starPositions: [:], meshSystems: [],
                    salvageUnits: [:], eventSystems: [], hubLocation: nil, now: now
                ),
                directives: [], log: [:], hubFootprint: nil
            )
            let brain = Brain(now: now)
            for _ in 0..<2 {
                await brain.ensureOne(
                    .haulRun, matching: { _ in true }, snapshot: stale, database: database
                ) {
                    Directive.fixture(id: "H1", kind: .haulRun, deviceCode: "CTRL")
                }
            }

            let rows = try await database.read { db in
                try Directive.where { $0.kind.eq(DirectiveKind.haulRun) }.fetchAll(db)
            }
            #expect(rows.count == 1)
        }
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter ensureOneIsIdempotentAcrossTicks`
Expected: FAIL — `value of type 'Brain' has no member 'ensureOne'`, and also `'Snapshot' is inaccessible due to 'private' protection level`.

- [ ] **Step 3: Widen `Snapshot` to internal**

`Brain.Snapshot` is `private struct Snapshot: Sendable` at `Brain.swift:361`. `@testable import` reaches `internal`, never `private`, so the test above cannot construct one. Drop the `private`:

```swift
struct Snapshot: Sendable {
```

Nothing else changes — it stays an implementation detail of the module, just a testable one.

- [ ] **Step 4: Add the helper**

In `Brain.swift`, beside `tendRestock`:

```swift
/// Keep exactly one live directive matching `kind` and `matching`. The
/// liveness read and the insert are separate steps, so the check runs AGAIN
/// inside the write transaction — a row from the previous tick lands in between.
func ensureOne(
    _ kind: DirectiveKind,
    matching: @escaping (Directive) -> Bool,
    snapshot: Snapshot,
    database: any DatabaseWriter,
    build: () -> Directive?
) async {
    guard !Task.isCancelled else { return }
    let live = snapshot.directives.contains {
        $0.kind == kind && Self.owningStatuses.contains($0.status) && matching($0)
    }
    guard !live else { return }
    guard let directive = build() else { return }

    do {
        try await database.write { db in
            let live = try Directive
                .where { $0.kind.eq(kind) }
                .fetchAll(db)
                .contains { Self.owningStatuses.contains($0.status) && matching($0) }
            guard !live else { return }
            try Directive.insert { directive }.execute(db)
            logger.info(
                "\(String(describing: kind), privacy: .public) \(directive.id, privacy: .public) launched on \(directive.deviceCode, privacy: .public)"
            )
        }
    } catch {
        logger.error("\(String(describing: kind), privacy: .public) launch failed: \(error)")
    }
}
```

- [ ] **Step 5: Run the test and watch it pass**

Run: `swift test --filter ensureOneIsIdempotentAcrossTicks`
Expected: PASS.

- [ ] **Step 6: Move `ensureSurvey` onto it, behaviour unchanged**

Replace `ensureSurvey`'s body (`Brain.swift:217-257`) with a call, keeping the verdict and the row build exactly as they are:

```swift
private func ensureSurvey(snapshot: Snapshot, database: any DatabaseWriter) async {
    guard case let .launch(carrier, roamCentre) = Self.surveyReadiness(view: snapshot.view) else { return }
    @Dependency(\.uuid) var uuid
    await ensureOne(.surveyRun, matching: { _ in true }, snapshot: snapshot, database: database) {
        Directive(
            id: uuid().uuidString,
            kind: .surveyRun,
            status: .running,
            deviceCode: carrier,
            controllerCode: nil, roamCentre: roamCentre, fleetTag: nil, sourceRelayCode: nil,
            targets: [], targetIndex: 0,
            step: SurveyRun().firstStep,
            stepStartedAt: now,
            returnToOrigin: false,
            originDesignation: snapshot.view.devices[carrier]?.location.map { SiteAssay.system(of: $0) },
            attentionReason: nil,
            createdAt: now, updatedAt: now
        )
    }
}
```

Leave `tendRestock` alone in this task — its demand-maintenance branch runs on an EXISTING row and does not fit `ensureOne`. Fold only its insert path onto the helper if it reads cleanly; if it does not, leave it and say so in the commit.

- [ ] **Step 7: Run the whole engine suite for regressions**

Run: `swift test --filter DirectiveEngineTests --event-stream-output-path /tmp/t1.jsonl`
Expected: zero failures. The shipped survey tests (`aSurveyLaunchWritesOneRow`, `stoppingClearsTheWhyViewsFeed`) must still pass unchanged — that is the proof the extraction is behaviour-neutral.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/Brain.swift app/Modules/DirectiveEngine/Tests/BrainSalvageGoalTests.swift
git commit -m "refactor(brain): hold the one-live-row invariant in one helper"
```

---

### Task 2: `Brain.salvageReadiness`

**Files:**
- Modify: `DirectiveEngine/Sources/Brain.swift` (beside `surveyReadiness`, ~line 878)
- Test: `DirectiveEngine/Tests/BrainSalvageGoalTests.swift`

**Interfaces:**
- Consumes: `WorldView` (Task 0, shipped), `SalvageRun.controller(aboard:in:)`, `SalvageRun.adoptedDrones(of:aboard:in:)`, `SalvageTargetPlanner.nextTarget`.
- Produces: `Brain.SalvageReadiness` — `.launch(carrier: String, roamCentre: String)` / `.idle(reason: String)`; `Brain.salvageCarrierTag = "auto:salvage"`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("Salvage readiness")
struct SalvageReadinessTests {
    @Test("an untagged fleet is idle and names the missing tag")
    func noTaggedCarrierIsIdle() {
        let view = WorldView(
            devices: ["V1": .fixture(code: "V1", type: "heaven_vessel", tags: [])],
            starPositions: ["AINALRAM": .fixture()],
            meshSystems: ["AINALRAM"], salvageUnits: ["AINALRAM": 500],
            eventSystems: [], hubLocation: "AINALRAM-BELT-1",
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(Brain.salvageReadiness(view: view, directives: []) == .idle(reason: "no auto:salvage vessel"))
    }

    @Test("a tagged carrier with no controller aboard is idle, never a stall")
    func unstagedFleetIsIdle() {
        let view = WorldView(
            devices: ["V1": .fixture(code: "V1", type: "heaven_vessel", tags: ["auto:salvage"])],
            starPositions: ["AINALRAM": .fixture()],
            meshSystems: ["AINALRAM"], salvageUnits: ["AINALRAM": 500],
            eventSystems: [], hubLocation: "AINALRAM-BELT-1",
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(Brain.salvageReadiness(view: view, directives: []) == .idle(reason: "V1 has no mining controller aboard"))
    }

    @Test("no meshed salvage system means idle even with a staged fleet")
    func unmeshedFrontierIsIdle() {
        let view = WorldView.stagedSalvageFleet(meshSystems: ["AINALRAM"], salvageUnits: ["FARAWAY": 900])
        #expect(Brain.salvageReadiness(view: view, directives: []) == .idle(reason: "no meshed salvage system with units left"))
    }

    @Test("a staged fleet and a meshed target launches")
    func stagedAndReachableLaunches() {
        let view = WorldView.stagedSalvageFleet(
            meshSystems: ["AINALRAM", "ALPAHARD"], salvageUnits: ["ALPAHARD": 900]
        )
        #expect(Brain.salvageReadiness(view: view, directives: []) == .launch(carrier: "V1", roamCentre: "AINALRAM"))
    }
}
```

Add the fixture helper in the same file (private, so it cannot capture other suites' call sites — the shared-helper trap from the survey fleet repair build):

```swift
private extension WorldView {
    static func stagedSalvageFleet(
        meshSystems: Set<String>, salvageUnits: [String: Double]
    ) -> WorldView {
        let vessel = Device.fixture(code: "V1", type: "heaven_vessel", tags: ["auto:salvage"])
        let controller = Device.fixture(
            code: "C1", type: "ami_mining_controller", tags: ["auto:salvage"], stowedIn: "V1"
        )
        let drone = Device.fixture(
            code: "D1", type: "mining_drone", tags: ["auto:salvage"], stowedIn: "V1", controlledBy: "C1"
        )
        var positions = ["AINALRAM": Position.fixture()]
        for system in meshSystems.union(salvageUnits.keys) where positions[system] == nil {
            positions[system] = .fixture()
        }
        return WorldView(
            devices: [vessel, controller, drone].reduce(into: [:]) { $0[$1.deviceCode] = $1 },
            starPositions: positions,
            meshSystems: meshSystems, salvageUnits: salvageUnits,
            eventSystems: [], hubLocation: "AINALRAM-BELT-1",
            now: Date(timeIntervalSince1970: 0)
        )
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter SalvageReadinessTests`
Expected: FAIL — `type 'Brain' has no member 'salvageReadiness'`.

- [ ] **Step 3: Implement the verdict**

```swift
/// The salvage verdict for `view`: a carrier to launch on, or a named idle.
/// **No stall case** — an unstaged fleet declines rather than manufacturing a
/// `noMiningControllerAboard` for a human.
enum SalvageReadiness: Equatable, Sendable {
    case launch(carrier: String, roamCentre: String)
    case idle(reason: String)
}

static let salvageCarrierTag = "auto:salvage"

/// Takes `directives` as well as `view` — unlike `surveyReadiness`, which
/// checks no reservations. Passing `[]` would make the free-carrier gate
/// vacuous rather than lenient.
static func salvageReadiness(view: WorldView, directives: [Directive]) -> SalvageReadiness {
    let reserved = reservedDevices(directives: directives, devices: view.devices)
    guard let carrier = view.devices.values
        .filter({ $0.deviceType == carrierDeviceType && $0.hasTag(salvageCarrierTag) })
        .filter({ !reserved.contains($0.deviceCode) })
        .min(by: { $0.deviceCode < $1.deviceCode })
    else {
        return .idle(reason: "no \(salvageCarrierTag) vessel")
    }

    let world = WorldSnapshot(devices: view.devices, openOperations: [:], now: view.now)
    guard let controller = SalvageRun.controller(aboard: carrier, in: world) else {
        return .idle(reason: "\(carrier.deviceCode) has no mining controller aboard")
    }
    guard !SalvageRun.adoptedDrones(of: controller, aboard: carrier, in: world).isEmpty else {
        return .idle(reason: "\(carrier.deviceCode)'s controller \(controller.deviceCode) has adopted no drone aboard")
    }

    guard let hub = view.hubLocation else {
        return .idle(reason: "the anchor has no resolvable location")
    }
    let centre = SiteAssay.system(of: hub)
    guard view.starPositions[centre] != nil else {
        return .idle(reason: "roam centre \(centre) is not in the census")
    }
    guard view.salvageUnits.contains(where: { view.meshSystems.contains($0.key) && $0.value > 0 }) else {
        return .idle(reason: "no meshed salvage system with units left")
    }
    return .launch(carrier: carrier.deviceCode, roamCentre: centre)
}
```

- [ ] **Step 4: Run and watch them pass**

Run: `swift test --filter SalvageReadinessTests`
Expected: PASS, four tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/Brain.swift app/Modules/DirectiveEngine/Tests/BrainSalvageGoalTests.swift
git commit -m "feat(brain): the salvage readiness verdict and its named idle reasons"
```

---

### Task 3: Keep one Salvage Run alive

**Files:**
- Modify: `DirectiveEngine/Sources/Brain.swift` (`report()` ~line 117, plus a new `ensureSalvage`)
- Test: `DirectiveEngine/Tests/BrainSalvageGoalTests.swift`

**Interfaces:**
- Consumes: `ensureOne` (Task 1), `salvageReadiness` (Task 2).
- Produces: nothing new; `report()` gains one call.

- [ ] **Step 1: Write the failing tests**

```swift
/// One tick of just the salvage liveness path, against `seeded` rows.
private func tickSalvage(seeded: [Directive]) async throws -> [Directive] {
    try await withDependencies {
        $0.defaultDatabase = try GameDatabase.bootstrap()
        $0.uuid = .incrementing
    } operation: {
        @Dependency(\.defaultDatabase) var database
        let now = Date(timeIntervalSince1970: 1_000)
        try await database.write { db in
            for row in seeded { try Directive.insert { row }.execute(db) }
        }
        let snapshot = Brain.Snapshot(
            view: .stagedSalvageFleet(
                meshSystems: ["AINALRAM", "ALPAHARD"], salvageUnits: ["ALPAHARD": 900]
            ),
            directives: seeded, log: [:], hubFootprint: nil
        )
        await Brain(now: now).ensureSalvage(snapshot: snapshot, database: database)
        return try await database.read { db in
            try Directive.where { $0.kind.eq(DirectiveKind.salvageRun) }.fetchAll(db)
        }
    }
}

@Test("a ready verdict writes one salvageRun row carrying the fleet tag")
func aReadyVerdictLaunchesOneSalvageRun() async throws {
    let rows = try await tickSalvage(seeded: [])
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.deviceCode == "V1")
    #expect(row.fleetTag == SalvageRun.defaultFleetTag)
    #expect(row.roamCentre == "AINALRAM")
    #expect(row.step == SalvageRun().firstStep)
    #expect(row.returnToOrigin == false)
    #expect(row.controllerCode == nil)   // claimed at preflight, never eager-written
}

@Test("an operator-launched salvage run satisfies the goal and is not duplicated")
func anExistingRunIsAdoptedNotDuplicated() async throws {
    let seeded = Directive.fixture(
        id: "OPERATOR", kind: .salvageRun, deviceCode: "OTHER",
        status: .running, fleetTag: SalvageRun.defaultFleetTag
    )
    let rows = try await tickSalvage(seeded: [seeded])
    #expect(rows.count == 1)
    #expect(rows.first?.id == "OPERATOR")
}

@Test("a needsAttention salvage run still counts as live")
func aHaltedRunBlocksRelaunch() async throws {
    let seeded = Directive.fixture(
        id: "HALTED", kind: .salvageRun, deviceCode: "V1",
        status: .needsAttention, attentionReason: .salvageBodyNotDepleted,
        fleetTag: SalvageRun.defaultFleetTag
    )
    let rows = try await tickSalvage(seeded: [seeded])
    #expect(rows.count == 1)
    #expect(rows.first?.id == "HALTED")
}
```

`ensureSalvage`, `ensureHaul` and `ensureSurvey` must be **internal, not `private`**, for these to compile — the same widening Task 1 applied to `Snapshot`.

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter aReadyVerdictLaunchesOneSalvageRun`
Expected: FAIL — no row inserted.

- [ ] **Step 3: Implement `ensureSalvage` and call it**

```swift
private func ensureSalvage(snapshot: Snapshot, database: any DatabaseWriter) async {
    guard case let .launch(carrier, roamCentre) = Self.salvageReadiness(view: snapshot.view, directives: snapshot.directives) else { return }
    @Dependency(\.uuid) var uuid
    await ensureOne(.salvageRun, matching: { _ in true }, snapshot: snapshot, database: database) {
        Directive(
            id: uuid().uuidString,
            kind: .salvageRun,
            status: .running,
            deviceCode: carrier,
            controllerCode: nil,
            roamCentre: roamCentre,
            fleetTag: SalvageRun.defaultFleetTag,
            sourceRelayCode: nil,
            targets: [], targetIndex: 0,
            step: SalvageRun().firstStep,
            stepStartedAt: now,
            returnToOrigin: false,
            originDesignation: snapshot.view.devices[carrier]?.location.map { SiteAssay.system(of: $0) },
            attentionReason: nil,
            createdAt: now, updatedAt: now
        )
    }
}
```

In `report()`, after `ensureSurvey`:

```swift
await ensureSurvey(snapshot: snapshot, database: database)
await ensureSalvage(snapshot: snapshot, database: database)
```

No same-tick guard against a grow dispatch is needed, for the reason the survey build recorded: `salvageReadiness` never touches `plan`/`ranked`/`decision`, and the fleets are disjoint by tag.

- [ ] **Step 4: Run and watch them pass**

Run: `swift test --filter BrainSalvageGoalTests --event-stream-output-path /tmp/t3.jsonl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/Brain.swift app/Modules/DirectiveEngine/Tests/BrainSalvageGoalTests.swift
git commit -m "feat(brain): keep one salvage run alive"
```

---

### Task 4: `Brain.haulReadiness`, scoped to the general drainer

The liveness rule counts only rows carrying `HaulRun.defaultFleetTag`, so `mine`'s future per-site rows neither satisfy it nor get relaunched around.

**Files:**
- Modify: `DirectiveEngine/Sources/Brain.swift`
- Test: `DirectiveEngine/Tests/BrainSalvageGoalTests.swift`

**Interfaces:**
- Consumes: `HaulRun.controllers(in:tag:)`, `HaulRun.defaultFleetTag`.
- Produces: `Brain.HaulReadiness` — `.launch(controller: String)` / `.idle(reason: String)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("Haul readiness")
struct HaulReadinessTests {
    @Test("no tagged ferry controller is idle")
    func noControllerIsIdle() {
        let view = WorldView(
            devices: [:], starPositions: [:], meshSystems: [], salvageUnits: [:],
            eventSystems: [], hubLocation: "AINALRAM-BELT-1", now: Date(timeIntervalSince1970: 0)
        )
        #expect(Brain.haulReadiness(view: view) == .idle(reason: "no auto:haul controller offering ferry"))
    }

    @Test("no hub on the mesh is idle")
    func noHubIsIdle() {
        let controller = Device.fixture(
            code: "T1", type: "ami_transport_controller",
            tags: ["auto:haul"], availableDirectives: ["ferry"]
        )
        let view = WorldView(
            devices: ["T1": controller], starPositions: [:], meshSystems: [],
            salvageUnits: [:], eventSystems: [], hubLocation: nil,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(Brain.haulReadiness(view: view) == .idle(reason: "no print hub on the mesh"))
    }

    @Test("a tagged ferry controller and a hub launches on the lowest code")
    func aTaggedControllerLaunches() {
        // two controllers T2 and T1; expect .launch(controller: "T1")
    }

    @Test("a per-site haul row does not satisfy the general drainer's liveness")
    func aPerSiteRowDoesNotCountAsTheGeneralDrainer() {
        let perSite = Directive.fixture(
            id: "PS", kind: .haulRun, deviceCode: "T9", fleetTag: "auto:haul:ALPAHARD"
        )
        #expect(Brain.isGeneralHaul(perSite) == false)
        let general = Directive.fixture(
            id: "G", kind: .haulRun, deviceCode: "T1", fleetTag: HaulRun.defaultFleetTag
        )
        #expect(Brain.isGeneralHaul(general) == true)
    }
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter HaulReadinessTests`
Expected: FAIL — no `haulReadiness`, no `isGeneralHaul`.

- [ ] **Step 3: Implement**

```swift
enum HaulReadiness: Equatable, Sendable {
    case launch(controller: String)
    case idle(reason: String)
}

/// Whether `directive` is THE general drainer rather than one of `mine`'s
/// future per-site rows. A nil tag counts: the run falls back to the default.
static func isGeneralHaul(_ directive: Directive) -> Bool {
    (directive.fleetTag ?? HaulRun.defaultFleetTag) == HaulRun.defaultFleetTag
}

static func haulReadiness(view: WorldView) -> HaulReadiness {
    let controllers = HaulRun.controllers(in: view.devices.values, tag: HaulRun.defaultFleetTag)
    guard let controller = controllers.first else {
        return .idle(reason: "no \(HaulRun.defaultFleetTag) controller offering ferry")
    }
    guard view.hubLocation != nil else {
        return .idle(reason: "no print hub on the mesh")
    }
    return .launch(controller: controller.deviceCode)
}
```

`HaulRun.controllers` already sorts by device code, so `.first` is the lowest and the choice is reproducible across ticks.

- [ ] **Step 4: Run and watch them pass**

Run: `swift test --filter HaulReadinessTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/Brain.swift app/Modules/DirectiveEngine/Tests/BrainSalvageGoalTests.swift
git commit -m "feat(brain): the haul readiness verdict, scoped to the general drainer"
```

---

### Task 5: Keep one general Haul Run alive

**Files:**
- Modify: `DirectiveEngine/Sources/Brain.swift`
- Test: `DirectiveEngine/Tests/BrainSalvageGoalTests.swift`

**Interfaces:**
- Consumes: `ensureOne`, `haulReadiness`, `isGeneralHaul`.

- [ ] **Step 1: Write the failing test**

```swift
@Test("a per-site haul row alive does not stop the general drainer launching")
func theGeneralDrainerLaunchesBesideAPerSiteRow() async throws {
    try await withDependencies {
        $0.defaultDatabase = try GameDatabase.bootstrap()
        $0.uuid = .incrementing
    } operation: {
        @Dependency(\.defaultDatabase) var database
        let now = Date(timeIntervalSince1970: 1_000)
        let perSite = Directive.fixture(
            id: "PERSITE", kind: .haulRun, deviceCode: "T9",
            status: .running, fleetTag: "auto:haul:ALPAHARD"
        )
        try await database.write { db in try Directive.insert { perSite }.execute(db) }

        let controller = Device.fixture(
            code: "T1", type: "ami_transport_controller",
            tags: ["auto:haul"], availableDirectives: ["ferry"]
        )
        let snapshot = Brain.Snapshot(
            view: WorldView(
                devices: ["T1": controller], starPositions: [:], meshSystems: [],
                salvageUnits: [:], eventSystems: [], hubLocation: "AINALRAM-BELT-1", now: now
            ),
            directives: [perSite], log: [:], hubFootprint: nil
        )
        await Brain(now: now).ensureHaul(snapshot: snapshot, database: database)

        let rows = try await database.read { db in
            try Directive.where { $0.kind.eq(DirectiveKind.haulRun) }.fetchAll(db)
        }
        #expect(rows.count == 2)
        #expect(rows.filter { $0.fleetTag == HaulRun.defaultFleetTag }.count == 1)
        #expect(rows.contains { $0.id == "PERSITE" })
    }
}
```

This is the forward-shaping assertion. It is the one test that would fail if someone later writes the liveness rule over `kind` alone.

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter theGeneralDrainerLaunchesBesideAPerSiteRow`
Expected: FAIL — only the seeded row exists.

- [ ] **Step 3: Implement `ensureHaul` and call it**

```swift
private func ensureHaul(snapshot: Snapshot, database: any DatabaseWriter) async {
    guard case let .launch(controller) = Self.haulReadiness(view: snapshot.view) else { return }
    @Dependency(\.uuid) var uuid
    await ensureOne(.haulRun, matching: Self.isGeneralHaul, snapshot: snapshot, database: database) {
        Directive(
            id: uuid().uuidString,
            kind: .haulRun,
            status: .running,
            deviceCode: controller,
            controllerCode: nil, roamCentre: nil,
            fleetTag: HaulRun.defaultFleetTag,
            sourceRelayCode: nil,
            targets: [], targetIndex: 0,
            step: HaulRun().firstStep,
            stepStartedAt: now,
            returnToOrigin: false,
            originDesignation: snapshot.view.hubLocation.map { SiteAssay.system(of: $0) },
            attentionReason: nil,
            createdAt: now, updatedAt: now
        )
    }
}
```

In `report()`, after `ensureSalvage`:

```swift
await ensureHaul(snapshot: snapshot, database: database)
```

- [ ] **Step 4: Run and watch it pass**

Run: `swift test --filter BrainSalvageGoalTests --event-stream-output-path /tmp/t5.jsonl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/Brain.swift app/Modules/DirectiveEngine/Tests/BrainSalvageGoalTests.swift
git commit -m "feat(brain): keep one general haul run alive"
```

---

### Task 6: Widen the brain-managed stall set

**Files:**
- Modify: `DirectiveEngine/Sources/Brain.swift:593-596`
- Test: `DirectiveEngine/Tests/BrainSalvageGoalTests.swift`

**Interfaces:**
- Consumes: `DirectiveAttentionReason.brainDisposition` (shipped), `Brain.stallResponse`, `Brain.retryBudget`, `Brain.retryInterval`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("Brain-managed stalls widen by kind")
struct WidenedStallTests {
    @Test("a retryable salvage stall is retried, then escalates on the fourth look")
    func salvageBodyNotDepletedRetriesThenEscalates() {
        let now = Date(timeIntervalSince1970: 10_000)
        let stalled = Directive.fixture(
            id: "S1", kind: .salvageRun, deviceCode: "V1",
            status: .needsAttention, attentionReason: .salvageBodyNotDepleted, step: "awaiting"
        )
        // No prior resolutions: the first look retries.
        #expect(
            Brain.stallResponse(for: stalled, log: [], now: now)
                == .retry(directiveID: "S1", reason: .salvageBodyNotDepleted, attempt: 1, lastAttemptAt: nil)
        )
        // Three spent attempts exhaust the budget.
        let spent = (0..<3).map { i in
            DirectiveLogEntry.fixture(
                directiveID: "S1", kind: .resolved, step: "awaiting",
                occurredAt: now.addingTimeInterval(Double(-3_600 * (3 - i)))
            )
        }
        #expect(
            Brain.stallResponse(for: stalled, log: spent, now: now)
                == .escalated(directiveID: "S1", reason: .salvageBodyNotDepleted)
        )
    }

    @Test("an escalate-classified salvage stall escalates on sight")
    func dronesNotRecoveredEscalatesImmediately() {
        let stalled = Directive.fixture(
            id: "S2", kind: .salvageRun, deviceCode: "V1",
            status: .needsAttention, attentionReason: .dronesNotRecovered, step: "verifying"
        )
        #expect(
            Brain.stallResponse(for: stalled, log: [], now: Date(timeIntervalSince1970: 0))
                == .escalated(directiveID: "S2", reason: .dronesNotRecovered)
        )
    }

    @Test("a haul stall is managed too")
    func haulCommandRejectedIsManaged() {
        let stalled = Directive.fixture(
            id: "H1", kind: .haulRun, deviceCode: "T1",
            status: .needsAttention, attentionReason: .commandRejected, step: "confirming"
        )
        #expect(Brain.brainManagedStall(stalled) == .commandRejected)
    }

    @Test("a survey stall stays the operator's")
    func surveyStallsAreStillUntouched() {
        let stalled = Directive.fixture(
            id: "Q1", kind: .surveyRun, deviceCode: "F1",
            status: .needsAttention, attentionReason: .commandRejected, step: "travelling"
        )
        #expect(Brain.brainManagedStall(stalled) == nil)
        #expect(Brain.stallResponse(for: stalled, log: [], now: Date(timeIntervalSince1970: 0)) == nil)
    }
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter WidenedStallTests`
Expected: FAIL on the salvage and haul cases (`brainManagedStall` returns nil); the survey case passes already, which is the point — it pins what must NOT change.

- [ ] **Step 3: Widen the gate**

```swift
/// The directive kinds the brain launched and may therefore answer. A run the
/// OPERATOR launched of another kind stays the operator's.
static let brainManagedKinds: Set<DirectiveKind> = [.relayRun, .salvageRun, .haulRun]

static func brainManagedStall(_ directive: Directive) -> DirectiveAttentionReason? {
    guard brainManagedKinds.contains(directive.kind), directive.status == .needsAttention else { return nil }
    return directive.attentionReason
}
```

Nothing else changes. `stallResponse`, `retryEpisode`, `respondToStalls` and the budget all read through this one gate.

- [ ] **Step 4: Run and watch them pass**

Run: `swift test --filter WidenedStallTests`
Expected: PASS, four tests.

- [ ] **Step 5: Run the whole engine suite**

Run: `swift test --filter DirectiveEngineTests --event-stream-output-path /tmp/t6.jsonl`
Expected: zero failures. Pay attention to `BrainStallResponseTests` — several of its assertions enumerate `DirectiveAttentionReason.allCases` and may assume relay-only membership.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/Brain.swift app/Modules/DirectiveEngine/Tests/BrainSalvageGoalTests.swift
git commit -m "feat(brain): answer salvage and haul stalls, not only relay ones"
```

---

### Task 7: Two why-view rows

**Files:**
- Modify: `DirectiveEngine/Sources/BrainReport.swift`, `DirectiveEngine/Sources/Brain.swift`
- Create: `DirectivesFeature/Sources/BrainWhySalvage.swift`
- Test: `DirectivesFeature/Tests/BrainWhySalvageTests.swift`

**Interfaces:**
- Produces: `BrainSalvageStatus` and `BrainHaulStatus`, both shaped exactly like the shipped `BrainSurveyStatus` (`.launched` / `.ready` / `.idle`); two new `BrainReport` fields.

- [ ] **Step 1: Write the failing tests**

The phrasing rule from the survey build is the thing under test — **state a status and a static fact, never a status and an active verb.**

```swift
@Test("the four salvage card states all read differently")
func theSalvageCardStatesAllReadDifferently() {
    #expect(BrainWhySalvage.sentence(.launched(carrier: "V1", system: "ALPAHARD", status: .running))
        == "working ALPAHARD — carrier V1")
    #expect(BrainWhySalvage.sentence(.launched(carrier: "V1", system: "ALPAHARD", status: .needsAttention))
        == "halted, last target ALPAHARD — carrier V1")
    #expect(BrainWhySalvage.sentence(.launched(carrier: "V1", system: "ALPAHARD", status: .paused))
        == "paused, last target ALPAHARD — carrier V1")
    #expect(BrainWhySalvage.sentence(.ready(carrier: "V1")) == "ready to launch — carrier V1")
}

@Test("an idle waiting on the mesh says so by name")
func meshWaitIsNamedNotHiddenAsAbsence() {
    #expect(
        BrainWhySalvage.sentence(.idle(reason: "no meshed salvage system with units left"))
            == "idle — no meshed salvage system with units left"
    )
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter BrainWhySalvageTests`
Expected: FAIL — `BrainWhySalvage` does not exist.

- [ ] **Step 3: Implement**

Add `BrainSalvageStatus` / `BrainHaulStatus` to `BrainReport.swift` mirroring `BrainSurveyStatus` (including its `LaunchedStatus` nested enum, and the same rule that `.launched` carries the live row's own status). Add `salvage:` and `haul:` to `BrainReport` and its `init`. Add `Brain.salvageStatus(directives:view:)` and `Brain.haulStatus(directives:view:)` mirroring `surveyStatus` — reading an already-live row rather than re-deriving, and falling through to the verdict otherwise. Note that `haulStatus` must match on `isGeneralHaul`, not kind alone.

Then `BrainWhySalvage.swift` in `DirectivesFeature`, rendering both rows beside the shipped survey card. Designations render in a mono token (`.rcMonoSmall`); never inline `design: .monospaced`.

- [ ] **Step 4: Run and watch them pass**

Run: `swift test --filter BrainWhySalvageTests`
Expected: PASS.

- [ ] **Step 5: Check the window-pin trap**

Any `fixedSize` `Text` in non-scrolling chrome pins the window's minimum height. If the new rows live in chrome rather than a `List` row, add `lineLimit` — the `RCErrorBanner` idiom.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/BrainReport.swift app/Modules/DirectiveEngine/Sources/Brain.swift app/Modules/DirectivesFeature/Sources/BrainWhySalvage.swift app/Modules/DirectivesFeature/Tests/BrainWhySalvageTests.swift
git commit -m "feat(brain): surface the salvage and haul verdicts on the why-view"
```

---

### Task 8: Pin the reservation-closure item the third carrier armed

**Files:**
- Test: `DirectiveEngine/Tests/BrainSalvageGoalTests.swift`

No production change. This is the guard the spec requires, so a future cross-link fails in the suite instead of as a fleet that quietly stops salvaging.

- [ ] **Step 1: Write the test**

```swift
@Test("the three tagged carriers reserve into three disjoint sets")
func taggedCarriersDoNotReserveEachOther() {
    // A live-shaped fixture: three heaven vessels, each with its own controller
    // and drones stowed aboard, one directive per fleet.
    let devices = Device.threeFleetFixture()   // tendmesh / salvage / survey
    let directives = [
        Directive.fixture(id: "R", kind: .relayRun, deviceCode: "MESH1"),
        Directive.fixture(id: "S", kind: .salvageRun, deviceCode: "SALV1", fleetTag: "auto:salvage"),
        Directive.fixture(id: "Q", kind: .surveyRun, deviceCode: "SURV1"),
    ]
    for directive in directives {
        let reserved = Brain.reservedDevices(directives: [directive], devices: devices)
        let carriers = ["MESH1", "SALV1", "SURV1"].filter { reserved.contains($0) }
        #expect(carriers == [directive.deviceCode], "\(directive.id) reserved \(carriers)")
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter taggedCarriersDoNotReserveEachOther`
Expected: PASS on today's fleet shape. **If it fails, stop and report** — that means the closure already crosses fleets and `salvageReadiness` would idle silently. Do not "fix" it by loosening the assertion.

- [ ] **Step 3: Commit**

```bash
git add app/Modules/DirectiveEngine/Tests/BrainSalvageGoalTests.swift
git commit -m "test(brain): pin the three carriers into disjoint reservation sets"
```

**Stage A ends here.** The brain now owns liveness and stalls for both runs, and no executor has changed behaviour.

---

### Task 9: Derive the haul sink from the hub

**Files:**
- Modify: `DirectiveEngine/Sources/HaulRun.swift:51,119,140,153,159-165,272,305`
- Test: `DirectiveEngine/Tests/HaulRunTests.swift`

**Interfaces:**
- Produces: `HaulRun.deliverySink(in world: WorldSnapshot) -> String`; `hasTakenSomeHaulConfig(_:delivery:)` and `drainedPile(of:delivery:)` gain a `delivery` parameter.
- `HaulRun.deliveryLocation` **survives** as the documented fallback, because two `DirectivesFeature` views read it with no `WorldSnapshot` in hand.

- [ ] **Step 1: Write the failing test**

```swift
@Test("the sink follows the hub, and a controller on the old value is repointed once")
func theSinkFollowsTheHub() {
    let world = WorldSnapshot.fixture(
        devices: [
            "HUB": .fixture(code: "HUB", type: "autofactory", location: "SOL-3-1"),
            "RELAY": .fixture(code: "RELAY", type: "ftl_relay", location: "SOL-5-L4", status: "relaying"),
            "T1": .fixture(
                code: "T1", type: "ami_transport_controller", tags: ["auto:haul"],
                availableDirectives: ["ferry"],
                currentDirective: "ferry",
                currentDirectiveConfig: ["collect": .string("ALPAHARD-7"), "deliver": .string("AINALRAM-BELT-1")]
            ),
        ]
    )
    #expect(HaulRun.deliverySink(in: world) == "SOL-3-1")
    // The old constant is no longer in force, so the run repoints exactly once.
    #expect(HaulRun.hasTakenSomeHaulConfig(world.device("T1")!, delivery: "SOL-3-1") == false)
}

@Test("no hub falls back to the constant rather than hauling nowhere")
func noHubFallsBackToTheConstant() {
    let world = WorldSnapshot.fixture(devices: [:])
    #expect(HaulRun.deliverySink(in: world) == HaulRun.deliveryLocation)
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter theSinkFollowsTheHub`
Expected: FAIL — no `deliverySink`, and `hasTakenSomeHaulConfig` takes one argument.

- [ ] **Step 3: Implement**

```swift
/// Where this run delivers: the recognised hub, or `deliveryLocation` when no
/// hub is on the mesh. One recognition rule, shared with `RelayRun`.
static func deliverySink(in world: WorldSnapshot) -> String {
    RelayRun.hubLocation(in: world) ?? deliveryLocation
}
```

Thread it through the four sites: `plans` passes `delivery: deliverySink(in: world)`; `isInForce` compares against `deliverySink(in: world)`; `hasTakenSomeHaulConfig` and `drainedPile` take a `delivery: String` parameter; the config builder at line 272 uses `Self.deliverySink(in: world)`. Update `deliveryLocation`'s doc to say it is the fallback, not the sink.

- [ ] **Step 4: Run and watch it pass, then run the whole haul suite**

Run: `swift test --filter HaulRunTests --event-stream-output-path /tmp/t9.jsonl`
Expected: PASS. The ~30 existing `HaulRun.deliveryLocation` fixtures keep working because their worlds have no hub, so `deliverySink` returns the fallback. Any that DO have a hub will now assert against the derived value — fix those fixtures, do not weaken the assertion.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/HaulRun.swift app/Modules/DirectiveEngine/Tests/HaulRunTests.swift
git commit -m "fix(haul): deliver to the recognised hub, not a constant"
```

---

### Task 10: Derive the salvage roam anchor

**Files:**
- Modify: `DirectiveEngine/Sources/SalvageRun.swift:69,287`
- Test: `DirectiveEngine/Tests/SalvageRunRelayRemovalTests.swift` (create)

- [ ] **Step 1: Write the failing test**

```swift
@Test("a row with no roam centre anchors on the hub's SYSTEM, not its location")
func theAnchorIsTheHubsSystem() {
    let world = WorldSnapshot.fixture(devices: [
        "HUB": .fixture(code: "HUB", type: "autofactory", location: "SOL-3-1"),
        "RELAY": .fixture(code: "RELAY", type: "ftl_relay", location: "SOL-5-L4", status: "relaying"),
        "V1": .fixture(code: "V1", type: "heaven_vessel", location: nil),
    ])
    let directive = Directive.fixture(
        id: "S1", kind: .salvageRun, deviceCode: "V1", roamCentre: nil, targets: []
    )
    #expect(SalvageRun().nextAction(directive: directive, world: world) == .extendQueue(centre: "SOL"))
}
```

`SOL`, never `SOL-3-1`. A location in the roam-centre slot sends the census read at a site.

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter theAnchorIsTheHubsSystem`
Expected: FAIL — `.extendQueue(centre: "AINALRAM")`.

- [ ] **Step 3: Implement**

Replace the `baseSystem` fallback at line 287:

```swift
let centre = directive.roamCentre
    ?? Self.system(of: vessel)
    ?? Self.hubSystem(in: world)
    ?? Self.baseSystem
```

```swift
/// The hub's SYSTEM — `RelayRun.hubLocation` is a location, and a location in
/// a roam-centre slot aims the census read at a site.
static func hubSystem(in world: WorldSnapshot) -> String? {
    RelayRun.hubLocation(in: world).map { SiteAssay.system(of: $0) }
}
```

- [ ] **Step 4: Run and watch it pass**

Run: `swift test --filter theAnchorIsTheHubsSystem`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/SalvageRun.swift app/Modules/DirectiveEngine/Tests/SalvageRunRelayRemovalTests.swift
git commit -m "fix(salvage): anchor an unset roam centre on the hub's system"
```

---

### Task 11: Narrow the planner to meshed systems

**Files:**
- Modify: `DirectiveEngine/Sources/SalvageTargetPlanner.swift:28-46,89-155`
- Test: `DirectiveEngine/Tests/SalvageTargetPlannerTests.swift`

**Interfaces:**
- Produces: `Target` loses `needsRelay`; `nextTarget` loses `relayRange`; `RankKey` loses `meshedRank`.
- `SalvageTargetPlanner.relayRangeLY` **stays** — `Brain.reclaimRangeLY` derives from it.

- [ ] **Step 1: Write the failing test, and demonstrate it failing against the pre-fix code**

```swift
@Test("a rich unmeshed system is not offered")
func anUnmeshedRichSystemIsNotOffered() {
    let stars = [
        "MESHED": Star.fixture(designation: "MESHED", position: .init(x: 0, y: 0, z: 0)),
        "NEAR": Star.fixture(designation: "NEAR", position: .init(x: 3, y: 0, z: 0)),
    ]
    let assays = [
        SiteAssay.fixture(system: "MESHED", body: "MESHED-1", totals: ["carbon": 100]),
        SiteAssay.fixture(system: "NEAR", body: "NEAR-1", totals: ["carbon": 9_000]),
    ]
    let target = SalvageTargetPlanner.nextTarget(
        assays: assays, stars: stars, meshSystems: ["MESHED"], attempted: [], vessel: nil
    )
    #expect(target?.system == "MESHED")
}
```

`NEAR` sits 3 ly from `MESHED`, inside the 7.5 ly relay range, and carries 90× the units. Under the shipped ranking it wins as a one-hop candidate. That is exactly the behaviour being removed.

- [ ] **Step 2: Run it against the unmodified planner**

Run: `swift test --filter anUnmeshedRichSystemIsNotOffered`
Expected: FAIL with `target?.system == "NEAR"`. **Record this output in the commit body** — this is the demonstration the house rule requires.

- [ ] **Step 3: Narrow the planner**

Drop `needsRelay` from `Target`, drop `relayRange` from `nextTarget`, and replace the reachability test with membership:

```swift
for (system, systemUnits) in units {
    guard meshSystems.contains(system), let star = stars[system] else { continue }
    let key = RankKey(
        units: systemUnits,
        distance: vessel.map { $0.distance(to: star.position) } ?? 0,
        designation: system
    )
    if let bestKey, !key.beats(bestKey) { continue }
    bestKey = key
    best = Target(system: system, units: systemUnits)
}
```

`RankKey.beats` loses its `meshedRank` clause; the order becomes units desc, distance asc, designation asc. Update the file header — it still describes a frontier expanding under its own steam.

- [ ] **Step 4: Run and watch it pass, then the suite**

Run: `swift test --filter SalvageTargetPlannerTests --event-stream-output-path /tmp/t11.jsonl`
Expected: PASS. Several shipped tests assert `needsRelay` — delete those assertions rather than the tests, unless the whole test was about emplacement.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/SalvageTargetPlanner.swift app/Modules/DirectiveEngine/Tests/SalvageTargetPlannerTests.swift
git commit -m "feat(salvage): rank only meshed systems, tendMesh owns the frontier"
```

---

### Task 12: Remove relay emplacement from the Salvage Run

**Files:**
- Modify: `DirectiveEngine/Sources/SalvageRun.swift` (steps at 32-37, 61; routing at 132-134, 147, 302-309, 371-390; helpers `emplace`/`activate`/`confirmRelay`/`restock`/`lagrangePoint`/`relay(aboard:)`/`deployedRelay(near:)`)
- Test: `DirectiveEngine/Tests/SalvageRunRelayRemovalTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@Test("arriving at a target always goes to the bots, never to emplacing")
func arrivalAlwaysGoesToTheBots() {
    // The vessel is parked AT an UNMESHED target with no relay aboard — the
    // exact shape that routed to `emplacing` before.
    let world = WorldSnapshot.fixture(devices: [
        "V1": .fixture(code: "V1", type: "heaven_vessel", location: "ALPAHARD-7"),
    ])
    let directive = Directive.fixture(
        id: "S1", kind: .salvageRun, deviceCode: "V1",
        step: SalvageRun.Step.travelling, targets: ["ALPAHARD"], targetIndex: 0
    )
    #expect(
        SalvageRun().nextAction(directive: directive, world: world)
            == .advanceStep(nextStep: SalvageRun.Step.deployingBots)
    )
}

@Test("a row parked on a removed step advances rather than waiting")
func aRowOnARemovedStepIsRemappedForward() {
    for step in ["emplacing", "activating", "confirmingRelay", "restocking"] {
        let directive = Directive.fixture(
            id: "S1", kind: .salvageRun, deviceCode: "V1", step: step, targets: ["ALPAHARD"]
        )
        #expect(
            SalvageRun().nextAction(directive: directive, world: .salvageFixture())
                == .advanceStep(nextStep: SalvageRun.Step.deployingBots),
            "\(step) must advance, not wait"
        )
    }
}

@Test("preflight departs for an unmeshed-in-snapshot target without a relay aboard")
func preflightDepartsWithoutARelay() {
    let now = Date(timeIntervalSince1970: 5_000)
    let world = WorldSnapshot.fixture(
        devices: [
            "V1": .fixture(code: "V1", type: "heaven_vessel", tags: ["auto:salvage"], updatedAt: now),
            "C1": .fixture(
                code: "C1", type: "ami_mining_controller", tags: ["auto:salvage"],
                stowedIn: "V1", updatedAt: now
            ),
            "D1": .fixture(
                code: "D1", type: "mining_drone", tags: ["auto:salvage"],
                stowedIn: "V1", controlledBy: "C1", updatedAt: now
            ),
        ],
        now: now
    )
    let directive = Directive.fixture(
        id: "S1", kind: .salvageRun, deviceCode: "V1",
        step: SalvageRun.Step.preflight, targets: ["ALPAHARD"], targetIndex: 0,
        fleetTag: SalvageRun.defaultFleetTag
    )
    #expect(
        SalvageRun().nextAction(directive: directive, world: world)
            == .assignController(deviceCode: "C1", nextStep: SalvageRun.Step.travelling)
    )
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter SalvageRunRelayRemovalTests`
Expected: FAIL on all three. Record the pre-fix routing in the commit body.

- [ ] **Step 3: Do the surgery**

Delete the four step constants, their four `case` arms in `nextAction`, and the `emplace`/`activate`/`confirmRelay`/`restock` methods along with `lagrangePoint(in:)`, `relay(aboard:in:)`, `deployedRelay(near:in:)`, `relayDeviceType`, `relayPollInterval`, `activationDeadline` and the `setDeviceTags` untag.

In `preflight`, delete the meshed/relay branch (lines 302-309) and drop the relay from `stagingRows`. In `travel`, replace the ternary with `.advanceStep(nextStep: Step.deployingBots)`.

Add the remap, above the `default:` arm in `nextAction`:

```swift
/// Steps this machine no longer has. A row parked on one when the surgery
/// merged must move on — `default:` waits, which would freeze it holding a fleet.
static let retiredSteps: Set<String> = ["emplacing", "activating", "confirmingRelay", "restocking"]
```

```swift
case let step where Self.retiredSteps.contains(step):
    return .advanceStep(nextStep: Step.deployingBots)
```

Update the file header: the run no longer plants relays.

- [ ] **Step 4: Run and watch them pass, then the whole engine suite**

Run: `swift test --filter DirectiveEngineTests --event-stream-output-path /tmp/t12.jsonl`
Expected: zero failures. Shipped `SalvageRunTests` covering emplacement will not compile — delete those tests; they cover behaviour that no longer exists. `awaitingRelayRestock` keeps its enum case and loses its producer, which is intended.

- [ ] **Step 5: Check the one-funnel invariant**

The salvage fleet repair build records it: **no exit from a target system may reach `.advanceTarget` directly.** Confirm the bot deploy/recall chain is still the only funnel now that the relay chain ahead of it is gone — the `restocking` detour used to be safe *because* deploy happened after the relay chain.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/SalvageRun.swift app/Modules/DirectiveEngine/Tests/SalvageRunRelayRemovalTests.swift
git commit -m "feat(salvage): stop planting relays, tendMesh is the sole mesh authority"
```

---

### Task 13: The end-to-end guard through the real seam

Clause 5 exists because of this feature: `SalvageTargetPlanner` once had zero production callers while every unit test passed. A planner unit test cannot discharge it.

**Files:**
- Create: `DirectiveEngine/Tests/BrainSalvageSeamTests.swift`

- [ ] **Step 1: Write the e2e**

```swift
@Test("a brain-launched salvage run reaches a meshed system and works it")
func aSalvageLaunchRunsAllTheWayToAWorkedSystem() async throws {
    // Drive the REAL DirectiveEngineCore, not a fixture:
    //   1. seed a staged auto:salvage fleet at the hub, one meshed salvage system
    //   2. tick the brain once — assert exactly one salvageRun row appears
    //   3. let the supervisor adopt it and run to `awaiting`
    //   4. assert the exact command array through the real CommandGovernor.liveValue
    //      — travel, then set_directive, then launch. NO deploy and NO activate:
    //      that absence is the surgery's end-to-end proof.
}
```

- [ ] **Step 2: Write the negative twin**

```swift
@Test("a salvage system that never depletes does not advance, and the brain keeps ranking it")
func aSystemThatNeverDepletesStallsRatherThanLooping() async throws {
    // The in-suite negative twin: without it the e2e above passes on a machine
    // that dispatches nothing.
}
```

- [ ] **Step 3: Prove the e2e is not blind**

Mutation-check it, the way the tendMesh build found its own e2e blind to two rails: temporarily make `salvageReadiness` always return `.idle` and confirm the e2e goes RED. If it stays green it is asserting nothing. Revert the mutation.

- [ ] **Step 4: Run the full package**

Run one event-stream path per product — the multi-target truncation trap:

```bash
swift test --filter DirectiveEngineTests   --event-stream-output-path /tmp/de.jsonl
swift test --filter DirectivesFeatureTests --event-stream-output-path /tmp/df.jsonl
swift test --filter GameModelsTests        --event-stream-output-path /tmp/gm.jsonl
swift test --filter GameServicesTests      --event-stream-output-path /tmp/gs.jsonl
```

Expected: zero failures in each. Discriminate suites from functions on the `test` record's `kind` field when counting. `theSupervisorAdoptsTheRowTheBrainLaunched` is a known whole-package-only failure and is pre-existing — do not attribute it to this branch.

- [ ] **Step 5: Run the comment checker**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources app/Modules/DirectivesFeature/Sources
```

Exit 0 is a floor, not proof. Re-read the new docs against the budget by eye.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Tests/BrainSalvageSeamTests.swift
git commit -m "test(brain): drive the salvage goal end to end through the real seam"
```

---

## Deliberately not in this plan

- **The two `DirectivesFeature` reads of `HaulRun.deliveryLocation`** (`DirectiveTargetsSection.swift:75`, `NewHaulRunSheet.swift:100`) keep showing the fallback constant. Both are launcher/summary chrome with no `WorldSnapshot` in hand; showing the live sink there needs a plumbing decision that is not this capability's. Note it in the build record.
- **Deleting the `awaitingRelayRestock` enum case.** It loses its producer here; removing the case ripples through the disposition table and its tests for no behavioural gain.
- **`restockRun` and `surveyRun` stall management.** Out of the widened set on purpose.
- **Per-site haul rows.** `mine`'s job; only the liveness rule is shaped to accept them.
- **`Brain.reservedDevices`' adoption closure.** Task 8 pins its current behaviour rather than changing it.

## Definition of done

Every Robustness clause in the spec has a named test, all four test products are green, both surgery regressions have been *demonstrated* failing against pre-fix code, and the e2e has been mutation-checked. Then write the build record to `app/.claude/memory/brain-salvage-build.md` with its `MEMORY.md` index line, recording what deviated from this plan — the deviations are the part worth keeping.
