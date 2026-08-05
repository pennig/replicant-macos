---
name: confirm-steps-need-fresh-evidence
description: "A polling step that judges a LOCAL device row must first prove the row is newer than the dispatch it is confirming — `controller.updatedAt >= directive.stepStartedAt`. Nothing in a mission's own loop refreshes device rows, so a pre-dispatch row satisfies a loose config check, the step fast-paths, its deadline never accumulates, and the run re-commands itself into a false stall. The staleness guard must sit AFTER the deadline check, or a failing read loops forever. And a DISPATCH step needs the same proof but keyed off the ARRIVAL, never `stepStartedAt` — a single arrival event closes the travel op and writes `device.location` in two separate transactions, so a tick landing between them re-commands travel at a vessel already parked on the destination."
metadata:
  type: reference
---

Caught in the Haul Run's final whole-branch review, 2026-07-31, and then again in the re-review of its
own fix. Both halves are easy to get wrong and neither shows up in a unit test.

## Half one: a stale row is not evidence

A confirm/poll step typically asks "has the device taken the command I just sent?" by reading its row
out of `WorldSnapshot`. **Nothing in a mission's own step loop refreshes device rows** — `.dispatch`
writes no device row, and the post-command confirm-read `CommandClient` performs can return nil. On
this account device rows refresh roughly every 5 minutes.

So in steady state the row the step reads is the row from *before* the dispatch. If the check is at all
loose — "is it running SOME config I could have issued?" — the pre-dispatch config satisfies it:

```swift
// BROKEN: a controller already running ferry->AINALRAM-BELT-1 satisfies this
// on the very next tick, whatever we just told it to collect.
if hasTakenSomeHaulConfig(controller) { return .advanceStep(nextStep: .assigning) }
```

Three things then go wrong at once, and they compound:
1. The step never waits, so its **deadline never accumulates** and the post-deadline escape is
   unreachable dead code.
2. The step that owns repointing re-derives the same assignment, re-pins, and **re-dispatches**.
3. The re-entry budget bounding that loop trips — so a command that *landed correctly* ends as
   `.commandRejected`, and Retry just buys another few laps of the same.

Measured end-to-end before the fix: 3 redundant POSTs, then `needsAttention`; Retry → 3 more.

**The guard is exact, because `DirectiveExecutor` stamps `stepStartedAt = now` on the accepted
`.dispatch`:**

```swift
guard controller.updatedAt >= directive.stepStartedAt else {
    // The row was read BEFORE the command went out — it cannot say whether
    // the controller took it.
    ...
}
```

Note the tests that missed it: every `confirming` fixture used a controller with **no** directive at
all — the fresh-controller case, the one case where the loose check happens to wait. If a polling
step's fixtures never carry a plausible *prior* state, the steady-state path is untested.

## Half two: the staleness guard must not outrank the deadline

The obvious fix — `guard` on staleness, buy a throttled authoritative read, else `.wait` — reintroduces
the failure from the other side if it `return`s before the deadline check. The read throttle is
naturally measured against `controller.updatedAt`, and **that only advances when a read succeeds**. So
when reads keep failing (offline, 429, a device the server 404s) the step never reaches its deadline,
never stalls, and issues a `.high` read every tick forever — `.high` bypasses both the PollCoordinator
TTL and the read-budget floor, so it is ~12 reads/minute per run, self-sustaining precisely under the
rate-limit exhaustion that caused it.

Measured: 10 evaluations → 10 reads, step unchanged, status `running`, `attentionReason` nil.

**Order matters. Deadline first, then staleness, then the throttled read:**

```swift
guard controller.updatedAt >= directive.stepStartedAt else {
    if world.now.timeIntervalSince(directive.stepStartedAt) >= Self.confirmDeadline {
        return .refreshDevices(deviceCodes: [code], thenStall: .commandRejected)
    }
    if world.now.timeIntervalSince(controller.updatedAt) > Self.confirmReadInterval {
        return .refreshDevices(deviceCodes: [code], thenStall: nil)   // bounded: reAsk collapses to .wait
    }
    return .wait
}
```

