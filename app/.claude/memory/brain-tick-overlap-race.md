---
name: brain-tick-overlap-race
description: "`start()`'s brain tick runs CONCURRENTLY with any explicit `tickBrain()`, and two overlapping ticks both read the pre-launch world — the root of the supervisor-adopts-row flake"
metadata:
  node_type: memory
  type: project
---

`DirectiveEngineCore.start()` spawns the brain as an unstructured `Task`. That
tick is **concurrent with**, never sequenced before, an explicit `tickBrain()`.
`tickBrain()` is actor-isolated but suspends at `await Brain(now:).report()`,
which releases the actor — and `report()` reads its snapshot at the top and
commits at the bottom, so an overlapping pair can both observe the world as it
was before either launched anything.

Two failures follow, both seen live:

1. **No restock row at all.** Both ticks see no grow row, so both decide
   `.dispatch`. One launch wins the in-transaction duplicate check and the other
   is refused — but the refused tick's `decision` is still `.dispatch`, and
   `Brain.tendRestock`'s `if existing == nil, case .dispatch = decision { continue }`
   makes a dispatching tick skip restock. Neither writes it.
2. **Row written too late.** The restock write lands after
   `reconcileExecutors()` has already read, so the row exists with no executor.

This is what made `BrainGrowLifecycleE2ETests/theSupervisorAdoptsTheRowTheBrainLaunched`
flaky. It was recorded as deterministic-under-whole-package and unexplained;
both halves were wrong. Measured 2026-08-15: **21 consecutive whole-package
`--build-system native` runs on an idle machine passed**, and with 24 CPU hogs
running, 5 of 10 failed. Load is the variable, not the backend — the overlap
window is `report()`'s duration, which a saturated cooperative pool stretches.

**`brainTickCount` cannot express completion.** It increments at the TOP of
`tickBrain()`, so it proves a tick STARTED. Waiting on it is not a barrier, and
neither is `TestClock.advance(by: .zero)` — that is `Task.megaYield()`, a fixed
20 yields (`swift-concurrency-extras`), which a loaded pool outruns.

**How to apply:** a test needing N completed brain ticks must `await
core.tickBrain()` N times itself. Calling `start()` is still required wherever
`reconcileExecutors()` must not be inert, but never count its tick as one of
yours — an extra concurrent tick is harmless, because every brain write
re-checks inside its own write transaction. See [[brain-salvage-build]] for
those in-transaction guards and [[brain-tendmesh-build]] for what the restock
row does.

Two other tests in this suite share the shape and are NOT yet flaky-proofed:
`BrainLoopTests/theTimerLoopItselfTicksOnSchedule` leans on
`advance(by: .zero)`, and `DirectiveEngineTests` has two `start()` +
`reconcileExecutors()` pairs that assert `executorCount` on rows seeded before
`start()` (so no brain write can race them).
