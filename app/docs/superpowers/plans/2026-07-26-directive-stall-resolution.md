# Directive Stall Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a stalled mission resolvable from the app. Today a run that enters `needsAttention` is visible but inert — clearing it means editing SQLite by hand. This adds the spec's three verbs (Retry step / Skip target / Cancel directive) plus pause/resume, and a detail-pane panel that says what went wrong in words.

**Architecture:** Resolution is a set of row transitions on `Directive`, so it lives in `DirectiveEngine` beside the executor that produces those states — not in the feature. A new `DirectiveResolutionClient` (struct-of-closures over one live implementation, the `DeviceRefreshClient`/`CommandGovernorClient` shape) vends `retry` / `skipTarget` / `cancel` / `pause` / `resume`, each writing the row and a `.resolved` timeline entry in one transaction. `MissionRegistry` becomes the single place mission machines are registered, so `skipTarget` can reset the step to the right machine's `firstStep` without the feature knowing any step vocabulary. `DirectivesFeature` gains five actions that call the client; the detail pane grows a stall panel carrying the reason in plain language.

**Why Retry is "clear the stall and re-stamp", not "restart the target":** re-stamping `stepStartedAt` is what makes the retry recover on its own. A `surveyIncomplete` stall re-stamped this way no longer sees the old completion entry (the guard is issue-time relative), so the machine drops back to waiting and the backstop re-polls rather than instantly re-stalling on the same stale evidence. A `noSurveyControllerAboard` retry re-validates staging — which is exactly what the user just fixed by hand.

**Tech Stack:** Swift 6.4, macOS 26+, SQLiteData, swift-dependencies, TCA (feature layer), Swift Testing.

**Spec:** `app/docs/superpowers/specs/2026-07-24-directives-design.md` §7 (detail pane) and §8 (error handling). **Deviation, deliberate:** §7 says "`RCErrorBanner` with Retry / Skip target / Cancel", but `RCErrorBanner` hard-codes a single Dismiss button and is used by four other screens. Widening it for one caller is the wrong trade, so this builds a purpose-made stall panel in `DirectivesFeature` using the same tokens. Same intent, no shared-control churn.

**Prior stages:** `app/.claude/memory/directives-feature.md` — Stage 3 and Stage 4 invariants. Do not undo them.

## Global Constraints

- Paths are relative to the repo root. SPM package root is `app/Modules/` — run `swift` commands there.
- **Run tests via the event stream, never console text.** Per product:
  ```bash
  swift test --test-product <Name>Tests --disable-xctest \
    --event-stream-version 0 --event-stream-output-path .build/ev.jsonl
  jq -r 'select(.kind=="event").payload | select(.kind=="issueRecorded" and .issue.isFailure != false) | "\(.testID)\n    \(.messages[0].text)"' .build/ev.jsonl
  ```
  Empty output means no failures; also confirm `runEnded` is present and no test started without ending.
- **Only `.running` directives are evaluated by the engine.** Every verb here either leaves the row unrunnable (`paused`, `cancelled`) or hands it back to the engine as `.running` — nothing in between.
- **One transaction per resolution:** the row change and its `.resolved` log entry land together, or neither does.
- **The engine owns step vocabulary.** The feature must never name a step string; `skipTarget` resolves `firstStep` through `MissionRegistry`.
- **No hard-coded colors, spacing, or font sizes** — `DesignSystem.swift` tokens only. **Designations render monospace.** **Row structs in their own file.** **Pure logic never as a static on a SwiftUI `View`.**
- **Loud test defaults:** the new client's `testValue` uses `unimplemented(...)`.
- **Logging:** `os.Logger`, subsystem `name.pennig.replicould`, category `DirectiveEngine` / `Directives`.
- **Commits go to the worktree branch; no PRs, no pushes.** One commit per task, and **scope `git add` to the files the task touched**.
- **Verify with SourceKit-LSP before signing off**; build first, and treat `No such module` diagnostics on code that compiles as index noise.

