# Salvage Run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `salvageRun` directive kind that flies a dedicated vessel to salvage systems it picks itself, plants an FTL relay so the system joins the mesh, mines every salvage body with `gather_salvage`, verifies the drones came home, and moves on — with no operator input.

**Architecture:** A new `SalvageRun: MissionStepMachine` in the existing `DirectiveEngine`, plus a pure `SalvageTargetPlanner` that ranks candidate systems so the relay frontier expands outward. One new `MissionAction` case (`refreshFleet`) gives missions a one-request authoritative read of a tagged fleet — the primitive that a location-scoped read structurally cannot provide. The Haul Run half of the spec is **a separate plan**; this one ends with piles of resources sitting at salvage bodies in newly-meshed systems.

**Tech Stack:** Swift 6, SwiftPM (`app/Modules`), Swift Testing, SQLiteData/GRDB, swift-dependencies, swift-openapi-generator, TCA (feature modules only).

**Spec:** `docs/superpowers/specs/2026-07-30-salvage-run-design.md`. Read §2 (the authority rule), §5 (the step machine) and §7 (the planner) before starting.

## Global Constraints

- **Migrations are append-only.** A schema change appends a new `SchemaMigration` to `GameDatabase.manifest`; never edit, rename or reorder a shipped one. Adding a column means a new `ALTER TABLE` migration, never an edit to the `CREATE TABLE`. `SchemaManifestTests` freezes the identifier list; `GoldenSchemaTests` snapshots the schema and is regenerated only with `RC_REGENERATE_SCHEMA_FIXTURE=1`.
- **`DirectiveEngine` is a non-feature module**: `Dependencies`, no TCA. Do not add `ComposableArchitecture` to it.
- **Step machines are pure.** No I/O, no `Date()` (use `world.now`), no randomness. Every effect is the returned `MissionAction`.
- **Loud test defaults.** A client's `testValue` uses `unimplemented(...)` with an inert `placeholder:`, never a quiet stub.
- **Logging** is `os.Logger` only, subsystem `name.pennig.replicould`, category `DirectiveEngine` / `Devices`.
- **Pure logic never lives as a static on a SwiftUI `View`** — it traps with signal 5 under `swift test`. Top-level enums only.
- **System and location designations render in mono tokens** (`.rcMono`, `.rcMonoSmall`, `.rcBodyEmphMono`) in any UI.
- **Read test results from the Swift Testing JSON event stream**, never by scraping console text. Use the `swift-test-event-stream` skill.

**Worktree setup — do this first, once:**

```bash
cd app/Modules && swift build --build-tests && ./scripts/link-index-store.sh
```

A fresh worktree has an empty index; the build populates it and the script symlinks SwiftPM's advertised index-store path to where the swiftbuild engine actually writes. Without the symlink every LSP reference query silently returns zero.

**Running a single suite** (used by every task below):

```bash
cd app/Modules && swift test --filter <SuiteName> \
  --event-stream-output-path "$TMPDIR/rc-events.jsonl" --event-stream-version 0
jq -r 'select(.kind == "testCaseEnded") | "\(.payload.testCase.id) \(.payload.testCase.result // "")"' \
  "$TMPDIR/rc-events.jsonl"
```

## File Structure

| File | Responsibility |
| --- | --- |
| `GameServices/Sources/DevicesClient.swift` (modify) | add `fetchByTag` — one paged walk of `GET /v1/devices/tags/{tag}` |
| `GameModels/Sources/Directive.swift` (modify) | `DirectiveKind.salvageRun`, `Directive.fleetTag`, its migration, four new `DirectiveAttentionReason` cases |
| `GameDatabase/Sources/GameDatabase.swift` (modify) | append the `fleetTag` migration to `manifest` |
| `DirectiveEngine/Sources/MissionStepMachine.swift` (modify) | `MissionAction.refreshFleet(tag:thenStall:)` |
| `DirectiveEngine/Sources/DirectiveEngine.swift` (modify) | resolve `.refreshFleet` |
| `DirectiveEngine/Sources/SalvageTargetPlanner.swift` (create) | pure: which system next, and does it need a relay |
| `DirectiveEngine/Sources/SalvageRun.swift` (create) | the step machine |
| `DirectiveEngine/Sources/MissionRegistry.swift` (modify) | register `SalvageRun()` |
| `DirectiveEngine/Tests/SalvageTargetPlannerTests.swift` (create) | planner fixtures |
| `DirectiveEngine/Tests/SalvageRunTests.swift` (create) | step-machine fixtures |
| `GameServices/Tests/DevicesClientTests.swift` (modify) | `fetchByTag` |
| `DirectivesFeature/Sources/NewSalvageRunSheet.swift` (create) | launcher |

`SalvageRun.swift` will land around 350 lines — comparable to `SurveyRun.swift` (478). If it passes ~500, split the fleet queries into `SalvageRun+Fleet.swift` rather than letting it grow.

---

### Task 1: `DevicesClient.fetchByTag`

The primitive the whole design rests on: a fleet-wide list filtered by tag, so it reports **stowed** and **travelling** devices that `?location=` structurally cannot (stowing clears `location`, dropping the device out of the location index entirely).

**Files:**
- Modify: `GameServices/Sources/DevicesClient.swift`
- Test: `GameServices/Tests/DevicesClientTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `DevicesClient.fetchByTag: @Sendable (_ tag: String) async throws -> [Device]`.

- [ ] **Step 1: Write the failing test**

Add to `GameServices/Tests/DevicesClientTests.swift`:

```swift
@Test func fetchByTagReturnsStowedAndTravellingDevices() async throws {
    // The whole point of the tag scope: a stowed device reports no location at
    // all, and a travelling one reports null — both must still come back.
    let devices = try await withDependencies {
        $0.devicesClient.fetchByTag = { tag in
            #expect(tag == "auto:salvage")
            return [
                Device.fixture(deviceCode: "VESSEL", location: "TOSLIT-3"),
                Device.fixture(deviceCode: "DRONE", location: nil, stowedInDeviceCode: "VESSEL"),
                Device.fixture(deviceCode: "PLATE", location: nil, status: "travelling"),
            ]
        }
    } operation: {
        @Dependency(\.devicesClient) var client
        return try await client.fetchByTag("auto:salvage")
    }

    #expect(devices.map(\.deviceCode) == ["VESSEL", "DRONE", "PLATE"])
    #expect(devices[1].stowedInDeviceCode == "VESSEL")
}

@Test func fetchByTagIsUnimplementedByDefault() async {
    // Loud defaults: a suite that forgets to stub must fail, not quietly get [].
    await #expect(processExitsWith: .failure) {
        @Dependency(\.devicesClient) var client
        _ = try? await client.fetchByTag("auto:salvage")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter DevicesClientTests`
Expected: FAIL — `value of type 'DevicesClient' has no member 'fetchByTag'`.

- [ ] **Step 3: Add the client property and live implementation**

In `DevicesClient` (after `fetchAtLocation`):

```swift
    /// Every device carrying `tag` (`GET /v1/devices/tags/{tag}`, paged).
    ///
    /// This is the ONE scope that answers "where is my whole fleet" correctly.
    /// `fetchAtLocation` answers PRESENCE and cannot see a stowed device —
    /// stowing clears `location`, which drops the row out of the location index
    /// (six drones stowed aboard a vessel returned exactly one row, the vessel,
    /// probed live 2026-07-29). A tag filter touches location not at all, so a
    /// stowed device comes back with its `stowedInDeviceCode` intact and a
    /// travelling one comes back with a null location (probed live 2026-07-30).
    ///
    /// **Not the authoritative full fleet.** Callers reconcile what it returns
    /// and must never follow it with `Reconciler.pruneDevices` — every untagged
    /// device is absent by construction.
    public var fetchByTag: @Sendable (_ tag: String) async throws -> [Device]
```

In `liveValue` (after `fetchAtLocation:`):

```swift
        fetchByTag: { tag in
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.date) var date
            // One client for the whole walk, and an issue-time stamp per page —
            // same reasoning as `walk`: a page reconciles by when it was asked
            // for, so a slow page can't regress a newer single-device read.
            let client = gameClient()
            var devices: [Device] = []
            var cursor: Int?
            repeat {
                let issuedAt = date.now
                let output = try await client.getV1DevicesTagsTag(
                    path: .init(tag: tag),
                    query: .init(cursor: cursor, limit: Self.pageSize)
                )
                let body = try output.ok.body.json
                devices.append(contentsOf: (body.devices ?? []).map { Device(schema: $0, fetchedAt: issuedAt) })
                cursor = body.nextCursor
            } while cursor != nil
            logger.info("fetched \(devices.count) device(s) tagged \(tag, privacy: .public)")
            return devices
        },
