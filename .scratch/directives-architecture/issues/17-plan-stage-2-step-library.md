# 17 — Write the Stage 2 (step library) plan

Type: task
Status: claimed
Blocked by: 07, 14, 15
Labels: directives-architecture, stage-2, planning

The design is in `spec.md` §Stage 2. This ticket produces the plan and its tickets; it writes no production code. It is deliberately a separate step because the exact duplication left after Stages 0–1 is what the plan must be written against, and the operator wants to review it before the build begins.

**Output:**
- `.scratch/directives-architecture/plan-stage-2.md` in the `superpowers:writing-plans` format (header, Global Constraints copied from `plan.md`, File Structure, tasks with failing-test-first steps and real code — no placeholders).
- Tickets `.scratch/directives-architecture/issues/20-…` onward, one per task, `Blocked by:` chains explicit, `Labels: directives-architecture, stage-2`.

---

- [ ] **Step 1: Re-measure the duplication**

With Stages 0–1 on `main`, re-run the audit's idiom count over `app/Modules/DirectiveEngine/Sources` (travel frames, hand ladders vs `MissionConfirm.ladder`/`isFresh`, return-homes, bot-phase pair, print sites, log walkers, sibling static references per mission). Record the table in `## Comments`. Anything the earlier stages already collapsed is out of scope for Stage 2.

- [ ] **Step 2: Invoke `superpowers:writing-plans`** against spec §Stage 2 with these constraints baked in:

- Sub-machines live in `app/Modules/DirectiveEngine/Sources/Steps/` (one file each: `TravelTo.swift`, `ConfirmRow.swift`, `PrintJob.swift`, `StowOrAttach.swift`, `BotPhase.swift`, `ReturnHome.swift`, plus `StepContext.swift`/`StepResult.swift`). Each is a pure value with `func next(_ ctx: StepContext) -> StepResult`; `StepContext` carries `directive`, `world`, `owner: CommandOwner`, and the mission's own `Step` for `nextStep` payloads.
- Migration order is fixed: (1) `BotPhase` replaces the Survey/Salvage pair (both suites green before and after; the ~200-line bodies deleted); (2) `TravelTo` + `ReturnHome` replace the 12+4 frames; (3) `ConfirmRow` replaces the remaining hand ladders (all `MissionConfirm.ladder` callers included, then delete `MissionConfirm`); (4) `PrintJob` wraps `MineFleetPrint.printer` for now — Stage 3 swaps the chooser; (5) `StowOrAttach` last (RelayRun stow, EventRun loading, MineRun attach).
- After each migration, the sibling-static reference count for the migrated idiom must be zero (`RelayRun→SalvageRun` etc.); the plan states the grep.
- Every sub-machine gets its own test file exercising deadline-first ordering, watermark semantics and the owner-aware guard directly, so the mechanical classes are tested ONCE at the sub-machine, not per mission.
- Delete the Stage-1 legacy fallbacks noted in tickets 15 (`lastDispatch` prose split, `DirectiveStallDetail` prefix parse).

- [ ] **Step 3: Self-review per the skill; then stop**

Set `Status: resolved` and leave the plan for operator review. Do not begin the build in the same session unless told to.