---

### Task 1: Put stall reasons into words

`DirectiveAttentionReason` has no display name, so a panel today could only show `noSurveyControllerAboard`. Each reason also has an obvious remedy worth stating — the user is being asked to fix something.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (extend `DirectiveAttentionReason`)
- Test: `app/Modules/GameModels/Tests/DirectiveSchemaTests.swift` (append)

**Interfaces:**
- Produces: `DirectiveAttentionReason.displayName: String`, `DirectiveAttentionReason.guidance: String`

- [ ] **Step 1: Write the failing test**

```swift
    /// Every stall reason reads as a sentence, not a case name — the detail
    /// pane shows these directly to the user, who is being asked to fix
    /// something and needs to know what.
    @Test func everyAttentionReasonHasWords() {
        for reason in DirectiveAttentionReason.allCases {
            #expect(reason.displayName != reason.rawValue)
            #expect(!reason.displayName.isEmpty)
            #expect(!reason.guidance.isEmpty)
        }
    }
```

- [ ] **Step 2: Run it to verify it fails.** Expected: no member `displayName`.

- [ ] **Step 3: Implement**

```swift
    /// The panel's headline for this stall.
    public var displayName: String {
        switch self {
        case .noRelayCoLocated: "No relay aboard"
        case .noSurveyDroneAboard: "No survey drone aboard"
        case .noSurveyControllerAboard: "No survey controller aboard"
        case .unreachableDevice: "Device unreachable"
        case .surveyIncomplete: "Survey incomplete"
        case .commandRejected: "Command rejected"
        }
    }

    /// What the user can do about it. Staging is the player's job (a Survey Run
    /// never stows or adopts), so these name the fix rather than implying the
    /// engine will retry into a fixed world on its own.
    public var guidance: String {
        switch self {
        case .noRelayCoLocated:
            "Stow an FTL relay aboard the vessel, then retry."
        case .noSurveyDroneAboard:
            "Stow a survey drone aboard the vessel and adopt it with the controller, then retry."
        case .noSurveyControllerAboard:
            "Stow an AMI survey controller aboard the vessel, then retry."
        case .unreachableDevice:
            "The mission's device is missing from the fleet. Cancel the run, or retry once it's back."
        case .surveyIncomplete:
            "The controller reported finishing, but the system isn't fully scanned. Retry to keep waiting, or skip this target."
        case .commandRejected:
            "The server refused the last command. Check the device, then retry or skip this target."
        }
    }
```

- [ ] **Step 4: Run the test.** Expected: green.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameModels
git commit -m "Put directive stall reasons into words"
```

---

### Task 2: `MissionRegistry` and `DirectiveResolutionClient`

The five transitions, plus one place mission machines are registered so `skipTarget` can find a kind's first step.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/MissionRegistry.swift`
- Create: `app/Modules/DirectiveEngine/Sources/DirectiveResolutionClient.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift` (default `makeLive` to the registry)
- Test: `app/Modules/DirectiveEngine/Tests/DirectiveResolutionTests.swift`

**Interfaces:**
- Consumes: `Directive`, `DirectiveLogEntry`, `SurveyRun`.
- Produces:
  - `MissionRegistry.machines: [any MissionStepMachine]`, `MissionRegistry.machine(for: DirectiveKind) -> (any MissionStepMachine)?`, `MissionRegistry.firstStep(for: DirectiveKind) -> String?`
  - `DirectiveResolutionClient` with `retry`, `skipTarget`, `cancel`, `pause`, `resume` — each `@Sendable (String) async -> Void` keyed by directive id — vended as `@Dependency(\.directiveResolution)`

**Transition table (exact):**