```

In `testValue`:

```swift
        fetchByTag: unimplemented("DevicesClient.fetchByTag", placeholder: []),
```

- [ ] **Step 4: Verify the generated operation name**

The generated method comes from the path, not an operationId. Confirm it before trusting the code above:

```bash
cd app/Modules && grep -rn "func getV1DevicesTags" \
  .build/plugins/outputs/modules/API/destination/OpenAPIGenerator/GeneratedSources/Client.swift
```

Expected: one match. If the name differs (e.g. `getV1DevicesTagsTag` vs `getV1DevicesTagTag`), use what the generator actually emitted and adjust `path:`/`query:` to the generated shapes.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter DevicesClientTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Modules/GameServices/Sources/DevicesClient.swift Modules/GameServices/Tests/DevicesClientTests.swift
git commit -m "Read a fleet by tag, so stowed devices stop being invisible"
```

---

### Task 2: The directive row — kind, fleet tag, stall reasons

**Files:**
- Modify: `GameModels/Sources/Directive.swift`
- Modify: `GameDatabase/Sources/GameDatabase.swift:71` (append to `manifest`)
- Test: `GameModels/Tests/DirectiveSchemaTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DirectiveKind.salvageRun`; `Directive.fleetTag: String?`; `Directive.addFleetTag` migration; `DirectiveAttentionReason` cases `.noMiningControllerAboard`, `.noMiningDroneAboard`, `.awaitingRelayRestock`, `.relayActivationFailed`.

- [ ] **Step 1: Write the failing test**

Add to `GameModels/Tests/DirectiveSchemaTests.swift`:

```swift
@Test func salvageRunKindHasATitle() {
    #expect(DirectiveKind.salvageRun.title == "Salvage Run")
}

@Test func newAttentionReasonsCarryGuidance() {
    // Every stall the engine can produce must name a fix — the panel renders
    // `guidance` verbatim, and an empty one reads as a dead end.
    for reason in [
        DirectiveAttentionReason.noMiningControllerAboard,
        .noMiningDroneAboard,
        .awaitingRelayRestock,
        .relayActivationFailed,
    ] {
        #expect(!reason.displayName.isEmpty)
        #expect(!reason.guidance.isEmpty)
    }
}

@Test func fleetTagRoundTripsThroughTheRow() throws {
    let database = try GameDatabase.bootstrap()
    let directive = Directive(
        id: "d1", kind: .salvageRun, status: .running, deviceCode: "VESSEL",
        fleetTag: "auto:salvage", targets: ["TOSLIT"], targetIndex: 0,
        step: "preflight", stepStartedAt: .distantPast, returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: .distantPast, updatedAt: .distantPast
    )
    try database.write { try Directive.insert { directive }.execute($0) }
    let read = try database.read { try Directive.all.fetchAll($0) }
    #expect(read.first?.fleetTag == "auto:salvage")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter DirectiveSchemaTests`
Expected: FAIL — `type 'DirectiveKind' has no member 'salvageRun'`.

- [ ] **Step 3: Add the kind, the reasons, the column and the migration**

In `DirectiveKind`, add the case and its title arm:

```swift
    case salvageRun
```
```swift
        case .salvageRun: "Salvage Run"
```

In `DirectiveAttentionReason`, add four cases with their `displayName` and `guidance` arms:

```swift
    /// No AMI mining controller is stowed aboard the vessel. Staging is the
    /// player's job — a Salvage Run uses what is already aboard and adopted.
    case noMiningControllerAboard
    /// The mining controller has no adopted drone stowed aboard the vessel.
    case noMiningDroneAboard
    /// The vessel is out of FTL relays and the next target needs one. It has
    /// returned to base; stow relays aboard and retry.
    case awaitingRelayRestock
    /// The relay was deployed but never came up — `activate` was rejected, or
    /// no `relay.activated` arrived before the backstop.
    case relayActivationFailed
```
```swift
        case .noMiningControllerAboard: "No mining controller aboard"
        case .noMiningDroneAboard: "No mining drone aboard"
        case .awaitingRelayRestock: "Out of FTL relays"
        case .relayActivationFailed: "Relay didn't come up"
```
```swift
        case .noMiningControllerAboard:
            "Stow an AMI mining controller aboard the vessel, then retry."
        case .noMiningDroneAboard:
            "Stow a mining drone aboard the vessel and adopt it with the controller, then retry."
        case .awaitingRelayRestock:
            "The vessel is at base with no relays left. Stow FTL relays aboard, then retry."
        case .relayActivationFailed:
            "The relay was deployed but never started relaying. Check it at the Lagrange point, then retry or skip this target."
```

In `Directive`, add the stored property (after `roamCentre`), the init parameter with a `nil` default, and the assignment:

```swift
    /// The tag identifying every device this run drives (`auto:salvage`).
    ///
    /// A tag rather than a device list because `GET devices/tags/{tag}` is the
    /// only scope that reports a STOWED device — the state a staged mining kit
    /// spends its whole life in. Nil for kinds that resolve their fleet some
    /// other way (Survey Run reads `stowedInDeviceCode` directly).
    public var fleetTag: String?
```

Append the migration to the `extension Directive` schema block — **a new one, never an edit to `createDirectives`**:

```swift
    /// A separate migration, not an edit to any above: all three have shipped
    /// and are recorded in real databases, so editing one means it silently
    /// never runs again.
    public static let addFleetTag = SchemaMigration("Add 'fleetTag' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "fleetTag" TEXT
            """
        )
        .execute(db)
    }
```

Append to `GameDatabase.manifest`, **after** `Directive.addRoamCentre` (append-only — never insert mid-list):

```swift
        Directive.addFleetTag,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter DirectiveSchemaTests`
Expected: PASS.

- [ ] **Step 5: Update the frozen schema fixtures**

`SchemaManifestTests` freezes the manifest's identifier list and `GoldenSchemaTests` snapshots the resulting schema; both fail now, correctly.

```bash
cd app/Modules && swift test --filter SchemaManifestTests
```

Add `"Add 'fleetTag' to 'directives'"` to the frozen list in `SchemaManifestTests` at the **end**, then regenerate the golden schema:

```bash
cd app/Modules && RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --filter GoldenSchemaTests
cd app/Modules && swift test --filter "SchemaManifestTests|GoldenSchemaTests"
```

Expected: PASS. Inspect the regenerated fixture's diff — it must show exactly one added column and nothing else.

- [ ] **Step 6: Commit**

```bash
git add Modules/GameModels Modules/GameDatabase
git commit -m "Give a directive a fleet tag and a salvage kind"
```

---

### Task 3: `MissionAction.refreshFleet`

Missions need "read my whole tagged fleet authoritatively, then ask me again". `.refreshDevices` does this for a **named** list; that costs one request per device and cannot discover a device the local rows don't already associate with the run. One tag request replaces both.

**Files:**
- Modify: `DirectiveEngine/Sources/MissionStepMachine.swift`
- Modify: `DirectiveEngine/Sources/DirectiveEngine.swift`
- Test: `DirectiveEngine/Tests/DirectiveEngineTests.swift`

**Interfaces:**
- Consumes: `DevicesClient.fetchByTag` (Task 1).
- Produces: `case refreshFleet(tag: String, thenStall: DirectiveAttentionReason?)` on `MissionAction`, resolved by the engine exactly like `.refreshDevices` — refresh, re-ask once, stall with `thenStall` if the machine asks again (or `wait` when `thenStall` is nil).

- [ ] **Step 1: Write the failing test**

Add to `DirectiveEngine/Tests/DirectiveEngineTests.swift`:

