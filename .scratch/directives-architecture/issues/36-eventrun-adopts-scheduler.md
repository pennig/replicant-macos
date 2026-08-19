# 36 — `EventRun.printing` adopts the scheduler

Type: task
Status: resolved
Blocked by: 35
Labels: directives-architecture, stage-3

The first of the two hand-rolled sites. `EventRun`'s own printer filter and its in-flight accounting both go.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 4. **Carries C3 and C4.**

**C3 — the capability predicate.** `EventRun.swift:401` filters on `deviceType == "autofactory"`, the only such string match in production. `Device.swift:173-177` documents `isPrintHub` as existing precisely to avoid it. After this ticket `EventRun` gains any print-capable vessel and loses any `autofactory` without `enqueue_print` in `availableCommands`. Both halves are behaviour changes; the first gets the test.

**C4 — the busy guard.** `EventRun.swift:411` uses the owner-unscoped `openOperation(for:)`, so a co-tenant's print hides the bench entirely and the run orders nothing. The three migrated sites are already owner-scoped.

**`printsInFlight` is deleted, not moved.** `EventRun.swift:275-285` counts device types from open ops' `detail.params` — that is `PrintScheduler.onOrder` with a different name and a narrower scope.

**Reorder while you are in there.** Today the bench is picked at `:373` and the type at `:376`. Ask "is there anything to print?" before "is there anywhere to print it?", or a depot with a free bench and nothing wanted takes the `noProgress` branch for the wrong reason.

`EventRun.printDeadline(for:in:)` stays. It is the one variable deadline and it is doing real work for a mission that orders a dependency tree; ticket 47 decides whether it ever comes home.

---

- [x] **Step 1:** Write the two failing tests. **Make the C4 test able to fail** — if the free bench sorts first it passes vacuously; rename the codes so the busy bench sorts first.
- [x] **Step 2:** Confirm both fail.
- [x] **Step 3:** Delete `printsInFlight`; net against `onOrder`; replace the filter and the pick with `PrintScheduler.choose`.
- [x] **Step 4:** All six targets green.
- [x] **Step 5:** `check-comments.sh`; commit.

**Done when:** a print-capable vessel that is not typed `autofactory` is a legal bench for an event run, with a test.

## Comments

**Built and reviewed 2026-08-19**, subagent-driven, on worktree branch
`worktree-directives-stage-3` off local `main` at `b7228f1`. **Not merged** — merging is Matt's
call. Every claim below was checked against the source or the event stream, not taken from a
subagent's summary.

| Commit | What |
|---|---|
| `ccaf2c9` | `refactor(directives): EventRun prints through PrintScheduler (C3, C4)` |
| `45c0201` | `fix(directives): rewrite EventRun print-test docs, fix C4' fixture` |

C3 lands: bench capability moves from `deviceType == "autofactory"` to
`acceptsPrintJobs && !isCarrierHull`.

**C4 IS STRUCK, and the plan has been corrected in place.** It claimed `EventRun`'s bench-busy
guard becomes owner-scoped. Verified against the pre-task source: the old guard
`world.openOperation(for: $0.deviceCode) == nil` (`EventRun.swift:411` at `a358fdf`) and
`PrintScheduler.choose`'s `$0.activeJob == nil` are the same any-owner predicate, so the
specified test passed whether or not the migration happened. C4 also contradicts C11, which
deliberately stops a mission dispatching onto a bench busy with another run's print. C11 wins.

**C4' is what this migration actually changed.** `printsInFlight` read
`world.dispatchedOperations` with **no location filter**, so a print open at another depot netted
against demand here and suppressed an order that should have gone out. `PrintScheduler.onOrder`
is depot-scoped. Pinned by `anotherDepotsPrintDoesNotNetHere`, rebuilt in `45c0201` so the far op
sits on a registered bench at a real second depot and differs from the near op only in depot —
before that it named an entity never registered as a device and exercised the filter by accident.

`printDeadline(for:in:)` is untouched; ticket 47 decides its fate. The `PrintJob.hasBench` guard
that the brief's snippet silently dropped was kept — dropping it would have turned a zero-bench
depot from a stall into a wait.