| Verb | Row changes | Log summary | Allowed from |
| --- | --- | --- | --- |
| `retry` | `status = .running`, `attentionReason = nil`, `stepStartedAt = now` | "Retried <step>" | `needsAttention` only |
| `skipTarget` | `targetIndex += 1`, `step = firstStep`, `stepStartedAt = now`, `status = .running`, `attentionReason = nil` | "Skipped <target>" | `needsAttention`, `paused` |
| `cancel` | `status = .cancelled`, `attentionReason = nil` | "Cancelled" | anything not already finished |
| `pause` | `status = .paused` | "Paused" | `running` only |
| `resume` | `status = .running`, `attentionReason = nil`, `stepStartedAt = now` | "Resumed" | `paused` only |

Every verb writes `updatedAt = now` and one `.resolved` `DirectiveLogEntry` (`directiveID` set, `deviceCode` nil, `step` = the step after the change). A verb applied from a disallowed status is a **no-op with a logged notice** — the UI shouldn't offer it, but a stale click must not corrupt the row.

`cancel` deliberately does NOT clear the controller's AMI directive: that is a server-side command with its own failure modes, and cancelling releases ownership (`.cancelled` is outside `DirectiveRow.owningStatuses`), so the built-in row's Clear button becomes available for the user to do it deliberately.

- [ ] **Step 1: Write the failing tests**

Create `DirectiveResolutionTests.swift`:

