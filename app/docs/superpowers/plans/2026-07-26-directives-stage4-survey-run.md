# Directives Stage 4 — Survey Run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Survey Run real — a pure step machine that flies a vessel down a queue of target systems, sets and launches its AMI survey controller at each, detects completion, and stalls loudly when the world isn't what it needs — plus a minimal creation sheet so a run can actually be started from the app.

**Architecture:** `SurveyRun` is a `MissionStepMachine` (pure: `(Directive, WorldSnapshot) → MissionAction`), registered into `DirectiveEngine.makeLive`. Stage 3's action vocabulary grows three cases the engine executes — `advanceStep`, `assignController`, `refreshSystem` — so the machine can move without dispatching, claim the controller it drives, and ask for a fresh `locations/{star}` read without doing I/O itself. `WorldSnapshot` grows the two things completion detection needs: this directive's `DirectiveLogEntry` rows and the cached `StarSystem` blobs for its targets. Completion is the spec's two-tier scheme: the `directive.completed` log entry Stage 3's route already writes is the fast path, and a `locations/{star}` re-read is the backstop *and* the confirmation — counts disagreeing with a completion event is a `surveyIncomplete` stall, never a silent advance.

**Preconditions are the player's job (operator decision, 2026-07-26).** The run does NOT stow or adopt anything. It uses an AMI survey controller already stowed aboard the vessel, and that controller's already-adopted drones. Missing either is a stall, not a step. This keeps the engine out of the business of re-parenting the fleet — adoption is persistent state that outlives a mission.

**Tech Stack:** Swift 6.4, macOS 26+, SQLiteData, swift-dependencies, TCA (creation sheet only), Swift Testing.

**Spec:** `app/docs/superpowers/specs/2026-07-24-directives-design.md` — §3 (verified API facts), §4 (Survey Run sequence), §5 (completion detection), §8 (stall matrix). Read all four before Task 4.

**Prior stages:** `2026-07-24-directives-stage1-2-unified-surface.md`, `2026-07-25-directives-stage3-engine.md`, and `app/.claude/memory/directives-feature.md` (Stage 3 invariants — do not undo them).

## Global Constraints

- All paths are relative to the repo root. The SPM package root is `app/Modules/` — run every `swift` command from there.
- **Run tests via the event stream, never console text.** Per product, from `app/Modules/`:
  ```bash
  swift test --test-product <Product>Tests --disable-xctest \
    --event-stream-version 0 --event-stream-output-path .build/ev.jsonl
  jq -r 'select(.kind=="event").payload | select(.kind=="issueRecorded" and .issue.isFailure != false) | "\(.testID)\n    \(.messages[0].text)"' .build/ev.jsonl
  ```
  Empty output means no failures. Also confirm the run completed (`runEnded` present) and that no test started without ending (a crash). Always pass `--test-product` — one output path shared by many test processes truncates to the last writer. See the repo skill `swift-test-event-stream`.
- **Step machines are PURE.** No I/O, no `Date()`, no randomness — read time from `world.now`. Every effect is expressed as the returned `MissionAction`. This is what makes the stall matrix a table of plain function calls.
- **The engine observes reconciled state.** Machines read `Device`/`Operation`/`DirectiveLogEntry`/`SystemDetail` rows via `WorldSnapshot`, never a `GameEventEnvelope`.
- **A `.deferred` dispatch is not a failure** and writes nothing — the executor asks again next tick.
- **Only `.running` directives are evaluated**; a stall or pause is the user's to resolve.
- **`GET locations/{star}` is presence-gated** — it 403s unless a replicant is in that system (`app/.claude/memory/location-endpoint-presence-gate.md`). Consequences baked into this plan: the pre-travel skip check reads the **cached** `SystemDetail` blob only, and any live re-read happens **after arrival**.
- **No hard-coded colors, spacing, or font sizes** — `DesignSystem.swift` tokens only. **Designations render monospace.** **List-row structs in their own file.** **Pure logic never as a static on a SwiftUI `View`.**
- **TCA is for feature modules only** — `DirectiveEngine` declares `Dependencies`, never `ComposableArchitecture`.
- **Logging:** `os.Logger`, subsystem `name.pennig.replicould`, category `DirectiveEngine` / `Directives`.
- **Commits go to the worktree branch; no PRs, no pushes.** One commit per task. **Scope `git add` to the files the task touched** — a broad `git add -A` swept a user's Xcode edit into an unrelated commit in Stage 3.
- **Verify with SourceKit-LSP before signing off**; build first (the index is only as fresh as your last build), and re-run `scripts/link-index-store.sh` after anything that wipes `.build`.

---

### Task 1: Correct the stale Stage 3 memory note

Already edited in this worktree, uncommitted. The Stage 3 note claims the Xcode link is outstanding; the user did it, and it is committed.

**Files:**
- Modify: `app/.claude/memory/directives-feature.md` (the "Manual step outstanding" paragraph)

- [ ] **Step 1: Confirm the edit is present and correct**

```bash
grep -n "App-target link: DONE" app/.claude/memory/directives-feature.md
```
Expected: one match. If absent, apply it: the paragraph should record that `DirectiveEngine` is in the app target's `packageProductDependencies` and Frameworks phase, that it landed in `ab6e977` via a broad `git add -A` (so that commit's message is stale), and link `[[pbxproj-link-is-manual]]`.

- [ ] **Step 2: Commit**

```bash
git add app/.claude/memory/directives-feature.md
git commit -m "Memory: the DirectiveEngine app-target link is done"
```

---

### Task 2: Grow the mission seam — three actions and a richer snapshot

Survey Run needs three things Stage 3's vocabulary can't express: move to the next step without POSTing anything, record which controller the run has claimed, and ask for a fresh system read. It also needs two things the snapshot doesn't carry: this directive's log entries, and the cached `StarSystem` blobs for its targets.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift` (three `MissionAction` cases)
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift` (log + systems, new `read` signature)
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (one new attention reason)
- Modify: `app/Modules/Package.swift` (`DirectiveEngine` gains `UniverseModels`)
- Test: `app/Modules/DirectiveEngine/Tests/WorldSnapshotTests.swift`

**Interfaces:**
- Consumes: `SystemDetail`, `StarSystem` (UniverseModels); `DirectiveLogEntry` (GameModels).
- Produces:
  - `MissionAction.advanceStep(nextStep: String)`
  - `MissionAction.assignController(deviceCode: String, nextStep: String)`
  - `MissionAction.refreshSystem(designation: String, nextStep: String)`
  - `DirectiveAttentionReason.noSurveyControllerAboard`
  - `WorldSnapshot.log: [DirectiveLogEntry]`, `WorldSnapshot.systems: [String: StarSystem]`
  - `WorldSnapshot.system(_ designation: String) -> StarSystem?`
  - `WorldSnapshot.read(from:now:directive:) async throws -> WorldSnapshot` (replaces the `now`-only signature)

- [ ] **Step 1: Add `UniverseModels` to the `DirectiveEngine` target and test target**

In `app/Modules/Package.swift`, add `"UniverseModels",` to both the `DirectiveEngine` target's and `DirectiveEngineTests`' `dependencies` arrays (alphabetical: after `"GameServices"`, before `"Utils"`).

- [ ] **Step 2: Write the failing snapshot tests**

Append to `WorldSnapshotTests.swift` (it already has file-private `device(_:)` and `op(_:device:status:)` helpers — reuse them):

```swift
    /// The snapshot carries THIS directive's log entries and no one else's —
    /// completion detection keys off them, so a neighbouring mission's
    /// timeline must never be mistaken for this one's.
    @Test func loadsOnlyThisDirectivesLogEntries() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D1", deviceCode: nil, kind: .directiveCompleted,
                    summary: "mine", step: nil, operationID: nil, eventID: "E1",
                    occurredAt: Date(timeIntervalSince1970: 10)
                )
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L2", directiveID: "D2", deviceCode: nil, kind: .directiveCompleted,
                    summary: "someone else's", step: nil, operationID: nil, eventID: "E2",
                    occurredAt: Date(timeIntervalSince1970: 11)
                )
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.log.map(\.id) == ["L1"])
    }

    /// Cached system blobs are decoded for the directive's targets, so the
    /// machine can read scan counts without any I/O of its own.
    @Test func decodesCachedSystemsForTheTargets() async throws {
        let database = try GameDatabase.bootstrap()
        var system = StarSystem(designation: "SOL")
        system.planetsScanned = 3
        system.planetsTotal = 3
        try await database.write { db in
            try SystemDetail.upsert {
                try SystemDetail(system: system, hydratedAt: Date(timeIntervalSince1970: 0))
            }.execute(db)
        }
        let world = try await WorldSnapshot.read(
            from: database, now: Date(timeIntervalSince1970: 100), directive: directive()
        )
        #expect(world.system("SOL")?.planetsScanned == 3)
        #expect(world.system("NOPE") == nil)
    }
```

