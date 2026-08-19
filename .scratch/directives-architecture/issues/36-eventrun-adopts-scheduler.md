# 36 — `EventRun.printing` adopts the scheduler

Type: task
Status: open
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

- [ ] **Step 1:** Write the two failing tests. **Make the C4 test able to fail** — if the free bench sorts first it passes vacuously; rename the codes so the busy bench sorts first.
- [ ] **Step 2:** Confirm both fail.
- [ ] **Step 3:** Delete `printsInFlight`; net against `onOrder`; replace the filter and the pick with `PrintScheduler.choose`.
- [ ] **Step 4:** All six targets green.
- [ ] **Step 5:** `check-comments.sh`; commit.

**Done when:** a print-capable vessel that is not typed `autofactory` is a legal bench for an event run, with a test.