```swift
//
//  DirectiveResolutionTests.swift
//  Replicould — DirectiveEngine
//
//  The five stall-resolution transitions. Each is a row change plus its
//  timeline entry in one transaction, and each refuses to run from a status it
//  doesn't apply to — the UI shouldn't offer it, but a stale click must not
//  corrupt the row.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import DirectiveEngine

private func stalled(
    _ reason: DirectiveAttentionReason = .commandRejected,
    step: String = "configuring",
    targets: [String] = ["TAU", "SOL"],
    targetIndex: Int = 0,
    status: DirectiveStatus = .needsAttention
) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: status, deviceCode: "VES1",
        controllerCode: "AMI1", targets: targets, targetIndex: targetIndex,
        step: step, stepStartedAt: Date(timeIntervalSince1970: 100),
        returnToOrigin: false, originDesignation: "SOL",
        attentionReason: status == .needsAttention ? reason : nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func seed(_ directive: Directive) async throws -> any DatabaseWriter {
    let database = try GameDatabase.bootstrap()
    try await database.write { db in try Directive.insert { directive }.execute(db) }
    return database
}

private func load(_ database: any DatabaseWriter) async throws -> Directive? {
    try await database.read { db in try Directive.where { $0.id.eq("D1") }.fetchOne(db) }
}

private func entries(_ database: any DatabaseWriter) async throws -> [DirectiveLogEntry] {
    try await database.read { db in try DirectiveLogEntry.order { $0.occurredAt }.fetchAll(db) }
}

@Suite("Directive resolution")
struct DirectiveResolutionTests {
    /// Retry hands the run back to the engine on the SAME step, with
    /// `stepStartedAt` re-stamped — which is what lets a surveyIncomplete stall
    /// recover instead of instantly re-stalling on the same stale completion.
    @Test func retryClearsTheStallAndRestampsTheStep() async throws {
        let database = try await seed(stalled(.surveyIncomplete, step: "confirming"))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.retry("D1")
        }
        let directive = try await load(database)
        #expect(directive?.status == .running)
        #expect(directive?.attentionReason == nil)
        #expect(directive?.step == "confirming")
        #expect(directive?.stepStartedAt == Date(timeIntervalSince1970: 5_000))
        #expect(try await entries(database).map(\.kind) == [.resolved])
    }

    /// Skip advances the queue and restarts at the machine's first step, so the
    /// next target begins with a fresh preflight rather than mid-procedure.
    @Test func skipTargetAdvancesAndRestartsTheMachine() async throws {
        let database = try await seed(stalled(step: "configuring", targetIndex: 0))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.skipTarget("D1")
        }
        let directive = try await load(database)
        #expect(directive?.targetIndex == 1)
        #expect(directive?.step == SurveyRun().firstStep)
        #expect(directive?.status == .running)
        #expect(directive?.attentionReason == nil)
        #expect(directive?.currentTarget == "SOL")
    }

    /// Skipping the LAST target leaves an exhausted queue, which the machine
    /// resolves to `.done` on its next evaluation — not an error state.
    @Test func skippingTheLastTargetExhaustsTheQueue() async throws {
        let database = try await seed(stalled(targets: ["TAU"], targetIndex: 0))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.skipTarget("D1")
        }
        let directive = try await load(database)
        #expect(directive?.targetIndex == 1)
        #expect(directive?.currentTarget == nil)
        #expect(directive?.status == .running)
    }

    /// Cancel ends the run. It deliberately does NOT clear the controller's AMI
    /// directive — that's a server command with its own failure modes, and
    /// cancelling releases ownership so the user can Clear it deliberately.
    @Test func cancelEndsTheRunAndReleasesTheController() async throws {
        let database = try await seed(stalled())
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.cancel("D1")
        }
        let directive = try await load(database)
        #expect(directive?.status == .cancelled)
        #expect(directive?.attentionReason == nil)
        #expect(directive?.controllerCode == "AMI1", "the record of what it drove survives")
    }

    /// Pause takes a running directive out of the engine's reach.
    @Test func pauseStopsARunningDirective() async throws {
        let database = try await seed(stalled(step: "awaiting", status: .running))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.pause("D1")
        }
        #expect(try await load(database)?.status == .paused)
    }

    /// Resume re-stamps the step for the same reason retry does.
    @Test func resumeRestartsAPausedDirective() async throws {
        let database = try await seed(stalled(step: "awaiting", status: .paused))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.resume("D1")
        }
        let directive = try await load(database)
        #expect(directive?.status == .running)
        #expect(directive?.stepStartedAt == Date(timeIntervalSince1970: 5_000))
    }

    /// A verb applied from a status it doesn't apply to is a no-op. The UI
    /// shouldn't offer it, but a stale click must not corrupt the row.
    @Test func verbsRefuseInapplicableStatuses() async throws {
        let database = try await seed(stalled(step: "awaiting", status: .running))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.retry("D1")     // only from needsAttention
            await resolution.resume("D1")    // only from paused
        }
        let directive = try await load(database)
        #expect(directive?.step == "awaiting")
        #expect(directive?.stepStartedAt == Date(timeIntervalSince1970: 100), "untouched")
        #expect(try await entries(database).isEmpty)
    }

    /// Cancelling an already-finished run writes nothing.
    @Test func cancelIsANoOpOnAFinishedRun() async throws {
        let database = try await seed(stalled(status: .completed))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.cancel("D1")
        }
        #expect(try await load(database)?.status == .completed)
        #expect(try await entries(database).isEmpty)
    }

    /// A missing directive id is a no-op, not a crash.
    @Test func unknownDirectiveIsANoOp() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 5_000))
            $0.uuid = .incrementing
        } operation: {
            @Dependency(\.directiveResolution) var resolution
            await resolution.retry("NOPE")
        }
        #expect(try await entries(database).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails.** Expected: no `directiveResolution`.

- [ ] **Step 3: Write `MissionRegistry`**

```swift
//
//  MissionRegistry.swift
//  Replicould — DirectiveEngine
//
//  The one place mission machines are registered. Both the engine (which
//  machine runs a directive) and resolution (which step a skipped target
//  restarts at) resolve through here, so adding Relay Run in Stage 5 is a
//  one-line edit rather than two.
//

import Foundation
import GameModels

public enum MissionRegistry {
    /// Every mission the app can run. Relay Run joins in Stage 5.
    public static let machines: [any MissionStepMachine] = [SurveyRun()]

    public static func machine(for kind: DirectiveKind) -> (any MissionStepMachine)? {
        machines.first { $0.kind == kind }
    }