Add a file-private fixture beside the existing helpers:

```swift
private func directive(targets: [String] = ["SOL"]) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
        targets: targets, targetIndex: 0, step: "preflight",
        stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}
```

**Check `StarSystem`'s initializer before writing this** — if `StarSystem(designation:)` needs more arguments, use whatever the existing `UniverseModels` tests construct and say so.

- [ ] **Step 3: Run to verify it fails**

```bash
swift test --test-product DirectiveEngineTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/ev.jsonl
```
Expected: compile failure — `read(from:now:directive:)` doesn't exist.

- [ ] **Step 4: Extend `WorldSnapshot`**

Add the two stored properties (and their `init` parameters, defaulted to empty so existing construction sites keep compiling):

```swift
    /// This directive's audit trail, oldest first. Completion detection reads
    /// it: the `directive.completed` route writes an entry, and the mission
    /// observes that ROW rather than the event — the observe-reconciled-state
    /// invariant is what keeps missions replay-immune.
    public let log: [DirectiveLogEntry]
    /// Cached `StarSystem` blobs for the systems this directive cares about,
    /// by star designation. Only the directive's own targets are decoded:
    /// decoding the whole catalogue costs real time at thousands of bodies.
    public let systems: [String: StarSystem]
```

```swift
    public func system(_ designation: String) -> StarSystem? { systems[designation] }
```

Replace `read(from:now:)` with:

```swift
    /// One consistent read of everything a mission reasons over, scoped to the
    /// directive being evaluated.
    public static func read(
        from database: any DatabaseReader,
        now: Date,
        directive: Directive
    ) async throws -> WorldSnapshot {
        // The systems worth decoding: every target, the origin, and whatever
        // system the vessel is in right now (the arrival check needs it).
        var wanted = Set(directive.targets)
        if let origin = directive.originDesignation { wanted.insert(origin) }
        let directiveID = directive.id
        let vesselCode = directive.deviceCode

        return try await database.read { db in
            let devices = try Device.all.fetchAll(db)
            let operations = try GameModels.Operation
                .where { $0.status.in(OperationStatus.openCases) }
                .fetchAll(db)
            let log = try DirectiveLogEntry
                .where { $0.directiveID.eq(directiveID) }
                .order { $0.occurredAt }
                .fetchAll(db)

            if let vessel = devices.first(where: { $0.deviceCode == vesselCode }),
               let location = vessel.location {
                wanted.insert(SiteAssay.system(of: location))
            }
            let details = try SystemDetail
                .where { $0.designation.in(Array(wanted)) }
                .fetchAll(db)
            let systems = details.reduce(into: [String: StarSystem]()) { systems, detail in
                // A blob that fails to decode is treated as absent: the mission
                // then can't prove the target is scanned and surveys it again,
                // which is the safe direction to be wrong in.
                if let system = try? detail.system() { systems[detail.designation] = system }
            }

            return WorldSnapshot(
                devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                openOperations: Dictionary(operations.map { ($0.entityCode, $0) }, uniquingKeysWith: { _, last in last }),
                log: log,
                systems: systems,
                now: now
            )
        }
    }
```

Add `import UniverseModels` at the top.

- [ ] **Step 5: Add the three action cases**

In `MissionAction`:

```swift
    /// Move to `nextStep` with no command at all. The step machine's way of
    /// saying "this step's work was already done" — a target already reached,
    /// a directive already configured — without a pointless POST.
    case advanceStep(nextStep: String)
    /// Record the AMI controller this run is driving, then move on. This is the
    /// ownership handshake `Directive.controllerCode` exists for: it is what
    /// badges and locks the controller's built-in row while the mission runs.
    case assignController(deviceCode: String, nextStep: String)
    /// Re-read `locations/{star}` and persist it, then move to `nextStep`. The
    /// engine owns the I/O; the machine sees the fresh counts on its next
    /// evaluation. Presence-gated (403 away from the system), so only ever
    /// asked for after arrival.
    case refreshSystem(designation: String, nextStep: String)
```

- [ ] **Step 6: Add the attention reason**

In `DirectiveAttentionReason` (GameModels), after `noSurveyDroneAboard`:

```swift
    /// No AMI survey controller is stowed aboard the vessel. Staging one is the
    /// player's job — the run uses what's aboard, it never stows or adopts.
    case noSurveyControllerAboard
```

- [ ] **Step 7: Fix the call site and run the tests**

`DirectiveEngineCore.evaluateOnce` calls `WorldSnapshot.read(from:now:)` — pass `directive: directive` instead. Then:

```bash
swift build --build-tests 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "\.swift:[0-9]+:[0-9]+: error" | sort -u
swift test --test-product DirectiveEngineTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/ev.jsonl
```
Expected: no errors, no failures. `GameModelsTests` and `DirectivesFeatureTests` must stay green too (the new enum case is additive).

- [ ] **Step 8: Commit**

```bash
git add app/Modules/Package.swift app/Modules/DirectiveEngine app/Modules/GameModels/Sources/Directive.swift
git commit -m "Grow the mission seam for Survey Run"
```

---

### Task 3: `LocationsClient.hydrateSystem` — the presence-gated re-read

The engine's `refreshSystem` needs one call that fetches a system, merges it over the cached blob, and persists — mirroring the existing `hydrateBody`.

**Files:**
- Modify: `app/Modules/GameServices/Sources/LocationsClient.swift` (new method beside `hydrateBody`)
- Test: `app/Modules/GameServices/Tests/LocationsClientSalvageTests.swift` or a new `LocationsClientHydrateTests.swift` — match whichever file already stubs `LocationsClient.system`

**Interfaces:**
- Consumes: `LocationsClient.system(_:)`, `StarSystem.mergingSystemDetail(_:)`, `SystemDetail(system:hydratedAt:)`.
- Produces: `LocationsClient.hydrateSystem(designation: String) async throws` — best-effort; a 403 (`LocationsError.noReplicantInSystem`) leaves the cache untouched and does NOT throw.

- [ ] **Step 1: Write the failing test**

```swift
    /// A successful re-read merges over the cached blob and persists it, so the
    /// engine's next evaluation sees fresh scan counts straight from SQLite.
    @Test func hydrateSystemPersistsFreshCounts() async throws {
        let database = try GameDatabase.bootstrap()
        var fresh = StarSystem(designation: "SOL")
        fresh.planetsScanned = 3
        fresh.planetsTotal = 3
        try await withDependencies {
            $0.defaultDatabase = database
            $0.locationsClient.system = { _ in fresh }
        } operation: {
            @Dependency(\.locationsClient) var client
            try await client.hydrateSystem(designation: "SOL")
        }
        let stored = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(try stored?.system().planetsScanned == 3)
    }

    /// Away from the system the endpoint 403s. That is expected, not an error:
    /// the cache is left alone and the caller carries on.
    @Test func hydrateSystemSwallowsThePresenceGate() async throws {
        let database = try GameDatabase.bootstrap()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.locationsClient.system = { _ in throw LocationsError.noReplicantInSystem }
        } operation: {
            @Dependency(\.locationsClient) var client
            try await client.hydrateSystem(designation: "SOL")
        }
        let stored = try await database.read { db in
            try SystemDetail.where { $0.designation.eq("SOL") }.fetchOne(db)
        }
        #expect(stored == nil)
    }
```

**Check `LocationsError`'s actual case name first** (`grep -n "enum LocationsError" -A 8 app/Modules/GameServices/Sources/LocationsClient.swift`) and match it.