```swift
@Test func refreshFleetReadsTheTagThenReAsksTheMachine() async throws {
    let reads = LockIsolated<[String]>([])
    // A scripted machine: demand a refresh first, then proceed. Exactly the
    // shape a preflight uses.
    let machine = ScriptedMachine(actions: [
        .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard),
        .advanceStep(nextStep: "travelling"),
    ])
    // ... engine harness as in the existing refreshDevices tests ...
    try await withDependencies {
        $0.devicesClient.fetchByTag = { tag in
            reads.withValue { $0.append(tag) }
            return [Device.fixture(deviceCode: "DRONE", stowedInDeviceCode: "VESSEL")]
        }
    } operation: {
        try await engine.evaluateOnce(directive: directive)
    }

    #expect(reads.value == ["auto:salvage"])
    let row = try database.read { try Directive.all.fetchAll($0) }.first
    #expect(row?.step == "travelling")
    #expect(row?.status == .running)
}

@Test func refreshFleetStallsWhenTheMachineStillWantsARefresh() async throws {
    // Bounded to ONE round — a machine that asks twice gets the carried stall,
    // never a loop.
    let machine = ScriptedMachine(actions: [
        .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard),
        .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard),
    ])
    // ... same harness ...
    let row = try database.read { try Directive.all.fetchAll($0) }.first
    #expect(row?.status == .needsAttention)
    #expect(row?.attentionReason == .noMiningDroneAboard)
}
```

Copy the exact harness (engine construction, `ScriptedMachine`, `LockIsolated`) from the existing `.refreshDevices` tests in this file rather than inventing one — they already wire `TestClock`, the in-memory database and the registry override.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter DirectiveEngineTests`
Expected: FAIL — `type 'MissionAction' has no member 'refreshFleet'`.

- [ ] **Step 3: Add the case**

In `MissionStepMachine.swift`, beside `refreshDevices`:

```swift
    /// The same demand as `.refreshDevices`, scoped to a TAG instead of a device
    /// list: `GET devices/tags/{tag}` in ONE request, reconciled, then the
    /// machine is asked again.
    ///
    /// Prefer this wherever a mission owns a tagged fleet. `.refreshDevices`
    /// costs one request per named device and can only refresh rows the mission
    /// already knows to name; a tag read is one request whatever the fleet size
    /// and returns members the local rows had not yet associated with the run.
    ///
    /// Unlike `.refreshDevicesInSystem` it CAN answer questions about stowed
    /// devices — a tag filter never touches `location`, so stowing does not
    /// erase the row from the scope. That is precisely the gate
    /// `.refreshDevicesInSystem` cannot serve.
    ///
    /// Bounded to one round, exactly like the other refresh cases: if the
    /// re-asked machine wants another refresh, the engine stalls with
    /// `thenStall` — or waits, when that is nil.
    case refreshFleet(tag: String, thenStall: DirectiveAttentionReason?)
```

- [ ] **Step 4: Resolve it in the engine**

Find where `DirectiveEngineCore` resolves `.refreshDevices` (the `resolveRefresh` path) and add a sibling arm. Reuse the existing reconcile-and-re-ask helper; only the *fetch* differs:

```swift
        case let .refreshFleet(tag, thenStall):
            // One request for the whole fleet. Reconciled through the same path
            // as every other device read, so provenance (`firstSeenAt`) and the
            // issue-time ordering guard are preserved.
            let devices = (try? await devicesClient.fetchByTag(tag)) ?? []
            // NEVER prune after this: every untagged device is absent by
            // construction, and treating those absences as "gone" deletes the
            // fleet.
            try await reconciler.reconcileDevices(devices)
            return try await reAsk(directive: directive, thenStall: thenStall)
```

Match the surrounding code's actual helper names — `reAsk` above is a placeholder for whatever the `.refreshDevices` arm already calls. If a read failure should be distinguishable, mirror `.refreshDevices` exactly: it treats a failed read as "no new information" and lets the re-ask decide.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter DirectiveEngineTests`
Expected: PASS, and every pre-existing test in the suite still passes.

- [ ] **Step 6: Commit**

```bash
git add Modules/DirectiveEngine
git commit -m "Let a mission refresh its fleet by tag in one request"
```

---

### Task 4: `SalvageTargetPlanner`

Pure. Decides which system the run works next, and whether that system needs a relay planted. The ranking is what makes the mesh frontier expand: prefer somewhere already meshed, then somewhere one relay-hop out, then the richest, then the nearest.

**Files:**
- Create: `DirectiveEngine/Sources/SalvageTargetPlanner.swift`
- Test: `DirectiveEngine/Tests/SalvageTargetPlannerTests.swift`

**Interfaces:**
- Consumes: `SiteAssay`, `Star`, `Position` (UniverseModels).
- Produces:
  ```swift
  SalvageTargetPlanner.relayRangeLY: Double            // 7.5
  SalvageTargetPlanner.Target: Equatable, Sendable     // .system: String, .units: Double, .needsRelay: Bool
  SalvageTargetPlanner.nextTarget(
      assays: [SiteAssay], stars: [String: Star], meshSystems: Set<String>,
      attempted: Set<String>, vessel: Position?, relayRange: Double = relayRangeLY
  ) -> Target?
  SalvageTargetPlanner.meshSystems(in: [Device]) -> Set<String>
  ```

- [ ] **Step 1: Write the failing tests**

Create `DirectiveEngine/Tests/SalvageTargetPlannerTests.swift`:

```swift
import Foundation
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite struct SalvageTargetPlannerTests {
    /// Stars laid out on the x-axis so distances are readable by eye.
    private func star(_ designation: String, x: Double) -> Star {
        Star(designation: designation, positionX: x, positionY: 0, positionZ: 0)
    }

    private func assay(_ system: String, body: String, units: Double) -> SiteAssay {
        SiteAssay(
            id: "\(body)-SAL-1", body: body, system: system,
            siteType: "salvage", totals: ["structural": units], assayedAt: .distantPast
        )
    }

    @Test func prefersAnAlreadyMeshedSystemOverARicherUnmeshedOne() {
        let stars = ["HOME": star("HOME", x: 0), "MESHED": star("MESHED", x: 3), "RICH": star("RICH", x: 5)]
        let target = SalvageTargetPlanner.nextTarget(
            assays: [assay("MESHED", body: "MESHED-1", units: 100),
                     assay("RICH", body: "RICH-1", units: 9000)],
            stars: stars, meshSystems: ["HOME", "MESHED"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        )
        // Meshed wins on the FIRST key even at 90x less salvage: no relay to
        // plant and no vessel needed to grant authority afterwards.
        #expect(target == .init(system: "MESHED", units: 100, needsRelay: false))
    }

    @Test func prefersAOneHopSystemOverAnUnreachableRicherOne() {
        let stars = [
            "HOME": star("HOME", x: 0),
            "NEAR": star("NEAR", x: 7),      // 7 ly from HOME's relay — inside 7.5
            "FAR": star("FAR", x: 20),       // nothing within range
        ]
        let target = SalvageTargetPlanner.nextTarget(
            assays: [assay("NEAR", body: "NEAR-1", units: 100),
                     assay("FAR", body: "FAR-1", units: 9000)],
            stars: stars, meshSystems: ["HOME"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        )
        #expect(target == .init(system: "NEAR", units: 100, needsRelay: true))
    }

    @Test func rejectsASystemMoreThanOneHopOut() {
        let stars = ["HOME": star("HOME", x: 0), "FAR": star("FAR", x: 20)]
        // Nothing reachable at all: the run has no target it could work, which
        // is a `nil` rather than a bad pick. The vessel stays where it is.
        #expect(SalvageTargetPlanner.nextTarget(
            assays: [assay("FAR", body: "FAR-1", units: 9000)],
            stars: stars, meshSystems: ["HOME"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        ) == nil)
    }

    @Test func theFrontierExpandsAsSystemsJoinTheMesh() {
        // FAR is 20 ly from HOME but only 6 from NEAR. Once NEAR is meshed it
        // becomes reachable — this is the bootstrap property the whole design
        // rests on, so it gets its own test.
        let stars = ["HOME": star("HOME", x: 0), "NEAR": star("NEAR", x: 14), "FAR": star("FAR", x: 20)]
        let assays = [assay("FAR", body: "FAR-1", units: 9000)]
        #expect(SalvageTargetPlanner.nextTarget(
            assays: assays, stars: stars, meshSystems: ["HOME", "NEAR"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        ) == .init(system: "FAR", units: 9000, needsRelay: true))
    }

    @Test func sumsEveryBodysUnitsInASystem() {
        let stars = ["HOME": star("HOME", x: 0), "TWO": star("TWO", x: 3)]
        let target = SalvageTargetPlanner.nextTarget(
            assays: [assay("TWO", body: "TWO-1", units: 100), assay("TWO", body: "TWO-6", units: 250)],
            stars: stars, meshSystems: ["HOME", "TWO"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        )
        #expect(target?.units == 350)
    }

    @Test func neverOffersAnAttemptedSystem() {
        // `attempted` is `Directive.targets` — append-only history. Without this
        // the operator's Skip is a no-op, and a system that can never report
        // itself finished pins the planner forever.
        let stars = ["HOME": star("HOME", x: 0), "DONE": star("DONE", x: 3)]
        #expect(SalvageTargetPlanner.nextTarget(
            assays: [assay("DONE", body: "DONE-1", units: 100)],
            stars: stars, meshSystems: ["HOME", "DONE"], attempted: ["DONE"],
            vessel: Position(x: 0, y: 0, z: 0)
        ) == nil)
    }

    @Test func breaksEqualRanksOnDesignationSoPlansAreReproducible() {
        let stars = ["HOME": star("HOME", x: 0), "AAA": star("AAA", x: 3), "BBB": star("BBB", x: 3)]
        let target = SalvageTargetPlanner.nextTarget(
            assays: [assay("BBB", body: "BBB-1", units: 100), assay("AAA", body: "AAA-1", units: 100)],
            stars: stars, meshSystems: ["HOME", "AAA", "BBB"], attempted: [],
            vessel: Position(x: 0, y: 0, z: 0)
        )
        #expect(target?.system == "AAA")
    }

    @Test func meshSystemsAreTheOnesHoldingARelayingRelay() {
        // Derived from live device rows, never from `ftlLinks` — an isolated
        // relay produces no link rows at all, so a link-derived set would miss
        // the system this run just meshed.
        let devices = [
            Device.fixture(deviceCode: "R1", features: ["relay"], status: "relaying", location: "TOSLIT-3-L4"),
            Device.fixture(deviceCode: "R2", features: ["relay"], status: "idle", location: "WATTL-1-L4"),
            Device.fixture(deviceCode: "V", features: ["cruise"], status: "idle", location: "TOSLIT-3"),
        ]
        #expect(SalvageTargetPlanner.meshSystems(in: devices) == ["TOSLIT"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter SalvageTargetPlannerTests`