    /// The step a freshly-started target begins on, or nil for a kind with no
    /// registered machine (which the engine leaves alone anyway).
    public static func firstStep(for kind: DirectiveKind) -> String? {
        machine(for: kind)?.firstStep
    }
}
```

Then change `DirectiveEngine.makeLive`'s default to `machines: [any MissionStepMachine] = MissionRegistry.machines`, updating its doc comment.

- [ ] **Step 4: Write the client**

Create `DirectiveResolutionClient.swift`. One `apply` helper does the read-modify-write plus the log entry in a single transaction; each verb supplies the allowed statuses, the mutation, and the summary. Shape:

```swift
public struct DirectiveResolutionClient: Sendable {
    /// Clear a stall and hand the run back to the engine on the same step.
    public var retry: @Sendable (_ directiveID: String) async -> Void
    /// Abandon the current target and restart the machine on the next one.
    public var skipTarget: @Sendable (_ directiveID: String) async -> Void
    /// End the run for good.
    public var cancel: @Sendable (_ directiveID: String) async -> Void
    /// Take a running directive out of the engine's reach.
    public var pause: @Sendable (_ directiveID: String) async -> Void
    /// Hand a paused directive back.
    public var resume: @Sendable (_ directiveID: String) async -> Void
}
```

with `liveValue` built over a private `apply(directiveID:from:summary:mutate:)`:

```swift
    /// One transaction: the row change and its timeline entry land together or
    /// neither does. A verb applied from a status it doesn't apply to is a
    /// logged no-op — the UI shouldn't offer it, but a stale click must not
    /// corrupt the row.
    private static func apply(
        _ directiveID: String,
        from allowed: Set<DirectiveStatus>,
        summary: @escaping @Sendable (Directive) -> String,
        mutate: @escaping @Sendable (inout Directive, Date) -> Void
    ) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        let now = date.now
        let entryID = uuid().uuidString
        do {
            try await database.write { db in
                guard var directive = try Directive.where({ $0.id.eq(directiveID) }).fetchOne(db)
                else {
                    logger.notice("resolution on unknown directive \(directiveID, privacy: .public) — ignored")
                    return
                }
                guard allowed.contains(directive.status) else {
                    logger.notice("resolution refused on \(directiveID, privacy: .public): status is \(directive.status.rawValue, privacy: .public)")
                    return
                }
                let text = summary(directive)
                mutate(&directive, now)
                directive.updatedAt = now
                try Directive.upsert { directive }.execute(db)
                try DirectiveLogEntry.insert {
                    DirectiveLogEntry(
                        id: entryID, directiveID: directiveID, deviceCode: nil,
                        kind: .resolved, summary: text, step: directive.step,
                        operationID: nil, eventID: nil, occurredAt: now
                    )
                }.execute(db)
            }
        } catch {
            logger.error("resolution write failed for \(directiveID, privacy: .public): \(error)")
        }
    }
```

Each verb per the transition table; `skipTarget`'s mutation uses `MissionRegistry.firstStep(for: directive.kind) ?? directive.step` (a kind with no machine keeps its step — it is inert either way). `testValue` uses `unimplemented(...)` for all five; `previewValue` is inert closures.

- [ ] **Step 5: Run the tests.** Expected: green, and `DirectiveEngineTests` overall still green.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine
git commit -m "Add directive stall-resolution transitions"
```

---

### Task 3: The verbs in the detail pane

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/DirectivesFeature.swift` (five actions)
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveDetailView.swift` (stall panel + pause/resume)
- Create: `app/Modules/DirectivesFeature/Sources/DirectiveStallPanel.swift`
- Test: `app/Modules/DirectivesFeature/Tests/DirectivesFeatureTests.swift` (append)

**Interfaces:**
- Consumes: `@Dependency(\.directiveResolution)`, `DirectiveAttentionReason.displayName`/`guidance`.
- Produces: `DirectivesFeature.Action` cases `retryTapped`, `skipTargetTapped`, `cancelRunTapped`, `pauseTapped`, `resumeTapped`; `DirectiveStallPanel` view.