- [ ] **Step 2: Run to verify it fails.** Expected: no member `hydrateSystem`.

- [ ] **Step 3: Implement it**

Beside `hydrateBody`, following its merge-and-upsert shape:

```swift
    /// Re-read one star system and fold it into the cached blob.
    ///
    /// Best-effort by contract: `GET locations/{star}` is **presence-gated**
    /// (403 "No replicant in system" whenever no replicant is there — see the
    /// location-endpoint-presence-gate memory note), and a caller away from the
    /// system is the normal case, not a failure. A 403 leaves the cache exactly
    /// as it was.
    public func hydrateSystem(designation: String) async throws {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        guard let fresh = try? await system(designation) else { return }
        let cached = try? await database.read { db in
            try SystemDetail.where { $0.designation.eq(designation) }.fetchOne(db)
        }
        let merged = (try? cached?.system()).map { $0.mergingSystemDetail(fresh) } ?? fresh
        let row = try SystemDetail(system: merged, hydratedAt: date.now)
        try await database.write { db in
            try SystemDetail.upsert { row }.execute(db)
        }
    }
```

- [ ] **Step 4: Run the tests.** Expected: green, and the rest of `GameServicesTests` unaffected.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameServices
git commit -m "Add a presence-gated system re-read for the engine"
```

---

### Task 4: Teach the executor the three new actions

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift`
- Test: `app/Modules/DirectiveEngine/Tests/DirectiveEngineTests.swift`

**Interfaces:**
- Consumes: `MissionAction.advanceStep/assignController/refreshSystem` (Task 2), `LocationsClient.hydrateSystem` (Task 3).
- Produces: no new API — behaviour only.

**Semantics, exactly:**
| Action | Row writes | Log entry | Still runnable |
| --- | --- | --- | --- |
| `.advanceStep(next)` | `step`, `stepStartedAt`, `updatedAt` | `.stepStarted` | yes |
| `.assignController(code, next)` | `controllerCode`, `step`, `stepStartedAt`, `updatedAt` | `.stepStarted` | yes |
| `.refreshSystem(designation, next)` | `step`, `stepStartedAt`, `updatedAt` — **after** the read | `.stepStarted` | yes |

A failed/403 refresh still advances the step: `hydrateSystem` is best-effort, and the confirming step re-reads whatever the cache holds. Stalling on a transient read would be wrong — the counts simply stay stale and the mission waits.

- [ ] **Step 1: Write the failing tests**

```swift
    /// `.advanceStep` moves the step with no command at all.
    @Test func advanceStepMovesWithoutDispatching() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "preflight") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.advanceStep(nextStep: "travelling")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatch = { _, _, _ in
                Issue.record("advanceStep must not POST")
                return .deferred(.budgetExhausted)
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "travelling")
            #expect(directive?.stepStartedAt == Date(timeIntervalSince1970: 1_000))
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.stepStarted])
        }
    }

    /// `.assignController` records the controller — this is what badges and
    /// locks its built-in row for the life of the run.
    @Test func assignControllerRecordsTheController() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "preflight") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.assignController(deviceCode: "AMI1", nextStep: "travelling")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.controllerCode == "AMI1")
            #expect(directive?.step == "travelling")
        }
    }

    /// `.refreshSystem` performs the read and then advances.
    @Test func refreshSystemReadsThenAdvances() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "awaiting") }.execute(db)
        }
        let asked = LockIsolated<String?>(nil)
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.refreshSystem(designation: "SOL", nextStep: "confirming")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.locationsClient.system = { designation in
                asked.setValue(designation)
                var system = StarSystem(designation: designation)
                system.planetsScanned = 2
                system.planetsTotal = 2
                return system
            }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            #expect(asked.value == "SOL")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "confirming")
        }
    }

    /// A refresh that 403s (vessel not in that system) still advances — the
    /// read is best-effort and the confirming step works off cached counts.
    @Test func refreshSystemAdvancesEvenWhenTheReadFails() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { mission(step: "awaiting") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.refreshSystem(designation: "SOL", nextStep: "confirming")])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.locationsClient.system = { _ in throw LocationsError.noReplicantInSystem }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(directive?.step == "confirming")
        }
    }
```

- [ ] **Step 2: Run to verify they fail** (switch must be non-exhaustive / cases unhandled).

- [ ] **Step 3: Implement the three cases in `DirectiveExecutor.apply`**

```swift
        case let .advanceStep(nextStep):
            await move(directive, to: nextStep, controllerCode: directive.controllerCode)
            return true

        case let .assignController(deviceCode, nextStep):
            logger.info("directive \(directive.id, privacy: .public) claims controller \(deviceCode, privacy: .public)")
            await move(directive, to: nextStep, controllerCode: deviceCode)
            return true

        case let .refreshSystem(designation, nextStep):
            // Best-effort by contract: the endpoint 403s away from the system,
            // and a stale cache simply means the confirming step waits. Stalling
            // on a transient read would strand a mission that is fine.
            @Dependency(\.locationsClient) var locationsClient
            try? await locationsClient.hydrateSystem(designation: designation)
            await move(directive, to: nextStep, controllerCode: directive.controllerCode)
            return true
```

and the shared helper beside `stall`:

```swift
    /// Move to a step, optionally claiming a controller, with the matching
    /// timeline entry. `stepStartedAt` is re-stamped: it is the reference point
    /// for the issue-time-relative completion guard.
    private static func move(
        _ directive: Directive,
        to nextStep: String,
        controllerCode: String?
    ) async {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        var updated = directive
        updated.step = nextStep
        updated.controllerCode = controllerCode
        updated.stepStartedAt = date.now
        updated.updatedAt = date.now
        await commit(updated, [
            entry(directive, .stepStarted, "Step: \(nextStep)",
                  step: nextStep, operationID: nil,
                  id: uuid().uuidString, at: date.now),
        ])
    }
```

- [ ] **Step 4: Run the tests.** Expected: green.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine
git commit -m "Execute the three new mission actions"
```

---

### Task 5: `SurveyRun` — preflight and travel, with the stall matrix

The first half of the machine, and the priority test suite from §8. Pure functions over fixtures; no engine involved.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/SurveyRun.swift`
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRunTests.swift`

**Interfaces:**
- Consumes: `MissionStepMachine`, `WorldSnapshot`, `Device`, `SiteAssay.system(of:)`.
- Produces:
  - `public struct SurveyRun: MissionStepMachine` — `kind == .surveyRun`, `firstStep == SurveyRun.Step.preflight`
  - `enum SurveyRun.Step` (raw `String` constants): `preflight`, `travelling`, `configuring`, `launching`, `awaiting`, `confirming`, `returning`
  - `SurveyRun.controller(aboard: Device, in: WorldSnapshot) -> Device?`
  - `SurveyRun.adoptedDrones(of: Device, aboard: Device, in: WorldSnapshot) -> [Device]`
  - `SurveyRun.isFullyScanned(_ system: StarSystem?) -> Bool`

**Step vocabulary and preflight/travel semantics:**

| Situation at `preflight` | Action |
| --- | --- |
| Vessel row missing from the fleet | `.stall(.unreachableDevice)` |
| Queue exhausted, `returnToOrigin` off | `.done` |
| Queue exhausted, `returnToOrigin` on, already home | `.done` |
| Queue exhausted, `returnToOrigin` on, not home | `.advanceStep(returning)` |
| No survey controller stowed aboard the vessel | `.stall(.noSurveyControllerAboard)` |
| Controller has no adopted survey drone aboard | `.stall(.noSurveyDroneAboard)` |
| Cached blob says the target is already fully scanned | `.advanceTarget` |
| Otherwise | `.assignController(controller, travelling)` |

| Situation at `travelling` | Action |
| --- | --- |
| Vessel already in the target system | `.advanceStep(configuring)` |
| Vessel has an open operation | `.wait` (mid-travel; expected, never a stall) |
| Otherwise | `.dispatch(.travel, vessel, destination: target, nextStep: travelling)` |

- [ ] **Step 1: Write the failing stall-matrix tests**

Create `SurveyRunTests.swift`. Fixtures first:

```swift
//
//  SurveyRunTests.swift
//  Replicould — DirectiveEngine
//
//  The Survey Run step machine as a pure function table. The stall matrix
//  (design spec §8) is the priority suite: every way the world can fail the
//  run has a named, tested outcome, because the engine pauses and surfaces
//  rather than improvising.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils
@testable import DirectiveEngine

