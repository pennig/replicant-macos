# 08 — Reads leave the SSE dispatch path

Type: task
Status: resolved
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

- [x] **Step 1: Failing tests (StalenessTrackerTests)**

`markUrgent` drains ahead of visible/op-holding marks; `markNew` drains a code with no `Device` row and upserts it via the refresher (stub the refresher, assert the call). Both respect the existing per-pass cap.

- [x] **Step 2: Implement**

Add the two marks and the drain ordering. In `deviceRoute`: replace `_ = await deviceRefresher.refresh(newCode, .high)` with `await deviceStaleness.markNew(newCode)`; replace the `completedOp && provenance == .stream` `.high` read with `await deviceStaleness.markUrgent(code, event.event)`. Keep the `markStale` else-branch.

- [x] **Step 3: Measure**

Under a replayed catch-up of ≥ 500 events (the `GameSyncTests` catch-up fixture), assert the route body performs zero network calls (stub `deviceRefresher` to record). Then run the app against the live stream for an hour and compare `EventPipeline` lag before/after (the OSLog `catch-up …` lines carry timing). Record the numbers in `## Comments`.

- [x] **Step 4: Commit**

`perf(sync): device events mark; the tracker reads`.

## Comments

Resolved in `ac532dd`.

**Deferral decision:** executed now, not deferred. The ticket is marked
deferrable to the start of Stage 2 only if Checkpoint A shows catch-up
regressions — that checkpoint hasn't happened yet, so there is no signal
to defer on.

**Step 3, in-scope half:** no ≥500-event catch-up fixture existed in
`GameSyncTests` in that form, so `catchUpReplayPerformsNoNetworkCalls`
builds one from this file's own fixtures — 510 `.catchUp`-provenance
events (450 thin, 40 op-closing arrivals against seeded `Operation`
rows, 20 `print.completed` clones), replayed through `deviceRoute`
directly. Result: **510 events processed** (`markStale` calls ==
`events.count`, `markNew` calls == 20), **zero calls** on the stubbed
`deviceRefresher` — the route body never reaches the network.

**Step 3, deferred half:** the live-stream hour and the before/after
`EventPipeline` catch-up lag numbers are outstanding — this session has
no logged-in app to drive. Matt: these are yours to collect during the
Checkpoint A evening.

**The `print.completed` clone read / `deviceCode` guard (ambiguity 5):**
`markNew` stays inside ticket 04's top-level `guard let code =
event.deviceCode` — the same position the read it replaces already
occupied. Ticket 04's review judged a nil `deviceCode` on a
`print.completed` event unreachable in practice and deferred it
deliberately; moving the mark outside the guard would silently reopen
that deferred question as a side effect of this ticket, which isn't
mine to decide. If it needs revisiting, that's its own ticket.

**Review round 2, fixed in `dd772fd`:** two findings. (1) The file
header was 11 `//`-prefixed lines, not 10 — trimmed by dropping the
trailing blank separator line. (2) `markUrgent` never self-triggered a
drain for a visible device, so a device open in the inspector whose
live op closed waited up to `drainInterval` for its read — slower than
the ordinary tier, and the opposite of what `deviceRoute`'s own comment
claims. Confirmed `drainSoon()` only schedules an earlier `drainPass()`
call, which still enforces `maxPerPass`/`urgentPerPass` — no cap
bypass — so `markUrgent` now calls `drainSoon()` when `visible.contains`,
mirroring `markStale` exactly; `markNew` still rides the periodic loop
only (the burst risk it guards against is real, per the original
report). Covered by a new test exercising the previously-untested
visible+urgent combination. `GameServicesTests` (283) and `GameSyncTests`
(66) re-ran green through the JSON event stream.