Each action guards on `case .custom` (mirroring the built-in-only guards already there — a built-in row has no mission to resolve) and calls the client with that directive's id.

- [ ] **Step 1: Write the failing tests**

```swift
    /// The three verbs reach the resolution client for the selected mission.
    @Test func stallVerbsResolveTheSelectedRun() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.stalledMission(id: "D1") }.execute(db)
        }
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "custom:D1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.directiveResolution.retry = { id in calls.withValue { $0.append("retry:\(id)") } }
            $0.directiveResolution.skipTarget = { id in calls.withValue { $0.append("skip:\(id)") } }
            $0.directiveResolution.cancel = { id in calls.withValue { $0.append("cancel:\(id)") } }
        }
        store.exhaustivity = .off

        await store.send(.retryTapped)
        await store.send(.skipTargetTapped)
        await store.send(.cancelRunTapped)
        #expect(calls.value == ["retry:D1", "skip:D1", "cancel:D1"])
    }

    /// The verbs are no-ops with a BUILT-IN row selected — it has no mission to
    /// resolve, and its `deviceCode` is a controller, not a directive id.
    @Test func stallVerbsAreNoOpsForABuiltInRow() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
        }
        let called = LockIsolated(false)
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.directiveResolution.retry = { _ in called.setValue(true) }
            $0.directiveResolution.cancel = { _ in called.setValue(true) }
        }
        store.exhaustivity = .off

        await store.send(.retryTapped)
        await store.send(.cancelRunTapped)
        #expect(called.value == false)
    }

    /// Pause and resume reach the client too.
    @Test func pauseAndResumeReachTheClient() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.stalledMission(id: "D1") }.execute(db)
        }
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "custom:D1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.directiveResolution.pause = { id in calls.withValue { $0.append("pause:\(id)") } }
            $0.directiveResolution.resume = { id in calls.withValue { $0.append("resume:\(id)") } }
        }
        store.exhaustivity = .off

        await store.send(.pauseTapped)
        await store.send(.resumeTapped)
        #expect(calls.value == ["pause:D1", "resume:D1"])
    }
```

Add a `nonisolated static func stalledMission(id:)` fixture (kind `.surveyRun`, status `.needsAttention`, `attentionReason: .commandRejected`, one target).

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Add the reducer cases**

```swift
            case .retryTapped:
                return resolve(state) { await $0.retry($1) }

            case .skipTargetTapped:
                return resolve(state) { await $0.skipTarget($1) }

            case .cancelRunTapped:
                return resolve(state) { await $0.cancel($1) }

            case .pauseTapped:
                return resolve(state) { await $0.pause($1) }

            case .resumeTapped:
                return resolve(state) { await $0.resume($1) }
```

with the helper beside `dispatch`:

```swift
    /// Run a resolution verb against the selected CUSTOM row. Guarded on the row
    /// kind for the same reason the built-in verbs are: a built-in row's
    /// `deviceCode` is a controller, not a directive id, so an unguarded handler
    /// would resolve nothing (or the wrong thing).
    private func resolve(
        _ state: State,
        _ verb: @escaping @Sendable (DirectiveResolutionClient, String) async -> Void
    ) -> Effect<Action> {
        guard case let .custom(directive) = state.selectedRow else { return .none }
        let resolution = self.directiveResolution
        let id = directive.id
        return .run { _ in await verb(resolution, id) }
    }
```

- [ ] **Step 4: Build the panel and wire the pane**

`DirectiveStallPanel` (own file): warning glyph, `reason.displayName` as the headline (`.rcBodyEmph`), `reason.guidance` below (`.rcCaption`, `.rcTextSecondary`), then a Retry / Skip Target / Cancel Run button row. Tokens only; surface `.rcSurfaceRaised`, `Radius.card`.

In `DirectiveDetailView.customDetail`, above the Targets section:

