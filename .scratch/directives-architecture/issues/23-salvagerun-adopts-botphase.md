# 23 — `SalvageRun` adopts `BotPhase`; `RepairFleet` narrows

Type: task
Status: open
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
