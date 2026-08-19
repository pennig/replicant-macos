# 38 — The print-only missions fan out across benches

Type: task
Status: open
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

- [ ] **Step 1:** Write the acceptance test: three benches, three evaluations, three dispatches to three distinct benches for three DISTINCT types. The type-count expectation is the one that matters — three of the same type would satisfy the first half and be exactly the duplicate spend being closed.
- [ ] **Step 1b:** Write ticket 18's other two acceptance criteria — **one autofactory behaves as it does today** (one job, then wait), and **a co-tenant's job neither blocks nor extends this run's deadline**. Ticket 18 asks for the second "through the real engine": add an engine-level case with two `mineFleetPrint` rows at one depot and two benches, asserting both ops exist and neither is `.superseded`. If that cannot be written against the existing harness, say so in `## Comments` and record what was pinned at unit level instead — do not quietly drop it.
- [ ] **Step 2:** Write the C2 regression test: one relay on order against a demand of one is a `.wait`, not a second dispatch.
- [ ] **Step 3:** Confirm both fail.
- [ ] **Step 4:** Net `MineFleetPrint.stocking` against `onOrder`; delete its bench guard; dispatch through `choose`; `nextStep: stocking`.
- [ ] **Step 5:** Make `MineFleetPrint.printing` a deadline holder, reached only when demand remains and no bench can take it.
- [ ] **Step 6:** Do the same to `RestockRun.stocking`, netting `idle + onOrder` against `desiredIdle`.
- [ ] **Step 7:** All six targets green.
- [ ] **Step 8:** **Mutation probe.** Put `nextStep` back to `printing` and confirm the acceptance test fails on iteration two. Delete the `onOrder` netting and confirm both new tests fail. Revert both.
- [ ] **Step 9:** Record the borrow count; `check-comments.sh`; commit.

**Done when:** three autofactories at one depot carry three different mine-fleet types within three ticks, with a test that fails if any of the three is a duplicate.

**Checkpoint E follows this ticket.** Do not start 39 until it has been run and its observed concurrent-print count recorded.