```swift
                if directive.status == .needsAttention, let reason = directive.attentionReason {
                    DirectiveStallPanel(
                        reason: reason,
                        retry: { store.send(.retryTapped) },
                        skip: { store.send(.skipTargetTapped) },
                        cancel: { store.send(.cancelRunTapped) }
                    )
                }
```

and a pause/resume control in the header row, shown per status: Pause when `.running`, Resume when `.paused`, neither when finished. Keep the existing `caption: directive.status.displayName`.

- [ ] **Step 5: Run `DirectivesFeatureTests`.** Expected: green.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectivesFeature
git commit -m "Resolve stalled runs from the detail pane"
```

---

### Task 4: Full-suite verification and the memory record

- [ ] **Step 1: Build and run every test product**

```bash
swift build --build-tests 2>&1 | tail -2
grep -n 'name: "[A-Za-z]*Tests"' Package.swift | sed 's/.*name: "//;s/".*//' | sort > /tmp/products.txt
rm -f .build/ev-all-*.jsonl
for p in $(cat /tmp/products.txt); do
  swift test --test-product "$p" --disable-xctest --event-stream-version 0 \
    --event-stream-output-path ".build/ev-all-$p.jsonl" </dev/null >/dev/null 2>&1
done
cat .build/ev-all-*.jsonl > .build/ev-all.jsonl
jq -s 'map(select(.kind=="event").payload) as $e
  | ($e | map(select(.kind=="issueRecorded" and .issue.isFailure != false).testID) | unique) as $f
  | { total: ($e|map(select(.kind=="testStarted"))|length), failed: ($f|length),
      runsCompleted: ($e|map(select(.kind=="runEnded"))|length),
      crashed: (($e|map(select(.kind=="testStarted").testID)) - ($e|map(select(.kind=="testEnded" or .kind=="testSkipped").testID)) | length) }' .build/ev-all.jsonl
```
Expected: `failed: 0`, `crashed: 0`, `runsCompleted` equal to the product count. The `</dev/null` matters — `swift test` in a loop otherwise eats the product list.

- [ ] **Step 2: Record it in the memory note**

Append to `app/.claude/memory/directives-feature.md`: the five verbs and their transition table in brief; **why Retry re-stamps `stepStartedAt`** (it's what lets a `surveyIncomplete` stall recover rather than instantly re-stall); that a verb from a disallowed status is a logged no-op; that `cancel` deliberately leaves the AMI directive in force for the user to Clear; that `MissionRegistry` is now the single registration point for mission machines; and the `RCErrorBanner` deviation (purpose-made panel instead of widening a control four other screens use). Update the note's `description:` and the `MEMORY.md` index line — the "stall-resolution verbs" gap is closed, leaving Stage 5 (Relay Run) and the §7 step timeline.

- [ ] **Step 3: Commit**

```bash
git add app/.claude/memory
git commit -m "Memory: record the stall-resolution verbs"
```

---

## Self-review

**Spec coverage.** §8's three verbs → Tasks 2 and 3. §7's pause/resume → same. §7's `RCErrorBanner` → deviation stated above and in the memory note.

**Deliberately not in this slice:** the §7 **live step timeline** fed by `DirectiveLogEntry`. It is the other half of the custom detail pane and the resolution entries this slice writes will feed it — but it is a read-only view, independent of the verbs, and the user asked for the verbs. Worth doing next; every entry it needs is already being written.

**Known risks.** (1) `DirectiveStatus` is `QueryBindable`; `Set<DirectiveStatus>` membership is plain Swift here, not SQL, so no query-builder concerns. (2) The `resolve` helper captures `directiveResolution` into a local before the `@Sendable` closure — the same non-Sendable-reducer capture that bit `NewDirectiveFeature`. (3) `skipTarget` from `.paused` is allowed by the table; confirm that reads sensibly in the UI (a paused run's panel offers Resume and Cancel, and Skip only when stalled) — if it doesn't, tighten the UI, not the client.
