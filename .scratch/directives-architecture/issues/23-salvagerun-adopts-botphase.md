# 23 — `SalvageRun` adopts `BotPhase`; `RepairFleet` narrows

Type: task
Status: resolved
Blocked by: 22
Labels: directives-architecture, stage-2

Delete `SalvageRun.swift:669-873` and `:568-570`. Same shape as ticket 22 with Salvage's own destinations: empty hold → `.armingBots`, armed → `.positioning`.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 4.

**Keep `controllerRecallDeadline` (`SalvageRun.swift:98`)** — `controllerNotAboard` (`:948`) reads it and that is not a bot phase.

With both missions migrated, `RepairFleet` has exactly one caller. `answers(_:to:)` (used only at `:38`, `:84`, `:94`) and `repairThreshold` (only by `needsRepair` at `:115`) have no external reader and become `internal`.

---

- [ ] **Step 1:** Baseline `SalvageRunRepairTests|SalvageRunTests|SalvageRunBotBoundTests`; record the count.
- [ ] **Step 2:** Delete the eight bodies and the six bot constants; add `botPhase(_:_:)` with `runNoun: "salvage run"` and the seven cases.
- [ ] **Step 3:** `grep -c "RepairFleet\." SurveyRun.swift SalvageRun.swift Steps/BotPhase.swift` — expect `0`, `0`, and ~12. Record the real `wc -l` for both mission files.
- [ ] **Step 4:** Narrow `answers` and `repairThreshold` to `internal`; rebuild.
- [ ] **Step 5:** Run **all five targets** (`DirectiveEngineTests`, `GameServicesTests`, `GameSyncTests`, `GameModelsTests`, `DirectivesFeatureTests`); `check-comments.sh`; commit.

**Done when:** ~400 duplicated lines are gone, all five targets green, and **Checkpoint C** is scheduled — one evening with the brain on, confirming both runs still deploy/arm/await/recall exactly as before.

---

## Comments

**Resolved by `6ae4964`.** `SalvageRun.swift` 999 → 823 lines. The eight bodies at `:669-873` and `recallArrival` at `:568-570` are gone; the seven bot `Step` cases map onto `BotPhase` in the same inline form `SurveyRun` uses, with Salvage's own destinations — `deployingBots`/`confirmingBotDeploy` `.finished` → `.armingBots`, `armingBots`/`confirmingBotArm` `.finished` → `.positioning`, and the recall pair → `.advanceTarget`. **No drift toward Survey's `.configuring`**, which was the obvious failure mode with Survey's block written two commits earlier.

`BotPhase` gained an `unrepairedStep` parameter in ticket 22's fix; Salvage passes `Step.armingBots.rawValue`, which equals its `.finished` destination — both of its original `deployBots` exits went there, so the parameter changes nothing for this mission.

`recallArrival`'s surviving caller at `:658` — in the "Mining done, drones still out" branch of the awaiting-completion logic, outside the deleted block — is repointed to `BotPhase.recallArrival`. The plan did not name that caller, exactly as it did not name `SurveyRun.recover`'s.

`controllerRecallDeadline` kept (readers at `:952` and `SalvageRunTests:1076`). Seven test references to deleted constants repointed as pure symbol swaps to identical values: `repairDeadline` ×2, `botRecallDeadline` → `BotPhase.recallDeadline` ×2, `botConfirmDeadline` → `BotPhase.confirmDeadline` ×3. No assertion edited.

`RepairFleet.answers(_:to:)` and `repairThreshold` narrowed to `internal`. The reviewer confirmed no cross-module reader: the only outside caller is `Steps/BotPhase.swift`, and `RepairFleetOwnershipTests` reaches them through `@testable import`.

`grep -c "RepairFleet\."` → `SurveyRun` **0**, `SalvageRun` **0**, `Steps/BotPhase.swift` **17**. The ticket guessed ~12; 17 is the true number once both missions' calls live in one place.

## What the pair bought

**397 lines of duplicated bot-lifecycle body deleted** — 194 from `SurveyRun`, 203 from `SalvageRun` — replaced by one 246-line `BotPhase.swift`. Net across the two missions is 337 fewer lines; the difference is the mapping each mission keeps, which is the point. What remains in a mission is its own destinations; what left is the mechanism.

Canonical `DirectiveEngineTests` 1709/1709, 0 issues, `runEnded` present. **All five targets green: 2564/2564, 0 issues, 5 `runEnded`.** `check-comments.sh` exit 0.

Deferred minor: `.repairing`'s `case .finished, .more:` arm is half dead, inherited from ticket 22's pattern.

## Checkpoint C is now due — operator action

Run the app for one evening with the brain on. Expected: survey and salvage runs deploy, arm, await and recall their service bots exactly as before, with the timeline showing the same step names in the same order, because only the bodies moved.

**Watch one thing in particular.** The bug this stage's first adoption shipped was invisible to a green suite: a multi-bot fleet where one bot deploys and a later one exhausts the dispatch-round budget must still pass through `armingBots` and `repairing`, not jump to `configuring`. A single-bot fleet cannot show the difference.
