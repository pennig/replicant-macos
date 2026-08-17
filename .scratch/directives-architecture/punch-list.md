# Directives Architecture — punch list

Small things deliberately not fixed when they were found, kept here so they are not lost between stages. Work the list at the end of the effort; anything still open then is either done or consciously dropped.

**Maintaining it.** When a review defers something, add a line: what it is, where (`file:line`), which stage found it, and why it was deferred. Tick the box when it lands, and say in the commit which item it closed. Do not delete a line to close it — a ticked line is the record that someone decided. If an item turns out to be wrong or no longer real, tick it and say so.

**Not for this list:** anything that blocks a merge, anything that changes behaviour a mission depends on, and anything a stage's own ticket already covers. Those belong in a ticket.

---

## Needs a human decision

- [ ] **`MineFleetPrint.stocking` has no deadline above its open-op guard.** Stage 0 owner-scoped the guard to match its three siblings but deliberately did not invent a deadline, because adding one changes mission behaviour outside the ticket's scope. Without it, a co-tenant on a shared bench can park the run for the length of its own print. `MineFleetPrint.swift` — decide whether `stocking` should carry a deadline like `printing` does.
- [ ] **automation-brain ticket 14 (RestockRun over-print race) is still open.** Stage 0 declined to close it: the ownership and ordering fixes did not touch the clone-row-lag race it describes. It now carries a cross-reference. Decide whether it belongs in a later stage of this effort or stays where it is.

## Measurements owed

- [ ] **Ticket 08's live-stream lag numbers.** The ≥500-event replay proves the route body makes zero network calls; the before/after `EventPipeline` lag under a real stream was never measured, because it needs a logged-in app. Collect during Checkpoint A from the OSLog `catch-up …` lines.
- [ ] **Watch item for Checkpoint A: a stale observation stamped fresh.** `Reconciler.applyDeviceEvent` stamps `updatedAt = now` on the op-closing path regardless of the event's age (spec S0.3, deliberate), and Stage 0 made `isFresh` the single freshness predicate at eleven confirm gates. After an SSE backlog an hours-old observation reads fresh. The tell is a `.stepStarted` immediately following a burst of replayed events with no read between them.

## Robustness

- [ ] **A dropped optimistic row is indistinguishable from "never dispatched".** `CommandClient`'s immediate-branch insert uses `try? await database.write`. Largely defused — the failure counter now compares before/after rather than testing for zero — but the underlying silent drop remains. Consider whether that write should be allowed to fail quietly at all.
- [ ] **The visible-ordinary staleness tier has no per-mark backoff.** A demoted urgent mark, or any never-satisfiable visible mark, still gets one `.low` read every pass forever. The coordinator's TTL does not suppress at that spacing; only the reads-budget floor does. `StalenessTracker.swift`. Strictly better than the old `.high` firehose it replaced, which could starve the budget.
- [ ] **`markNew`'s "rides the periodic loop only" property is not enforced in code.** It delegates to `markUrgent`, so it inherits the visible self-trigger; the property holds only because `visible` can contain at most one code and never a not-yet-known clone. Inert today. Re-examine if `markNew` gains a second caller. `StalenessTracker.swift`.
- [ ] **`EventRun.printing`'s progress witness falls back to `stepStartedAt` when the run holds no open print op.** Reachable when another directive occupies every printer at the depot. The fallback measures genuinely blocked time rather than working time, so it is defensible, but it is the old wide-window behaviour in a narrower case. `EventRun.swift`.
- [ ] **`MineFleetPrint.fleetEvidenceIsStale` became a weaker gate.** It compares `newest < stepStartedAt`, and with same-step dispatches no longer re-stamping that clock it forces fewer fleet sweeps. The risk is a duplicate order, never a false stall. `MineFleetPrint.swift`.

## Constants and coupling

- [ ] **`unresolvedReadBand` is tied to the engine tick by comment only.** The band (15 s) must exceed the worst observed tick period; the tick literal lives separately in `DirectiveEngine.swift`. Changing the tick silently breaks the pairing. Give them one shared constant, or a test that fails when they diverge.
- [ ] **The 60-second unresolved-retry window is an uncalibrated default.** Chosen without measurement. Tune against real API latency, or record it as a tunable with its bounds the way the other calibrations are.

## Tests

- [ ] **`StalenessTrackerTests.urgentMarkOnAVisibleDeviceSelfTriggersADrain` is flaky under a narrow `--filter`.** Its 200-yield spin is too short for an actor hop plus a GRDB read; it passes in full-target runs. It cannot produce a false green. Fix it early anyway — RED checks are run with exactly that filter, so the next person meets a red test that is not theirs. Replace the spin with a `confirmation` or an awaited drain handle.
- [ ] **`RestockRunTests` lacks an "own print open, past the deadline" case.** The courier suite has the matching one. No functional gap — the deadline check runs unconditionally before the op guard — but only one of the two runs pins the ordering that Stage 0 fixed.
- [ ] **The catch-up replay test's `processed` counter asserts nothing.** It is trivially true regardless of route behaviour; `markedOrdinary.value.count` carries the real proof. Drop it or make it mean something. `GameSyncTests.swift`.
- [ ] **The arrival atomicity test reads the op and the device separately.** Atomicity is guaranteed structurally by the single `database.write`, so the test is weaker than the guarantee rather than wrong. `ReconcilerDeviceEventTests.swift`.

## Cosmetic

- [ ] **`completeOpenOperation`'s `logger.notice` diagnostics are absent from the device-event path.** Inlining the op-close into `applyDeviceEvent` dropped the kind-mismatch and stale-time rejection lines. No behaviour depends on them; they are the lines that would explain a silent non-close. `Reconciler.swift`.
- [ ] **The `print.completed` clone read no longer runs when an event carries no device code.** Stage 0 hoisted the `deviceCode` guard above it and later kept the mark inside that guard deliberately. Unreachable in practice — print completions always carry a code.
- [ ] **`DirectiveExecutor.move`'s doc comment is 13 `///` lines against a 3-line budget.** Inherited, not grown by this effort, and `check-comments.sh` cannot see it.
- [ ] **`DirectiveEngineCore.collapse`'s doc is a 4-line `///`.** Same class, adjacent to code Stage 0 touched.
- [ ] **`GameModels.Operation` is fully qualified in one test file and bare in its sibling.** Cosmetic inconsistency between `DirectiveEngineTests` and `CommandDedupTests`.
- [ ] **Every `.dispatch` tick now runs one extra `SELECT count(*)`.** The failure counter reads before and after. Small, but it is per tick for the life of a step that defers every tick. Measure before assuming it is free.
