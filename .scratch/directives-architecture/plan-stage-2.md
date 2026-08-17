# Directives Stage 2 — Step Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Tickets live one per file under `.scratch/directives-architecture/issues/`; steps use checkbox (`- [ ]`) syntax for tracking. Claim a ticket by setting `Status: claimed` before touching code; resolve it by setting `Status: resolved` and appending a `## Comments` note with the commit sha(s).

**Goal:** Retire the copy-propagation mechanism — the reason 14 of ~150 Directives bugs recurred in a second mission after being fixed in a first — by moving the six copied step idioms into typed sub-machines under `DirectiveEngine/Sources/Steps/`, so each mechanical rule is written, tested and fixed ONCE rather than per mission.

**Architecture:** A mission keeps its `MissionStepMachine` conformance and its bespoke core. Each of its mechanical steps delegates to a pure sub-machine value with `func next(_ ctx: StepContext) -> StepResult`. The sub-machine owns the ordering rule (deadline → arrival wait → staleness → throttled read) and the dispatch frame; it never names a mission step — it returns `.finished`/`.more` and the MISSION chooses what follows. That single decision is what lets one sub-machine serve call sites that today end in `.advanceStep`, `.done` and `.advanceTarget` alike.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26+), Composable Architecture, SQLiteData + GRDB, StructuredQueries, Swift Testing, swift-openapi-generator.

**Spec:** `.scratch/directives-architecture/spec.md` §Stage 2 — read it first, together with the "Where the spec did not survive measurement" section below, which records four places this plan deliberately departs from the spec's provisional shape and why.

**Parent plan:** `.scratch/directives-architecture/plan.md`. **Punch list:** `.scratch/directives-architecture/punch-list.md`.

## Global Constraints

Every task's requirements implicitly include this section. Copied verbatim from `plan.md`.

- **LSP setup, once per worktree, before anything else:** `cd app/Modules && swift build --build-tests`, then `./scripts/link-index-store.sh`. Without the second the index returns zero references silently. LSP root is `app/Modules/`, not the repo root.
- **Use Swift-LSP for navigation and verification**, not grep, for anything in `app/Modules/`. An empty `findReferences` on same-session code is a cold index, never proof a symbol is unused — fall back to `swift build --build-tests`. **Measured during ticket 17: a `findReferences` on `RestockRun.pollInterval` returned empty while the file emitted `No such module 'GameModels'` — that is a cold index, and the claim had to be settled by an exhaustive textual sweep instead. Expect this and say which tool answered.**
- **Read test results from the Swift Testing JSON event stream** via the `swift-test-event-stream` skill. Never parse console text; a grep for "fail" false-positives on test method names. Run the whole `DirectiveEngineTests`, `GameServicesTests`, `GameSyncTests`, `GameModelsTests` and `DirectivesFeatureTests` targets after every ticket that touches their module — the recurrence history of this feature is exactly "green in the module I edited, red in the sibling".
- **Migrations are append-only.** A schema change appends a new `SchemaMigration` to `GameDatabase.manifest` (`app/Modules/GameDatabase/Sources/GameDatabase.swift:47`). Never edit, rename or reorder a shipped one. **Stage 2 changes no schema: every task here is a pure refactor of `DirectiveEngine` sources. If a task finds itself writing a migration, stop — it has left scope.**
- **Comment budget is hard:** file header ≤ 10 lines, `///` ≤ 3 lines, inline `//` ≤ 2 lines. No dated history, no rejected alternatives, no rationale for *why we chose this* — that goes to `app/.claude/memory/` (with an index line in `app/.claude/memory/MEMORY.md`) or this spec. Run `./app/scripts/check-comments.sh <paths>` from the repo root.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = module or service name.
- **Loud test doubles:** a shared client's `testValue` uses `unimplemented(...)`; rich fixtures belong on `previewValue`.
- **UI:** never hard-code colours, spacing or font sizes — use `DesignSystem.swift` tokens. Every system and location designation renders in a monospace token. List-row structs live in their own file, never beside a `#Preview`. **Stage 2 renders nothing new.** Task 10 is the only task that leaves `DirectiveEngine`, and it changes one pure namespace in `DirectivesFeature` (`DirectiveStallDetail`), not a view.
- **Git:** commit directly to `main`, or to a worktree branch merged to `main` on review. No PRs, no pushing, `origin` is not part of the workflow. One commit per ticket step group is fine; the ticket's `## Comments` records the shas.
- **Naming:** the domain word is **Theatre** (British). A **bench** is one print-capable device's queue. A **lease** is a device reserved by a running directive row. A **scoped** tag carries a theatre or belt; an **unscoped** tag does not.
- **`Sources/Steps/` needs no `Package.swift` edit.** `DirectiveEngine` is a path-based target (`path: "DirectiveEngine/Sources"`, `Package.swift:272`), so SPM picks up subdirectories automatically.
- **Sub-machine types are `internal`, not `public`.** Spec §Stage 2 calls the step library "module-internal", and nothing outside `DirectiveEngine` consumes a sub-machine — the missions that use them all live in this target, and the tests reach them through `@testable import DirectiveEngine`. The code blocks below are written with `public` on the type members for readability; **drop it when you write the file** unless the compiler demands otherwise. `StepContext`/`StepResult` follow the same rule.
- **Every sub-machine's own test file must exercise deadline-first ordering and its watermark semantics directly** (ticket 17's constraint). The **owner-aware guard is tested once**, in `StepContextTests` — `openOperation(for:)` and `ownedOperation(for:)` given the same co-tenant op must disagree. That is the whole of the owner-aware behaviour; repeating it per sub-machine would test `StepContext` five times.
- **Behaviour-preserving by default.** D5 says every stage ends with the app running and green. Each adoption task must leave the migrated mission's existing suite green *without editing its assertions*, except where this plan names a deliberate behaviour change and gives it its own test. Two such changes exist, in Task 11 and Task 13; there are no others.

---

## What the re-measurement found (ticket 17, Step 1)

Measured against `main` at `0115c20`, with Stages 0–1 landed. Where the audit's figure differs, both are shown. `Δ` is what Stages 0–1 already collapsed and Stage 2 therefore must not re-do.

| Idiom | Audit figure | Measured now | Notes |
|---|---|---|---|
| Travel frames | ~12 | **13 dispatch sites** (9 outbound + 4 return-home) | `RelayRun` 4, `EventRun` 3, `SalvageRun` 2, `SurveyRun` 2, `MineRun` 2. Zero in `HaulRun`, `RestockRun`, `MineFleetPrint`, `EventCourierPrint` — the word "travel" does not appear in those four files. |
| — of which same-step loops | not measured | **11 of 13** | Only `MineRun.swift:355` and `EventRun.swift:510` have the dispatch+confirm pair the spec assumes. The majority shape has no confirming step and no flight deadline. |
| — sharing one watermark guard | not measured | **13 of 13** | All call `SalvageRun.travelPositionUnconfirmed` (`SalvageRun.swift:323`). **Δ — the fresh-evidence half is already collapsed;** what is duplicated is the frame around it. |
| Return-homes | 4 | **4** | `SurveyRun:500`, `MineRun:522`, `RelayRun:920`, `EventRun:758`. `MineRun:507` and `RelayRun:908` are the same function twice, differing only in a logger string. |
| Hand ladders | ~13 | **21 hand-rolled sites**, plus **10** calling the shared `MissionConfirm.ladder` | The 21 split into seven families by what each needs that the shared ladder cannot express — see the ConfirmRow section below. |
| Bot-phase pair | 2×~200 lines | **194 + 203 lines** (151 + 160 non-comment) | `SurveyRun:598-791`, `SalvageRun:669-873`. Five genuine differences; everything else is line-wrapping and doc wording. `probe` is byte-identical in both (md5 `d630420ab179204a442cae451e3f796c`). |
| Print sites | 4 print-only kinds | **5 dispatch sites** | `MineFleetPrint:142`, `RestockRun:133`, `EventCourierPrint:97`, `EventRun:380`, `RelayRun:401`. Three collapse cleanly; two force parameters. |
| Log walkers | 4 | **3 functions, 15 call sites** | `dispatchRounds` no-kind ×10, `dispatchRounds(kind:)` ×3, `lastDispatch` ×2. Both legacy prose fallbacks still live, at `MissionLogBudget.swift:48` and `:84`. |
| Sibling static references | `RelayRun→SalvageRun` ×17 | **114 occurrences / 108 distinct lines**; `RelayRun→SalvageRun` is **16** | `RepairFleet` (34) and `MineRecipe` (28) are intentional namespaces. That leaves **52 borrows reaching into a live mission struct**, of which `SalvageRun` absorbs 24. |

Most-borrowed members, by number of borrowing files — these are the extraction targets:

| Rank | Member | Callers | Sites |
|---|---|---|---|
| 1= | `SalvageRun.travelPositionUnconfirmed` | 4 | 11 |
| 1= | `RelayRun.init(reserveFloor:)` + `.footprintCensusIsStale` + `.printStockIsShort` | 4 | 5 constructions, 10 calls |
| 3= | `RelayRun.theatreDepot(in:for:)` | 3 | 3 |
| 3= | `RestockRun.printDeadline` | 3 | 3 |

Four missions construct a whole sibling mission struct (`RelayRun(reserveFloor:)`) purely to reach two instance methods that have nothing to do with relays. `RelayRun.theatreDepot(in:for:)` is a one-line pass-through to `world.theatreDepot(for:)` (`RelayRun.swift:929-931`), reached by three missions.

**Already collapsed by Stages 0–1 — out of scope for Stage 2:**

- The arrival watermark: one implementation, 13 call sites.
- The freshness predicate: `world.isFresh` (`WorldSnapshot.swift:194`), 14 call sites, replacing per-mission comparisons.
- The owner-scoped op guard: `world.openOperation(for:owner:)` exists and is used by `RestockRun`, `MineFleetPrint`, `EventCourierPrint`.
- Typed `Step` enums per machine, and typed `commandKind`/`targetDeviceCode` log columns.

---

## Where the spec did not survive measurement

Four departures from spec §Stage 2's provisional shape. Each is a measured finding, not a preference. Ticket 17's fixed migration ORDER is honoured unchanged.

### 1. `StepResult` needs four cases, not two

Spec says `.action(MissionAction)` or `.finished`. Measurement forces two more:

- **`.more`** — every dispatch/confirm loop (bot deploy, bot arm, bot recall, attach, adopt, load) handles one item then returns to its own dispatch step. Expressing that as `.action(.advanceStep(...))` would put mission step names back inside the sub-machine, which is the whole thing being removed.
- **`.noSubject`** — `EventRun.swift:749` returns `.done` when no depot resolves but `:763` returns `.advanceStep(.depositing)` on arrival, so a return-home sub-machine that collapses both into `.finished` cannot serve `EventRun`. `MineRun:510` and `RelayRun:909` collapse them, which is why the pair looked collapsible.

### 2. `ConfirmRow` cannot take a predicate, and must not try

Spec's `ConfirmRow(deviceCodes:, predicate:, deadline:, thenStall:)` implies the sub-machine decides success. The 21 hand-rolled sites disagree on success in six incompatible ways (a containment column, a `statusBase` string, a config-content test, `RepairFleet.isRepairing`, a scalar `cargoUsed`, a non-`Device` event row). A closure parameter would cover them at the cost of making `ConfirmRow` non-`Equatable` and untestable as a value.

**The bug class Stage 2 retires is ordering, not predicate.** So `ConfirmRow` owns the ordering rule and returns `.judge` when the rows are fresh enough for the mission to apply its own test. This is exactly how `MissionConfirm.ladder` and `probe` are already split today; the plan generalises `probe`'s nil-return rather than `ladder`'s fold-everything-in.

Honest coverage: **26 of 31 ladder sites** (all 10 `MissionConfirm.ladder` callers + 16 of the 21 hand-rolled). Deliberately excluded: the five sites whose subject is not a `Device` (`EventRun.confirmProgress` at `:607`, `SalvageRun.unresolvedSystem` at `:451`, `RelayRun.unresolvedSystem` at `:765`, `SalvageRun.sameBodyAgain` at `:982`) and the four print polls, which Task 11 gives to `PrintJob`. `SalvageRun.unresolvedSystem` and `RelayRun.unresolvedSystem` are duplicated verbatim and are worth their own extraction later; this plan does not attempt it, and Task 13 records it on the punch list.

### 3. `PrintJob` covers three of five sites in Stage 2

`RelayRun.swift:401` anchors bench selection on **`carrier.location`, not a depot** — a mobile anchor, because the run prints wherever its carrier is standing. `EventRun.swift:380` computes its deadline as `printSlack + the longest blueprint print time in the job` measured from `lastOrderedAt` (the newest open print op) rather than `stepStartedAt`. Forcing both into `PrintJob(deviceType:, at depot:, owner:)` means an anchor union, a deadline union, a deadline-anchor union and a terminal-disposition union in a type Stage 3 is about to rewrite anyway.

Task 11 therefore takes the three depot-anchored sites (`MineFleetPrint`, `RestockRun`, `EventCourierPrint`) and states the other two as Stage 3's, where the `PrintScheduler` replaces the chooser for all five at once. Ticket 18 must carry that forward — it is written into this plan's hand-off section.

### 4. `StowOrAttach`'s three named sites are in three different families

Spec scopes it to "RelayRun stow, EventRun loading, MineRun attach". Measured across all 18 containment-verb dispatch sites, those three land in three structurally different families:

- **A — carrier-addressed, one device per round, confirmed on a containment column:** `EventRun:431` (attach), `EventRun:719` (attach), `MineRun:321` (attach), `MineRun:422` (adopt). Four sites, one shape. `adopt` confirms on `controllerDeviceCode` rather than `attachedToDeviceCode`, so the sub-machine needs a confirm-field selector.
- **B — carrier-addressed, whole list in one command:** `EventRun:564` (detach), `MineRun:385` (detach). A singular `device:` parameter structurally cannot express this.
- **C — device-addressed, carrier as `target:`:** `RelayRun:695` (stow), alone. `RelayRun.swift:692-693` documents why the inverse addressing is deliberate: "the inverse would stow the vessel into the relay". A `verb` parameter cannot switch which end the command is issued at.
- **D — resource moves, no device at all:** `EventRun:441`, `:576`, `:697`, `:784`. The payload is `[String: Int]`; the confirm is `cargoUsed`, a scalar. Two of the four have no confirmation by design.
- **E — parameterless lifecycle at the moving device:** `RelayRun:821` (deploy), `SurveyRun:611`/`:762`, `SalvageRun:686`/`:843` (deploy, recall), `SurveyRun:541`/`SalvageRun:555` (launch). Four of these belong to `BotPhase`.

`EventRun`'s `loading` step is a single step dispatching **two verbs from two families** (attach at `:431`, `collect_resources` at `:441`, both handing to `confirmingLoad`), so "cover EventRun's loading" means covering family D too, or splitting the step.

Task 12 delivers `StowOrAttach` over **families A and B — six sites** — and excludes C, D and E with the reasons above. `MineRun`'s attach is covered; `RelayRun`'s stow and half of `EventRun`'s loading are not. This is a narrower deliverable than the ticket wording implies, and it is the honest one.

---

## File structure

**New files**

| Path | Responsibility |
| --- | --- |
| `app/Modules/DirectiveEngine/Sources/Steps/StepContext.swift` | The `(directive, world, step)` frame, plus derived `owner`, `elapsed`, and the two op-guard flavours |
| `app/Modules/DirectiveEngine/Sources/Steps/StepResult.swift` | `.action` / `.finished` / `.more` / `.noSubject` |
| `app/Modules/DirectiveEngine/Sources/Steps/TravelTo.swift` | The travel frame + the arrival watermark, moved off `SalvageRun` |
| `app/Modules/DirectiveEngine/Sources/Steps/ReturnHome.swift` | `TravelTo` aimed at a depot or origin, with the three-way no-destination rule |
| `app/Modules/DirectiveEngine/Sources/Steps/ConfirmRow.swift` | The ordering rule: deadline → arrival wait → staleness → throttled read |
| `app/Modules/DirectiveEngine/Sources/Steps/BotPhase.swift` | The seven-phase service-bot lifecycle |
| `app/Modules/DirectiveEngine/Sources/Steps/PrintJob.swift` | Depot-anchored bench choice, rail gates, print deadline |
| `app/Modules/DirectiveEngine/Sources/Steps/StowOrAttach.swift` | Carrier-addressed containment, single and batch |
| `app/Modules/DirectiveEngine/Tests/Steps/StepContextTests.swift` | Owner derivation, elapsed, the two op guards |
| `app/Modules/DirectiveEngine/Tests/Steps/TravelToTests.swift` | Guard order, both arrival tests, same-step dispatch |
| `app/Modules/DirectiveEngine/Tests/Steps/ReturnHomeTests.swift` | Arrived / in-flight / no-destination three ways |
| `app/Modules/DirectiveEngine/Tests/Steps/ConfirmRowTests.swift` | **Deadline-first ordering**, each watermark, each expiry, the throttle |
| `app/Modules/DirectiveEngine/Tests/Steps/BotPhaseTests.swift` | Each phase, the round budget, the nil-location branches |
| `app/Modules/DirectiveEngine/Tests/Steps/PrintJobTests.swift` | Bench choice, free-bench preference, deadline above the guard |
| `app/Modules/DirectiveEngine/Tests/Steps/StowOrAttachTests.swift` | Single and batch, both confirm fields |

**Modified files**