Expected: FAIL — `cannot find 'SalvageTargetPlanner' in scope`.

- [ ] **Step 3: Write the planner**

Create `DirectiveEngine/Sources/SalvageTargetPlanner.swift`:

```swift
//
//  SalvageTargetPlanner.swift
//  Replicould — DirectiveEngine
//
//  Where a Salvage Run goes next. Ranked so the FTL-mesh frontier expands
//  outward under its own steam: prefer a system already on the mesh, then one
//  that a single relay would bring onto it, then the richest, then the nearest.
//
//  Measured against the live 53-site catalogue on 2026-07-30: planting relays
//  only at salvage systems, richest-first, reaches 10 of 13 systems and 15,650
//  of 20,471 units with 9 relays and no side-trips — TOSLIT's relay brings
//  ARCTURUSAN into range, which brings ABSOLUTN, and so on. Three systems
//  (POLARISUM, ASTELLIO, SOHIMU — 4,821 units) need a relay at a NON-salvage
//  waypoint first and are deliberately never offered here; that errand is Relay
//  Run's, not this planner's.
//
//  Pure by contract — no I/O, no clock, no randomness. Must NOT be a static on a
//  SwiftUI `View`: pure logic in that position traps with signal 5 under
//  `swift test`.
//

import Foundation
import GameModels
import UniverseModels

public enum SalvageTargetPlanner {
    /// A relay's maximum edge range. Not a coverage radius — a system is on the
    /// mesh only if it holds its OWN relay; this is how far apart two relays may
    /// be and still link.
    public static let relayRangeLY: Double = 7.5

    public struct Target: Equatable, Sendable {
        public let system: String
        /// Total assayed units across every salvage body in the system. A floor,
        /// not a total: an unassayed site contributes nothing rather than
        /// pretending to be zero.
        public let units: Double
        /// Whether the run must plant a relay on arrival. False when the system
        /// is already meshed — the emplace step is skipped entirely.
        public let needsRelay: Bool

        public init(system: String, units: Double, needsRelay: Bool) {
            self.system = system
            self.units = units
            self.needsRelay = needsRelay
        }
    }

    /// The systems currently on the mesh: those holding a relay that is actually
    /// relaying.
    ///
    /// Derived from device rows rather than from the `ftlLinks` table on purpose.
    /// A relay that is up but not yet linked to anything produces NO link rows,
    /// so a link-derived set would omit the system this run just meshed — the
    /// one case that matters most here. Device rows also update the moment the
    /// activation confirm-read lands.
    public static func meshSystems(in devices: [Device]) -> Set<String> {
        Set(
            devices
                .filter { $0.features.contains("relay") && $0.status == "relaying" }
                .compactMap(\.location)
                .map { SiteAssay.system(of: $0) }
        )
    }

    /// The next system to work, or nil when nothing is reachable.
    ///
    /// `attempted` must carry every system this run has already aimed at, not
    /// just the ones it finished — `Directive.targets` is exactly that set, kept
    /// append-only for this reason. Omitting it breaks two ways that both occur:
    /// the operator's Skip becomes a no-op, and a system that cannot report
    /// itself finished pins the planner on it forever.
    public static func nextTarget(
        assays: [SiteAssay],
        stars: [String: Star],
        meshSystems: Set<String>,
        attempted: Set<String>,
        vessel: Position?,
        relayRange: Double = relayRangeLY
    ) -> Target? {
        // Fold the per-site assays into per-system totals once.
        var units: [String: Double] = [:]
        for assay in assays where !attempted.contains(assay.system) {
            units[assay.system, default: 0] += assay.totals.values.reduce(0, +)
        }

        // The relay positions that define the current frontier.
        let relayPositions = meshSystems.compactMap { stars[$0] }.map(Position.init(star:))

        var best: Target?
        var bestKey: RankKey?
        for (system, systemUnits) in units {
            guard let star = stars[system] else { continue }
            let position = Position(star: star)
            let meshed = meshSystems.contains(system)
            // One hop means: a relay planted HERE would link to an existing one.
            let reachable = meshed || relayPositions.contains { distance($0, position) <= relayRange }
            guard reachable else { continue }

            let key = RankKey(
                meshedRank: meshed ? 0 : 1,
                units: systemUnits,
                distance: vessel.map { distance($0, position) } ?? 0,
                designation: system
            )
            if let bestKey, !key.beats(bestKey) { continue }
            bestKey = key
            best = Target(system: system, units: systemUnits, needsRelay: !meshed)
        }
        return best
    }

    /// The ranking, in one place so the ordering is total and reproducible:
    /// meshed first, then most units, then nearest, then designation. The final
    /// key exists so two equal candidates always resolve the same way across
    /// evaluations — without it a run could oscillate between them.
    private struct RankKey {
        let meshedRank: Int
        let units: Double
        let distance: Double
        let designation: String

        func beats(_ other: RankKey) -> Bool {
            if meshedRank != other.meshedRank { return meshedRank < other.meshedRank }
            if units != other.units { return units > other.units }
            if distance != other.distance { return distance < other.distance }
            return designation < other.designation
        }
    }

    private static func distance(_ a: Position, _ b: Position) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

private extension Position {
    init(star: Star) {
        self.init(x: star.positionX, y: star.positionY, z: star.positionZ)
    }
}
```