private func device(
    _ code: String,
    type: String,
    location: String? = "SOL-3",
    stowedIn: String? = nil,
    controlledBy: String? = nil,
    controlled: [String] = []
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !controlled.isEmpty {
        detail["controlled_devices"] = .array(controlled.map { code in
            .object(["device_code": .string(code), "device_type": .string("survey_drone")])
        })
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: "idle",
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: controlledBy,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: [], tags: [], detail: .object(detail),
        updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// A vessel with a controller and one adopted drone stowed aboard — the staged
/// state the run REQUIRES (stowing and adopting are the player's job).
private func stagedFleet(vesselAt location: String = "SOL-3") -> [Device] {
    [
        device("VES1", type: "transport_hauler", location: location),
        device("AMI1", type: "ami_survey_controller", location: location,
               stowedIn: "VES1", controlled: ["DRONE1"]),
        device("DRONE1", type: "survey_drone", location: location,
               stowedIn: "VES1", controlledBy: "AMI1"),
    ]
}

private func world(
    _ devices: [Device],
    log: [DirectiveLogEntry] = [],
    systems: [String: StarSystem] = [:],
    now: Date = Date(timeIntervalSince1970: 1_000)
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, l in l }),
        openOperations: [:], log: log, systems: systems, now: now
    )
}

private func run(
    step: String = SurveyRun.Step.preflight,
    targets: [String] = ["TAU"],
    targetIndex: Int = 0,
    controllerCode: String? = nil,
    returnToOrigin: Bool = false,
    origin: String? = "SOL",
    stepStartedAt: Date = Date(timeIntervalSince1970: 900)
) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
        controllerCode: controllerCode, targets: targets, targetIndex: targetIndex,
        step: step, stepStartedAt: stepStartedAt, returnToOrigin: returnToOrigin,
        originDesignation: origin, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}
```

Then the matrix:

```swift
@Suite("Survey Run — stall matrix")
struct SurveyRunStallTests {
    /// No controller stowed aboard: staging one is the player's job, so the run
    /// stalls with a reason naming exactly what's missing.
    @Test func stallsWithNoControllerAboard() {
        let fleet = [device("VES1", type: "transport_hauler")]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .stall(.noSurveyControllerAboard))
    }

    /// A controller that is co-located but NOT stowed doesn't count — `launch`
    /// deploys stowed devices, so an un-stowed controller would strand the run.
    @Test func stallsWhenTheControllerIsMerelyCoLocated() {
        let fleet = [
            device("VES1", type: "transport_hauler"),
            device("AMI1", type: "ami_survey_controller", controlled: ["DRONE1"]),
            device("DRONE1", type: "survey_drone", controlledBy: "AMI1"),
        ]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .stall(.noSurveyControllerAboard))
    }

    /// Controller aboard but no adopted drone with it: `launch` would deploy
    /// nothing and the survey would never start.
    @Test func stallsWithNoAdoptedDroneAboard() {
        let fleet = [
            device("VES1", type: "transport_hauler"),
            device("AMI1", type: "ami_survey_controller", stowedIn: "VES1"),
        ]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .stall(.noSurveyDroneAboard))
    }

    /// A drone stowed aboard but adopted by a DIFFERENT controller doesn't
    /// count — `launch` only deploys what this controller has adopted.
    @Test func stallsWhenTheDroneIsAdoptedElsewhere() {
        let fleet = [
            device("VES1", type: "transport_hauler"),
            device("AMI1", type: "ami_survey_controller", stowedIn: "VES1"),
            device("DRONE1", type: "survey_drone", stowedIn: "VES1", controlledBy: "AMI9"),
        ]
        #expect(SurveyRun().nextAction(directive: run(), world: world(fleet))
                == .stall(.noSurveyDroneAboard))
    }

    /// The vessel isn't in the fleet at all (decommissioned, or never read).
    @Test func stallsOnAMissingVessel() {
        #expect(SurveyRun().nextAction(directive: run(), world: world([]))
                == .stall(.unreachableDevice))
    }
}

@Suite("Survey Run — preflight and travel")
struct SurveyRunPreflightTests {
    /// A staged fleet claims its controller and moves to travel.
    @Test func preflightClaimsTheController() {
        #expect(SurveyRun().nextAction(directive: run(), world: world(stagedFleet()))
                == .assignController(deviceCode: "AMI1", nextStep: SurveyRun.Step.travelling))
    }

    /// A target the cache already shows fully scanned is SKIPPED, not surveyed
    /// (spec §5's precondition). Cached-only: the live read 403s before arrival.
    @Test func skipsAnAlreadyScannedTarget() {
        var scanned = StarSystem(designation: "TAU")
        scanned.planetsScanned = 4
        scanned.planetsTotal = 4
        scanned.moonsScanned = 7
        scanned.moonsTotal = 7
        let snapshot = world(stagedFleet(), systems: ["TAU": scanned])
        #expect(SurveyRun().nextAction(directive: run(), world: snapshot) == .advanceTarget)
    }

    /// Partial scan progress is NOT a skip.
    @Test func doesNotSkipAPartiallyScannedTarget() {
        var partial = StarSystem(designation: "TAU")
        partial.planetsScanned = 2
        partial.planetsTotal = 4
        let snapshot = world(stagedFleet(), systems: ["TAU": partial])
        #expect(SurveyRun().nextAction(directive: run(), world: snapshot)
                == .assignController(deviceCode: "AMI1", nextStep: SurveyRun.Step.travelling))
    }

    /// Unknown counts never count as scanned — surveying a done system wastes
    /// a trip, but skipping an unscanned one silently loses the whole point.
    @Test func unknownCountsAreNotScanned() {
        #expect(SurveyRun.isFullyScanned(nil) == false)
        #expect(SurveyRun.isFullyScanned(StarSystem(designation: "TAU")) == false)
    }

    /// Travel is dispatched at the vessel, toward the target system.
    @Test func travelDispatchesTowardTheTarget() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        let action = SurveyRun().nextAction(directive: directive, world: world(stagedFleet()))
        #expect(action == .dispatch(
            kind: .travel, deviceCode: "VES1",
            params: CommandParams(destination: "TAU"),
            nextStep: SurveyRun.Step.travelling
        ))
    }

    /// Already in the target system: no travel command at all.
    @Test func skipsTravelWhenAlreadyThere() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        let snapshot = world(stagedFleet(vesselAt: "TAU-2"))
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.configuring))
    }

    /// Mid-travel is a WAIT, never a stall (spec §4) — and never a second
    /// travel command on top of the one in flight.
    @Test func waitsWhileTravelling() {
        let directive = run(step: SurveyRun.Step.travelling, controllerCode: "AMI1")
        var snapshot = world(stagedFleet())
        snapshot = WorldSnapshot(
            devices: snapshot.devices,
            openOperations: ["VES1": GameModels.Operation(
                id: "OP1", entityCode: "VES1", kind: OperationKind.travel.rawValue,
                status: .active, source: .optimistic,
                startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
                lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
            )],
            log: [], systems: [:], now: snapshot.now
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot) == .wait)
    }
}
```

- [ ] **Step 2: Run to verify they fail.** Expected: no `SurveyRun`.

- [ ] **Step 3: Implement preflight and travel**

Create `SurveyRun.swift`. Header comment must state the precondition contract (the run uses what's staged; it never stows or adopts). Then:

```swift
public struct SurveyRun: MissionStepMachine {
    public let kind: DirectiveKind = .surveyRun
    public var firstStep: String { Step.preflight }

    public init() {}

    /// This mission's step vocabulary. Plain strings because `Directive.step`
    /// is deliberately untyped — each kind owns its own vocabulary.
    public enum Step {
        public static let preflight = "preflight"
        public static let travelling = "travelling"
        public static let configuring = "configuring"
        public static let launching = "launching"
        public static let awaiting = "awaiting"
        public static let confirming = "confirming"
        public static let returning = "returning"
    }

