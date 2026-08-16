# 08 — Reads leave the SSE dispatch path

Type: task
Status: open
Blocked by: 04
Labels: directives-architecture, stage-0, deferrable

Spec S0.7. `GameSync.deviceRoute` performs `.high` reads inline (the post-close read and the `print.completed` clone read) and `EventRouter.dispatch` awaits routes serially inside `for await event in stream` (`GameSync.swift` was `:195-197, 335, 366`), so a burst of events queues behind network reads and ops close on the poll path while rows lag — the recorded 2 h 08 m backlog (`brain-mine-build`). Marks are already how every non-closing event is handled; make the closing path mark too and let `StalenessTracker` drain at its highest tier.

This ticket may be deferred to the start of Stage 2 if Checkpoint A shows catch-up regressions; record the decision in `## Comments`.

**Files:**
- Modify: `app/Modules/GameSync/Sources/GameSync.swift` (`deviceRoute`)
- Modify: `app/Modules/GameServices/Sources/StalenessTracker.swift` (a `.high`-tier mark that drains within one pass, and a mark for a device code with NO row yet)
- Test: `app/Modules/GameServices/Tests/StalenessTrackerTests.swift`, `app/Modules/GameSync/Tests/GameSyncTests.swift`

**Interfaces:**
- Produces: `DeviceStalenessClient.markUrgent(_ code: String, _ reason: String)` — drained before the ordinary tiers, at most `urgentPerPass` (4) per drain, `.high` priority; `markNew(_ code:)` for a code with no row (the print clone) — the drain issues the read even though nothing local references the code.
- Consumes: ticket 04's `applyDeviceEvent` (the transaction must land BEFORE the mark, and does).

---

- [ ] **Step 1: Failing tests (StalenessTrackerTests)**

`markUrgent` drains ahead of visible/op-holding marks; `markNew` drains a code with no `Device` row and upserts it via the refresher (stub the refresher, assert the call). Both respect the existing per-pass cap.

- [ ] **Step 2: Implement**

Add the two marks and the drain ordering. In `deviceRoute`: replace `_ = await deviceRefresher.refresh(newCode, .high)` with `await deviceStaleness.markNew(newCode)`; replace the `completedOp && provenance == .stream` `.high` read with `await deviceStaleness.markUrgent(code, event.event)`. Keep the `markStale` else-branch.

- [ ] **Step 3: Measure**

Under a replayed catch-up of ≥ 500 events (the `GameSyncTests` catch-up fixture), assert the route body performs zero network calls (stub `deviceRefresher` to record). Then run the app against the live stream for an hour and compare `EventPipeline` lag before/after (the OSLog `catch-up …` lines carry timing). Record the numbers in `## Comments`.

- [ ] **Step 4: Commit**

`perf(sync): device events mark; the tracker reads`.
