# 38 — The print-only missions fan out across benches

Type: task
Status: resolved
Blocked by: 37
Labels: directives-architecture, stage-3

**The ticket Stage 3 exists for.** `MineFleetPrint` and `RestockRun` stop waiting for a clone before deciding again, and net their demand against what is already on order.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 6. **Carries C1 and C2. Holds the acceptance test.**

**What blocks goal A is not the index.** `operation_one_open_per_device` is keyed on `entityCode`, so three benches may each hold a live op today. What blocks it is that `MineFleetPrint.printing` returns `.wait` until the whole eleven-device recipe is satisfied or thirty minutes pass (`MineFleetPrint.swift:124-138`). Two of three autofactories stand idle per job.

**C2 — the over-print bug and goal A are the same mechanism.** `RestockRun` already fans out, by accident: the chooser moves to a free bench each tick, the owner-scoped guard asks the new bench and finds nothing of ours, and a second relay is ordered against a demand of one. Punch-list line 255. Netting against `onOrder` makes the fan-out deliberate and closes the duplicate spend with one change.

**Delete the owner-scoped bench guards** at `MineFleetPrint.swift:86` and `RestockRun.swift:95`. `onOrder` does that job across every bench; keeping both means the first in-flight job blocks the second, which is the serial behaviour being removed.

**`nextStep` becomes the same step.** `stocking` re-enters `stocking`. That is the shape `EventRun` already uses and it is what makes fan-out work across ticks.

**Read `MissionAction.wait`'s doc (`MissionStepMachine.swift:23-26`) before choosing the all-busy transition.** `.wait` is the only action that does not re-stamp `stepStartedAt`, so a `.wait` loop accumulates the deadline and an `.advanceStep` loop resets it. Whichever you pick, pin it.

**Expect `RelayReturnAndRestockTests` to redden.** It holds the `idleCap`/`desiredIdle` cases at `:377-394`. A case asserting "one print, then wait" is asserting the serial behaviour this ticket removes — rewrite it to assert the new sequence and name the case in `## Comments`.

---

- [x] **Step 1:** Write the acceptance test: three benches, three evaluations, three dispatches to three distinct benches for three DISTINCT types. The type-count expectation is the one that matters — three of the same type would satisfy the first half and be exactly the duplicate spend being closed.
- [x] **Step 1b:** Write ticket 18's other two acceptance criteria — **one autofactory behaves as it does today** (one job, then wait), and **a co-tenant's job neither blocks nor extends this run's deadline**. Ticket 18 asks for the second "through the real engine": add an engine-level case with two `mineFleetPrint` rows at one depot and two benches, asserting both ops exist and neither is `.superseded`. If that cannot be written against the existing harness, say so in `## Comments` and record what was pinned at unit level instead — do not quietly drop it.
- [x] **Step 2:** Write the C2 regression test: one relay on order against a demand of one is a `.wait`, not a second dispatch.
- [x] **Step 3:** Confirm both fail.
- [x] **Step 4:** Net `MineFleetPrint.stocking` against `onOrder`; delete its bench guard; dispatch through `choose`; `nextStep: stocking`.
- [x] **Step 5:** Make `MineFleetPrint.printing` a deadline holder, reached only when demand remains and no bench can take it.
- [x] **Step 6:** Do the same to `RestockRun.stocking`, netting `idle + onOrder` against `desiredIdle`.
- [x] **Step 7:** All six targets green.
- [x] **Step 8:** **Mutation probe.** Put `nextStep` back to `printing` and confirm the acceptance test fails on iteration two. Delete the `onOrder` netting and confirm both new tests fail. Revert both.
- [x] **Step 9:** Record the borrow count; `check-comments.sh`; commit.

**Done when:** three autofactories at one depot carry three different mine-fleet types within three ticks, with a test that fails if any of the three is a duplicate.

**Checkpoint E follows this ticket.** Do not start 39 until it has been run and its observed concurrent-print count recorded.

## Comments

**Built and reviewed 2026-08-19**, subagent-driven, on worktree branch
`worktree-directives-stage-3` off local `main` at `b7228f1`. **Not merged** — merging is Matt's
call. Every claim below was checked against the source or the event stream, not taken from a
subagent's summary.

| Commit | What |
|---|---|
| `d3713f5` | `feat(directives): print-only missions fan out across benches (C1, C2)` |
| `60e2e4e` | `fix(directives): MineFleetPrint.stocking decides .done on the true shortfall` |
| `a50ff53` | `fix(directives): review round 2 — vacuous deadline test, doc comments` |

C1 and C2 land, and both missions' `printing` step becomes a thin deadline holder. 18
pre-existing tests were rewritten, each named in the report with its old and new assertion, none
deleted or weakened.

**This ticket found a real defect in the plan's own code, and it would have been Phase A's
headline bug.** The brief's `stocking` computed the true shortfall from device rows, subtracted
what was on order, and returned `.done` on the remainder — so the mission completed as soon as
every missing type had an order *placed*, with every clone still on the platen and nothing left
watching them land. Five lines below, `printing` tested the **un-netted** `remaining`, so the two
steps disagreed about what finished means. Netting tells you what to order next; it does not tell
you the work is done.

Fixed in `60e2e4e`: `.done` is decided on un-netted `remaining` before `onOrder` is touched;
everything outstanding already on order advances to `printing`; anything unordered falls through
to the chooser. `fullyOrderedDemandHoldsInPrintingRatherThanCompleting` asserts both
`row.step == .printing` and `row.status == .running` — the second is what distinguishes
`.advanceStep` from `.done`, since "no dispatch" is equally true of both. It was confirmed RED
pre-fix with the directive actually reaching `.completed`. The review then grepped the file:
`.done` appears exactly once in `MineFleetPrint.swift` and zero times in `RestockRun.swift`, so
no other path completes with prints outstanding.

**The double-dispatch gap ticket 35's review raised is closed here**, by required tests for both
missions: own print open on bench A, bench B free at the same depot, demand already covered,
expect no second dispatch.

`desiredIdle` was left at its one-argument form for ticket 39 to change, per the plan's prose
over its own code block.