    /// The survey configuration this mission insists on: a FULL survey with the
    /// drones recalled when done, so the vessel can move on to the next target
    /// (spec §4 step 4). Note this differs from the composer's manual default
    /// (`moons: none`) — a Survey Run means the whole system.
    public static let surveyConfig: [String: JSONValue] = [
        "planets": .string("all"),
        "moons": .string("all"),
        "recall": .bool(true),
    ]

    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let vessel = world.device(directive.deviceCode) else {
            return .stall(.unreachableDevice)
        }
        switch directive.step {
        case Step.preflight: return preflight(directive, vessel, world)
        case Step.travelling: return travel(directive, vessel, world)
        default: return .wait   // later steps land in Tasks 6-7
        }
    }
    ...
}
```

with:

```swift
    /// The AMI survey controller stowed aboard this vessel, if any. STOWED, not
    /// merely co-located: `launch` deploys the controller's stowed devices, so
    /// one standing alongside the vessel would strand the run.
    public static func controller(aboard vessel: Device, in world: WorldSnapshot) -> Device? {
        world.devices.values.first { device in
            device.stowedInDeviceCode == vessel.deviceCode
                && device.availableDirectives.contains("survey_system")
        }
    }

    /// The controller's adopted drones that are also aboard the vessel. Both
    /// halves matter: `launch` only deploys devices this controller has
    /// adopted, and only ones that travelled with it.
    public static func adoptedDrones(
        of controller: Device, aboard vessel: Device, in world: WorldSnapshot
    ) -> [Device] {
        let adopted = Set(controller.controlledDeviceCodes)
        return world.devices.values
            .filter { adopted.contains($0.deviceCode) && $0.stowedInDeviceCode == vessel.deviceCode }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// Whether a system's scan counts say it is completely surveyed. UNKNOWN
    /// counts are never "scanned": surveying an already-done system costs a
    /// trip, but skipping an unscanned one loses the whole point of the run.
    public static func isFullyScanned(_ system: StarSystem?) -> Bool {
        guard let system,
              let planetsTotal = system.planetsTotal, planetsTotal > 0,
              let planetsScanned = system.planetsScanned,
              planetsScanned >= planetsTotal
        else { return false }
        // Moons are optional in the payload; when the server reports a total,
        // it must be met too.
        if let moonsTotal = system.moonsTotal, moonsTotal > 0 {
            guard let moonsScanned = system.moonsScanned, moonsScanned >= moonsTotal else {
                return false
            }
        }
        return true
    }
```

Preflight (identifier-for-identifier with the table above) and travel:

```swift
    private func preflight(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            // Queue exhausted. Stay put unless the run was created with
            // `returnToOrigin` — an unwanted return leg costs fuel and time.
            guard directive.returnToOrigin,
                  let origin = directive.originDesignation,
                  Self.system(of: vessel) != origin
            else { return .done }
            return .advanceStep(nextStep: Step.returning)
        }
        guard let controller = Self.controller(aboard: vessel, in: world) else {
            return .stall(.noSurveyControllerAboard)
        }
        guard !Self.adoptedDrones(of: controller, aboard: vessel, in: world).isEmpty else {
            return .stall(.noSurveyDroneAboard)
        }
        // Cached-only skip check: the live read is presence-gated, so a target
        // we haven't reached yet can only be judged from what we already hold.
        if Self.isFullyScanned(world.system(target)) { return .advanceTarget }
        return .assignController(deviceCode: controller.deviceCode, nextStep: Step.travelling)
    }

    private func travel(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else { return .advanceStep(nextStep: Step.preflight) }
        if Self.system(of: vessel) == target { return .advanceStep(nextStep: Step.configuring) }
        // An open op means the trip is under way. Expected, not a stall — and
        // the guard that stops a second travel landing on top of the first.
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: target), nextStep: Step.travelling
        )
    }

    /// The star system a device is currently in, or nil in transit/stowed.
    static func system(of device: Device) -> String? {
        device.location.map { SiteAssay.system(of: $0) }
    }
```

**Verify `Device.controlledDeviceCodes` and `Device.availableDirectives` exist** with those names before relying on them (`GameModels/Sources/Device.swift` around lines 226–290).

- [ ] **Step 4: Run the tests.** Expected: green.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine
git commit -m "Add Survey Run preflight and travel, with the stall matrix"
```

---

### Task 6: `SurveyRun` — configure and launch

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/SurveyRun.swift`
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRunTests.swift`

**Interfaces:**
- Consumes: `SurveyRun.surveyConfig`, `OperationKind.setDirective`, `OperationKind.simple("launch")`.
- Produces: no new API.

| Situation at `configuring` | Action |
| --- | --- |
| Controller unresolvable (not aboard any more) | `.stall(.noSurveyControllerAboard)` |
| Controller already running `survey_system` with exactly `surveyConfig` | `.advanceStep(launching)` |
| Otherwise | `.dispatch(.setDirective, controller, directive+config, nextStep: launching)` |

| Situation at `launching` | Action |
| --- | --- |
| Controller unresolvable | `.stall(.noSurveyControllerAboard)` |
| Otherwise | `.dispatch(.simple("launch"), controller, nextStep: awaiting)` |

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("Survey Run — configure and launch")
struct SurveyRunConfigureTests {
    /// A controller with no directive gets the full-survey config.
    @Test func setsTheSurveyDirective() {
        let directive = run(step: SurveyRun.Step.configuring, controllerCode: "AMI1")
        let action = SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
        #expect(action == .dispatch(
            kind: .setDirective, deviceCode: "AMI1",
            params: CommandParams(directive: "survey_system", configuration: SurveyRun.surveyConfig),
            nextStep: SurveyRun.Step.launching
        ))
    }

    /// An in-force directive that already matches EXACTLY is not re-issued —
    /// spec §4 step 4.
    @Test func skipsSetDirectiveWhenAlreadyExact() {
        var fleet = stagedFleet(vesselAt: "TAU-2")
        fleet[1] = withDirective(fleet[1], name: "survey_system", config: [
            "planets": .string("all"), "moons": .string("all"), "recall": .bool(true),
        ])
        let directive = run(step: SurveyRun.Step.configuring, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(fleet))
                == .advanceStep(nextStep: SurveyRun.Step.launching))
    }

    /// A MISMATCHED config is re-issued — `moons: none` left over from manual
    /// use would silently survey half the system.
    @Test func reissuesAMismatchedConfig() {
        var fleet = stagedFleet(vesselAt: "TAU-2")
        fleet[1] = withDirective(fleet[1], name: "survey_system", config: [
            "planets": .string("all"), "moons": .string("none"), "recall": .bool(true),
        ])
        let directive = run(step: SurveyRun.Step.configuring, controllerCode: "AMI1")
        guard case .dispatch(let kind, _, _, _) = SurveyRun().nextAction(directive: directive, world: world(fleet)) else {
            Issue.record("expected a re-issue")
            return
        }
        #expect(kind == .setDirective)
    }

    /// A different directive entirely is replaced.
    @Test func replacesADifferentDirective() {
        var fleet = stagedFleet(vesselAt: "TAU-2")
        fleet[1] = withDirective(fleet[1], name: "belt_search", config: [:])
        let directive = run(step: SurveyRun.Step.configuring, controllerCode: "AMI1")
        guard case .dispatch(let kind, _, _, _) = SurveyRun().nextAction(directive: directive, world: world(fleet)) else {
            Issue.record("expected a replacement")
            return
        }
        #expect(kind == .setDirective)
    }

    /// Launch goes to the CONTROLLER, not the vessel — it is what deploys the
    /// adopted stowed drones (spec §3).
    @Test func launchesTheController() {
        let directive = run(step: SurveyRun.Step.launching, controllerCode: "AMI1")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
                == .dispatch(kind: OperationKind.simple("launch"), deviceCode: "AMI1",
                             params: CommandParams(), nextStep: SurveyRun.Step.awaiting))
    }

    /// The controller vanishing mid-run (released, decommissioned) stalls
    /// rather than dispatching at a device that is no longer there.
    @Test func stallsWhenTheControllerIsGone() {
        let directive = run(step: SurveyRun.Step.launching, controllerCode: "AMI1")
        let fleet = [device("VES1", type: "transport_hauler", location: "TAU-2")]
        #expect(SurveyRun().nextAction(directive: directive, world: world(fleet))
                == .stall(.noSurveyControllerAboard))
    }
}
```

Add the fixture helper beside the others:

```swift
private func withDirective(_ device: Device, name: String, config: [String: JSONValue]) -> Device {
    var updated = device
    var detail: [String: JSONValue] = {
        if case let .object(existing) = updated.detail { return existing }
        return [:]
    }()
    detail["ami_directive"] = .object(["name": .string(name), "config": .object(config)])
    updated.detail = .object(detail)
    return updated
}
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement**