| Path | Change |
| --- | --- |
| `DirectiveEngine/Sources/SurveyRun.swift` | Bot phase → `BotPhase`; travel/return-home → `TravelTo`/`ReturnHome`; ladders → `ConfirmRow`; `probe` deleted |
| `DirectiveEngine/Sources/SalvageRun.swift` | The same, plus `travelPositionUnconfirmed` moves out and the shared constants leave |
| `DirectiveEngine/Sources/RelayRun.swift` | 4 travel sites, ladders, the rail extraction; `trackedKinds` deleted |
| `DirectiveEngine/Sources/EventRun.swift` | 3 travel sites, 5 ladder sites, 2 stow/attach sites |
| `DirectiveEngine/Sources/MineRun.swift` | 2 travel sites, 5 ladder sites, 3 stow/attach sites |
| `DirectiveEngine/Sources/HaulRun.swift` | 1 ladder site; the `RelayRun.theatreDepot` borrow |
| `DirectiveEngine/Sources/RestockRun.swift` | `PrintJob`; dead `pollInterval` deleted |
| `DirectiveEngine/Sources/MineFleetPrint.swift` | `PrintJob`; `printer(for:in:)` moves into it |
| `DirectiveEngine/Sources/EventCourierPrint.swift` | `PrintJob`; the wrong-device poll guard fixed |
| `DirectiveEngine/Sources/MissionLogBudget.swift` | `MissionConfirm` deleted; both legacy prose fallbacks deleted |
| `DirectiveEngine/Sources/RepairFleet.swift` | `answers` and `repairThreshold` become non-public |
| `DirectivesFeature/Sources/DirectiveStallDetail.swift` | The third legacy prose fallback deleted; the prefix MATCH kept |
| `DirectiveEngine/Tests/MissionLogBudgetTests.swift` | The two legacy-fallback tests retired; the fail-closed tests kept |
| `DirectivesFeature/Tests/DirectiveStallDetailTests.swift` | The prose-fallback test retired; the column-wins test kept |

## Order of work and checkpoints

Ticket 17 fixes this order and it is not negotiable — each migration has to be green before the next starts.

1. **Tasks 1–4** (tickets 20–23): foundation, then `BotPhase` and its two adoptions. Both bot-phase bodies deleted.
2. **Tasks 5–7** (tickets 24–26): `TravelTo`, the 9 outbound sites, then `ReturnHome` and the 4 return-home sites.
3. **Tasks 8–10** (tickets 27–29): `ConfirmRow`, the ladder migrations, then the legacy prose deletion.
4. **Task 11** (ticket 30): `PrintJob` over the three depot-anchored sites.
5. **Task 12** (ticket 31): `StowOrAttach` over families A and B.
6. **Task 13** (ticket 32): constants come home; the borrow count is measured against its target and recorded.

**Checkpoint C** (after Task 4): run the app for one evening with the brain on. Expected: survey and salvage runs deploy, arm, await and recall their service bots exactly as before — the timeline shows the same step names in the same order, because only the bodies moved.

**Checkpoint D** (after Task 10): the timeline shows no `Dispatched …` prose being re-parsed; `MissionLogBudget` reads columns only.

**After each of tasks 4, 7, 10, 11 and 12**, run and record:

```bash
cd app/Modules/DirectiveEngine/Sources
grep -c "SalvageRun\.\|RelayRun\.\|RestockRun\.\|MineFleetPrint\.\|HaulRun\.\|EventRun\.\|SurveyRun\.\|MineRun\." *.swift | grep -v ":0$"
```

The number must fall at every checkpoint and never rise. Task 13 states the final target.

---

## Task 1: The step frame

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/Steps/StepContext.swift`
- Create: `app/Modules/DirectiveEngine/Sources/Steps/StepResult.swift`
- Test: `app/Modules/DirectiveEngine/Tests/Steps/StepContextTests.swift`

**Interfaces:**
- Consumes: `Directive`, `WorldSnapshot`, `CommandOwner` (`GameServices/Sources/CommandOwner.swift`), `MissionAction`.
- Produces: `StepContext(directive:world:step:)` with `.owner`, `.now`, `.elapsed`, `.openOperation(for:)`, `.ownedOperation(for:)`; `StepResult` with `.action(MissionAction)`, `.finished`, `.more`, `.noSubject`. Every later task consumes both.

No mission changes in this task. It exists so tasks 2–12 have a frame to compile against.

- [ ] **Step 1: Write the failing test**

`app/Modules/DirectiveEngine/Tests/Steps/StepContextTests.swift`:

```swift
//
//  StepContextTests.swift
//  Replicould — DirectiveEngine
//
//  The frame sub-machines read, and the one derivation it owns: the owner.
//

import Foundation
import GameModels
import GameServices
import Testing

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)
private let stepStart = now.addingTimeInterval(-90)

private func row(step: String = "travelling") -> Directive {
    Directive(
        id: "D1", kind: .mineRun, status: .running, deviceCode: "C1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: ["AINALRAM-BELT-1"], targetIndex: 0, step: step, stepStartedAt: stepStart,
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: stepStart, updatedAt: now, theatreDepot: nil
    )
}

private func operation(_ entityCode: String, directiveID: String?) -> GameModels.Operation {
    GameModels.Operation(
        id: "OP-\(entityCode)", entityCode: entityCode, kind: .travel, status: .active,
        source: .optimistic, startedAt: stepStart, completesAt: now.addingTimeInterval(60),
        lastConfirmedAt: stepStart, detail: .object([:]), directiveID: directiveID,
        step: "travelling", paramsDigest: nil
    )
}

@Suite("Step context")
struct StepContextTests {
    /// The owner a sub-machine reasons with must be the one `DirectiveExecutor`
    /// stamps, or a de-dup window and a guard disagree about the same command.
    @Test("the derived owner is the one the executor stamps")
    func ownerMatchesTheExecutor() {
        let directive = row()
        let ctx = StepContext(
            directive: directive,
            world: WorldSnapshot(devices: [:], openOperations: [:], now: now),
            step: "travelling"
        )
        #expect(ctx.owner == CommandOwner(
            directiveID: directive.id, step: directive.step, since: directive.stepStartedAt
        ))
    }

    @Test("elapsed measures the current step, not the run")
    func elapsedMeasuresTheStep() {
        let ctx = StepContext(
            directive: row(),
            world: WorldSnapshot(devices: [:], openOperations: [:], now: now),
            step: "travelling"
        )
        #expect(ctx.elapsed == 90)
    }

    /// The two guards are different questions. Travel sites ask the first,
    /// print sites ask the second; conflating them silently changes 13 sites.
    @Test("the unowned guard sees a co-tenant's op and the owned one does not")
    func theTwoGuardsDiffer() {
        let ctx = StepContext(
            directive: row(),
            world: WorldSnapshot(
                devices: [:],
                openOperations: ["C1": operation("C1", directiveID: "D2")],
                now: now
            ),
            step: "travelling"
        )
        #expect(ctx.openOperation(for: "C1") != nil)
        #expect(ctx.ownedOperation(for: "C1") == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'StepContext' in scope`.

- [ ] **Step 3: Write the implementation**

`app/Modules/DirectiveEngine/Sources/Steps/StepResult.swift`:

```swift
//
//  StepResult.swift
//  Replicould — DirectiveEngine
//
//  What a sub-machine answers. It never names a mission's step: the mission
//  reads the outcome and picks what follows, which is what lets one
//  sub-machine serve sites ending in `.advanceStep`, `.done` and
//  `.advanceTarget` alike.
//

import Foundation

/// One sub-machine evaluation's outcome.
public enum StepResult: Equatable, Sendable {
    /// Take this action, then ask again next tick.
    case action(MissionAction)
    /// This sub-machine's whole job is done.
    case finished
    /// One item handled and more remain — the mission returns to this
    /// sub-machine's own dispatch step.
    case more
    /// The subject does not exist: no depot to return to, no row for the
    /// device. Never a stall on its own; the mission decides.
    case noSubject
}
```

`app/Modules/DirectiveEngine/Sources/Steps/StepContext.swift`:

```swift
//
//  StepContext.swift
//  Replicould — DirectiveEngine
//
//  What a sub-machine reads: one directive, one world, one step. Every clock
//  reading comes off `world.now`, so sub-machines stay as pure as the
//  missions they serve.
//

import Foundation
import GameModels
import GameServices

/// The read-only frame a sub-machine evaluates against.
public struct StepContext: Equatable, Sendable {
    public let directive: Directive
    public let world: WorldSnapshot
    /// The mission's own current step. A same-step dispatch names it.
    public let step: String

    public init(directive: Directive, world: WorldSnapshot, step: String) {
        self.directive = directive
        self.world = world
        self.step = step
    }

    /// The owner `DirectiveExecutor` stamps on this step's commands, derived
    /// from the row so the two cannot disagree.
    public var owner: CommandOwner {
        CommandOwner(
            directiveID: directive.id, step: directive.step, since: directive.stepStartedAt
        )
    }

    public var now: Date { world.now }
    /// How long the current step has been running.
    public var elapsed: TimeInterval { world.now.timeIntervalSince(directive.stepStartedAt) }

    /// The device's live op whoever owns it — "is this device busy at all?".
    public func openOperation(for code: String) -> GameModels.Operation? {
        world.openOperation(for: code)
    }

    /// The device's live op only when THIS directive owns it — "is my own
    /// command still in flight?". A co-tenant's op is invisible here.
    public func ownedOperation(for code: String) -> GameModels.Operation? {
        world.openOperation(for: code, owner: directive.id)
    }

    /// `device.updatedAt >= directive.stepStartedAt`.
    public func isFresh(_ device: Device) -> Bool {
        world.isFresh(device, since: directive.stepStartedAt)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
cd app/Modules && swift test --filter StepContextTests \
  --event-stream-output-path /tmp/steps.jsonl 2>&1 | tail -5
```

Read the result from `/tmp/steps.jsonl` per the `swift-test-event-stream` skill — never the console text. Expected: 3 passing.

- [ ] **Step 5: Comment check and commit**

```bash
./app/scripts/check-comments.sh \
  app/Modules/DirectiveEngine/Sources/Steps/StepContext.swift \
  app/Modules/DirectiveEngine/Sources/Steps/StepResult.swift
git add app/Modules/DirectiveEngine/Sources/Steps app/Modules/DirectiveEngine/Tests/Steps
git commit -m "feat(directives): the step-library frame — StepContext and StepResult"
```

---

## Task 2: `BotPhase`

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/Steps/BotPhase.swift`
- Test: `app/Modules/DirectiveEngine/Tests/Steps/BotPhaseTests.swift`

**Interfaces:**
- Consumes: `StepContext`, `StepResult`, `RepairFleet` (`bots(aboard:in:owner:)`, `bots(deployedNear:in:owner:)`, `botsOut(near:in:owner:)`, `anyBotDeployed(in:system:owner:)`, `anyBotOut(in:system:owner:)`, `openRecall(for:in:)`, `isArmed(_:)`, `isRepairing(_:)`, `needsRepair(_:)`, `fleet(of:in:owner:)`), `MissionLogBudget.dispatchRounds`, `FleetTag`.
- Produces: `BotPhase(vesselCode:owner:system:phase:dispatchStep:confirmStep:runNoun:)` with `func next(_ ctx: StepContext) -> StepResult`, and the six constants (`probeDelay`, `probeInterval`, `confirmDeadline`, `repairDeadline`, `recallDeadline`, `dispatchRounds`). Tasks 3 and 4 consume it.

The two bodies being replaced are `SurveyRun.swift:598-791` (194 lines) and `SalvageRun.swift:669-873` (203 lines). They differ in exactly five things: three next-step destinations (which `.finished`/`.more` remove from the sub-machine entirely), one constant NAME (`recallDeadline` vs `botRecallDeadline`, both `20 * 60`), and log prose (`runNoun`). Nothing else.

Write the sub-machine so that no phase names a mission step, and so `probe` — byte-identical in both files — exists once.

- [ ] **Step 1: Write the failing tests**

`app/Modules/DirectiveEngine/Tests/Steps/BotPhaseTests.swift`. `repairDevice` and `repairFixtureNow` come from the existing `Tests/RepairTestSupport.swift`.

```swift
//
//  BotPhaseTests.swift
//  Replicould — DirectiveEngine
//
//  The service-bot lifecycle, tested once here instead of twice per mission.
//

import Foundation
import GameModels
import Testing

@testable import DirectiveEngine

private let now = repairFixtureNow
private let vesselCode = "V1"
private let system = "SOL"

private func row(step: String, startedAgo: TimeInterval) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: .running, deviceCode: vesselCode,
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: [system], targetIndex: 0, step: step,
        stepStartedAt: now.addingTimeInterval(-startedAgo),
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: now.addingTimeInterval(-3_600), updatedAt: now, theatreDepot: nil
    )
}

private func world(_ devices: [Device], log: [DirectiveLogEntry] = []) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { a, _ in a }),
        openOperations: [:], log: log, now: now
    )
}

private func phase(_ phase: BotPhase.Phase) -> BotPhase {
    BotPhase(
        vesselCode: vesselCode, owner: nil, system: system, phase: phase,
        dispatchStep: "deployingBots", confirmStep: "confirmingBotDeploy", runNoun: "survey run"
    )
}

private let vessel = repairDevice(vesselCode, type: "heaven_vessel", location: "SOL-3")

@Suite("Bot phase")
struct BotPhaseTests {
    @Test("deploy orders the first bot still aboard")
    func deployOrdersTheFirstBotAboard() {
        let bot = repairDevice("B1", type: "service_bot", location: nil,
                               stowedIn: vesselCode, directives: ["service"])
        let ctx = StepContext(
            directive: row(step: "deployingBots", startedAgo: 0),
            world: world([vessel, bot]), step: "deployingBots"
        )
        #expect(phase(.deploy).next(ctx) == .action(.dispatch(
            kind: .simple("deploy"), deviceCode: "B1",
            params: CommandParams(), nextStep: "confirmingBotDeploy"
        )))
    }

    /// The whole reason the mission keeps its own step names: Survey sends an
    /// empty hold to `configuring` and Salvage to `armingBots`.
    @Test("deploy with nothing aboard finishes rather than naming a step")
    func deployWithEmptyHoldFinishes() {
        let ctx = StepContext(
            directive: row(step: "deployingBots", startedAgo: 0),
            world: world([vessel]), step: "deployingBots"
        )
        #expect(phase(.deploy).next(ctx) == .finished)
    }

    /// The bound `stepStartedAt` cannot give: the confirm step re-stamps it,
    /// so a dispatch/confirm pair would reset its own deadline every round.
    @Test("deploy stops at the round budget and finishes unrepaired")
    func deployStopsAtTheRoundBudget() {
        let bot = repairDevice("B1", type: "service_bot", location: nil,
                               stowedIn: vesselCode, directives: ["service"])
        var log: [DirectiveLogEntry] = []
        for round in 0...BotPhase.dispatchRounds {
            log.append(DirectiveLogEntry(
                id: "S\(round)", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
                summary: "Step: deployingBots", step: "deployingBots", operationID: nil,
                eventID: nil, occurredAt: now.addingTimeInterval(TimeInterval(round))
            ))
        }
        let ctx = StepContext(
            directive: row(step: "deployingBots", startedAgo: 0),
            world: world([vessel, bot], log: log), step: "deployingBots"
        )
        #expect(phase(.deploy).next(ctx) == .finished)
    }

    /// Deadline BEFORE the read. A failing read never advances `updatedAt`, so
    /// the other order loops forever at one high-priority read per tick.
    @Test("await repair stalls on the deadline rather than buying another read")
    func awaitRepairChecksTheDeadlineFirst() {
        let bot = repairDevice("B1", type: "service_bot", location: "SOL-3",
                               directives: ["service"], capacity: 10,
                               updatedAt: now.addingTimeInterval(-10_000),
                               repairingTarget: "D9")
        let ctx = StepContext(
            directive: row(step: "repairing", startedAgo: BotPhase.repairDeadline + 1),
            world: world([vessel, bot]), step: "repairing"
        )
        #expect(phase(.awaitRepair).next(ctx) == .action(.stall(.repairUnfinished)))
    }

    @Test("await repair finishes once every bot is idle on a row read since the step began")
    func awaitRepairFinishesWhenIdle() {
        let bot = repairDevice("B1", type: "service_bot", location: "SOL-3",
                               directives: ["service"], capacity: 10, updatedAt: now)
        let ctx = StepContext(
            directive: row(step: "repairing", startedAgo: BotPhase.probeDelay + 1),
            world: world([vessel, bot]), step: "repairing"
        )
        #expect(phase(.awaitRepair).next(ctx) == .finished)
    }

    /// A recalled bot carries `location: nil` for its whole cruise home, so a
    /// location query drops precisely the device the question is about.
    @Test("confirm recall counts a bot in transit as still out")
    func confirmRecallCountsABotInTransit() {
        let cruising = repairDevice("B1", type: "service_bot", location: nil,
                                    directives: ["service"], updatedAt: now)
        let world = WorldSnapshot(
            devices: [vesselCode: vessel, "B1": cruising],
            openOperations: ["B1": repairOperation("B1", completesAt: now.addingTimeInterval(120))],
            now: now
        )
        let ctx = StepContext(
            directive: row(step: "confirmingBotStow", startedAgo: BotPhase.probeDelay + 1),
            world: world, step: "confirmingBotStow"
        )
        #expect(phase(.confirmRecall).next(ctx) != .finished)
    }
}
```

> `repairOperation` is the existing helper in `Tests/RepairTestSupport.swift` (declared just below `repairDevice`). If its argument labels differ from the call above, use the file's own — do not add a second helper.

- [ ] **Step 2: Run to verify it fails**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'BotPhase' in scope`.

