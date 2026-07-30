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
2. **`DirectiveExecutor.apply`'s `.dispatch` case re-stamps `stepStartedAt` on EVERY accepted dispatch**,
   unconditionally — there is no same-step exception. So a step that re-dispatches into itself resets the
   very clock its own backstop measures from.

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