Add the two cases to the `switch`, and:

```swift
    /// The controller this run claimed, re-resolved from the fleet each time —
    /// the row is the checkpoint, and a controller that has since been released
    /// or decommissioned must surface rather than be dispatched at.
    private func claimedController(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> Device? {
        guard let code = directive.controllerCode else {
            return Self.controller(aboard: vessel, in: world)
        }
        return world.device(code)
    }

    private func configure(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            return .stall(.noSurveyControllerAboard)
        }
        if controller.currentDirective == "survey_system",
           Self.configMatches(controller.currentDirectiveConfig) {
            return .advanceStep(nextStep: Step.launching)
        }
        return .dispatch(
            kind: .setDirective, deviceCode: controller.deviceCode,
            params: CommandParams(directive: "survey_system", configuration: Self.surveyConfig),
            nextStep: Step.launching
        )
    }

    private func launch(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let controller = claimedController(directive, vessel, world) else {
            return .stall(.noSurveyControllerAboard)
        }
        return .dispatch(
            kind: OperationKind.simple("launch"), deviceCode: controller.deviceCode,
            params: CommandParams(), nextStep: Step.awaiting
        )
    }

    /// Whether an in-force config already equals `surveyConfig` on the three
    /// fields that matter. Compared field-by-field rather than whole-object:
    /// the server may echo extra keys, and an inequality there is not a reason
    /// to re-issue.
    static func configMatches(_ config: JSONValue?) -> Bool {
        guard let config else { return false }
        return config["planets"]?.stringValue == "all"
            && config["moons"]?.stringValue == "all"
            && config["recall"]?.boolValue == true
    }
```

- [ ] **Step 4: Run the tests.** Expected: green.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine
git commit -m "Add Survey Run configure and launch steps"
```

---

### Task 7: `SurveyRun` — completion detection, advance, and return

Spec §5, the riskiest part of the design: the controller drives its drones server-side, so there is no operation the app created to key off.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/SurveyRun.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift` (register the machine)
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRunTests.swift`

**Interfaces:**
- Consumes: `WorldSnapshot.log`, `DirectiveLogKind.directiveCompleted`.
- Produces: `SurveyRun.completionSeen(_ directive: Directive, _ world: WorldSnapshot) -> Bool`; `SurveyRun.backstopInterval: TimeInterval`; `DirectiveEngine.makeLive()` now defaults to `[SurveyRun()]`.

| Situation at `awaiting` | Action |
| --- | --- |
| A `.directiveCompleted` entry at or after `stepStartedAt - 5s` | `.refreshSystem(target, confirming)` |
| No entry, but `now - stepStartedAt > backstopInterval` | `.refreshSystem(target, confirming)` |
| Otherwise | `.wait` |

| Situation at `confirming` | Action |
| --- | --- |
| Counts say fully scanned | `.advanceTarget` |
| Not scanned, a completion entry exists | `.stall(.surveyIncomplete)` |
| Not scanned, no completion entry (backstop poll) | `.advanceStep(awaiting)` |

| Situation at `returning` | Action |
| --- | --- |
| Vessel already at origin (or no origin recorded) | `.done` |
| Vessel has an open operation | `.wait` |
| Otherwise | `.dispatch(.travel, vessel, destination: origin, nextStep: returning)` |

The guard is **issue-time relative** (`eventTime >= stepStartedAt - 5s`), matching `Reconciler.completeOpenOperation` and Stage 3's ingestion route: a completion delivered by catch-up after the app was closed still counts, while one that predates this step does not.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("Survey Run — completion detection")
struct SurveyRunCompletionTests {
    /// No completion yet, inside the backstop window: just wait. Cheap, and the
    /// common case for most of a survey.
    @Test func waitsForCompletion() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let snapshot = world(stagedFleet(vesselAt: "TAU-2"), now: Date(timeIntervalSince1970: 1_000))
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// A completion entry triggers the confirming read (spec §5 fast path).
    @Test func completionEventTriggersTheConfirmingRead() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .refreshSystem(designation: "TAU", nextStep: SurveyRun.Step.confirming))
    }

    /// A completion stamped BEFORE this step began is a replay — it must not
    /// end a survey that only just started.
    @Test func ignoresAReplayedPreStepCompletion() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 500))],
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot) == .wait)
    }

    /// Within the 5s skew tolerance an entry marginally older still counts.
    @Test func toleratesClockSkewOnTheCompletionGuard() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 897))],
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .refreshSystem(designation: "TAU", nextStep: SurveyRun.Step.confirming))
    }

    /// The lost-event backstop: after the interval, poll the counts even with
    /// no completion event. A dropped SSE frame must not strand the run forever.
    @Test func backstopPollsAfterTheInterval() {
        let directive = run(step: SurveyRun.Step.awaiting, controllerCode: "AMI1",
                            stepStartedAt: Date(timeIntervalSince1970: 900))
        let late = Date(timeIntervalSince1970: 900 + SurveyRun.backstopInterval + 1)
        let snapshot = world(stagedFleet(vesselAt: "TAU-2"), now: late)
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .refreshSystem(designation: "TAU", nextStep: SurveyRun.Step.confirming))
    }

    /// Counts agree: the target is done, move on.
    @Test func confirmingAdvancesWhenFullyScanned() {
        var scanned = StarSystem(designation: "TAU")
        scanned.planetsScanned = 4
        scanned.planetsTotal = 4
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            systems: ["TAU": scanned], now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot) == .advanceTarget)
    }

    /// A completion event whose counts DISAGREE stalls `surveyIncomplete`
    /// rather than silently advancing (spec §5, confirmation branch).
    @Test func confirmingStallsWhenTheEventDisagrees() {
        var partial = StarSystem(designation: "TAU")
        partial.planetsScanned = 2
        partial.planetsTotal = 4
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"),
            log: [completionEntry(at: Date(timeIntervalSince1970: 950))],
            systems: ["TAU": partial], now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .stall(.surveyIncomplete))
    }

    /// A BACKSTOP poll that finds the survey unfinished goes back to waiting —
    /// no completion was ever claimed, so there is nothing to disbelieve.
    @Test func backstopDisagreementReturnsToWaiting() {
        var partial = StarSystem(designation: "TAU")
        partial.planetsScanned = 2
        partial.planetsTotal = 4
        let directive = run(step: SurveyRun.Step.confirming, controllerCode: "AMI1")
        let snapshot = world(
            stagedFleet(vesselAt: "TAU-2"), systems: ["TAU": partial],
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(SurveyRun().nextAction(directive: directive, world: snapshot)
                == .advanceStep(nextStep: SurveyRun.Step.awaiting))
    }
}

@Suite("Survey Run — finishing")
struct SurveyRunFinishTests {
    /// Queue exhausted with returnToOrigin off: done, vessel stays put.
    @Test func finishesWithoutReturning() {
        let directive = run(targets: ["TAU"], targetIndex: 1)
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
                == .done)
    }

    /// returnToOrigin on and away from home: one final leg.
    @Test func returnsToOriginWhenAsked() {
        let directive = run(targets: ["TAU"], targetIndex: 1, returnToOrigin: true, origin: "SOL")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
                == .advanceStep(nextStep: SurveyRun.Step.returning))
    }

    /// Already home: done, no pointless leg.
    @Test func doesNotReturnWhenAlreadyHome() {
        let directive = run(targets: ["TAU"], targetIndex: 1, returnToOrigin: true, origin: "SOL")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "SOL-3")))
                == .done)
    }

    /// The return leg dispatches travel home, then completes on arrival.
    @Test func returningTravelsHomeThenCompletes() {
        let directive = run(step: SurveyRun.Step.returning, targets: ["TAU"], targetIndex: 1,
                            returnToOrigin: true, origin: "SOL")
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "TAU-2")))
                == .dispatch(kind: .travel, deviceCode: "VES1",
                             params: CommandParams(destination: "SOL"),
                             nextStep: SurveyRun.Step.returning))
        #expect(SurveyRun().nextAction(directive: directive, world: world(stagedFleet(vesselAt: "SOL-3")))
                == .done)
    }
}
```