- [ ] **Step 3: Write the implementation**

`app/Modules/DirectiveEngine/Sources/Steps/BotPhase.swift`:

```swift
//
//  BotPhase.swift
//  Replicould — DirectiveEngine
//
//  The service-bot lifecycle: deploy on arrival, arm, hold while they repair,
//  recall before departing. One copy, serving every bot-carrying mission.
//

import Foundation
import GameModels
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

/// One leg of the service-bot lifecycle, as a pure value.
public struct BotPhase: Equatable, Sendable {
    /// Each case is one mission step. The confirm legs are separate because
    /// `deploy` and `recall` are immediate verbs carrying no operation row.
    public enum Phase: Equatable, Sendable {
        case deploy, confirmDeploy
        case arm, confirmArm
        case awaitRepair
        case recall, confirmRecall
    }

    /// Grace before the first read of a just-ordered command.
    public static let probeDelay: TimeInterval = 10
    /// Floor between reads of one row while polling.
    public static let probeInterval: TimeInterval = 30
    /// How long a deploy or arm may go unconfirmed.
    public static let confirmDeadline: TimeInterval = 10 * 60
    /// How long the run holds while bots repair.
    public static let repairDeadline: TimeInterval = 20 * 60
    /// How long a recall may go unconfirmed before the run refuses to leave.
    public static let recallDeadline: TimeInterval = 20 * 60
    /// Dispatch rounds one loop may spend. Read off the log, because the
    /// confirm leg re-stamps `stepStartedAt` on every hop.
    public static let dispatchRounds = 6

    /// The vessel the bots ride and are judged around.
    public let vesselCode: String
    /// The fleet whose bots answer — `RepairFleet.answers`.
    public let owner: FleetTag?
    /// The run's target system, for the branches a nil vessel location cannot
    /// answer from a location query.
    public let system: String?
    public let phase: Phase
    /// This phase's own dispatch/confirm step pair, for the log budget.
    public let dispatchStep: String
    public let confirmStep: String
    /// Names the run in the operator log: "survey run", "salvage run".
    public let runNoun: String

    public init(
        vesselCode: String, owner: FleetTag?, system: String?, phase: Phase,
        dispatchStep: String, confirmStep: String, runNoun: String
    ) {
        self.vesselCode = vesselCode
        self.owner = owner
        self.system = system
        self.phase = phase
        self.dispatchStep = dispatchStep
        self.confirmStep = confirmStep
        self.runNoun = runNoun
    }

    public func next(_ ctx: StepContext) -> StepResult {
        guard let vessel = ctx.world.device(vesselCode) else { return .noSubject }
        switch phase {
        case .deploy: return deploy(vessel, ctx)
        case .confirmDeploy: return confirmDeploy(vessel, ctx)
        case .arm: return arm(vessel, ctx)
        case .confirmArm: return confirmArm(vessel, ctx)
        case .awaitRepair: return awaitRepair(vessel, ctx)
        case .recall: return recall(vessel, ctx)
        case .confirmRecall: return confirmRecall(vessel, ctx)
        }
    }

    /// One throttled read of `rows` when any predates the step, or nil when
    /// they are fresh enough to judge. Callers check their deadline FIRST.
    private func probe(_ rows: [Device], _ ctx: StepContext) -> MissionAction? {
        guard rows.contains(where: { !ctx.isFresh($0) }) else { return nil }
        let lastLook = rows.map(\.updatedAt).min() ?? .distantPast
        if ctx.now.timeIntervalSince(lastLook) < Self.probeInterval { return .wait }
        return .refreshDevices(deviceCodes: rows.map(\.deviceCode), thenStall: nil)
    }

    /// The vessel's own row is what makes a system-scoped bot query answerable,
    /// so a nil location is uncertainty — but only where a bot is out to lose.
    private func withoutLocation(
        _ vessel: Device, _ ctx: StepContext, anyOut: Bool,
        deadline: TimeInterval, thenStall: DirectiveAttentionReason
    ) -> StepResult {
        guard anyOut else { return .finished }
        if ctx.elapsed > deadline { return .action(.stall(thenStall)) }
        if ctx.now.timeIntervalSince(vessel.updatedAt) < Self.probeInterval { return .action(.wait) }
        return .action(.refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: nil))
    }

    private func rounds(_ ctx: StepContext) -> Int {
        MissionLogBudget.dispatchRounds(ctx.world, dispatch: dispatchStep, confirm: confirmStep)
    }

    private func deploy(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        let aboard = RepairFleet.bots(aboard: vessel, in: ctx.world, owner: owner)
        guard let next = aboard.first else { return .finished }
        if rounds(ctx) > Self.dispatchRounds {
            logger.notice("\(runNoun, privacy: .public) \(ctx.directive.id, privacy: .public): \(next.deviceCode, privacy: .public) will not deploy — proceeding unrepaired")
            return .finished
        }
        return .action(.dispatch(
            kind: .simple("deploy"), deviceCode: next.deviceCode,
            params: CommandParams(), nextStep: confirmStep
        ))
    }

    private func confirmDeploy(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        if ctx.elapsed < Self.probeDelay { return .action(.wait) }
        if ctx.elapsed > Self.confirmDeadline {
            logger.notice("\(runNoun, privacy: .public) \(ctx.directive.id, privacy: .public): bot deploy unconfirmed — proceeding unrepaired")
            return .finished
        }
        let aboard = RepairFleet.bots(aboard: vessel, in: ctx.world, owner: owner)
        guard aboard.isEmpty else {
            // A row unread since the deploy was ordered cannot show it landing.
            if let probe = probe(aboard, ctx) { return .action(probe) }
            return .more
        }
        // The arm leg judges the DEPLOYED rows, and nothing has read them since
        // the order — a stale one reads armed and skips repair.
        let deployed = RepairFleet.bots(deployedNear: vessel.location, in: ctx.world, owner: owner)
        if let probe = probe(deployed, ctx) { return .action(probe) }
        return .finished
    }

    private func arm(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        let deployed = RepairFleet.bots(deployedNear: vessel.location, in: ctx.world, owner: owner)
        guard let next = deployed.first(where: { !RepairFleet.isArmed($0) }) else { return .finished }
        if rounds(ctx) > Self.dispatchRounds {
            logger.notice("\(runNoun, privacy: .public) \(ctx.directive.id, privacy: .public): \(next.deviceCode, privacy: .public) will not arm")
            return .action(.stall(.serviceBotNotArmed))
        }
        guard next.currentDirective == "service" else {
            return .action(.dispatch(
                kind: .setDirective, deviceCode: next.deviceCode,
                params: CommandParams(directive: "service"), nextStep: confirmStep
            ))
        }
        return .action(.dispatch(
            kind: .simple("activate"), deviceCode: next.deviceCode,
            params: CommandParams(), nextStep: confirmStep
        ))
    }

    private func confirmArm(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        if ctx.elapsed < Self.probeDelay { return .action(.wait) }
        if ctx.elapsed > Self.confirmDeadline { return .action(.stall(.serviceBotNotArmed)) }
        let deployed = RepairFleet.bots(deployedNear: vessel.location, in: ctx.world, owner: owner)
        // "Everything is armed" is the conclusion that skips repair entirely,
        // so it needs the same proof the mis-armed one does.
        if let probe = probe(deployed, ctx) { return .action(probe) }
        guard deployed.contains(where: { !RepairFleet.isArmed($0) }) else { return .finished }
        return .more
    }

    private func awaitRepair(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        guard let location = vessel.location else {
            return withoutLocation(
                vessel, ctx,
                anyOut: RepairFleet.anyBotDeployed(in: ctx.world, system: system, owner: owner),
                deadline: Self.repairDeadline, thenStall: .repairUnfinished
            )
        }
        let bots = RepairFleet.bots(deployedNear: location, in: ctx.world, owner: owner)
        if bots.isEmpty { return .finished }
        // A fleet nothing is worn enough to hold for leaves without paying the
        // probe delay or a single read.
        if !RepairFleet.needsRepair(RepairFleet.fleet(of: vessel, in: ctx.world, owner: owner)) {
            return .finished
        }
        if ctx.elapsed < Self.probeDelay { return .action(.wait) }
        if ctx.elapsed > Self.repairDeadline { return .action(.stall(.repairUnfinished)) }
        // Bots repair silently server-side; an unread row cannot be trusted to
        // report idle, so treat it as still working until a read says so.
        let stale = bots.contains { !ctx.isFresh($0) }
        if !stale, !bots.contains(where: RepairFleet.isRepairing) { return .finished }
        let lastLook = bots.map(\.updatedAt).min() ?? .distantPast
        if ctx.now.timeIntervalSince(lastLook) < Self.probeInterval { return .action(.wait) }
        return .action(.refreshDevices(deviceCodes: bots.map(\.deviceCode), thenStall: nil))
    }

    /// `recall`, not `stow`: `stow` needs the bot beside the vessel, and one
    /// that cruised off to repair a drone is not.
    private func recall(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        guard let location = vessel.location else {
            return withoutLocation(
                vessel, ctx,
                anyOut: RepairFleet.anyBotOut(in: ctx.world, system: system, owner: owner),
                deadline: Self.recallDeadline, thenStall: .serviceBotNotRecovered
            )
        }
        let out = RepairFleet.botsOut(near: location, in: ctx.world, owner: owner)
        guard let next = out.first else { return .finished }
        if rounds(ctx) > Self.dispatchRounds { return .action(.stall(.serviceBotNotRecovered)) }
        if RepairFleet.openRecall(for: next.deviceCode, in: ctx.world) != nil {
            if ctx.elapsed > Self.recallDeadline { return .action(.stall(.serviceBotNotRecovered)) }
            return .action(.wait)
        }
        return .action(.dispatch(
            kind: .simple("recall"), deviceCode: next.deviceCode,
            params: CommandParams(), nextStep: confirmStep
        ))
    }

    private func confirmRecall(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        if ctx.elapsed < Self.probeDelay { return .action(.wait) }
        if ctx.elapsed > Self.recallDeadline { return .action(.stall(.serviceBotNotRecovered)) }
        guard let location = vessel.location else {
            return withoutLocation(
                vessel, ctx,
                anyOut: RepairFleet.anyBotOut(in: ctx.world, system: system, owner: owner),
                deadline: Self.recallDeadline, thenStall: .serviceBotNotRecovered
            )
        }
        let out = RepairFleet.botsOut(near: location, in: ctx.world, owner: owner)
        if out.isEmpty { return .finished }
        // A recall cruises the bot home, so wait out its own arrival time.
        if let arrival = Self.recallArrival(out), arrival > ctx.now { return .action(.wait) }
        if out.contains(where: { !ctx.isFresh($0) }) {
            let lastLook = out.map(\.updatedAt).min() ?? .distantPast
            if ctx.now.timeIntervalSince(lastLook) < Self.probeInterval { return .action(.wait) }
            return .action(.refreshDevices(deviceCodes: out.map(\.deviceCode), thenStall: nil))
        }
        return .more
    }

    /// The latest arrival among the recalls still in flight.
    static func recallArrival(_ out: [Device]) -> Date? {
        out.compactMap(\.activityDeadline).max()
    }
}
```

> `recallArrival`'s body must be copied from the existing `SurveyRun.swift:488-490` / `SalvageRun.swift:568-570` (they are byte-identical, md5 `e19c5e72fec75b74be1cb082dfe97c30`) rather than re-derived. If it reads a different field from `activityDeadline`, use theirs.

- [ ] **Step 4: Run the tests**

```bash
cd app/Modules && swift test --filter BotPhaseTests \
  --event-stream-output-path /tmp/botphase.jsonl 2>&1 | tail -5
```

Expected: 6 passing, read from the event stream.

- [ ] **Step 5: Comment check and commit**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/Steps/BotPhase.swift
git add app/Modules/DirectiveEngine/Sources/Steps/BotPhase.swift \
        app/Modules/DirectiveEngine/Tests/Steps/BotPhaseTests.swift
git commit -m "feat(directives): BotPhase — the service-bot lifecycle, once"
```

---

## Task 3: `SurveyRun` adopts `BotPhase`

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/SurveyRun.swift:598-791` (delete), `:86-104` (constants), `:488-490` (`recallArrival`)
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRunRepairTests.swift` (must pass **unedited**)

**Interfaces:**
- Consumes: `BotPhase` from Task 2.
- Produces: nothing new. `SurveyRun.Step` is unchanged — the timeline must read identically after this task.

The eight step bodies go; the eight `Step` cases stay and become a mapping. Survey's `deployingBots` none-aboard exit goes to `.configuring` (skipping arming) and Salvage's to `.armingBots`; `.finished` is what lets both keep their own answer. **Do not unify that destination in this task** — see Open Question 1.

- [ ] **Step 1: Run the existing suite and record the baseline**

```bash
cd app/Modules && swift test --filter "SurveyRunRepairTests|SurveyRunTests|SurveyRunBotArmTests" \
  --event-stream-output-path /tmp/survey-before.jsonl 2>&1 | tail -5
```

Record the passing count in the ticket. It must be identical at Step 4 with no assertion edited.

- [ ] **Step 2: Replace the eight bodies with the mapping**

Delete `SurveyRun.swift:598-791` entirely (`deployBots`, `probe`, `confirmBotDeploy`, `armBots`, `confirmBotArm`, `awaitRepair`, `stowBots`, `confirmBotStow`) and `:488-490` (`recallArrival`). Delete the constants `recallProbeDelay` (`:75`), `recallProbeInterval` (`:80`), `botProbeDelay` (`:89`), `botProbeInterval` (`:92`), `repairDeadline` (`:95`), `botConfirmDeadline` (`:99`), `botDispatchRounds` (`:104`).

**Keep `recallDeadline` (`:86`)** — `recover` (`SurveyRun.swift:453`) reads it for drone recovery, which `BotPhase` does not own. Add a one-line trailing comment saying so.

Add, in `SurveyRun.swift`:

```swift
    /// The bot phase this step runs, and where the mission goes when it ends.
    private func botPhase(_ phase: BotPhase.Phase, _ directive: Directive) -> BotPhase {
        let (dispatch, confirm): (Step, Step) = switch phase {
        case .deploy, .confirmDeploy: (.deployingBots, .confirmingBotDeploy)
        case .arm, .confirmArm: (.armingBots, .confirmingBotArm)
        case .awaitRepair: (.repairing, .repairing)
        case .recall, .confirmRecall: (.stowingBots, .confirmingBotStow)
        }
        return BotPhase(
            vesselCode: directive.deviceCode, owner: Self.fleetTag(directive),
            system: directive.currentTarget, phase: phase,
            dispatchStep: dispatch.rawValue, confirmStep: confirm.rawValue,
            runNoun: "survey run"
        )
    }
