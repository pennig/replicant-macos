---
name: same-step-dispatch-needs-tracked-op
description: "A mission step that dispatches with nextStep == its OWN step is safe ONLY for tracked op kinds (.travel/.mine/.print/.surveyScan). For a .simple verb (deploy/activate/recall) no Operation row is created, so the openOperation guard is always nil, the command re-issues every tick forever, AND DirectiveExecutor re-stamps stepStartedAt on each accepted dispatch, so any step deadline can never fire."
metadata:
  type: reference
---

Caught in review during the Salvage Run build, 2026-07-30, before it ever ran. It looks correct because
it mirrors working code a few lines away.

## The shape

```swift
// SAFE — .travel is tracked
if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
return .dispatch(kind: .travel, deviceCode: vessel.deviceCode,
                 params: ..., nextStep: Step.travelling)   // same step

// BROKEN — .simple creates no Operation
if world.openOperation(for: relay.deviceCode) != nil { return .wait }   // ALWAYS nil
return .dispatch(kind: .simple("activate"), deviceCode: relay.deviceCode,
                 params: ..., nextStep: Step.activating)   // same step
```

## Why the second one fails, in two parts

1. **`OperationKind.simple` creates no tracked `Operation`.** `CommandClient.completion(for:)` classifies
   `activate` / `deploy` / `recall` and friends as `.immediate`; that branch returns
   `.accepted(operationID: nil)` and never inserts an `operations` row. So
   `world.openOperation(for: thatDevice)` is *structurally* always nil, and the guard that appears to
   prevent a second dispatch prevents nothing. See [[device-command-shapes]] for the full per-command
   response-class table — the tracked kinds are `.travel` (deadline), `.mine` (continuous),
   `.print` (enqueued) and the scan family.
2. **`DirectiveExecutor.apply` re-stamps `stepStartedAt` on EVERY action except `.wait`.** Verified
   2026-07-30: `.wait` returns at `DirectiveExecutor.swift:37-41` writing nothing at all, while
   `.dispatch` (accepted), `.advanceStep`, `.assignController` and `.refreshSystem` all go through
   `move()`, which sets `stepStartedAt = date.now` unconditionally. There is no same-step exception
   anywhere. So a step that loops back into itself by ANY of those routes resets the very clock its own
   backstop measures from.

   **`.wait` is the only action that lets a step deadline accumulate.** That generalises past dispatch:
   a step that answers "not ready yet" with `.refreshSystem(designation:nextStep: <its own step>)` is
   just as broken as one that re-dispatches, and looks even more innocent. Salvage Run's
   system-resolution backstop is a bounded `.wait` for exactly this reason.

Together: the command is re-issued at the live API on every 5s tick forever, and the deadline that was
supposed to surface a stall can never accumulate. The failure is invisible in unit tests, because a step
machine tested in isolation is called *once* with a hand-built `stepStartedAt` — the executor
interaction that resets it is out of frame.

## The fix, and the pattern to copy

**Split dispatch from polling.** `SurveyRun` already models it: `launching` dispatches and names
`awaiting` as its `nextStep`; `awaiting` only ever waits, advances, or stalls. `stepStartedAt` is then
stamped once on entry to the polling step and the deadline accumulates honestly. `SalvageRun` now has the
same pair — `activating` dispatches, `confirmingRelay` polls.

`SurveyRun.recover` obeys the same discipline from the other direction: while polling a recall it returns
only `.wait` or `.refreshDevices(thenStall: nil)` — never a dispatch — which is exactly why *its*
`recallDeadline` works.

## Rules

- A same-step `.dispatch` requires a tracked op kind. If the kind is `.simple`, split the step.
- Before writing `if world.openOperation(for: X) != nil { return .wait }`, check that the command you are
  guarding actually creates an op. If it does not, the guard is dead code — and worse, it makes the
  redispatch look guarded to the next reader.
- A step deadline must measure from a value nothing in that step's own loop rewrites.

See [[directives-feature]] for the engine's step-machine contract and [[salvage-run-design]] for the
feature this surfaced in.

## The escape hatch: a re-entry budget off the timeline (2026-07-30)

The rule above has a cost that bit on the next review: a step whose only real way forward is a READ
cannot poll for it, because every refresh action re-stamps the clock its own backstop measures from.
Salvage Run's three `.unresolved` branches took the safe half (`.wait`, bounded, then stall) and
inherited the other half of the problem — the stall's guidance said "Retry to fetch it again", but
nothing on that path ever fetched anything and `DirectiveResolutionClient.retry` only re-stamps
`stepStartedAt`. Retry re-ran a pure function over the identical snapshot and re-stalled forever.

The resolution, and the pattern to copy:

- **Wait on the polling branch; read on the terminal one.** The deadline accumulates honestly under
  `.wait`, and the single `.refreshSystem` fires only once the deadline has expired — the point at
  which resetting the clock costs nothing because the alternative was stopping anyway.
- **Bound the reads with a counter derived from the log, not a column.**
  `DirectiveExecutor.move` writes a `.stepStarted` row on every transition, so walking `world.log`
  backwards to the first entry naming a *different* step counts how many times the current step has
  been entered contiguously. It survives a relaunch (same database as the row) and needs no migration.
- **Stop the walk at `.resolved`, and count it.** Retry and Skip write that entry, so an operator's
  Retry buys a genuinely new read instead of replaying the stall — which is what makes the guidance
  true. Counting the boundary itself keeps the budget uniform however the step was reached.

`SalvageRun.stepEntryCount` is the implementation; `unresolvedSystem` and `sameBodyAgain` are its two
consumers (the second is the mining loop's terminator, which had no bound at all).

**One known imprecision in the budget, accepted:** a step that legitimately re-enters itself via a
TRACKED dispatch also writes a second `.stepStarted`, so it arrives at its own read budget already
partly spent. `SalvageRun.emplace` does this — it dispatches `.travel` to the Lagrange point with
`nextStep: .emplacing`, so if the system blob goes missing *after* that hop, `unresolvedSystem` stalls
without spending its automatic read. It fails safe (stalls rather than loops) and the operator's Retry
still buys a real read, because `.resolved` re-arms the budget. Worth knowing before reusing
`stepEntryCount` on a step with a self-dispatch.