Fixture helper:

```swift
private func completionEntry(at occurredAt: Date) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: "L1", directiveID: "D1", deviceCode: "AMI1", kind: .directiveCompleted,
        summary: "Survey System completed at TAU", step: "awaiting",
        operationID: nil, eventID: "E1", occurredAt: occurredAt
    )
}
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement**

```swift
    /// How long to wait on the `directive.completed` fast path before polling
    /// the counts anyway. A dropped SSE frame must not strand a run forever;
    /// ten minutes keeps the cost to a handful of reads per survey.
    public static let backstopInterval: TimeInterval = 10 * 60

    /// Tolerance when comparing a completion's time against the step's start.
    /// Same value and reasoning as `Reconciler.eventTimeSkewTolerance`.
    static let eventTimeSkewTolerance: TimeInterval = 5

    /// Whether a completion for THIS step has landed in the timeline.
    /// Issue-time relative (not wall-clock): a completion delivered by catch-up
    /// after the app was closed still counts, while one predating this step is
    /// a replay and does not.
    public static func completionSeen(_ directive: Directive, _ world: WorldSnapshot) -> Bool {
        world.log.contains { entry in
            entry.kind == .directiveCompleted
                && entry.occurredAt >= directive.stepStartedAt.addingTimeInterval(-eventTimeSkewTolerance)
        }
    }

    private func awaitCompletion(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else { return .advanceStep(nextStep: Step.preflight) }
        if Self.completionSeen(directive, world) {
            return .refreshSystem(designation: target, nextStep: Step.confirming)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) > Self.backstopInterval {
            return .refreshSystem(designation: target, nextStep: Step.confirming)
        }
        return .wait
    }

    private func confirm(_ directive: Directive, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else { return .advanceStep(nextStep: Step.preflight) }
        if Self.isFullyScanned(world.system(target)) { return .advanceTarget }
        // The server SAID it finished and the counts disagree — surface it
        // rather than advancing over a half-surveyed system.
        if Self.completionSeen(directive, world) { return .stall(.surveyIncomplete) }
        // A backstop poll that found it unfinished: nothing claimed completion,
        // so there is nothing to disbelieve. Keep waiting.
        return .advanceStep(nextStep: Step.awaiting)
    }

    private func returnHome(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let origin = directive.originDesignation else { return .done }
        if Self.system(of: vessel) == origin { return .done }
        if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
        return .dispatch(
            kind: .travel, deviceCode: vessel.deviceCode,
            params: CommandParams(destination: origin), nextStep: Step.returning
        )
    }