If `Position` has no memberwise `init(x:y:z:)` or the label differs, match whatever `SurveyRoamPlanner`'s tests construct — that file already uses `Position` the same way.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter SalvageTargetPlannerTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Modules/DirectiveEngine
git commit -m "Choose salvage targets so the relay frontier expands itself"
```

---

### Task 5: `SalvageRun` — preflight and travel

**Files:**
- Create: `DirectiveEngine/Sources/SalvageRun.swift`
- Test: `DirectiveEngine/Tests/SalvageRunTests.swift`

**Interfaces:**
- Consumes: `MissionAction.refreshFleet` (Task 3), `SalvageTargetPlanner` (Task 4), `DirectiveKind.salvageRun` and the new reasons (Task 2).
- Produces: `SalvageRun: MissionStepMachine` with `Step.preflight/travelling/emplacing/activating/configuring/launching/awaiting/verifying/restocking`, and the statics `SalvageRun.controller(aboard:in:)`, `.adoptedDrones(of:aboard:in:)`, `.relay(aboard:in:)`, `.salvageBodies(in:world:)`.

- [ ] **Step 1: Write the failing tests**

Create `DirectiveEngine/Tests/SalvageRunTests.swift`. Copy the fixture helpers from `SurveyRunTests.swift` — it already has `Device` and `Directive` builders shaped for this engine.

```swift
@Suite struct SalvageRunPreflightTests {
    @Test func stallsWhenNoMiningControllerIsAboard() {
        // NEGATIVE finding over local rows: demand an authoritative look before
        // surfacing it, because "nothing aboard" and "nobody has looked lately"
        // are the same silence locally, and only the first is worth stopping for.
        let world = world(devices: [vessel])
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: .noMiningControllerAboard))
    }

    @Test func stallsWhenTheControllerHasNoDroneAboard() {
        let world = world(devices: [vessel, controller])
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: .noMiningDroneAboard))
    }

    @Test func claimsTheControllerAndTravelsWhenFullyStaged() {
        let world = world(devices: [vessel, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: world)
            == .assignController(deviceCode: "CTRL", nextStep: "travelling"))
    }

    @Test func routesToBaseWhenOutOfRelaysAndTheTargetNeedsOne() {
        // The relay is an ENABLER, not an optional extra: without one the run
        // would have to park at the target for the whole haul, which is exactly
        // what the two-machine split exists to avoid.
        let world = world(devices: [vessel, controller, drone])  // no relay aboard
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: world)
            == .advanceStep(nextStep: "restocking"))
    }

    @Test func extendsTheQueueWhenItEmpties() {
        // A Salvage Run is always continuous — it has no finish line, so an
        // empty queue means "plan the next one", never `.done`.
        let world = world(devices: [vessel, controller, drone, relay])
        let directive = running(step: "preflight", targets: ["TOSLIT"], targetIndex: 1)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .extendQueue(centre: "AINALRAM"))
    }

    @Test func stallsWhenTheVesselIsMissingEntirely() {
        #expect(SalvageRun().nextAction(directive: running(step: "preflight"), world: world(devices: []))
            == .stall(.unreachableDevice))
    }
}

@Suite struct SalvageRunTravelTests {
    @Test func dispatchesTravelToTheTarget() {
        let world = world(devices: [vessel, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: world)
            == .dispatch(kind: .travel, deviceCode: "VESSEL",
                         params: CommandParams(destination: "TOSLIT"), nextStep: "travelling"))
    }