```

Then each of the eight cases in `nextAction` becomes a call plus the mission's own destinations. The four confirm legs and `repairing`:

```swift
        case .deployingBots:
            return switch botPhase(.deploy, directive).next(ctx) {
            case let .action(action): action
            // An empty hold skips arming: Survey configures and gets on with it.
            case .finished: .advanceStep(nextStep: Step.configuring.rawValue)
            case .more: .advanceStep(nextStep: Step.deployingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }

        case .confirmingBotDeploy:
            return switch botPhase(.confirmDeploy, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .more: .advanceStep(nextStep: Step.deployingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }

        case .armingBots:
            return switch botPhase(.arm, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.configuring.rawValue)
            case .more: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }

        case .confirmingBotArm:
            return switch botPhase(.confirmArm, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.configuring.rawValue)
            case .more: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }

        case .repairing:
            return switch botPhase(.awaitRepair, directive).next(ctx) {
            case let .action(action): action
            case .finished, .more: .advanceStep(nextStep: Step.stowingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }

        case .stowingBots:
            return switch botPhase(.recall, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceTarget
            case .more: .advanceStep(nextStep: Step.stowingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }

        case .confirmingBotStow:
            return switch botPhase(.confirmRecall, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceTarget
            case .more: .advanceStep(nextStep: Step.stowingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
```

`ctx` is built once at the top of `nextAction`:

```swift
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
```

- [ ] **Step 3: Verify the deletion left no caller behind**

```bash
cd app/Modules && swift build --build-tests 2>&1 | grep -E "error:" | head
grep -n "botProbeInterval\|botConfirmDeadline\|botDispatchRounds\|SurveyRun.probe" \
  DirectiveEngine/Sources/*.swift DirectiveEngine/Tests/*.swift
```

Expected: no errors, and no hits outside `SalvageRun.swift` (which Task 4 handles).

- [ ] **Step 4: Run the whole target and compare**

```bash
cd app/Modules && swift test --filter DirectiveEngineTests \
  --event-stream-output-path /tmp/survey-after.jsonl 2>&1 | tail -5
```

Expected: the same passing count as Step 1 for the three survey suites, with **no assertion edited**. If a test needs editing, stop — the migration changed behaviour and that is a finding, not a fix.

- [ ] **Step 5: Commit**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/SurveyRun.swift
git add app/Modules/DirectiveEngine/Sources/SurveyRun.swift
git commit -m "refactor(directives): SurveyRun's bot phase moves to BotPhase"
```

---

## Task 4: `SalvageRun` adopts `BotPhase`

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/SalvageRun.swift:669-873` (delete), `:84-106` (constants), `:568-570` (`recallArrival`)
- Test: `app/Modules/DirectiveEngine/Tests/SalvageRunRepairTests.swift` (must pass **unedited**)

**Interfaces:**
- Consumes: `BotPhase`.
- Produces: nothing new.

Identical in shape to Task 3, with Salvage's own destinations: `deployingBots` finished → `.armingBots` (not `.configuring`), and `armingBots`/`confirmingBotArm` finished → `.positioning` (not `.configuring`).

- [ ] **Step 1: Baseline the suite**

```bash
cd app/Modules && swift test --filter "SalvageRunRepairTests|SalvageRunTests|SalvageRunBotBoundTests" \
  --event-stream-output-path /tmp/salvage-before.jsonl 2>&1 | tail -5
```

- [ ] **Step 2: Replace the eight bodies**

Delete `SalvageRun.swift:669-873` and `:568-570`. Delete `botProbeDelay` (`:84`), `botProbeInterval` (`:87`), `repairDeadline` (`:90`), `botRecallDeadline` (`:93`), `botConfirmDeadline` (`:102`), `botDispatchRounds` (`:106`). **Keep `controllerRecallDeadline` (`:98`)** — `controllerNotAboard` (`:948`) reads it and that is not a bot phase.

Add the same `botPhase(_:_:)` helper as Task 3 with `runNoun: "salvage run"`, and the same seven `switch` cases with these destinations:

```swift
        case .deployingBots:
            return switch botPhase(.deploy, directive).next(ctx) {
            case let .action(action): action
            // Salvage arms whatever is already standing here; Survey does not.
            case .finished: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .more: .advanceStep(nextStep: Step.deployingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }

        case .confirmingBotDeploy:
            return switch botPhase(.confirmDeploy, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .more: .advanceStep(nextStep: Step.deployingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }

        case .armingBots:
            return switch botPhase(.arm, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.positioning.rawValue)
            case .more: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }

        case .confirmingBotArm:
            return switch botPhase(.confirmArm, directive).next(ctx) {
            case let .action(action): action
            case .finished: .advanceStep(nextStep: Step.positioning.rawValue)
            case .more: .advanceStep(nextStep: Step.armingBots.rawValue)
            case .noSubject: .stall(.unreachableDevice)
            }
```

`repairing`, `stowingBots` and `confirmingBotStow` take Task 3's bodies verbatim — Salvage's destinations for those three are the same (`.stowingBots`, `.advanceTarget`).

- [ ] **Step 3: Prove both bodies are gone**

```bash
cd app/Modules/DirectiveEngine/Sources
grep -c "RepairFleet\." SurveyRun.swift SalvageRun.swift Steps/BotPhase.swift
```

Expected: `SurveyRun.swift:0`, `SalvageRun.swift:0`, `Steps/BotPhase.swift:12` or thereabouts. `RepairFleet` now has exactly one caller.

```bash
cd app/Modules && wc -l DirectiveEngine/Sources/SurveyRun.swift DirectiveEngine/Sources/SalvageRun.swift
```

Expected: roughly 792 → ~640 and 999 → ~840. Record the real numbers in the ticket.

- [ ] **Step 4: Narrow `RepairFleet`'s surface**

With one caller, `answers(_:to:)` and `repairThreshold` have no external reader (`answers` is used only inside `RepairFleet` at `:38`, `:84`, `:94`; `repairThreshold` only by `needsRepair` at `:115`). Make both `internal` rather than `public`. Verify:

```bash
cd app/Modules && swift build --build-tests 2>&1 | grep -E "error:" | head
```

- [ ] **Step 5: Run every affected target and commit**

```bash
cd app/Modules && swift test \
  --filter "DirectiveEngineTests|GameServicesTests|GameSyncTests|GameModelsTests|DirectivesFeatureTests" \
  --event-stream-output-path /tmp/stage2-task4.jsonl 2>&1 | tail -5
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/SalvageRun.swift \
                                app/Modules/DirectiveEngine/Sources/RepairFleet.swift
git add app/Modules/DirectiveEngine/Sources
git commit -m "refactor(directives): SalvageRun's bot phase moves to BotPhase; ~400 duplicated lines deleted"
```

**Checkpoint C** is due here — see Order of work.

---

## Task 5: `TravelTo`

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/Steps/TravelTo.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/SalvageRun.swift:292-334` (move out), `:76`, `:80` (constants)
- Test: `app/Modules/DirectiveEngine/Tests/Steps/TravelToTests.swift`

**Interfaces:**
- Consumes: `StepContext`, `StepResult`, `SiteAssay.system(of:)`.
- Produces: `TravelTo(deviceCode:destination:arrivalTest:confirmStep:)` with `func next(_ ctx: StepContext) -> StepResult` and `func hasArrived(_ device: Device) -> Bool`; statics `TravelTo.positionUnconfirmed(_:_:)`, `TravelTo.lastTravelCompletion(for:_:)`, `TravelTo.arrivalConfirmDeadline` (300), `TravelTo.arrivalReadInterval` (30). Tasks 6 and 7 consume all of it.

This task moves `lastTravelCompletion` and `travelPositionUnconfirmed` off `SalvageRun` — the single most-borrowed member in the engine (4 caller files, 11 sites) — and wraps the frame around them. `SalvageRun.arrivalConfirmDeadline` and `arrivalReadInterval` move too; `MineRun.swift:50` aliases the first and must be repointed.

- [ ] **Step 1: Write the failing tests**

`app/Modules/DirectiveEngine/Tests/Steps/TravelToTests.swift`:

```swift
//
//  TravelToTests.swift
//  Replicould — DirectiveEngine
//
//  The travel frame: guard order, both arrival tests, and the same-step loop.
//

import Foundation
import GameModels
import Testing
import UniverseModels

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)

private func row(step: String = "travelling", startedAgo: TimeInterval = 30) -> Directive {
    Directive(
        id: "D1", kind: .salvageRun, status: .running, deviceCode: "V1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: ["SOL"], targetIndex: 0, step: step,
        stepStartedAt: now.addingTimeInterval(-startedAgo),
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: now.addingTimeInterval(-3_600), updatedAt: now, theatreDepot: nil
    )
}

private func vessel(at location: String?, updatedAt: Date = now) -> Device {
    Device(
        deviceCode: "V1", deviceType: "heaven_vessel", replicantCode: "R1", status: "idle",
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: [], tags: [], detail: .object([:]),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func travelOp(status: OperationStatus, confirmedAt: Date) -> GameModels.Operation {
    GameModels.Operation(
        id: "OP1", entityCode: "V1", kind: .travel, status: status, source: .optimistic,
        startedAt: confirmedAt.addingTimeInterval(-600), completesAt: confirmedAt,
        lastConfirmedAt: confirmedAt, detail: .object([:]),
        directiveID: "D1", step: "travelling", paramsDigest: nil
    )
}

private func ctx(
    _ device: Device, open: [String: GameModels.Operation] = [:],
    dispatched: [String: GameModels.Operation] = [:], startedAgo: TimeInterval = 30
) -> StepContext {
    StepContext(
        directive: row(startedAgo: startedAgo),
        world: WorldSnapshot(
            devices: ["V1": device], openOperations: open,
            dispatchedOperations: dispatched, now: now
        ),
        step: "travelling"
    )
}

@Suite("Travel to")
struct TravelToTests {
    private let toSystem = TravelTo(
        deviceCode: "V1", destination: "SOL", arrivalTest: .system, confirmStep: nil
    )

    /// A location is a SITE, not a system: `SOL-3` is in `SOL`.
    @Test("the system test accepts any site in the destination system")
    func systemTestAcceptsASiteInTheSystem() {
        #expect(toSystem.next(ctx(vessel(at: "SOL-3"))) == .finished)
    }

    @Test("the exact test rejects a sibling site in the same system")
    func exactTestRejectsASiblingSite() {
        let exact = TravelTo(
            deviceCode: "V1", destination: "SOL-3-1", arrivalTest: .exactLocation, confirmStep: nil
        )
        #expect(exact.next(ctx(vessel(at: "SOL-3"))) != .finished)
    }

    /// 11 of the 13 sites loop on their own step; a tracked `.travel` op is
    /// what stops the dispatch re-issuing every tick.
    @Test("a nil confirm step dispatches into the mission's own step")
    func nilConfirmStepLoopsOnItsOwnStep() {
        #expect(toSystem.next(ctx(vessel(at: "VEGA-1"))) == .action(.dispatch(
            kind: .travel, deviceCode: "V1",
            params: CommandParams(destination: "SOL"), nextStep: "travelling"
        )))
    }

    @Test("a named confirm step dispatches into it instead")
    func namedConfirmStepIsUsed() {
        let paired = TravelTo(
            deviceCode: "V1", destination: "SOL", arrivalTest: .system,
            confirmStep: "confirmingArrival"
        )
        #expect(paired.next(ctx(vessel(at: "VEGA-1"))) == .action(.dispatch(
            kind: .travel, deviceCode: "V1",
            params: CommandParams(destination: "SOL"), nextStep: "confirmingArrival"
        )))
    }

    @Test("an in-flight op waits rather than commanding a second travel")
    func anOpenOpWaits() {
        let open = ["V1": travelOp(status: .active, confirmedAt: now)]
        #expect(toSystem.next(ctx(vessel(at: "VEGA-1"), open: open)) == .action(.wait))
    }

    /// One arrival settles in two transactions — the op closes, then the
    /// location is written. A tick in that gap must not re-command travel.
    @Test("a row predating its own arrival buys a read instead of dispatching")
    func aRowPredatingItsArrivalBuysARead() {
        let arrival = now.addingTimeInterval(-60)
        let stale = vessel(at: "VEGA-1", updatedAt: arrival.addingTimeInterval(-120))
        let result = toSystem.next(ctx(
            stale, dispatched: ["OP1": travelOp(status: .completed, confirmedAt: arrival)]
        ))
        #expect(result == .action(.refreshDevices(deviceCodes: ["V1"], thenStall: nil)))
    }

    /// Deadline BEFORE the read: a failing read never advances `updatedAt`.
    @Test("past the deadline the read carries a stall")
    func pastTheDeadlineTheReadStalls() {
        let arrival = now.addingTimeInterval(-(TravelTo.arrivalConfirmDeadline + 1))
        let stale = vessel(at: "VEGA-1", updatedAt: arrival.addingTimeInterval(-120))
        let result = toSystem.next(ctx(
            stale, dispatched: ["OP1": travelOp(status: .completed, confirmedAt: arrival)]
        ))
        #expect(result == .action(.refreshDevices(
            deviceCodes: ["V1"], thenStall: .vesselPositionUnconfirmed
        )))
    }

    /// `.superseded` and `.unknown` also stamp `lastConfirmedAt` on travels
    /// that never arrived; gating on one blocks a real dispatch forever.
    @Test("only a completed travel is a watermark")
    func onlyACompletedTravelIsAWatermark() {
        let arrival = now.addingTimeInterval(-60)
        let stale = vessel(at: "VEGA-1", updatedAt: arrival.addingTimeInterval(-120))
        let result = toSystem.next(ctx(
            stale, dispatched: ["OP1": travelOp(status: .superseded, confirmedAt: arrival)]
        ))
        #expect(result == .action(.dispatch(
            kind: .travel, deviceCode: "V1",
            params: CommandParams(destination: "SOL"), nextStep: "travelling"
        )))
    }

    @Test("an unknown device is no subject, not a stall")
    func anUnknownDeviceIsNoSubject() {
        let empty = StepContext(
            directive: row(),
            world: WorldSnapshot(devices: [:], openOperations: [:], now: now),
            step: "travelling"
        )
        #expect(toSystem.next(empty) == .noSubject)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'TravelTo' in scope`.

- [ ] **Step 3: Write the implementation**

`app/Modules/DirectiveEngine/Sources/Steps/TravelTo.swift`:

```swift
//
//  TravelTo.swift
//  Replicould — DirectiveEngine
//
//  Flying one device to one place: the already-there test, the busy guard, the
//  arrival watermark, the dispatch. Every travelling mission's frame.
//

import Foundation
import GameModels
import UniverseModels

/// One travel leg, as a pure value.
public struct TravelTo: Equatable, Sendable {
    /// How close counts as arrived. A location is a SITE, so `SOL-3` is in
    /// `SOL` under `.system` and is not `SOL-3-1` under `.exactLocation`.
    public enum ArrivalTest: Equatable, Sendable {
        case system
        case exactLocation
    }

    /// How long an unconfirmed arrival is tolerated before the read stalls.
    public static let arrivalConfirmDeadline: TimeInterval = 5 * 60
    /// Floor between reads of a row that predates its own arrival.
    public static let arrivalReadInterval: TimeInterval = 30

    public let deviceCode: String
    public let destination: String
    public let arrivalTest: ArrivalTest
    /// The step the dispatch names. Nil is the same-step loop, where the
    /// tracked `.travel` op is the guard against re-issuing every tick.
    public let confirmStep: String?

    public init(
        deviceCode: String, destination: String, arrivalTest: ArrivalTest, confirmStep: String?
    ) {
        self.deviceCode = deviceCode
        self.destination = destination
        self.arrivalTest = arrivalTest
        self.confirmStep = confirmStep
    }

    public func hasArrived(_ device: Device) -> Bool {
        switch arrivalTest {
        case .system: device.location.map { SiteAssay.system(of: $0) } == destination
        case .exactLocation: device.location == destination
        }
    }

    public func next(_ ctx: StepContext) -> StepResult {
        guard let device = ctx.world.device(deviceCode) else { return .noSubject }
        if hasArrived(device) { return .finished }
        // An open op means the trip is under way; waiting stops a second
        // travel landing on top of the first.
        if ctx.openOperation(for: deviceCode) != nil { return .action(.wait) }
        // The equality check above misreads a row still lagging the arrival.
        if let unconfirmed = Self.positionUnconfirmed(device, ctx) { return .action(unconfirmed) }
        return .action(.dispatch(
            kind: .travel, deviceCode: deviceCode,
            params: CommandParams(destination: destination),
            nextStep: confirmStep ?? ctx.step
        ))
    }

    /// When the last travel this directive dispatched for `device` finished, or
    /// nil. Filters on `.completed` EXACTLY: `.superseded` and `.unknown` also
    /// stamp `lastConfirmedAt` on travels that never arrived.
    static func lastTravelCompletion(for device: Device, _ world: WorldSnapshot) -> Date? {
        world.dispatchedOperations.values
            .lazy
            .filter {
                $0.entityCode == device.deviceCode
                    && $0.kind == OperationKind.travel.rawValue
                    && $0.status == .completed
            }
            .map(\.lastConfirmedAt)
            .max()
    }

    /// What a dispatch site should do when `device`'s row cannot yet be trusted
    /// to say where it is; nil means dispatch may proceed. The watermark is the
    /// ARRIVAL, never `stepStartedAt`.
    ///
    /// **The order is mandated:** deadline, throttled read, `.wait`. The
    /// throttle measures `updatedAt`, which advances only on a SUCCESSFUL read.
    public static func positionUnconfirmed(_ device: Device, _ ctx: StepContext) -> MissionAction? {
        // Nothing to post-date, so cold runs and first entries dispatch at once.
        guard let completion = lastTravelCompletion(for: device, ctx.world) else { return nil }
        guard device.updatedAt < completion else { return nil }
        if ctx.now.timeIntervalSince(completion) >= arrivalConfirmDeadline {
            return .refreshDevices(
                deviceCodes: [device.deviceCode], thenStall: .vesselPositionUnconfirmed
            )
        }
        if ctx.now.timeIntervalSince(device.updatedAt) > arrivalReadInterval {
            return .refreshDevices(deviceCodes: [device.deviceCode], thenStall: nil)
        }
        return .wait
    }
}
```

- [ ] **Step 4: Delete the originals and repoint the alias**

Delete `SalvageRun.swift:292-334` (`lastTravelCompletion`, `travelPositionUnconfirmed` and the `// MARK: - Arrival freshness` banner) and the constants `arrivalConfirmDeadline` (`:76`) and `arrivalReadInterval` (`:80`).

`SalvageRun.swift:956` reads `Self.arrivalReadInterval` inside `controllerNotAboard` — repoint it to `TravelTo.arrivalReadInterval`. `MineRun.swift:50` aliases `SalvageRun.arrivalConfirmDeadline` — repoint to `TravelTo.arrivalConfirmDeadline`.

Leave the 13 call sites of `SalvageRun.travelPositionUnconfirmed` compiling by **not** deleting them yet; instead repoint each to `TravelTo.positionUnconfirmed(device, ctx)` as part of Tasks 6 and 7. Until then the build is broken, so do Step 5 in the same commit as Task 6 if you prefer one green commit — the ticket permits either, but the branch must not be left red.

- [ ] **Step 5: Run and commit**

```bash
cd app/Modules && swift test --filter TravelToTests \
  --event-stream-output-path /tmp/travelto.jsonl 2>&1 | tail -5
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/Steps/TravelTo.swift
git add app/Modules/DirectiveEngine/Sources/Steps/TravelTo.swift \
        app/Modules/DirectiveEngine/Tests/Steps/TravelToTests.swift
git commit -m "feat(directives): TravelTo — the travel frame and the arrival watermark"
```

---

## Task 6: The nine outbound travel sites adopt `TravelTo`

**Files:**
- Modify: `SalvageRun.swift:338-354`, `:474-492`; `SurveyRun.swift:559-568`; `MineRun.swift:346-361`; `RelayRun.swift:552-571`, `:729-757`, `:789-812`; `EventRun.swift:485-514`
- Test: the existing mission suites, **unedited**

**Interfaces:**
- Consumes: `TravelTo` from Task 5.
- Produces: nothing new.

Every site keeps its own arrival destination, its own pre-guards and its own stalls. What is deleted from each is the identical guard triple: already-there test, `openOperation` guard, `travelPositionUnconfirmed`, and the `.dispatch` literal.

**Use `ctx.openOperation(for:)`, the UNOWNED guard.** All 13 sites use the unowned form today. Switching them to owner-scoped is a real behaviour change (a co-tenant's op would stop blocking travel) and is NOT in this task — it goes on the punch list in Task 13.

The nine sites, with the measured facts each `TravelTo` must be built from:

| # | Site | Device | Destination | Arrival test | `confirmStep` |
|---|---|---|---|---|---|
| 1 | `SalvageRun.swift:350` `travel` | `vessel` | `directive.currentTarget` | `.system` | nil |
| 2 | `SalvageRun.swift:491` `position` | `vessel` | `body` from `Self.nextBody(in:world:)` | `.exactLocation` | nil |
| 3 | `SurveyRun.swift:567` `travel` | `vessel` | `directive.currentTarget` | `.system` | nil |
| 4 | `MineRun.swift:355` `travel` | `carrier` | `Self.targetBelt(of: directive)` | `.exactLocation` | `Step.confirmingArrival.rawValue` |
| 5 | `RelayRun.swift:570` `fetch` | `carrier` | `source.location` | `.exactLocation` | nil |
| 6 | `RelayRun.swift:756` `travel` | `carrier` | `directive.currentTarget` | `.system` | nil |
| 7 | `RelayRun.swift:808` `emplace` | `carrier` | `SalvageRun.lagrangePoint(in: system)` | `.exactLocation` | nil |
| 8 | `EventRun.swift:497` `departing` | `convoy.carrier` | `event.location` | `.exactLocation` | nil |
| 9 | `EventRun.swift:510` `departing` | `convoy.freighter` | `event.location` | `.exactLocation` | `Step.confirmingArrival.rawValue` |

**Rule for every site: the `.finished` branch takes whatever that site returns today on arrival, copied verbatim.** Do not re-derive a destination — read the line and move it. Sites 6, 7 and 8 are not plain returns and are written out in full below.

- [ ] **Step 1: The six plain sites**

Sites 1, 2, 3, 4, 5, 9 follow one pattern. Site 1 in full, as the model:

```swift
    private func travel(_ directive: Directive, _ vessel: Device, _ world: WorldSnapshot) -> MissionAction {
        guard let target = directive.currentTarget else {
            return .advanceStep(nextStep: Step.preflight.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let leg = TravelTo(
            deviceCode: vessel.deviceCode, destination: target,
            arrivalTest: .system, confirmStep: nil
        )
        return switch leg.next(ctx) {
        case let .action(action): action
        case .finished: .advanceStep(nextStep: Step.deployingBots.rawValue)
        case .more, .noSubject: .stall(.unreachableDevice)
        }
    }
```

Site 4 keeps its paired confirming step untouched — only `travel` changes, not `confirmArrival` (Task 8 takes that one).

Site 2 keeps its `NextBodyResolution` switch and its `unresolvedSystem` ladder above the `TravelTo`; only the guard triple inside the `.body` branch is replaced.

Site 5 keeps both pre-guards above the `TravelTo`: the missing-source-row `.refreshDevices(.unreachableDevice)` at `RelayRun.swift:557` and the nil-source-location `.stall(.unreachableDevice)` at `:561`.

- [ ] **Step 2: Site 6 — the forked arrival**

`RelayRun.travel` does not plainly advance on arrival: it recomputes mesh membership and forks. Keep the fork, replace only the frame:

```swift
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let leg = TravelTo(
            deviceCode: carrier.deviceCode, destination: target,
            arrivalTest: .system, confirmStep: nil
        )
        switch leg.next(ctx) {
        case let .action(action): return action
        case .more, .noSubject: return .stall(.unreachableDevice)
        case .finished: break   // arrived — the fork below decides where to
        }
```

then the existing mesh-membership fork at `RelayRun.swift:738-746` follows unchanged, including its `meshRaceLoss` warning.

- [ ] **Step 3: Site 7 — guards nested inside a conditional**

`RelayRun.emplace` runs the guard triple inside `if carrier.location != point { … }` and continues past it to a `deploy` dispatch. The three stalls above it (uncached system `:791`, no Lagrange point `:794`, no relay `:800`) stay exactly where they are. Replace only the inner block:

```swift
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let leg = TravelTo(
            deviceCode: carrier.deviceCode, destination: point,
            arrivalTest: .exactLocation, confirmStep: nil
        )
        switch leg.next(ctx) {
        case let .action(action): return action
        case .more, .noSubject: return .stall(.unreachableDevice)
        case .finished: break   // standing at the point — deploy below
        }
```

- [ ] **Step 4: Site 8 — two frames, fall-through**

`EventRun.departing` moves the carrier, then falls through to move the freighter. Both frames become `TravelTo`; the carrier's `.finished` falls through rather than returning:

```swift
    private func departing(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        let destination = event.location
        let ctx = StepContext(directive: directive, world: world, step: directive.step)

        let carrierLeg = TravelTo(
            deviceCode: convoy.carrier.deviceCode, destination: destination,
            arrivalTest: .exactLocation, confirmStep: nil
        )
        switch carrierLeg.next(ctx) {
        case let .action(action): return action
        case .more, .noSubject: return .stall(.unreachableDevice)
        case .finished: break   // carrier placed — the freighter leg follows
        }

        guard let freighter = convoy.freighter else {
            return .refreshFleet(tag: Self.rootTag, thenStall: .unreachableDevice)
        }
        let freighterLeg = TravelTo(
            deviceCode: freighter.deviceCode, destination: destination,
            arrivalTest: .exactLocation, confirmStep: Step.confirmingArrival.rawValue
        )
        return switch freighterLeg.next(ctx) {
        case let .action(action): action
        case .finished: .advanceStep(nextStep: Step.confirmingArrival.rawValue)
        case .more, .noSubject: .stall(.unreachableDevice)
        }
    }
```

- [ ] **Step 5: Prove the borrow is gone and the suites are unchanged**

```bash
cd app/Modules/DirectiveEngine/Sources
grep -rn "travelPositionUnconfirmed\|lastTravelCompletion" *.swift Steps/*.swift
```

Expected: hits only inside `Steps/TravelTo.swift`. Nine of the eleven borrow sites are gone; the remaining two are the return-homes, which Task 7 takes.

```bash
cd app/Modules && swift test --filter DirectiveEngineTests \
  --event-stream-output-path /tmp/task6.jsonl 2>&1 | tail -5
```

Expected: the whole target green with **no assertion edited**.

- [ ] **Step 6: Commit**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/{SalvageRun,SurveyRun,MineRun,RelayRun,EventRun}.swift
git add app/Modules/DirectiveEngine/Sources
git commit -m "refactor(directives): the nine outbound travel frames move to TravelTo"
```

---

## Task 7: `ReturnHome` and the four return-home sites

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/Steps/ReturnHome.swift`
- Modify: `SurveyRun.swift:494-503`; `MineRun.swift:507-526`; `RelayRun.swift:908-924`; `EventRun.swift:746-764`
- Test: `app/Modules/DirectiveEngine/Tests/Steps/ReturnHomeTests.swift`

**Interfaces:**
- Consumes: `TravelTo`, `StepContext`, `StepResult`, `WorldSnapshot.theatreDepot(for:)`, `WorldSnapshot.theatreWentClaimed(for:)`.
- Produces: `ReturnHome(deviceCodes:destination:)` with `func next(_ ctx: StepContext) -> StepResult`, and `ReturnHome.Destination` (`.theatreDepot` / `.origin`).

`MineRun.swift:507` and `RelayRun.swift:908` are the same function twice, differing only in a logger string and in `RelayRun.theatreDepot` vs `Self.theatreDepot` — the same function either way. This is the cleanest extraction the measurement found.

Two things make the sub-machine less trivial than that pair suggests:

- **`EventRun` iterates two hulls**, moving whichever needs moving, one per evaluation. So `ReturnHome` takes `deviceCodes: [String]`, and the pair passes one.
- **`EventRun` needs to tell "arrived" from "no depot" apart** (`.advanceStep(.depositing)` vs `.done`), which is what `.noSubject` is for. `SurveyRun` returns `.done` for both; `MineRun` and `RelayRun` return `.done` for both after a `theatreWentClaimed` wait.

- [ ] **Step 1: Write the failing tests**

`app/Modules/DirectiveEngine/Tests/Steps/ReturnHomeTests.swift`:

```swift
//
//  ReturnHomeTests.swift
//  Replicould — DirectiveEngine
//
//  Going home: arrived, in flight, and the three-way no-destination rule.
//

import Foundation
import GameModels
import Testing

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)
private let depot = "AINALRAM-BELT-1"

private func row(theatreDepot: String?, origin: String? = nil) -> Directive {
    Directive(
        id: "D1", kind: .mineRun, status: .running, deviceCode: "C1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: ["SOL"], targetIndex: 0, step: "returning",
        stepStartedAt: now.addingTimeInterval(-60), returnToOrigin: origin != nil,
        originDesignation: origin, attentionReason: nil,
        createdAt: now.addingTimeInterval(-3_600), updatedAt: now, theatreDepot: theatreDepot
    )
}

private func carrier(at location: String?) -> Device {
    Device(
        deviceCode: "C1", deviceType: "surge_carrier", replicantCode: "R1", status: "idle",
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: [], tags: [], detail: .object([:]),
        updatedAt: now, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func ctx(_ device: Device, _ directive: Directive, theatres: [Theatre] = []) -> StepContext {
    StepContext(
        directive: directive,
        world: WorldSnapshot(
            devices: [device.deviceCode: device], openOperations: [:],
            theatres: theatres, now: now
        ),
        step: "returning"
    )
}

@Suite("Return home")
struct ReturnHomeTests {
    private let home = ReturnHome(deviceCodes: ["C1"], destination: .theatreDepot)

    @Test("standing at the depot is finished")
    func standingAtTheDepotIsFinished() {
        let theatres = [operationalTheatre(depot: depot)]
        let result = home.next(ctx(carrier(at: depot), row(theatreDepot: depot), theatres: theatres))
        #expect(result == .finished)
    }

    @Test("away from the depot it flies")
    func awayFromTheDepotItFlies() {
        let theatres = [operationalTheatre(depot: depot)]
        let result = home.next(ctx(carrier(at: "VEGA-1"), row(theatreDepot: depot), theatres: theatres))
        #expect(result == .action(.dispatch(
            kind: .travel, deviceCode: "C1",
            params: CommandParams(destination: depot), nextStep: "returning"
        )))
    }

    /// No depot at all is the mission's call — leave the hull where it stands,
    /// or wait. `.noSubject` is what keeps that decision out of here.
    @Test("no depot is no subject, never a stall")
    func noDepotIsNoSubject() {
        #expect(home.next(ctx(carrier(at: "VEGA-1"), row(theatreDepot: nil))) == .noSubject)
    }

    /// A row whose own theatre went `.claimed` while another stands
    /// `.operational` waits for it rather than flying somewhere else.
    @Test("a claimed theatre waits instead of reporting no subject")
    func aClaimedTheatreWaits() {
        let elsewhere = [operationalTheatre(depot: "DENEBED-2")]
        let result = home.next(ctx(carrier(at: "VEGA-1"), row(theatreDepot: depot), theatres: elsewhere))
        #expect(result == .action(.wait))
    }

    /// Survey aims at `originDesignation`, a bare SYSTEM, and matches at
    /// system level — the only site that does.
    @Test("the origin destination matches at system level")
    func theOriginDestinationMatchesAtSystemLevel() {
        let toOrigin = ReturnHome(deviceCodes: ["C1"], destination: .origin)
        let result = toOrigin.next(ctx(carrier(at: "SOL-3"), row(theatreDepot: nil, origin: "SOL")))
        #expect(result == .finished)
    }

    /// One hull moves per evaluation; the other's turn comes next tick.
    @Test("with two hulls only the one that needs moving is commanded")
    func onlyOneHullMovesPerEvaluation() {
        let pair = ReturnHome(deviceCodes: ["C1", "F1"], destination: .theatreDepot)
        let freighter = Device(
            deviceCode: "F1", deviceType: "cargo_freighter", replicantCode: "R1", status: "idle",
            location: "VEGA-1", locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
            features: [], tags: [], detail: .object([:]),
            updatedAt: now, firstSeenAt: Date(timeIntervalSince1970: 0)
        )
        let world = WorldSnapshot(
            devices: ["C1": carrier(at: depot), "F1": freighter], openOperations: [:],
            theatres: [operationalTheatre(depot: depot)], now: now
        )
        let result = pair.next(StepContext(
            directive: row(theatreDepot: depot), world: world, step: "returning"
        ))
        #expect(result == .action(.dispatch(
            kind: .travel, deviceCode: "F1",
            params: CommandParams(destination: depot), nextStep: "returning"
        )))
    }
}
```

> `operationalTheatre(depot:)` is whatever the existing suites use to build an `.operational` `Theatre` — reuse it (`Tests/BrainTestSupport.swift` or `Tests/MissionTheatreTests.swift` hold one). Do not add a second.

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL — `cannot find 'ReturnHome' in scope`.

- [ ] **Step 3: Write the implementation**

`app/Modules/DirectiveEngine/Sources/Steps/ReturnHome.swift`:

```swift
//
//  ReturnHome.swift
//  Replicould — DirectiveEngine
//
//  The trip back: resolve the destination, then fly whichever hull still
//  needs moving. One hull per evaluation, like every other dispatch.
//

import Foundation
import GameModels
import UniverseModels

/// The return leg, as a pure value.
public struct ReturnHome: Equatable, Sendable {
    /// Where home is. `.theatreDepot` names a LOCATION and matches exactly;
    /// `.origin` names a bare SYSTEM and matches at system level.
    public enum Destination: Equatable, Sendable {
        case theatreDepot
        case origin
    }

    /// The hulls to bring home, in the order they should be moved.
    public let deviceCodes: [String]
    public let destination: Destination

    public init(deviceCodes: [String], destination: Destination) {
        self.deviceCodes = deviceCodes
        self.destination = destination
    }

    public func next(_ ctx: StepContext) -> StepResult {
        guard let home = resolve(ctx) else {
            // Its own theatre went `.claimed` while another stands operational:
            // wait for it rather than flying the hull anywhere else.
            if destination == .theatreDepot, ctx.world.theatreWentClaimed(for: ctx.directive) {
                return .action(.wait)
            }
            return .noSubject
        }
        let arrivalTest: TravelTo.ArrivalTest = destination == .origin ? .system : .exactLocation
        for code in deviceCodes {
            let leg = TravelTo(
                deviceCode: code, destination: home, arrivalTest: arrivalTest, confirmStep: nil
            )
            switch leg.next(ctx) {
            case .finished: continue
            // A hull the fleet read does not hold cannot be flown; the next one
            // still can, so this is not the whole leg's answer.
            case .noSubject: continue
            case let .action(action): return .action(action)
            case .more: return .more
            }
        }
        return .finished
    }

    private func resolve(_ ctx: StepContext) -> String? {
        switch destination {
        case .theatreDepot: ctx.world.theatreDepot(for: ctx.directive)
        case .origin: ctx.directive.originDesignation
        }
    }
}
```

- [ ] **Step 4: Migrate the four sites**

`MineRun.swift:507` and `RelayRun.swift:908` become the same body, each keeping its own logger prose:

```swift
    private func returnHome(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let home = ReturnHome(deviceCodes: [carrier.deviceCode], destination: .theatreDepot)
        return switch home.next(ctx) {
        case let .action(action): action
        // Nowhere to return to is done, not a stall: the mine is installed.
        case .finished, .more: .done
        case .noSubject: noDepot(directive)
        }
    }

    /// Nothing to fly home to. Says so once, then finishes.
    private func noDepot(_ directive: Directive) -> MissionAction {
        logger.notice("mine run \(directive.id, privacy: .public): no depot to return to — leaving the carrier where it stands")
        return .done
    }
```

`SurveyRun.swift:494` uses `.origin` and returns `.done` on every outcome:

```swift
    private func returnHome(
        _ directive: Directive, _ vessel: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let home = ReturnHome(deviceCodes: [vessel.deviceCode], destination: .origin)
        return switch home.next(ctx) {
        case let .action(action): action
        case .finished, .more, .noSubject: .done
        }
    }
```

`EventRun.swift:746` passes both hulls and is the one site that distinguishes the two endings:

```swift
    private func returning(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let hulls = [convoy.carrier, convoy.freighter].compactMap { $0?.deviceCode }
        let home = ReturnHome(deviceCodes: hulls, destination: .theatreDepot)
        // A statement switch, not an expression one: the `.noSubject` arm logs
        // before it answers, and an expression arm has nowhere to put that.
        switch home.next(ctx) {
        case let .action(action):
            return action
        case .finished, .more:
            return .advanceStep(nextStep: Step.depositing.rawValue)
        case .noSubject:
            logger.notice("event run \(directive.id, privacy: .public): no depot to return to — leaving the convoy where it stands")
            return .done
        }
    }
```

> `convoy.carrier` is non-optional and `convoy.freighter` optional — `compactMap` over `[Device?]` handles both; check the real declarations and adjust the literal rather than the shape.

- [ ] **Step 5: Verify and commit**

```bash
cd app/Modules/DirectiveEngine/Sources
grep -rn "travelPositionUnconfirmed" *.swift Steps/*.swift
```

Expected: hits only inside `Steps/TravelTo.swift`. The 11-site, 4-file borrow is now zero.

```bash
cd app/Modules && swift test --filter DirectiveEngineTests \
  --event-stream-output-path /tmp/task7.jsonl 2>&1 | tail -5
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/Steps/ReturnHome.swift \
  app/Modules/DirectiveEngine/Sources/{SurveyRun,MineRun,RelayRun,EventRun}.swift
git add app/Modules/DirectiveEngine
git commit -m "refactor(directives): ReturnHome — the four return legs, one rule"
```

---

## Task 8: `ConfirmRow`, and the ten shared-ladder sites

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/Steps/ConfirmRow.swift`
- Modify: `EventRun.swift:477`, `:529`, `:596`, `:737`, `:798`; `MineRun.swift:340`, `:371`, `:405`, `:442`, `:533`
- Modify: `MissionLogBudget.swift:95-119` (delete `MissionConfirm`)
- Test: `app/Modules/DirectiveEngine/Tests/Steps/ConfirmRowTests.swift`

**Interfaces:**
- Consumes: `StepContext`, `FleetTag`, `DirectiveAttentionReason`.
- Produces: `ConfirmRow(deadline:onExpiry:)` with the four defaulted knobs (`watermark`, `refresh`, `probeDelay`, `readInterval`, `waitsOutArrival`), `func verdict(_ rows: [Device], _ ctx: StepContext) -> ConfirmVerdict`, and `ConfirmVerdict` (`.judge` / `.act(MissionAction)`). Task 9 consumes all of it.

**`ConfirmRow` does not decide success.** It owns the ordering — probe delay, deadline, arrival wait, staleness, throttled read — and answers `.judge` when the rows are fresh enough for the mission to apply its own test. See "Where the spec did not survive measurement", point 2, for why a `predicate:` parameter was rejected.

- [ ] **Step 1: Write the failing tests**

`app/Modules/DirectiveEngine/Tests/Steps/ConfirmRowTests.swift`:

```swift
//
//  ConfirmRowTests.swift
//  Replicould — DirectiveEngine
//
//  The ordering rule, tested once: deadline before read, always.
//

import Foundation
import GameModels
import Testing

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 10_000)

private func row(startedAgo: TimeInterval) -> Directive {
    Directive(
        id: "D1", kind: .mineRun, status: .running, deviceCode: "C1",
        controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
        targets: ["SOL"], targetIndex: 0, step: "confirming",
        stepStartedAt: now.addingTimeInterval(-startedAgo), returnToOrigin: false,
        originDesignation: nil, attentionReason: nil,
        createdAt: now.addingTimeInterval(-3_600), updatedAt: now, theatreDepot: nil
    )
}

private func device(_ code: String, updatedAt: Date, arrival: Date? = nil) -> Device {
    var detail: [String: JSONValue] = [:]
    if let arrival {
        detail["travel"] = .object(["arrives_at": .string(arrival.formatted(.iso8601))])
    }
    return Device(
        deviceCode: code, deviceType: "service_bot", replicantCode: "R1", status: "idle",
        location: "SOL-3", locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [],
        features: [], tags: [], detail: .object(detail),
        updatedAt: updatedAt, firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func ctx(_ startedAgo: TimeInterval) -> StepContext {
    StepContext(
        directive: row(startedAgo: startedAgo),
        world: WorldSnapshot(devices: [:], openOperations: [:], now: now),
        step: "confirming"
    )
}

@Suite("Confirm row")
struct ConfirmRowTests {
    private let ladder = ConfirmRow(deadline: 300, onExpiry: .readThenStall(.commandRejected))

    /// THE rule this whole sub-machine exists to hold. A failing read never
    /// advances `updatedAt`, so a staleness-first order can never reach the
    /// deadline and loops at one high-priority read per tick forever.
    @Test("the deadline is read before the staleness gate")
    func theDeadlineComesFirst() {
        let stale = device("B1", updatedAt: now.addingTimeInterval(-10_000))
        #expect(ladder.verdict([stale], ctx(301)) == .act(.refreshDevices(
            deviceCodes: ["B1"], thenStall: .commandRejected
        )))
    }

    @Test("fresh rows are handed back for the mission to judge")
    func freshRowsAreJudged() {
        #expect(ladder.verdict([device("B1", updatedAt: now)], ctx(60)) == .judge)
    }

    @Test("a stale row inside the deadline buys a throttled read")
    func aStaleRowBuysAThrottledRead() {
        let stale = device("B1", updatedAt: now.addingTimeInterval(-60))
        #expect(ladder.verdict([stale], ctx(60)) == .act(.refreshDevices(
            deviceCodes: ["B1"], thenStall: nil
        )))
    }

    @Test("a row read within the interval waits rather than reading again")
    func aRecentlyReadRowWaits() {
        let stale = device("B1", updatedAt: now.addingTimeInterval(-5))
        #expect(ladder.verdict([stale], ctx(60)) == .act(.wait))
    }

    /// The non-stall exit: four bot sites proceed unrepaired rather than halt.
    @Test("expiry can hand back instead of stalling")
    func expiryCanHandBack() {
        let judgeOnExpiry = ConfirmRow(deadline: 300, onExpiry: .judge)
        let stale = device("B1", updatedAt: now.addingTimeInterval(-10_000))
        #expect(judgeOnExpiry.verdict([stale], ctx(301)) == .judge)
    }

    /// `awaitRepair` and `confirmRelay` stall outright rather than paying for
    /// one more read they have no reason to believe will answer.
    @Test("expiry can stall outright without buying a read")
    func expiryCanStallOutright() {
        let stallNow = ConfirmRow(deadline: 300, onExpiry: .stallNow(.repairUnfinished))
        let stale = device("B1", updatedAt: now.addingTimeInterval(-10_000))
        #expect(stallNow.verdict([stale], ctx(301)) == .act(.stall(.repairUnfinished)))
    }

    /// A recalled device carries `location: nil` and cruises home; a read
    /// before its own arrival buys nothing at all.
    @Test("waiting out an arrival beats reading a device still in flight")
    func waitingOutAnArrival() {
        var waits = ConfirmRow(deadline: 1_200, onExpiry: .stallNow(.serviceBotNotRecovered))
        waits.waitsOutArrival = true
        let cruising = device(
            "B1", updatedAt: now.addingTimeInterval(-10_000),
            arrival: now.addingTimeInterval(120)
        )
        #expect(waits.verdict([cruising], ctx(60)) == .act(.wait))
    }

    /// One arrival event and a sub-second local clock can disagree by seconds.
    @Test("a skewed watermark accepts a row a few seconds early")
    func aSkewedWatermarkAcceptsAnEarlyRow() {
        var skewed = ConfirmRow(deadline: 300, onExpiry: .readThenStall(.commandRejected))
        skewed.watermark = .skewed(5)
        let justBefore = device("B1", updatedAt: now.addingTimeInterval(-63))
        #expect(skewed.verdict([justBefore], ctx(60)) == .judge)
    }

    /// The drones may be anywhere, so they are not addressable by code.
    @Test("a fleet refresh replaces the device refresh wholesale")
    func aFleetRefreshIsUsedWhenAsked() {
        let tag = FleetTag(goal: .salvage)
        var fleet = ConfirmRow(deadline: 300, onExpiry: .readThenStall(.commandRejected))
        fleet.refresh = .fleet(tag)
        let stale = device("B1", updatedAt: now.addingTimeInterval(-60))
        #expect(fleet.verdict([stale], ctx(60)) == .act(.refreshFleet(tag: tag, thenStall: nil)))
    }

    @Test("inside the probe delay nothing is read at all")
    func insideTheProbeDelayNothingIsRead() {
        var delayed = ConfirmRow(deadline: 300, onExpiry: .readThenStall(.commandRejected))
        delayed.probeDelay = 10
        let stale = device("B1", updatedAt: now.addingTimeInterval(-10_000))
        #expect(delayed.verdict([stale], ctx(5)) == .act(.wait))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL — `cannot find 'ConfirmRow' in scope`.

- [ ] **Step 3: Write the implementation**

`app/Modules/DirectiveEngine/Sources/Steps/ConfirmRow.swift`:

```swift
//
//  ConfirmRow.swift
//  Replicould — DirectiveEngine
//
//  The order a confirming step asks its questions in. Not what counts as
//  success — the mission owns that — only when it may be asked at all.
//

import Foundation
import GameModels

/// Whether the mission may judge its rows yet.
public enum ConfirmVerdict: Equatable, Sendable {
    /// Fresh enough — apply the mission's own success test.
    case judge
    /// Take this instead.
    case act(MissionAction)
}

/// The confirm ladder, as a pure value.
public struct ConfirmRow: Equatable, Sendable {
    /// What the deadline means when it passes.
    public enum Expiry: Equatable, Sendable {
        /// Buy one last read carrying the stall; the engine collapses an
        /// unresolved re-ask onto it. No `detail:` — `MissionAction`'s refresh
        /// cases have no slot for one.
        case readThenStall(DirectiveAttentionReason)
        /// Stall outright, buying no read.
        case stallNow(DirectiveAttentionReason, detail: String? = nil)
        /// Hand back to the mission to judge whatever it holds — the
        /// degrade-rather-than-halt exit.
        case judge
    }

    /// What "read since this mattered" means.
    public enum Watermark: Equatable, Sendable {
        case stepStart
        /// `stepStartedAt` less a tolerance, for a server clock seconds behind.
        case skewed(TimeInterval)
        /// Pure age, with no relation to the step — for a row named before the
        /// step existed.
        case age(TimeInterval)
    }

    /// Which read buys the evidence.
    public enum Refresh: Equatable, Sendable {
        case devices
        case fleet(FleetTag)
    }

    public let deadline: TimeInterval
    public let onExpiry: Expiry
    public var watermark: Watermark = .stepStart
    public var refresh: Refresh = .devices
    /// Grace before the first read of a just-ordered command.
    public var probeDelay: TimeInterval = 0
    /// Floor between reads of one row.
    public var readInterval: TimeInterval = 30
    /// Wait out a device's own cruise home before reading it.
    public var waitsOutArrival: Bool = false

    public init(deadline: TimeInterval, onExpiry: Expiry) {
        self.deadline = deadline
        self.onExpiry = onExpiry
    }

    public func verdict(_ rows: [Device], _ ctx: StepContext) -> ConfirmVerdict {
        if ctx.elapsed < probeDelay { return .act(.wait) }
        if ctx.elapsed > deadline { return expired(rows) }
        if waitsOutArrival, let arrival = rows.compactMap(\.activityDeadline).max(),
           arrival > ctx.now {
            return .act(.wait)
        }
        guard rows.contains(where: { !isFresh($0, ctx) }) else { return .judge }
        let lastLook = rows.map(\.updatedAt).min() ?? .distantPast
        if ctx.now.timeIntervalSince(lastLook) > readInterval {
            return .act(read(rows, thenStall: nil))
        }
        return .act(.wait)
    }

    private func expired(_ rows: [Device]) -> ConfirmVerdict {
        switch onExpiry {
        case let .readThenStall(reason): .act(read(rows, thenStall: reason))
        case let .stallNow(reason, detail): .act(.stall(reason, detail: detail))
        case .judge: .judge
        }
    }

    private func read(_ rows: [Device], thenStall: DirectiveAttentionReason?) -> MissionAction {
        switch refresh {
        case .devices: .refreshDevices(deviceCodes: rows.map(\.deviceCode), thenStall: thenStall)
        case let .fleet(tag): .refreshFleet(tag: tag, thenStall: thenStall)
        }
    }

    private func isFresh(_ device: Device, _ ctx: StepContext) -> Bool {
        switch watermark {
        case .stepStart:
            ctx.isFresh(device)
        case let .skewed(tolerance):
            device.updatedAt >= ctx.directive.stepStartedAt.addingTimeInterval(-tolerance)
        case let .age(maximum):
            ctx.now.timeIntervalSince(device.updatedAt) <= maximum
        }
    }
}
```

> Only `.stallNow` carries `detail:`, because only `MissionAction.stall` has a slot for one. `EventRun.confirmProgress` is the sole site that passes a detail today (`.eventCriteriaUnmet, detail: event.designation`) and it is out of `ConfirmRow`'s scope anyway — its subject is a `LocationEvent`, not a `Device`.

- [ ] **Step 4: Migrate the ten `MissionConfirm.ladder` sites**

All ten pass `deadline:` and `thenStall:` and nothing else, so each becomes `ConfirmRow(deadline:onExpiry: .readThenStall(...))` and a `switch`. `MineRun.swift:371` in full, as the model:

```swift
    private func confirmArrival(
        _ directive: Directive, _ carrier: Device, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let belt = Self.targetBelt(of: directive) else { return .stall(.unreachableDevice) }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        if world.isFresh(carrier, since: directive.stepStartedAt), carrier.location == belt {
            return .advanceStep(nextStep: Step.detaching.rawValue)
        }
        if world.openOperation(for: carrier.deviceCode) != nil { return .wait }
        let ladder = ConfirmRow(
            deadline: TravelTo.arrivalConfirmDeadline,
            onExpiry: .readThenStall(.vesselPositionUnconfirmed)
        )
        return switch ladder.verdict([carrier], ctx) {
        case let .act(action): action
        // Fresh and still not at the belt: keep waiting for the row to move.
        case .judge: .wait
        }
    }
```

The `.judge` branch differs per site — it is whatever the site does when the rows are fresh but its own success test fails. For all ten that is `.wait`, because each already returned the ladder's own `.wait` in that case. **Verify that per site rather than assuming it**; if any site's success test is not already evaluated above the ladder call, move it there first.

The remaining nine: `EventRun.swift:477` (`loadConfirmDeadline`, `.commandRejected`), `:529` (`arrivalConfirmDeadline`, `.vesselPositionUnconfirmed`), `:596` (`stageConfirmDeadline`, `.commandRejected`), `:737` (`recoveryConfirmDeadline`, `.commandRejected`), `:798` (`depositConfirmDeadline`, `.commandRejected`); `MineRun.swift:340` (`attachConfirmDeadline`, `.commandRejected`), `:405` (same), `:442` (same), `:533` (`attachConfirmDeadline`, `.serviceBotNotArmed` for a `service_bot` else `.commandRejected` — keep that branch in the mission, choosing the `Expiry` before constructing the `ConfirmRow`).

- [ ] **Step 5: Delete `MissionConfirm`**

Delete `MissionLogBudget.swift:95-119` entirely. `MissionConfirm.readInterval` (30) is now `ConfirmRow.readInterval`'s default.

```bash
cd app/Modules/DirectiveEngine && grep -rn "MissionConfirm" Sources Tests
```

Expected: no hits.

- [ ] **Step 6: Run the whole target and commit**

```bash
cd app/Modules && swift test --filter DirectiveEngineTests \
  --event-stream-output-path /tmp/task8.jsonl 2>&1 | tail -5
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/Steps/ConfirmRow.swift \
  app/Modules/DirectiveEngine/Sources/{MissionLogBudget,EventRun,MineRun}.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(directives): ConfirmRow owns the ladder ordering; MissionConfirm deleted"
```

---

## Task 9: The hand-rolled ladders adopt `ConfirmRow`

**Files:**
- Modify: `SurveyRun.swift:437`, `:619` (`probe`, delete), `SalvageRun.swift:613`, `:694` (`probe`, delete), `:849`, `:948`; `HaulRun.swift:365`; `RelayRun.swift:507`, `:612`, `:656`, `:706`, `:868`; `SurveyRun.swift:355`, `:768`
- Test: the existing mission suites, **unedited**

**Interfaces:**
- Consumes: `ConfirmRow`, `ConfirmVerdict`.
- Produces: nothing new.

Sixteen sites, in the four families `ConfirmRow` was built to cover. The `probe` helper is deleted from both files — it is `ConfirmRow` with `onExpiry: .judge` and the deadline checked by the caller, which `ConfirmRow` now folds in.

**Task 4 already deleted the six `probe` callers inside the bot phase.** What remains here are the non-bot sites.

| Family | Site | `ConfirmRow` configuration |
|---|---|---|
| ETA wait | `SurveyRun.swift:437` `recover` | `deadline: recallDeadline`, `.stallNow(.dronesNotRecovered)`, `waitsOutArrival = true`. **No staleness gate today** — its success test is `stranded.isEmpty`, a presence test. Keep that above the ladder. |
| ETA wait | `SurveyRun.swift:768` / `SalvageRun.swift:849` `confirmBotStow` | Deleted by Tasks 3–4; listed here only so the executor does not go looking for them. |
| ETA wait | `SalvageRun.swift:948` `controllerNotAboard` | `deadline: controllerRecallDeadline`, `.stallNow(.miningControllerNotRecovered)`, `waitsOutArrival = true`, `readInterval: TravelTo.arrivalReadInterval`. Keep the `nil`-when-aboard return in the mission. |
| Extra predicate | `HaulRun.swift:365` `confirm` | `deadline: confirmDeadline`, `.readThenStall(...)` matching today's, `readInterval: confirmReadInterval`. **Check the two-armed shape at `:372-396` carefully** — the deadline is currently tested inside BOTH arms; `ConfirmRow` tests it once, above. Prove the collapse preserves behaviour with the existing `HaulRunTests`. |
| Extra predicate | `RelayRun.swift:612` `confirmIdle` | Success is `source.statusBase != "relaying"`, evaluated in the mission. **No freshness gate today** — set `watermark: .age(RelayRun.reclaimFreshness)` only if a test demands it; otherwise keep the mission's own gate and use `ConfirmRow` for the deadline and throttle alone. |
| Extra predicate | `RelayRun.swift:868` `confirmRelay` | `deadline: SalvageRun.activationDeadline`, `.stallNow(.relayActivationFailed)`, `readInterval: RelayRun.pollInterval`. Success `relay.statusBase == relayingStatus` stays in the mission. |
| Extra predicate | `RelayRun.swift:706` `confirmStow` | `deadline: stowDeadline`, `.stallNow(.noRelayCoLocated)`. **The success exit is `.claimRelay(deviceCode:nextStep:)`, an action carrying a write** — that is exactly why `ConfirmRow` must not own success. |
| Different watermark | `RelayRun.swift:507` `confirmSource` | `watermark: .age(reclaimFreshness)`. It returns a `SourceConfirmation` enum handing the confirmed `Device` back; keep that. It has **no deadline today** — give it `deadline: .infinity` and `onExpiry: .judge` rather than inventing one, and put the missing bound on the punch list. |
| Different watermark | `RelayRun.swift:656` `carrierRetainsAuthority` | Two-sided: after the step start AND younger than `reclaimFreshness`. `ConfirmRow` has no two-sided watermark; **leave this site alone** and record it on the punch list. It is one site and inventing a fifth `Watermark` case for it is not worth the surface. |
| Different watermark | `SurveyRun.swift:355` `awaitCompletion` | `watermark: .skewed(eventTimeSkewTolerance)`, `readInterval: backstopInterval`. Its positive exit is `.refreshSystem(designation:nextStep:)`, which stays in the mission. **No deadline today** — same treatment as `confirmSource`. |
| Fleet refresh | `SalvageRun.swift:613` `awaitCompletion` | `refresh: .fleet(tag)`, `readInterval: reconcileInterval`, **no deadline by design** ("never stall, however long the cycle runs") → `deadline: .infinity`, `onExpiry: .judge`. Its three-way controller verdict stays in the mission. |

- [ ] **Step 1: Migrate the sites one family at a time, running the suite between families**

Four commits, one per family, each with `swift test --filter DirectiveEngineTests` green in between. A family that turns out not to fit is a finding: record it, leave the site alone, and move on rather than bending `ConfirmRow`.

- [ ] **Step 2: Delete both `probe` copies**

```bash
cd app/Modules/DirectiveEngine && grep -rn "static func probe" Sources
```

Expected: no hits. Delete `SurveyRun.swift:616-626` and `SalvageRun.swift:691-701` if Tasks 3–4 have not already.

- [ ] **Step 3: Pin the throttle boundary**

`MissionConfirm.ladder` throttled on `now - lastLook > readInterval`; `probe` throttled on `< probeInterval` and read otherwise. At exactly `readInterval` the two disagree by one tick: the ladder waits, `probe` reads. `ConfirmRow` uses the ladder's `>`, so every migrated `probe` site now waits one extra tick at that exact instant.

Confirm no test pins the old boundary:

```bash
cd app/Modules && swift test --filter DirectiveEngineTests \
  --event-stream-output-path /tmp/task9.jsonl 2>&1 | tail -5
```

If a test fails only at that boundary, that is the finding — record it in the ticket and decide the boundary deliberately rather than editing the test.

- [ ] **Step 4: Commit**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/*.swift
git add app/Modules/DirectiveEngine
git commit -m "refactor(directives): the hand-rolled confirm ladders adopt ConfirmRow"
```

---

## Task 10: Delete the legacy prose fallbacks

**Files:**
- Modify: `MissionLogBudget.swift:47-52`, `:83-90`
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveStallDetail.swift:26-28`
- Modify: `app/Modules/DirectiveEngine/Tests/MissionLogBudgetTests.swift:75-81`, `:133-144`
- Modify: `app/Modules/DirectivesFeature/Tests/DirectiveStallDetailTests.swift:39-43`
- Test: `MissionLogBudgetTests`, `MineRunTests`, **`DirectiveStallDetailTests`**

**Interfaces:** no signature changes. `dispatchRounds(_:dispatch:confirm:kind:)`, `lastDispatch(_:dispatch:confirm:)` and `DirectiveStallDetail.detail(for:in:)` keep their shapes and stop reading `summary` for content.

Ticket 15 left **three** prose parsers behind for rows written before the typed columns existed, each marked `// Legacy row written before the columns existed; Stage 2 deletes this`. Two are in `DirectiveEngine`; **the third is in `DirectivesFeature`** (`DirectiveStallDetail.swift:26-28`) and is easy to miss because every other Stage 2 task stays inside `DirectiveEngine`. Ticket 17 names it explicitly.

**`DirectiveStallDetail`'s prefix MATCH at `:24` stays.** There is no typed reason column on `DirectiveLogEntry` — the summary prefix is how an entry is matched to the row's current reason, so an entry recording an earlier stall never speaks under a different one. Only the detail-from-prose at `:27` goes.

**The fail-closed leg must survive.** `lastDispatch`'s parse currently returns `.nothingSent` when the prose is unparseable, and two tests pin that: `MissionLogBudgetTests.swift:85-91` `anUnparseableLegacyRowNamesNoOrder` and `MineRunTests.swift:1223` `unnamedDispatchReturnsToArming` (fixture `unnamedDispatch` at `MineRunTests.swift:217-221`). Deleting the parse is only safe if the removed branch returns `.nothingSent` too.

- [ ] **Step 1: Delete the two branches**

In `dispatchRounds(kind:)`, `MissionLogBudget.swift:45-52` becomes:

```swift
            guard entry.commandKind == kind.rawValue else { continue }
```

In `lastDispatch`, `MissionLogBudget.swift:81-89` becomes:

```swift
            guard let kind = entry.commandKind, let deviceCode = entry.targetDeviceCode else {
                return .nothingSent
            }
            return .dispatched(kind: kind, deviceCode: deviceCode)
```

An untyped row now reads as "nothing sent" — the same answer the unparseable-prose path already gave, which is what keeps the two fail-closed tests green.

- [ ] **Step 2: Retire the two tests that pin the parse**

Delete `MissionLogBudgetTests.swift:75-81` (`lastDispatchFallsBackToTheSummaryForALegacyRow`) and `:133-144` (`dispatchRoundsCountsLegacyRowsFromTheSummary`). **Keep** `anUnparseableLegacyRowNamesNoOrder` at `:85-91` and keep the `legacyDispatch` fixture — it now exercises the untyped-row path, which is still a real case.

Replace the two deleted tests with one that pins the new rule:

```swift
    /// A row written before the columns existed names no order at all. The
    /// columns are the record; there is no prose to fall back to.
    @Test("an untyped row counts for nothing")
    func anUntypedRowCountsForNothing() {
        let log = [
            stepEntry(dispatchStep, at: now.addingTimeInterval(-300)),
            legacyDispatch(summary: "Dispatched attach to C1", at: now.addingTimeInterval(-240)),
            stepEntry(confirmStep, at: now.addingTimeInterval(-180)),
        ]
        #expect(lastDispatch(log) == .nothingSent)
        #expect(MissionLogBudget.dispatchRounds(
            world(log), dispatch: dispatchStep, confirm: confirmStep, kind: .attach
        ) == 0)
    }
```

- [ ] **Step 3: Delete the third fallback, in `DirectivesFeature`**

`DirectiveStallDetail.swift:25-28` becomes:

```swift
        guard let detail = newest.detail, !detail.isEmpty else { return nil }
        return detail
```

`DirectiveStallDetailTests.swift:39-43` is the test that pins the prose path — its fixture passes no `detail:` and expects `"MEREDIANA-3"` recovered from the summary. Retire it and replace it with the new rule:

```swift
    /// The column is the record. A row written before it existed carries no
    /// detail, whatever its summary says.
    @Test("a legacy row with no detail column names nothing")
    func aLegacyRowNamesNothing() {
        let entries = [entry("L1", summary: "\(reason.rawValue): MEREDIANA-3", at: 10)]
        #expect(DirectiveStallDetail.detail(for: reason, in: entries) == nil)
    }
```

The four other tests in that suite pass `detail:` explicitly or assert `nil` for a non-matching reason, and stay as they are — including `:29-34`, which pins that the **column wins over a disagreeing summary** (`summary: "…MEREDIANA-9"`, `detail: "MEREDIANA-3"`, expecting `MEREDIANA-3`). That one is the whole point of the change and must stay green.

- [ ] **Step 4: Run and commit**

```bash
cd app/Modules && swift test \
  --filter "MissionLogBudgetTests|MineRunTests|DirectiveStallDetailTests" \
  --event-stream-output-path /tmp/task10.jsonl 2>&1 | tail -5
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/MissionLogBudget.swift \
  app/Modules/DirectivesFeature/Sources/DirectiveStallDetail.swift
git add app/Modules/DirectiveEngine app/Modules/DirectivesFeature
git commit -m "refactor(log): the typed columns are the only record; prose parsing deleted"
```

This is the one Stage 2 task that touches `DirectivesFeature`, so run that target as well as `DirectiveEngineTests`.

**Checkpoint D** is due here — see Order of work.

---

## Task 11: `PrintJob` over the three depot-anchored sites

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/Steps/PrintJob.swift`
- Modify: `MineFleetPrint.swift:55-101` (move out), `:106-166`; `RestockRun.swift:66-171`; `EventCourierPrint.swift:75-116`
- Test: `app/Modules/DirectiveEngine/Tests/Steps/PrintJobTests.swift`

**Interfaces:**
- Consumes: `StepContext`, `ConfirmRow`, `Device.acceptsPrintJobs`, `Device.isCarrierHull`, `RelayRun(reserveFloor:)`'s `footprintCensusIsStale`/`printStockIsShort`.
- Produces: `PrintJob(deviceType:quantity:printTags:depot:pollStep:)` with `func bench(_ ctx: StepContext) -> Device?`, `func next(_ ctx: StepContext) -> StepResult`, `PrintJob.deadline` (1800), and `PrintJob.fleetEvidenceIsStale(_:at:in:)`. `pollStep` is `String?` and mirrors `TravelTo.confirmStep` — nil self-targets (`EventRun`'s shape, unused by the three migrated sites), non-nil names the polling step each of them already has. `MineFleetPrint.printer(for:in:)` and `MineFleetPrint.fleetEvidenceIsStale` move here and are deleted from `MineFleetPrint`.

**Scope: three of the five print sites.** `EventRun.swift:380` (mobile bench selection is not its problem — a variable, blueprint-derived deadline measured from `lastOrderedAt` is) and `RelayRun.swift:401` (bench anchored on `carrier.location`, and the only site that stalls rather than waits on a short rail) stay as they are. Stage 3's `PrintScheduler` replaces the chooser at all five sites at once; forcing a four-way parameter union into a type that is about to be rewritten buys nothing. See "Where the spec did not survive measurement", point 3.

**This task carries the one deliberate behaviour change in the first eleven tasks.** `EventCourierPrint.swift:113` polls `world.openOperation(for: directive.deviceCode, owner: directive.id)` — the launch-pinned host — while the dispatch at `:98` went to `printer.deviceCode`, which `printer(for:in:)` may have substituted to a different bench. On substitution the poll guard asks about the wrong queue. It gets its own failing test.

- [ ] **Step 1: Write the failing test for the real defect**

Add to `app/Modules/DirectiveEngine/Tests/Steps/PrintJobTests.swift`:

```swift
    /// The dispatch goes to the chosen bench, so the poll must watch THAT
    /// bench. Watching the launch pin asks about the wrong queue whenever
    /// substitution moved the job.
    @Test("the poll guard watches the bench the job went to, not the launch pin")
    func thePollWatchesTheChosenBench() {
        // The pinned host refuses jobs, so `bench` substitutes to B2.
        let pinned = benchDevice("B1", status: "compacting")
        let free = benchDevice("B2", status: "idle")
        let job = PrintJob(
            deviceType: "matrix_container", quantity: 1, printTags: [], depot: depot,
            pollStep: "awaitingClone"
        )
        let ctx = printCtx(devices: [pinned, free], pinnedCode: "B1")
        #expect(job.bench(ctx)?.deviceCode == "B2")
    }
```

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL — `cannot find 'PrintJob' in scope`.

- [ ] **Step 3: Write the implementation**

`app/Modules/DirectiveEngine/Sources/Steps/PrintJob.swift`:

```swift
//
//  PrintJob.swift
//  Replicould — DirectiveEngine
//
//  Enqueuing one print at a depot: which bench takes it, whether the fleet
//  evidence is good enough to order against, and how long to wait.
//

import Foundation
import GameModels

/// One print order at one depot, as a pure value.
public struct PrintJob: Equatable, Sendable {
    /// How long a print may go unfinished before the run re-decides. A
    /// transport job is exactly 30m00s, so this equals it rather than
    /// undercutting it.
    public static let deadline: TimeInterval = 30 * 60

    public let deviceType: String
    public let quantity: Int?
    public let printTags: [String]
    /// The depot the bench must stand at. Never a device location — a hub that
    /// unfurls elsewhere must not drag the run with it.
    public let depot: String
    /// The step the dispatch names. Nil self-targets, as `EventRun` does.
    public let pollStep: String?

    public init(
        deviceType: String, quantity: Int?, printTags: [String],
        depot: String, pollStep: String?
    ) {
        self.deviceType = deviceType
        self.quantity = quantity
        self.printTags = printTags
        self.depot = depot
        self.pollStep = pollStep
    }

    /// The bench to print with: the row's own while it still accepts jobs, else
    /// a free able bench at the depot, lowest code first. A hub keeps
    /// advertising `enqueue_print` while packed, so only status separates them.
    public func bench(_ ctx: StepContext) -> Device? {
        let pinned = ctx.world.device(ctx.directive.deviceCode)
        if let pinned, pinned.acceptsPrintJobs, pinned.location == depot { return pinned }
        let able = ctx.world.devices.values
            .filter { $0.acceptsPrintJobs && $0.location == depot && !$0.isCarrierHull }
        // Substituting opens a queue either way, so a bench standing free beats
        // one already serving another run. Lowest code breaks both ties.
        return able.filter { ctx.openOperation(for: $0.deviceCode) == nil }
            .min { $0.deviceCode < $1.deviceCode }
            ?? able.min { $0.deviceCode < $1.deviceCode }
    }

    /// Order the print, or say why not.
    public func next(_ ctx: StepContext) -> StepResult {
        guard let bench = bench(ctx) else { return .noSubject }
        if Self.fleetEvidenceIsStale(ctx.directive, at: depot, in: ctx.world) {
            return .action(.refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice))
        }
        if ctx.ownedOperation(for: bench.deviceCode) != nil { return .action(.wait) }
        return .action(.dispatch(
            kind: .print, deviceCode: bench.deviceCode,
            params: CommandParams(deviceType: deviceType, quantity: quantity, printTags: printTags),
            nextStep: pollStep ?? ctx.step
        ))
    }

    /// Whether every row at `location` predates the step — the evidence a print
    /// decision is made against.
    public static func fleetEvidenceIsStale(
        _ directive: Directive, at location: String, in world: WorldSnapshot
    ) -> Bool {
        let newest = world.devices.values
            .filter { $0.location == location }
            .map(\.updatedAt)
            .max()
        guard let newest else { return true }
        return newest < directive.stepStartedAt
    }
}
```

> No migrated site passes `pollStep: nil`. It exists so Stage 3 can bring `EventRun.swift:380` — the one self-targeting print site — onto the same type without changing its step vocabulary.

- [ ] **Step 4: Migrate the three sites**

Each site keeps its own rail gates (`RelayRun(reserveFloor:)`), its own "already have one" escape, and its own polling step. What changes: `MineFleetPrint.printer(for:in:)` becomes `job.bench(ctx)`, and the polling step's guard becomes `ctx.ownedOperation(for: bench.deviceCode)`.

`EventCourierPrint.awaitingClone` (`:105-115`) becomes:

```swift
    private func awaitingClone(
        _ directive: Directive, _ depot: String, _ world: WorldSnapshot
    ) -> MissionAction {
        if container(at: depot, in: world) != nil {
            return .advanceStep(nextStep: Step.replicating.rawValue)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let job = PrintJob(
            deviceType: EventRun.courierDeviceType, quantity: 1,
            printTags: [EventRun.rootTag.string], depot: depot,
            pollStep: Step.awaitingClone.rawValue
        )
        if world.now.timeIntervalSince(directive.stepStartedAt) > PrintJob.deadline {
            return .advanceStep(nextStep: Step.printing.rawValue)
        }
        // The job went to the chosen bench, so poll THAT bench — the launch pin
        // is a different device whenever substitution moved the print.
        if let bench = job.bench(ctx), ctx.ownedOperation(for: bench.deviceCode) != nil {
            return .wait
        }
        return .advanceStep(nextStep: Step.printing.rawValue)
    }
```

Note the deadline stays **above** the guard, which is where all three sites already have it.

- [ ] **Step 5: Delete the borrowed members**

Delete `MineFleetPrint.swift:55-69` (`printer`) and `:92-101` (`fleetEvidenceIsStale`). Repoint `RestockRun.swift:72` and `EventCourierPrint.swift:79`, `:88`, and `EventRun.swift:350` (which borrows `fleetEvidenceIsStale` and stays on its own bench selection otherwise).

```bash
cd app/Modules/DirectiveEngine/Sources
grep -rn "MineFleetPrint\.printer\|MineFleetPrint\.fleetEvidenceIsStale" *.swift Steps/*.swift
```

Expected: no hits.

- [ ] **Step 6: Run and commit**

```bash
cd app/Modules && swift test --filter DirectiveEngineTests \
  --event-stream-output-path /tmp/task11.jsonl 2>&1 | tail -5
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/Steps/PrintJob.swift \
  app/Modules/DirectiveEngine/Sources/{MineFleetPrint,RestockRun,EventCourierPrint}.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(directives): PrintJob owns the bench rule; the courier poll watches its own bench"
```

---

## Task 12: `StowOrAttach` over families A and B

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/Steps/StowOrAttach.swift`
- Modify: `EventRun.swift:431`, `:564`, `:719`; `MineRun.swift:321`, `:385`, `:422`
- Test: `app/Modules/DirectiveEngine/Tests/Steps/StowOrAttachTests.swift`

**Interfaces:**
- Consumes: `StepContext`, `StepResult`, `MissionLogBudget.dispatchRounds`.
- Produces: `StowOrAttach(carrierCode:deviceCodes:verb:confirmField:confirmStep:)` with `func next(_ ctx: StepContext) -> StepResult` and `func placed(_ ctx: StepContext) -> [Device]`; `StowOrAttach.Verb` (`.attach`, `.detach`, `.adopt`), `StowOrAttach.ConfirmField` (`.attachedTo`, `.controlledBy`, `.loose`).

**Scope: six of the eighteen containment sites.** Families C, D and E are excluded with reasons in "Where the spec did not survive measurement", point 4. In particular `RelayRun`'s stow is NOT covered: it is issued ON the device with the carrier as `target:`, and `RelayRun.swift:692-693` records why the inverse addressing would be wrong.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("Stow or attach")
struct StowOrAttachTests {
    /// One device per round, so a partial failure is visible in the timeline
    /// rather than hidden inside a batch.
    @Test("attach orders the first loose device")
    func attachOrdersTheFirstLooseDevice() {
        let job = StowOrAttach(
            carrierCode: "C1", deviceCodes: ["D1", "D2"], verb: .attach,
            confirmField: .attachedTo, confirmStep: "confirmingAttach"
        )
        #expect(job.next(loadCtx(attached: [])) == .action(.dispatch(
            kind: .attach, deviceCode: "C1",
            params: CommandParams(devices: ["D1"]), nextStep: "confirmingAttach"
        )))
    }

    @Test("attach finishes once every device is aboard")
    func attachFinishesWhenAllAboard() {
        let job = StowOrAttach(
            carrierCode: "C1", deviceCodes: ["D1", "D2"], verb: .attach,
            confirmField: .attachedTo, confirmStep: "confirmingAttach"
        )
        #expect(job.next(loadCtx(attached: ["D1", "D2"])) == .finished)
    }

    /// `adopt` confirms on `controllerDeviceCode`; everything else on
    /// `attachedToDeviceCode`. The verb alone does not say which.
    @Test("adopt confirms on the controller column")
    func adoptConfirmsOnTheControllerColumn() {
        let job = StowOrAttach(
            carrierCode: "A1", deviceCodes: ["D1"], verb: .adopt,
            confirmField: .controlledBy, confirmStep: "confirmingAdopt"
        )
        #expect(job.next(adoptedCtx(controlledBy: ["D1"])) == .finished)
    }

    /// Detach sends every code in one command; a singular parameter cannot.
    @Test("detach sends the whole list at once")
    func detachSendsTheWholeList() {
        let job = StowOrAttach(
            carrierCode: "C1", deviceCodes: ["D1", "D2"], verb: .detach,
            confirmField: .loose, confirmStep: "confirmingDetach"
        )
        #expect(job.next(loadCtx(attached: ["D1", "D2"])) == .action(.dispatch(
            kind: .detach, deviceCode: "C1",
            params: CommandParams(devices: ["D1", "D2"]), nextStep: "confirmingDetach"
        )))
    }
}
```

> `loadCtx` / `adoptedCtx` / `benchDevice` / `printCtx` are fixtures this task and Task 11 add to their own test files. Build them from the `Device(...)` literal shown in Task 5, not from a new shared helper — `survey-fleet-repair-build.md` records what a shared internal test helper did to four suites when Swift preferred it over a private one.

- [ ] **Step 2: Write the implementation**

```swift
//
//  StowOrAttach.swift
//  Replicould — DirectiveEngine
//
//  Putting devices into and out of a carrier: one command per round for the
//  loading verbs, one command for the whole list on the way out.
//

import Foundation
import GameModels

/// One containment order, as a pure value.
public struct StowOrAttach: Equatable, Sendable {
    public enum Verb: Equatable, Sendable {
        case attach, detach, adopt

        var kind: OperationKind {
            switch self {
            case .attach: .attach
            case .detach: .detach
            case .adopt: .adopt
            }
        }

        /// Whether one command carries the whole list. `detach` empties a grid
        /// in one order; the loading verbs go one at a time so a partial
        /// failure is visible.
        var isBatch: Bool { self == .detach }
    }

    /// Which column proves the order landed.
    public enum ConfirmField: Equatable, Sendable {
        case attachedTo
        case controlledBy
        /// Detach's proof: the column is nil.
        case loose
    }

    /// The device the command is issued ON — the carrier, or the controller
    /// for `.adopt`.
    public let carrierCode: String
    public let deviceCodes: [String]
    public let verb: Verb
    public let confirmField: ConfirmField
    public let confirmStep: String

    public init(
        carrierCode: String, deviceCodes: [String], verb: Verb,
        confirmField: ConfirmField, confirmStep: String
    ) {
        self.carrierCode = carrierCode
        self.deviceCodes = deviceCodes
        self.verb = verb
        self.confirmField = confirmField
        self.confirmStep = confirmStep
    }

    /// The named devices already where this order would put them.
    public func placed(_ ctx: StepContext) -> [Device] {
        deviceCodes.compactMap { ctx.world.device($0) }.filter { isPlaced($0) }
    }

    public func next(_ ctx: StepContext) -> StepResult {
        let rows = deviceCodes.compactMap { ctx.world.device($0) }
        guard rows.count == deviceCodes.count else { return .noSubject }
        let pending = rows.filter { !isPlaced($0) }
        guard !pending.isEmpty else { return .finished }
        let sending = verb.isBatch ? pending : [pending[0]]
        return .action(.dispatch(
            kind: verb.kind, deviceCode: carrierCode,
            params: CommandParams(devices: sending.map(\.deviceCode)),
            nextStep: confirmStep
        ))
    }

    private func isPlaced(_ device: Device) -> Bool {
        switch confirmField {
        case .attachedTo: device.attachedToDeviceCode == carrierCode
        case .controlledBy: device.controllerDeviceCode == carrierCode
        case .loose: device.attachedToDeviceCode == nil
        }
    }
}
```

- [ ] **Step 3: Migrate the six sites**

Each keeps its own round-budget check (`MissionLogBudget.dispatchRounds` compared against a landing score) and its own confirm ladder from Task 8 — `StowOrAttach` replaces the selection-and-dispatch half only. `MineRun.attach` (`:310-324`) becomes:

```swift
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        let job = StowOrAttach(
            carrierCode: carrier.deviceCode, deviceCodes: roster.map(\.deviceCode),
            verb: .attach, confirmField: .attachedTo,
            confirmStep: Step.confirmingAttach.rawValue
        )
        return switch job.next(ctx) {
        case let .action(action): action
        case .finished: .advanceStep(nextStep: Step.travelling.rawValue)
        case .more: .advanceStep(nextStep: Step.attaching.rawValue)
        case .noSubject: .stall(.unreachableDevice)
        }
```

`EventRun.loading` (`:420-445`) keeps its `collect_resources` leg (family D) exactly as it is — only the `attach` leg at `:431` moves. Do not attempt to fold the resource leg in.

`MineRun.confirmDetach` (`:392-409`) keeps its extra `location == belt` assertion; `placed(_:)` answers only the containment half.

- [ ] **Step 4: Run and commit**

```bash
cd app/Modules && swift test --filter DirectiveEngineTests \
  --event-stream-output-path /tmp/task12.jsonl 2>&1 | tail -5
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/Steps/StowOrAttach.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(directives): StowOrAttach — carrier-addressed containment, six sites"
```

---

## Task 13: The constants come home

**Files:**
- Modify: `SalvageRun.swift`, `RelayRun.swift`, `RestockRun.swift`, `EventRun.swift`, `MineRun.swift`, `HaulRun.swift`, `MineFleetPrint.swift`, `EventCourierPrint.swift`
- Create: `app/Modules/DirectiveEngine/Sources/Steps/PrintRail.swift`
- Modify: `.scratch/directives-architecture/punch-list.md`

**Interfaces:**
- Produces: `PrintRail(reserveFloor:)` with `footprintCensusIsStale(_:)` and `printStockIsShort(_:)`, replacing four missions' construction of a whole `RelayRun`.

Six constants have **only cross-file readers** — the declaring file never uses them: `SalvageRun.activationDeadline` (read by `RelayRun:874`), `SalvageRun.relayPollInterval` (`RelayRun:109`), `EventRun.courierDeviceType` (`EventCourierPrint:100`), `MineRecipe.carrierDeviceType` (`MineFleetPrint:78,86,134`), `MineRecipe.carried` (`MineRun:53,105,134,191,297`). Two are dead or near-dead. Several reach their real owner through a two-hop alias chain.

- [ ] **Step 1: Delete what nothing reads**

`RestockRun.pollInterval` (`RestockRun.swift:64`) has **zero readers in `Modules`, production or test** — confirmed by exhaustive sweep during ticket 17, after an LSP `findReferences` came back empty on a cold index and could not be trusted. Delete it.

`RelayRun.trackedKinds` (`RelayRun.swift:89`) has no production reader; its only readers are `RelayRunTests.swift:1535` and `:1559`. Decide deliberately: either delete both the constant and the two assertions, or keep it and add the production reader the two tests imply exists. **Do not leave it as it is** — a constant only tests read is a claim nothing enforces.

- [ ] **Step 2: Extract the print rail**

Four missions construct `RelayRun(reserveFloor:)` to reach two instance methods that have nothing to do with relays: `EventRun:171,345`, `RestockRun:120`, `MineFleetPrint:118`, `EventCourierPrint:83`. Move `footprintCensusIsStale` and `printStockIsShort` into `PrintRail`, leave `RelayRun` a caller like the rest, and repoint all five construction sites. This is the largest single borrow in the engine after `travelPositionUnconfirmed`, which Task 5 already retired.

- [ ] **Step 3: Move the rest onto the sub-machine that uses them**

| Constant | Today | Moves to |
|---|---|---|
| `SalvageRun.arrivalConfirmDeadline`, `arrivalReadInterval` | `SalvageRun:76,80` | `TravelTo` (done in Task 5) |
| `SurveyRun`/`SalvageRun` `botProbeDelay`, `botProbeInterval`, `repairDeadline`, `botConfirmDeadline`, `botDispatchRounds`, `botRecallDeadline` | declared **twice** each, identical values | `BotPhase` (done in Tasks 2–4) |
| `MissionConfirm.readInterval` | `MissionLogBudget:99` | `ConfirmRow.readInterval` default (done in Task 8) |
| `RelayRun.printDeadline`, `RestockRun.printDeadline`, `EventRun.printSlack` | a two-hop alias chain to one 30-minute value | `PrintJob.deadline`; `EventRun` keeps its own name for the variable part it adds |
| `SalvageRun.activationDeadline`, `relayPollInterval` | declared in `SalvageRun`, read only by `RelayRun` | `RelayRun` |
| `EventRun.courierDeviceType` | declared in `EventRun`, read only by `EventCourierPrint` | leave — `EventCourierPrint` prints EventRun's courier, so the ownership is right even though the reader is elsewhere |

`stagingFreshness = 5 * 60` is declared three times (`SurveyRun:119`, `SalvageRun:67`, `HaulRun:62`) with no alias linking them, so nothing prevents drift. They are read by three different staging checks that Stage 2 does not unify; **leave them and add a punch-list line** rather than inventing a fifth sub-machine to hold one number.

- [ ] **Step 4: Measure the borrow count and record it**

```bash
cd app/Modules/DirectiveEngine/Sources
for f in *.swift; do
  n=$(grep -o "SalvageRun\.\|RelayRun\.\|RestockRun\.\|MineFleetPrint\.\|HaulRun\.\|EventRun\.\|SurveyRun\.\|MineRun\." "$f" | wc -l)
  [ "$n" -gt 0 ] && echo "$f $n"
done
```

Baseline at `0115c20`: **114 occurrences / 108 distinct lines**, of which 52 reach into a live mission struct (`RepairFleet` 34 and `MineRecipe` 28 are intentional namespaces and are not counted in the 52).

Target after this task: **the 52 falls below 15**. `travelPositionUnconfirmed` (11 sites, 4 files) goes in Task 5; the rail (10 calls, 4 files) goes in Step 2 above; `MineFleetPrint.printer`/`fleetEvidenceIsStale` (4 sites) go in Task 11; `RelayRun.theatreDepot` (3 sites) is a one-line pass-through to `world.theatreDepot(for:)` and its three callers should call `world` directly. What remains is `RelayRun→SalvageRun`'s genuine relay vocabulary, which is not a copied idiom and stays.

**Record the real number in the ticket.** If it does not fall below 15, say what is left and why rather than forcing it.

- [ ] **Step 5: Add the deferred items to the punch list**

Append to `punch-list.md`, each with `file:line` and the stage that found it:

- All 13 travel sites use the unowned `openOperation` guard while the print sites use the owner-scoped one. A co-tenant's op blocks travel. `Steps/TravelTo.swift` — deliberate in Stage 2 to keep the migration behaviour-preserving.
- `RelayRun.swift:507` `confirmSource` and `SurveyRun.swift:355` `awaitCompletion` have **no deadline at all**, bounded only by the engine's `paid`-set collapse. `SalvageRun.swift:613` `awaitCompletion` has none by design and its throttle advances only on a successful read, so a persistently-failing fleet read costs one `.refreshFleet` per tick indefinitely.
- `RelayRun.swift:656` `carrierRetainsAuthority` uses a two-sided watermark `ConfirmRow` does not model; one site, left alone.
- `SalvageRun.swift:451` and `RelayRun.swift:765` `unresolvedSystem` are duplicated verbatim and were not extracted — their subject is a system blob, not a `Device`.
- `stagingFreshness` is declared three times with no alias linking them.
- `EventRun.swift:380` and `RelayRun.swift:401` remain outside `PrintJob`; Stage 3 unifies all five.

- [ ] **Step 6: Run every target and commit**

```bash
cd app/Modules && swift test \
  --filter "DirectiveEngineTests|GameServicesTests|GameSyncTests|GameModelsTests|DirectivesFeatureTests" \
  --event-stream-output-path /tmp/stage2-final.jsonl 2>&1 | tail -5
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/*.swift \
                                app/Modules/DirectiveEngine/Sources/Steps/*.swift
git add app/Modules/DirectiveEngine .scratch/directives-architecture/punch-list.md
git commit -m "refactor(directives): constants move onto their sub-machines; the print rail leaves RelayRun"
```

---

## Open questions for the operator

These are decisions, not tasks. Three of them block nothing; the first one wants an answer before Task 3 lands.

1. **`SurveyRun` and `SalvageRun` disagree about an empty hold, and the tests pin both.** Arriving at a system with no bots aboard but bots already standing there, `SurveyRun.swift:602` goes to `.configuring` and never arms them — repair silently does not happen. `SalvageRun.swift:676` goes to `.armingBots` and arms them. Both are pinned by name: `SurveyRunRepairTests.swift:17` `arrivalWithNoBotAboardSkipsStraightToConfiguring` and `SalvageRunRepairTests.swift:106` `noBotAboardSkipsStraightToArming`. **Neither fixture distinguishes the case** — both worlds hold zero service bots anywhere, so they pin "botless fleet", not "bots already deployed". This plan preserves both behaviours (`.finished` lets each mission keep its own destination) and does not pick. Which is right?

2. **`RelayRun.trackedKinds` is read only by tests.** Task 13 Step 1 asks for a deliberate choice: delete it with the two assertions, or add the production reader the tests imply. Which?

3. **The four no-deadline confirm sites.** Two are bounded by the engine's `paid`-set collapse and two by nothing. `SalvageRun.awaitCompletion`'s is deliberate ("never stall, however long the cycle runs") but its throttle advances only on a successful read, so a persistently-failing fleet read spends one `.refreshFleet` per 5s tick forever. Is that acceptable, or should Stage 2 bound it?

4. **`ConfirmRow`'s throttle boundary.** `ladder` waits at exactly `readInterval`; `probe` reads. Task 9 Step 3 adopts `ladder`'s. If a test pins the other, which wins?

## Hand-off to ticket 18

Two things this plan deliberately leaves for Stage 3, which ticket 18's plan must pick up:

- **`EventRun.swift:380` and `RelayRun.swift:401` are still their own bench selectors.** `EventRun` filters on `deviceType == "autofactory"` rather than `isPrintHub`, with no `isCarrierHull` exclusion; `RelayRun.hub(near:in:)` anchors on `carrier.location` and does not prefer a free bench. `PrintScheduler.choose(job:at:in:)` must subsume all five sites, not three.
- **`RelayRun` is the only print site that stalls on a short rail** (`.stall(.printStockShort)`) where the other four `.wait`. Stage 3's demand aggregation has to decide whether that stays a per-site choice.

## Definition of done per ticket

- The ticket's tests exist and were run through the JSON event stream; the whole affected targets are green.
- The migrated mission's existing suite passes **with no assertion edited**, except where this plan names a deliberate behaviour change (Task 11 only).
- `check-comments.sh` exit 0 on touched paths.
- No schema changed. If one did, the task left scope.
- The borrow count was measured and recorded, and did not rise.
- A memory note under `app/.claude/memory/` only for a fact a competent reader could not recover from the code; otherwise none.
- Anything a review deferred is a line on `punch-list.md`, with its `file:line` and why.
- `Status: resolved` + commit sha(s) in the ticket's `## Comments`.