```

Wire the three steps into the `switch`, and replace the `default: return .wait` with a case that logs an unknown step and waits (an unrecognised step must never dispatch).

Then register the machine:

```swift
    public static func makeLive(machines: [any MissionStepMachine] = [SurveyRun()]) -> DirectiveEngine {
```

updating that doc comment — it currently says the registry is empty in production.

- [ ] **Step 4: Run the whole `DirectiveEngineTests` product.** Expected: green. Note the engine's `unknownKindIsLeftAlone` test uses `.relayRun`, which stays unregistered — it should still pass.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine
git commit -m "Detect Survey Run completion and finish the queue"
```

---

### Task 8: A minimal "New Survey Run" sheet

Nothing creates `Directive` rows today, so without this the mission is only reachable from tests. Trimmed to Survey Run: pick a vessel, build a target queue, launch.

**Files:**
- Create: `app/Modules/DirectivesFeature/Sources/NewDirectiveFeature.swift`
- Create: `app/Modules/DirectivesFeature/Sources/NewDirectiveSheet.swift`
- Create: `app/Modules/DirectivesFeature/Sources/EligibleVesselRow.swift` (row struct in its own file — preview JIT crash)
- Modify: `app/Modules/DirectivesFeature/Sources/DirectivesFeature.swift` (`@Presents` destination + toolbar action)
- Modify: `app/Modules/DirectivesFeature/Sources/DirectivesListView.swift` (the "+" button)
- Modify: `app/Modules/Package.swift` (`DirectivesFeature` gains `DirectiveEngine` and `UniverseModels`)
- Test: `app/Modules/DirectivesFeature/Tests/NewDirectiveFeatureTests.swift`

**Interfaces:**
- Consumes: `SurveyRun.controller(aboard:in:)`/`adoptedDrones(of:aboard:in:)` for eligibility, `Star` (census) for target search, `@Dependency(\.uuid)`, `@Dependency(\.date)`.
- Produces:
  - `NewDirectiveFeature` (`@Reducer`) with `State` holding `vesselCode: String?`, `targets: [String]`, `search: String`, `returnToOrigin: Bool`, `@FetchAll` devices + stars
  - `NewDirectiveFeature.State.eligibleVessels: [Device]`
  - `NewDirectiveFeature.Action.Delegate.created(Directive)`
  - `DirectivesFeature.Action.newDirectiveTapped`

**Eligibility rule (the whole point of surfacing it):** a vessel is eligible when `SurveyRun.controller(aboard:in:)` finds a stowed survey controller AND that controller has at least one adopted drone stowed aboard. Ineligible vessels are not offered — with an empty state naming the precondition, since staging is the player's job.

Build the eligibility check against a `WorldSnapshot` assembled from the feature's `@FetchAll devices` (`WorldSnapshot(devices:openOperations:log:systems:now:)` with empties) so there is exactly one definition of "staged", shared with the engine.

- [ ] **Step 1: Write the failing reducer tests**

```swift
@Suite("New directive")
@MainActor
struct NewDirectiveFeatureTests {
    /// Only properly staged vessels are offered — a vessel with no controller
    /// aboard would stall on its first evaluation.
    @Test func onlyStagedVesselsAreEligible() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
            try Device.insert { Self.bareVessel("VES2") }.execute(db)
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off
        #expect(store.state.eligibleVessels.map(\.deviceCode) == ["VES1"])
    }

    /// Launch writes a running directive seeded at the machine's first step,
    /// with the origin recorded so returnToOrigin has a destination.
    @Test func launchCreatesARunningDirective() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for device in Self.stagedFleet() { try Device.insert { device }.execute(db) }
        }
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.vesselCode, "VES1")))
        await store.send(.targetAdded("TAU"))
        await store.send(.launchTapped)

        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.count == 1)
        #expect(created[0].status == .running)
        #expect(created[0].kind == .surveyRun)
        #expect(created[0].deviceCode == "VES1")
        #expect(created[0].targets == ["TAU"])
        #expect(created[0].targetIndex == 0)
        #expect(created[0].step == SurveyRun().firstStep)
        #expect(created[0].originDesignation == "SOL")
        #expect(created[0].controllerCode == nil, "the engine claims the controller at preflight")
    }

    /// Launch is refused with no vessel or no targets — a run with an empty
    /// queue would complete instantly and confuse.
    @Test func launchNeedsAVesselAndATarget() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        #expect(store.state.canLaunch == false)
        await store.send(.launchTapped)
        let created = try await database.read { db in try Directive.all.fetchAll(db) }
        #expect(created.isEmpty)
    }

    /// The same target isn't queued twice by a double tap; a deliberate revisit
    /// is a separate concern (the queue allows duplicates by design, but the
    /// picker doesn't create them accidentally).
    @Test func doesNotDoubleAddATarget() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: NewDirectiveFeature.State()) {
            NewDirectiveFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.targetAdded("TAU"))
        await store.send(.targetAdded("TAU"))
        #expect(store.state.targets == ["TAU"])
    }
}
```

Fixtures mirror `SurveyRunTests`' `stagedFleet()` (vessel + stowed controller with one adopted stowed drone) and a `bareVessel(_:)` with nothing aboard.

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement the reducer**

`NewDirectiveFeature`: `@ObservableState` holding `@FetchAll(Device.order { $0.deviceCode })` devices and `@FetchAll(Star.order { $0.designation })` stars, plus `vesselCode`, `targets`, `search`, `returnToOrigin`. Computed `eligibleVessels` (per the rule above), `canLaunch` (`vesselCode != nil && !targets.isEmpty`), and `searchResults` (stars whose designation has the search prefix, case-insensitive, minus already-queued targets, capped at 50 — the census runs to thousands).

`.launchTapped` builds the row and writes it:

```swift
            case .launchTapped:
                guard let vesselCode = state.vesselCode, !state.targets.isEmpty,
                      let vessel = state.devices.first(where: { $0.deviceCode == vesselCode })
                else { return .none }
                let directive = Directive(
                    id: uuid().uuidString,
                    kind: .surveyRun,
                    status: .running,
                    deviceCode: vesselCode,
                    // The engine claims the controller at preflight, from
                    // whatever is actually aboard when the run starts.
                    controllerCode: nil,
                    targets: state.targets,
                    targetIndex: 0,
                    step: SurveyRun().firstStep,
                    stepStartedAt: date.now,
                    returnToOrigin: state.returnToOrigin,
                    originDesignation: vessel.location.map { SiteAssay.system(of: $0) },
                    attentionReason: nil,
                    createdAt: date.now,
                    updatedAt: date.now
                )
                return .run { send in
                    try? await database.write { db in
                        try Directive.insert { directive }.execute(db)
                    }
                    await send(.delegate(.created(directive)))
                }
```

- [ ] **Step 4: Implement the sheet and wire it into `DirectivesFeature`**

`NewDirectiveSheet`: vessel `Picker` over `eligibleVessels` (designation in `.rcMonoSmall`); a search `RCField` plus results list; the queued targets as an ordered list with remove buttons; a `returnToOrigin` `Toggle` with the caption "Fly home when the queue empties"; Cancel/Launch buttons. Empty state when `eligibleVessels.isEmpty`: "No vessel is carrying a survey controller with adopted drones. Stow an AMI Survey Controller and at least one adopted Survey Drone aboard a vessel first." Tokens only; designations mono.

In `DirectivesFeature`: add `@Presents public var newDirective: NewDirectiveFeature.State?`, a `newDirectiveTapped` action that assigns it, a `.ifLet`, and handle `.newDirective(.presented(.delegate(.created(directive))))` by selecting the new row (`state.selectedRowID = "custom:\(directive.id)"`) and dismissing. Present with `.sheet(item: $store.scope(state: \.newDirective, action: \.newDirective))` — feature-tier dialect, never `.sheet(isPresented:)`.

In `DirectivesListView`: a toolbar "+" button sending `.newDirectiveTapped`.

- [ ] **Step 5: Run `DirectivesFeatureTests`.** Expected: green, including the Stage 1–3 tests.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/Package.swift app/Modules/DirectivesFeature
git commit -m "Add a minimal New Survey Run sheet"
```

---

### Task 9: Full-suite verification and the memory record

**Files:**
- Modify: `app/.claude/memory/directives-feature.md` (Stage 4 section)
- Modify: `app/.claude/memory/MEMORY.md` (index line)

- [ ] **Step 1: Build and run every test product**

```bash
swift build --build-tests 2>&1 | tail -2
grep -n 'name: "[A-Za-z]*Tests"' Package.swift | sed 's/.*name: "//;s/".*//' | sort > /tmp/products.txt
rm -f .build/ev-all-*.jsonl
for p in $(cat /tmp/products.txt); do
  swift test --test-product "$p" --disable-xctest --event-stream-version 0 \
    --event-stream-output-path ".build/ev-all-$p.jsonl" </dev/null >/dev/null 2>&1
  [ -f ".build/ev-all-$p.jsonl" ] || echo "MISSING STREAM: $p"
done
cat .build/ev-all-*.jsonl > .build/ev-all.jsonl
jq -s 'map(select(.kind=="event").payload) as $e
  | ($e | map(select(.kind=="issueRecorded" and .issue.isFailure != false).testID) | unique) as $f
  | { total: ($e|map(select(.kind=="testStarted"))|length), failed: ($f|length),
      runsCompleted: ($e|map(select(.kind=="runEnded"))|length),
      crashed: (($e|map(select(.kind=="testStarted").testID)) - ($e|map(select(.kind=="testEnded" or .kind=="testSkipped").testID)) | length) }' .build/ev-all.jsonl
```
Expected: `failed: 0`, `crashed: 0`, and `runsCompleted` equal to the product count. Redirect `</dev/null` on `swift test` — inside a loop it otherwise eats the product list.

- [ ] **Step 2: Record Stage 4 in the memory note**

Append a "## Stage 4 SHIPPED" section to `app/.claude/memory/directives-feature.md` covering:

- What landed: `SurveyRun`, the three new mission actions, the richer `WorldSnapshot`, `LocationsClient.hydrateSystem`, `noSurveyControllerAboard`, and the New Survey Run sheet.
- **The precondition contract** (operator decision): the run uses an already-stowed controller and its already-adopted stowed drones; it never stows or adopts, because adoption is persistent state that outlives the mission. Missing either is a stall.
- **The §5 deviation:** the "skip an already-scanned target" precondition reads the CACHED blob only — `GET locations/{star}` is presence-gated, so a live read before arrival is impossible. Live re-reads happen only after arrival.
- **Unknown scan counts are never treated as scanned** — the safe direction to be wrong in.
- The completion scheme: `directive.completed` log entry (fast path, issue-time-relative guard) → `refreshSystem` → counts agree ⇒ advance, disagree ⇒ `surveyIncomplete` stall; plus the 10-minute backstop poll for a dropped event, whose disagreement returns to waiting rather than stalling.
- That `DirectiveEngine.makeLive` now registers `[SurveyRun()]`, so the engine is no longer inert.
- Full-suite numbers at ship.

Update the `MEMORY.md` index line to say Stages 1–4 shipped and Relay Run (Stage 5) is what remains.

- [ ] **Step 3: Commit**

```bash
git add app/.claude/memory
git commit -m "Memory: record Survey Run and its precondition contract"
```

---

## Self-review

**Spec coverage.** §4 Survey Run: steps 1 (stow) and the adopt implication are deliberately *preconditions*, not steps, per the operator's 2026-07-26 decision — recorded in the plan header, the machine's stall matrix, and the memory note. Step 2 (travel) → Task 5. Step 3 (automatic replicant scan) → no engine work, correct. Step 4 (`set_directive` with exact-match skip) → Task 6. Step 5 (`launch` on the controller) → Task 6. Step 6 (wait for completion) → Task 7. Step 7 (next target, `returnToOrigin`) → Task 7. §5 completion detection: fast path, backstop, precondition skip, and the confirmation-disagreement stall → Tasks 5 and 7. §8 stall matrix: `noSurveyControllerAboard`, `noSurveyDroneAboard`, `unreachableDevice`, `surveyIncomplete` all tested; `commandRejected` is already the executor's behaviour from Stage 3. §7's new-directive flow → Task 8, trimmed to Survey Run.

**Out of scope, deliberately:** Relay Run and the FTL-mesh incremental add (Stage 5); the `needsAttention` resolution verbs (Retry / Skip target / Cancel) — spec §7 puts them in the detail pane and no stage claims them, so they are the natural first slice after this one, and until then a stalled run is visible but not resolvable from the UI; `.opCompleted` log entries; device tagging (§7).

**Known risks.** (1) `StarSystem`'s initializer may need more than `designation:` — check before writing fixtures. (2) `OperationKind.simple("launch")` classifies as an immediate command, so it creates no `Operation` row; the machine therefore does not wait on one after launching, which is why `awaiting` keys off the completion entry rather than an op. (3) The backstop interval (10 min) times against `stepStartedAt`, which `refreshSystem` re-stamps — so a run that keeps failing to confirm polls every 10 minutes rather than tightening into a loop. That is intended; if it proves too slow to notice a finished survey, lower the constant rather than adding a second timer.