    @Test func waitsWhileTheTripIsUnderway() {
        // An open op is the guard that stops a second travel landing on the
        // first. Expected, never a stall.
        let world = world(devices: [vessel, controller, drone, relay],
                          openOperations: ["VESSEL": operation(kind: .travel)])
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: world) == .wait)
    }

    @Test func skipsStraightToMiningWhenTheSystemIsAlreadyMeshed() {
        // Arrived, and a relay is already relaying here — nothing to emplace.
        let arrived = device("VESSEL", location: "TOSLIT-3")
        let here = device("R", features: ["relay"], status: "relaying", location: "TOSLIT-3-L4")
        let world = world(devices: [arrived, controller, drone, relay, here])
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: world)
            == .advanceStep(nextStep: "configuring"))
    }

    @Test func goesToEmplaceTheRelayOnArrivalAtAnUnmeshedSystem() {
        let arrived = device("VESSEL", location: "TOSLIT-3")
        let world = world(devices: [arrived, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "travelling"), world: world)
            == .advanceStep(nextStep: "emplacing"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter SalvageRun`
Expected: FAIL — `cannot find 'SalvageRun' in scope`.

- [ ] **Step 3: Write the machine's skeleton, fleet queries, preflight and travel**

Create `DirectiveEngine/Sources/SalvageRun.swift` with the header comment, `Step` vocabulary, the fleet queries, and the two steps. Model it closely on `SurveyRun.swift` — the same `nextAction` switch shape, the same `claimedController` re-resolution, the same `system(of:)` helper.

Key points the tests pin:

```swift
public struct SalvageRun: MissionStepMachine {
    public let kind: DirectiveKind = .salvageRun
    public var firstStep: String { Step.preflight }

    public enum Step {
        public static let preflight = "preflight"
        public static let travelling = "travelling"
        public static let emplacing = "emplacing"
        public static let activating = "activating"
        public static let configuring = "configuring"
        public static let launching = "launching"
        public static let awaiting = "awaiting"
        public static let verifying = "verifying"
        public static let restocking = "restocking"
    }

    /// The salvage configuration this mission insists on: deplete the named
    /// body, then recall the drones so the vessel can move on. `recall` is
    /// load-bearing — since v2.3.3 the server holds `directive.completed` until
    /// the recall lands, which is what lets `verifying` be one confirming read
    /// rather than a timed wait.
    public static func salvageConfig(body: String) -> [String: JSONValue] {
        ["location": .string(body), "recall": .bool(true)]
    }

    /// The AMI mining controller stowed aboard, identified by CAPABILITY
    /// (`gather_salvage` among its available directives) rather than by
    /// `device_type`, and STOWED rather than merely co-located — `launch`
    /// deploys stowed devices, and one left standing beside the vessel is left
    /// behind the moment it departs.
    public static func controller(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        world.devices.values
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
            .filter { $0.availableDirectives.contains("gather_salvage") }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// An FTL relay stowed aboard the vessel, if any.
    public static func relay(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        world.devices.values
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
            .filter { $0.features.contains("relay") }
            .min { $0.deviceCode < $1.deviceCode }
    }
}
```

**Extract the adoption queries into a shared helper — do not duplicate them.** (Operator ruling, 2026-07-30, overriding this plan's first draft, which said to copy them.)

Both machines need the same two-ended read: adoption is resolved from `controller.controlledDeviceCodes` **and** each drone's `controllerDeviceCode`, because `controlled_devices` ships only in the single-device payload and a list sync erases it from `detail`. Reading one end alone made a perfectly staged vessel look unstaged. That invariant is subtle enough that two copies would mean a future correction lands in only one of them.

So: create `DirectiveEngine/Sources/AMIFleet.swift` — a plain enum, no TCA, no I/O — holding

```swift
AMIFleet.adoptedDrones(of: Device, in: WorldSnapshot) -> [Device]
AMIFleet.adoptedDrones(of: Device, aboard: Device, in: WorldSnapshot) -> [Device]
AMIFleet.stowed(aboard: Device, in: WorldSnapshot, offering directive: String) -> Device?
```

Move `SurveyRun`'s implementations there verbatim, **carrying their doc comments across intact** — the comments are the record of why the two-ended read exists. Then have `SurveyRun` call through. `SurveyRun.controller(aboard:in:)` becomes `AMIFleet.stowed(aboard:in:offering: "survey_system")` and `SalvageRun`'s becomes the same call with `"gather_salvage"`.

This touches shipped `SurveyRun` code, which this plan did not originally budget for. Keep the change mechanical: no behaviour may change, and `SurveyRunTests` must stay green **without edits**. If a `SurveyRunTests` assertion has to change to accommodate the move, stop — that means the extraction altered behaviour, which it must not.

`preflight` order (each guard matters and the order is load-bearing):
1. vessel missing → `.stall(.unreachableDevice)`
2. no `currentTarget` → `.extendQueue(centre:)` — a Salvage Run is always continuous
3. no controller aboard → `.refreshFleet(tag:thenStall: .noMiningControllerAboard)`
4. no adopted drone aboard → `.refreshFleet(tag:thenStall: .noMiningDroneAboard)`
5. target needs a relay and none is aboard → `.advanceStep(nextStep: Step.restocking)`
6. otherwise → `.assignController(deviceCode:nextStep: Step.travelling)`

Use `directive.fleetTag ?? "auto:salvage"` for the tag so a row written without one still works.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter SalvageRun`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/DirectiveEngine
git commit -m "Fly a salvage run to a target it staged for"
```

---

### Task 6: `SalvageRun` — relay emplacement

**Files:**
- Modify: `DirectiveEngine/Sources/SalvageRun.swift`
- Test: `DirectiveEngine/Tests/SalvageRunTests.swift`

**Interfaces:**
- Consumes: Task 5's `Step` vocabulary.
- Produces: the `emplacing` and `activating` steps. Deliberately shaped as a self-contained pair so a future location-event mission (relay at an L4 *plus* a beacon at the event site) reuses it.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct SalvageRunEmplacementTests {
    @Test func travelsToALagrangePointBeforeDeploying() {
        // Relays only work at L4/L5 — the vessel must actually be there, not
        // merely in the system.
        let arrived = device("VESSEL", location: "TOSLIT-3")
        let world = world(devices: [arrived, controller, drone, relay], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "emplacing"), world: world)
            == .dispatch(kind: .travel, deviceCode: "VESSEL",
                         params: CommandParams(destination: "TOSLIT-3-L4"), nextStep: "emplacing"))
    }

    @Test func deploysTheRelayOnceAtTheLagrangePoint() {
        let atL4 = device("VESSEL", location: "TOSLIT-3-L4")
        let world = world(devices: [atL4, controller, drone, relay], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "emplacing"), world: world)
            == .dispatch(kind: .simple("deploy"), deviceCode: "RELAY",
                         params: CommandParams(), nextStep: "activating"))
    }

    @Test func activatesTheDeployedRelay() {
        // `deploy` does NOT activate — that is a separate command, verified in
        // the directives spec §3.
        let atL4 = device("VESSEL", location: "TOSLIT-3-L4")
        let deployed = device("RELAY", features: ["relay"], status: "idle", location: "TOSLIT-3-L4")
        let world = world(devices: [atL4, controller, drone, deployed], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "activating"), world: world)
            == .dispatch(kind: .simple("activate"), deviceCode: "RELAY",
                         params: CommandParams(), nextStep: "activating"))
    }

    @Test func advancesToMiningOnceTheRelayIsRelaying() {
        let atL4 = device("VESSEL", location: "TOSLIT-3-L4")
        let up = device("RELAY", features: ["relay"], status: "relaying", location: "TOSLIT-3-L4")
        let world = world(devices: [atL4, controller, drone, up], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "activating"), world: world)
            == .advanceStep(nextStep: "configuring"))
    }

    @Test func stallsWhenTheRelayNeverComesUp() {
        // The backstop. A relay that deployed but never started relaying is a
        // dead run — the whole point of the trip was the mesh membership.
        let atL4 = device("VESSEL", location: "TOSLIT-3-L4")
        let deployed = device("RELAY", features: ["relay"], status: "idle", location: "TOSLIT-3-L4")
        let stale = running(step: "activating", stepStartedAt: now.addingTimeInterval(-11 * 60))
        let world = world(devices: [atL4, controller, drone, deployed],
                          systems: ["TOSLIT": toslit], now: now)
        #expect(SalvageRun().nextAction(directive: stale, world: world)
            == .stall(.relayActivationFailed))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter SalvageRunEmplacementTests`
Expected: FAIL — the machine falls through to `.wait` on the unknown steps.

- [ ] **Step 3: Implement the two steps**

```swift
    /// How long to let an `activate` take before surfacing
    /// `relayActivationFailed`. Generous — the relay's own confirm-read is what
    /// flips its status, and that read is subject to the poll budget.
    public static let activationDeadline: TimeInterval = 10 * 60

    /// The Lagrange point to emplace at: the first L4/L5 the system reports,
    /// ordered by designation so the choice is reproducible across evaluations.
    /// Relays require a gravitationally stable point and will not work anywhere
    /// else, so a system with none is not emplaceable.
    ///
    /// Lagrange points hang off each PLANET (`Planet.lagrange: [SpecialSite]`),
    /// not off the system — there is no `StarSystem.lagrangePoints`.
    static func lagrangePoint(in system: StarSystem?) -> String? {
        system?.planets.flatMap(\.lagrange).map(\.designation).sorted().first
    }

    private func emplace(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget,
              let point = Self.lagrangePoint(in: world.system(target))
        else { return .advanceStep(nextStep: Step.configuring) }
        guard let relay = Self.relay(aboard: vessel, in: world) else {
            return .advanceStep(nextStep: Step.restocking)
        }
        if vessel.location != point {
            if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
            return .dispatch(
                kind: .travel, deviceCode: vessel.deviceCode,
                params: CommandParams(destination: point), nextStep: Step.emplacing
            )
        }
        return .dispatch(
            kind: OperationKind.simple("deploy"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.activating
        )
    }

    private func activate(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        // Resolve the relay by where it now IS, not by what is stowed: `deploy`
        // cleared its `stowedInDeviceCode`, so the aboard-query no longer finds
        // it. This is the easy bug here.
        guard let relay = Self.deployedRelay(near: vessel, in: world) else {
            return .stall(.relayActivationFailed)
        }
        if relay.status == "relaying" { return .advanceStep(nextStep: Step.configuring) }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.activationDeadline {
            return .stall(.relayActivationFailed)
        }
        if world.openOperation(for: relay.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: OperationKind.simple("activate"), deviceCode: relay.deviceCode,
            params: CommandParams(), nextStep: Step.activating
        )
    }

    /// A relay sitting at the vessel's own location — the one just deployed.
    static func deployedRelay(near vessel: Device, in world: WorldSnapshot) -> Device? {
        guard let location = vessel.location else { return nil }
        return world.devices.values
            .filter { $0.features.contains("relay") && $0.location == location }
            .min { $0.deviceCode < $1.deviceCode }
    }
```

Add the two `case` arms to `nextAction`'s switch. If `StarSystem` exposes Lagrange points under a different name than `lagrangePoints`, find the real accessor — `OrreryLayout` and the Locations catalog both consume them, and `LocationDecoding` is the facade.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter SalvageRun`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/DirectiveEngine
git commit -m "Plant a relay at the target so the freighter can work alone"
```

---

### Task 7: `SalvageRun` — the mining loop

`gather_salvage` targets ONE body, so a system with several salvage bodies needs several cycles. The body index rides on `targetIndex`'s sibling: the machine re-derives "which bodies are left" from the catalogue each evaluation rather than storing a cursor, so nothing can drift.

**Files:**
- Modify: `DirectiveEngine/Sources/SalvageRun.swift`
- Test: `DirectiveEngine/Tests/SalvageRunTests.swift`

**Interfaces:**
- Consumes: Task 6's `Step.configuring`.
- Produces: `WorldSnapshot.siteAssays`, `configuring`, `launching`, `awaiting` steps, and `SalvageRun.nextBody(in:world:)`.

**Prerequisite discovered during Task 5 — do this part first.** `WorldSnapshot` does **not** carry `SiteAssay` totals, so a machine cannot rank bodies by assayed units without them. A Task 5 implementer wrote a version ranking on summed `remainingPct` instead; it was reverted, because `LocationModels.swift` documents that roster-sourced sites carry an **empty** `remainingPct`, which makes that sort degrade silently to alphabetical with no signal that it did.

So add to `WorldSnapshot`:

```swift
    /// Stored assay totals for the salvage sites in this directive's systems,
    /// keyed by SITE designation (`TOSLIT-3-2-SAL-1`) — the shape
    /// `StarSystem.salvageBodies(totals:)` expects.
    ///
    /// Read here rather than derived, because a site's ORIGINAL unit total is
    /// historical event knowledge that the catalogue payload never carries: it
    /// arrives once, on `salvage.discovered`, and would be clobbered by every
    /// re-scan's blob rewrite. `SiteAssay` is the table that survives that
    /// churn. Without it a mission can only see percentages, and a
    /// roster-sourced site's percentages are empty.
    public let siteAssays: [String: [String: Double]]
```

Populate it inside the existing `WorldSnapshot.read` transaction, scoped to the same `wanted` set of systems the `SystemDetail` blobs are scoped to — never the whole table. `SiteAssay` has a `system` column, so this is one `where { $0.system.in(Array(wanted)) }` fetch folded into `[siteDesignation: totals]`. Give it a `[:]` default in the initializer so every existing construction site keeps compiling.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct SalvageRunMiningTests {
    @Test func configuresGatherSalvageForTheRichestUnworkedBody() {
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "configuring"), world: world)
            == .dispatch(kind: .setDirective, deviceCode: "CTRL",
                         params: CommandParams(directive: "gather_salvage", configuration: [
                             "location": .string("TOSLIT-6-5"), "recall": .bool(true),
                         ]), nextStep: "launching"))
    }

    @Test func skipsSetDirectiveWhenTheInForceConfigAlreadyMatches() {
        // Re-issuing is the default: a leftover `location` from manual use would
        // silently work the wrong body. Only an exact match skips.
        let configured = device("CTRL", currentDirective: "gather_salvage",
                                currentDirectiveConfig: ["location": .string("TOSLIT-6-5"),
                                                         "recall": .bool(true)])
        let world = world(devices: [atSystem, configured, drone], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "configuring"), world: world)
            == .advanceStep(nextStep: "launching"))
    }

    @Test func reIssuesWhenTheInForceConfigNamesAnotherBody() {
        let wrong = device("CTRL", currentDirective: "gather_salvage",
                           currentDirectiveConfig: ["location": .string("TOSLIT-3-2"),
                                                    "recall": .bool(true)])
        let world = world(devices: [atSystem, wrong, drone], systems: ["TOSLIT": toslit])
        guard case .dispatch(_, _, _, let next) = SalvageRun()
            .nextAction(directive: running(step: "configuring"), world: world) else {
            Issue.record("expected a re-issue"); return
        }
        #expect(next == "launching")
    }

    @Test func launchesTheController() {
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "launching"), world: world)
            == .dispatch(kind: .simple("launch"), deviceCode: "CTRL",
                         params: CommandParams(), nextStep: "awaiting"))
    }

    @Test func waitsForCompletionThenVerifies() {
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "awaiting"), world: world) == .wait)
    }

    @Test func advancesToVerifyingWhenCompletionLands() {
        // Issue-time relative: a completion predating this step is a replay.
        let directive = running(step: "awaiting", stepStartedAt: now)
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": toslit],
                          log: [completion(at: now.addingTimeInterval(1))], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .advanceStep(nextStep: "verifying"))
    }

    @Test func stallsWhenALaunchDeployedNothing() {
        // No drones out means no completion is ever coming — surface it rather
        // than waiting forever.
        let directive = running(step: "awaiting", stepStartedAt: now)
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": toslit],
                          log: [emptyLaunch(at: now.addingTimeInterval(1))], now: now)
        #expect(SalvageRun().nextAction(directive: directive, world: world)
            == .stall(.launchDeployedNothing))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter SalvageRunMiningTests`
Expected: FAIL.

- [ ] **Step 3: Implement the loop**

```swift
    /// The next salvage body to work in the current target system: the richest
    /// one still holding salvage, by assayed units then designation.
    ///
    /// Re-derived from the catalogue on every evaluation rather than stored as a
    /// cursor. A cursor would drift the moment anything else depleted a site,
    /// and a depleted body simply stops being offered.
    static func nextBody(in directive: Directive, world: WorldSnapshot) -> String? {
        guard let target = directive.currentTarget, let system = world.system(target) else { return nil }
        // `salvageBodies(totals:)` ALREADY excludes depleted sites
        // (`where !site.depleted`), so no extra filter is needed — a drained body
        // simply stops appearing, which is what makes `nil` mean "system finished".
        // Pass the assay totals: without them `unitsRemaining` and
        // `discoveredTotal` are both nil for every body and the ranking below
        // collapses to the designation tiebreak.
        return system.salvageBodies(totals: world.siteAssays)
            .max { lhs, rhs in
                // `unitsRemaining` is nil until the body's live percentages have
                // been fetched; `discoveredTotal` carries the historical figure
                // for exactly that case, and is the COMMON one. Falling back to 0
                // instead would rank every unhydrated body last and send the run
                // to the least valuable target it knows about.
                let l = lhs.unitsRemaining ?? lhs.discoveredTotal ?? 0
                let r = rhs.unitsRemaining ?? rhs.discoveredTotal ?? 0
                // `max(by:)` wants "lhs strictly precedes rhs"; ties break on
                // designation so the pick is reproducible across evaluations.
                return l == r ? lhs.designation > rhs.designation : l < r
            }?
            .designation
    }
```

**Body, not site — confirmed in the codebase, not assumed.** `SalvageBody`'s own doc says it plainly: "`gather_salvage` directive targets. Dispatching to the body works every salvage site on it, so the picker offers bodies rather than sites." So one `set_directive` per body drains every site on it, and the loop is per-body.

`configuring` dispatches `set_directive` unless `configMatches` — compare `location` and `recall` field by field, never whole-object (the server echoes extra keys). `launching` dispatches `launch`. `awaiting` mirrors `SurveyRun.awaitCompletion`: completion seen → `verifying`; empty launch seen → stall; past the backstop → `verifying` anyway; else `.wait`.

When `nextBody` returns nil the system is drained: `advanceTarget`.

Reuse `SurveyRun`'s `completionSeen` / `emptyLaunchSeen` guard shape verbatim, including `eventTimeSkewTolerance` — it is issue-time relative so a catch-up completion still counts while a replay does not.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter SalvageRun`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/DirectiveEngine
git commit -m "Work every salvage body in a system before moving on"
```

---

### Task 8: `SalvageRun` — verification, restock, advance

The step that exists because a Survey Run once lost its whole drone complement. **Not a timed wait** — since v2.3.3 the server holds `directive.completed` until a recall-configured directive's drones have finished travelling, so a single confirming read is the right shape.

**Files:**
- Modify: `DirectiveEngine/Sources/SalvageRun.swift`
- Test: `DirectiveEngine/Tests/SalvageRunTests.swift`

**Interfaces:**
- Consumes: Task 7's `Step.verifying`.
- Produces: `verifying` and `restocking` steps.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct SalvageRunVerificationTests {
    @Test func advancesWhenEveryAdoptedDroneIsBackAboard() {
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .advanceStep(nextStep: "configuring"))
    }

    @Test func readsTheFleetOnceBeforeBelievingADroneIsStranded() {
        // "Just in case": completion now implies recall, so a stranded-looking
        // drone is far more likely a stale row than a real loss. One
        // authoritative read decides — and only if it AGREES does the run stall.
        let stranded = device("DRONE", controllerDeviceCode: "CTRL", stowedInDeviceCode: nil,
                              location: "TOSLIT-6-5")
        let world = world(devices: [atSystem, controller, stranded], systems: ["TOSLIT": toslit])
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .refreshFleet(tag: "auto:salvage", thenStall: .dronesNotRecovered))
    }

    @Test func advancesTheTargetOnceTheSystemIsDrained() {
        // No salvage left anywhere in the system: this target is finished.
        let world = world(devices: [atSystem, controller, drone], systems: ["TOSLIT": drainedToslit])
        #expect(SalvageRun().nextAction(directive: running(step: "verifying"), world: world)
            == .advanceTarget)
    }
}

@Suite struct SalvageRunRestockTests {
    @Test func travelsToBaseWhenOutOfRelays() {
        let world = world(devices: [vessel, controller, drone])
        #expect(SalvageRun().nextAction(directive: running(step: "restocking"), world: world)
            == .dispatch(kind: .travel, deviceCode: "VESSEL",
                         params: CommandParams(destination: "AINALRAM-BELT-1"), nextStep: "restocking"))
    }

    @Test func stallsForRestockOnceAtBase() {
        // The engine does NOT stow — that would loosen the never-stow contract,
        // which is its own future design. It parks and asks.
        let atBase = device("VESSEL", location: "AINALRAM-BELT-1")
        let world = world(devices: [atBase, controller, drone])
        #expect(SalvageRun().nextAction(directive: running(step: "restocking"), world: world)
            == .stall(.awaitingRelayRestock))
    }

    @Test func resumesWhenRelaysAreStowedAndTheRunIsRetried() {
        let atBase = device("VESSEL", location: "AINALRAM-BELT-1")
        let world = world(devices: [atBase, controller, drone, relay])
        #expect(SalvageRun().nextAction(directive: running(step: "restocking"), world: world)
            == .advanceStep(nextStep: "preflight"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter "SalvageRunVerificationTests|SalvageRunRestockTests"`
Expected: FAIL.

- [ ] **Step 3: Implement the two steps**

```swift
    /// The base a run restocks at. A constant for now — the delivery location is
    /// spec §1's fixed destination, and making it configurable before there is a
    /// second base would be a setting with one possible value.
    public static let baseDesignation = "AINALRAM-BELT-1"

    /// Confirm the recall actually landed before doing anything else.
    ///
    /// Since v2.3.3 `directive.completed` is held until a recall-configured
    /// directive's drones have finished travelling, so by the time this step runs
    /// they SHOULD be aboard. That makes a stranded-looking drone far more likely
    /// to be a stale local row than a real loss — hence one authoritative read
    /// rather than a stall, and rather than the elaborate ETA-driven wait Survey
    /// Run still carries. If the fresh rows agree, it really is a loss.
    private func verify(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            return .advanceTarget
        }
        let stranded = Self.adoptedDrones(of: controller, in: world)
            .filter { $0.stowedInDeviceCode != vessel.deviceCode }
        if !stranded.isEmpty {
            return .refreshFleet(tag: Self.fleetTag(directive), thenStall: .dronesNotRecovered)
        }
        // Recovered. More bodies here? Work the next one; otherwise this target
        // is done.
        return Self.nextBody(in: directive, world: world) == nil
            ? .advanceTarget
            : .advanceStep(nextStep: Step.configuring)
    }

    private func restock(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        if Self.relay(aboard: vessel, in: world) != nil {
            return .advanceStep(nextStep: Step.preflight)
        }
        if vessel.location == Self.baseDesignation { return .stall(.awaitingRelayRestock) }
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: Self.baseDesignation), nextStep: Step.restocking
        )
    }

    static func fleetTag(_ directive: Directive) -> String {
        directive.fleetTag ?? "auto:salvage"
    }
```

- [ ] **Step 4: Run the whole engine suite**

Run: `cd app/Modules && swift test --filter DirectiveEngine`
Expected: PASS — every `SalvageRun*` suite plus every pre-existing `SurveyRun` and engine test.

- [ ] **Step 5: Commit**

```bash
git add Modules/DirectiveEngine
git commit -m "Confirm the drones came home before the vessel leaves"
```

---

### Task 9: Registration, wiring and the launcher

**Files:**
- Modify: `DirectiveEngine/Sources/MissionRegistry.swift:16`
- Create: `DirectivesFeature/Sources/NewSalvageRunSheet.swift`
- Modify: `DirectivesFeature/Sources/DirectivesFeature.swift` (present the sheet)
- Modify: `GameModels/Sources/Directive.swift` (row subtitle arm)
- Test: `DirectiveEngine/Tests/SalvageRunTests.swift`, `DirectivesFeature/Tests/DirectivesFeatureTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: a running Salvage Run creatable from the UI.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func salvageRunIsRegistered() {
    // Until this passes the engine leaves every salvageRun row completely alone.
    #expect(MissionRegistry.machine(for: .salvageRun) is SalvageRun)
    #expect(MissionRegistry.firstStep(for: .salvageRun) == "preflight")
}

@Test func aRoamingSalvageRunReportsWorkDoneNotMOverN() {
    // `targetIndex == targets.count` for the whole window between systems, so an
    // m/n readout says "n/n" — a finished run — for most of its life.
    let row = DirectiveRow.custom(directive(
        kind: .salvageRun, roamCentre: "AINALRAM", targets: ["TOSLIT", "WATTL"], targetIndex: 2
    ))
    #expect(row.subtitle == "2 systems drained")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter "SalvageRun|DirectiveRowTests"`
Expected: FAIL — the registry returns nil.

- [ ] **Step 3: Register the machine**

```swift
    public static let machines: [any MissionStepMachine] = [SurveyRun(), SalvageRun()]
```

- [ ] **Step 4: Add the row subtitle arm**

In `DirectiveRow.subtitle`, add a `.salvageRun` branch beside the existing roam branch, pluralising correctly ("1 system drained"). Keep it on `DirectiveRow`, **not** as a computed property on the view — a private computed property on a `View` is untestable and traps under `swift test`.

- [ ] **Step 5: Build the launcher sheet**

Create `DirectivesFeature/Sources/NewSalvageRunSheet.swift`, modelled on the existing New Survey Run sheet. Requirements:

- The vessel picker offers **only staged vessels**, computed through `SalvageRun`'s own fleet queries (`controller(aboard:in:)` + `adoptedDrones(of:aboard:in:)`) so the picker and the engine share one definition of "staged" and the sheet cannot manufacture a stall.
- Writes `kind: .salvageRun`, `fleetTag: "auto:salvage"`, `roamCentre:` the vessel's current system, `controllerCode: nil` (the controller is claimed at preflight, not at creation — recording it here would go stale if the fleet moved first), `targets: []` (the engine plans the first target on its first evaluation), `returnToOrigin: false`.
- Designations render in `.rcMono` / `.rcBodyEmphMono`.
- Presented via `@Presents` (it is a feature with its own reducer), and dismissal cancels its in-flight effects.

- [ ] **Step 6: Tag the fleet — a one-time operator step, not code**

The run resolves its fleet by tag, so the devices must carry it. `DevicesClient.updateTags` already exists and the device inspector already manages tags. Document in the sheet's empty state that the vessel, its mining controller, its adopted mining drones and its relays must all be tagged `auto:salvage`.

- [ ] **Step 7: Run the full suite**

```bash
cd app/Modules && swift test \
  --event-stream-output-path "$TMPDIR/rc-all.jsonl" --event-stream-version 0
jq -r 'select(.kind == "testCaseEnded" and .payload.testCase.result == "failure")
       | .payload.testCase.id' "$TMPDIR/rc-all.jsonl"
```

Expected: no output (no failures). Note the multi-target truncation trap — several test processes share one output path; see the `swift-test-event-stream` skill for the per-target workaround if the stream looks short.

- [ ] **Step 8: Commit**

```bash
git add Modules/
git commit -m "Launch a salvage run from the directives list"
```

---

## Self-review

**Spec coverage.** §4.2 tag fleets → Tasks 1, 3. §5.1 planTarget → Tasks 4, 5. §5.2 preflight → Task 5. §5.3 travel → Task 5. §5.4 emplaceRelay → Task 6. §5.5 mine → Task 7. §5.6 verifyRecovered → Task 8. §5.7 advance → Tasks 7, 8. §5.8 restock → Task 8. §7 planner ranking → Task 4. §8 stalls → Task 2 (reasons) and the tasks that raise them. §9 UI → Task 9. §4.1 is struck in the spec and correctly has no task.

**Not covered here, by design:** §6 Haul Run is a separate plan. §10's recorded-not-built items are memory notes.

**Names verified against the code during review**, not left as assertions:

- `StarSystem.lagrangePoints` **does not exist** — Lagrange points hang off each planet (`Planet.lagrange: [SpecialSite]`). Task 6 now uses `system.planets.flatMap(\.lagrange)`.
- `SalvageBody.hasRemainingSalvage` **does not exist and is not needed** — `salvageBodies()` already excludes depleted sites internally. Task 7's filter was removed.
- `SalvageBody.discoveredTotal` **does exist** and matters: `unitsRemaining` is nil until a body's live percentages are fetched, which is the common state, so ranking on `unitsRemaining ?? 0` would send the run to its least valuable known target. Task 7 now falls back through `discoveredTotal`.
- The body-vs-site question is **answered in the codebase**, not open: `SalvageBody`'s doc comment states that dispatching `gather_salvage` to a body works every salvage site on it. The loop is per-body, and the earlier "confirm on the first live run" caveat has been struck.

**The one name still unverified** is the generated `getV1DevicesTagsTag` (Task 1 Step 4), which cannot be checked until the package builds — hence its own verification step rather than a note here.