`thenStall: nil` is what makes the mid-flight read bounded — `DirectiveEngine.reAsk` collapses a repeat
refresh request to `.wait` rather than looping.

## Half three: a DISPATCH step needs it too, and its watermark is NOT `stepStartedAt`

Live incident 2026-08-01: Salvage Run stalled `commandRejected: "Already at destination"` **139 ms**
after its vessel's `travel.arrived`. The cause is one level below the step machine.
`GameSync.deviceRoute` settles two facts from a single arrival event in **two separate transactions
with awaits between them** — `Reconciler.applyOperationEvent` closes the travel op
(`GameSync.swift:314`), then `Reconciler.applyEventFields` writes `device.location`
(`GameSync.swift:354`). All four of `SalvageRun`'s travel dispatch sites guarded only on
`openOperation`, which is exactly write #1. The instant it lands the guard opens; a 5 s tick falling
before write #2 sees "travel finished, but I'm not there" and re-commands travel at the body the
vessel is parked on.

Intermittent by construction: the three earlier cycles that night had the tick land 2.2–4.7 s after
arrival and advanced cleanly. **Two facts settled by two transactions are not one fact** — if a step
branches on both, it must prove they agree.

**The watermark is the arrival, not `stepStartedAt`.** Half one's gate is right for a *polling* step
but wrong for a *dispatch* step: on first entry `stepStartedAt` is the step-entry time and the row is
legitimately older, so it would delay every first travel; and a same-step `.travel` re-stamps it, so
a `stepStartedAt` deadline is already blown on arrival. Use the completion of the last travel THIS
directive dispatched — `WorldSnapshot.dispatchedOperations` keeps closed ops for exactly this, so no
column and no migration. Filter `status == .completed` **exactly**, never `isTerminal`:
`.superseded` (`CommandClient.swift:209`) and `.unknown` (`DeadlineScheduler.swift:199`) stamp
`lastConfirmedAt` on accepted travels that never arrived, and would install a non-arrival as the
watermark.

**Still unfixed, know it before you chase it again:** `Reconciler.swift:256`'s
`guard eventTime >= device.updatedAt` drops the location write outright when a device read stamps
`updatedAt` later within the same wall-clock second as the arrival (live `createdAt` is
second-granularity). The op still closes, so the row reads **fresh-but-wrong** and the gate above
*passes* — same stall, different door. The fix belongs in `applyEventFields`, not in a mission.

**Sibling exposure:** `SurveyRun.swift:416` (`returnHome`) and `:488` (`travel`) still have the
pre-fix shape — both guard a travel dispatch on `world.openOperation` alone.

## Rules

- A polling step that reads a local row must prove the row post-dates the dispatch before believing it.
- Any "is it settled?" check loose enough to match a *plausible prior state* will match the pre-dispatch
  row. Either compare exactly, or gate on freshness first.
- Every escape a step relies on must be reachable from every path that can persist. Ask specifically:
  "if this read never succeeds, what stops this?"
- Fixture the *prior* state, not just the empty one. A confirm step tested only against a device with no
  directive is untested.
- A DISPATCH step must prove it too, keyed off the arrival — and gate the dispatch path ONLY. A stale
  row that already names the destination is the benign direction (advance); the hazard is exclusively
  stale-says-elsewhere → re-command.
- Test the gate's PLACEMENT, not just whether it fires. Every stale fixture with
  `location != destination` still passes if the gate is hoisted above the equality check — measured:
  that mutation broke exactly ONE test in a 335-test package.

See [[same-step-dispatch-needs-tracked-op]] for the sibling trap (which actions re-stamp
`stepStartedAt`, and why only `.wait` lets an interval accumulate), [[haul-run-design]] for the
feature half one surfaced in, and [[salvage-run-design]] for half three's.
