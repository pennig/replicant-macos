---
name: mining-gate-read-an-ungated-row
description: "`SalvageRun.awaitCompletion` gates the DRONE rows through `ConfirmRow` and then reads `isMining` off the CONTROLLER row, which nothing gates — so the guard installed to stop false `dronesNotRecovered` could be answered by the previous cycle's terminal `completed`"
metadata:
  node_type: memory
  type: reference
---

`awaitCompletion`'s freshness ladder is keyed off the drone rows alone (`min`),
deliberately — see [[post-launch-read-precedes-deployment]]. Once that ladder
returns `.judge`, the step consults `isMining(controller)` as the load-bearing
protection against reading a deployed fleet as recovered. **That call reads a row
the ladder never vouched for.** `ConfirmRow.verdict(drones, ctx)` proves the
drones were read since `stepStartedAt`; it says nothing about the controller.

The stale value the controller row most likely holds is the exact one that
defeats the guard. `ami_directive_status` is left at `completed` when a cycle
ends (`_eval_state: "depleted:complete"`), and nothing between that completion
and the next `awaiting` necessarily re-reads the controller: `positioning`,
`configuring` and `launching` all decide from the row they already have. So
`isMining` reads `completed`, returns false, and the drone branches below
fall through to `advanceStep(verifying)` — the false `dronesNotRecovered`
that gate exists to prevent.

**The drone rows already carry the same fact, on rows proven fresh.** A working
drone reports `status: "mining (<resource>)"`; the vocabulary is
`mining (…)` / `idle` / `stowed` / `out_of_range`, so `statusBase == "mining"`
separates a live cycle from both a recall and a genuine strand. `awaitCompletion`
now waits on `isMining(controller) || anyDroneMining(drones)`.

Why the drone check does not mask the failures the step must still name:

- dropped completion frame — the recall landed, so the drones read `stowed`
  aboard the vessel, not `mining`; the aboard branch still advances
- real `dronesNotRecovered` — mining is over and the drones sit `idle` or
  `out_of_range`, never `mining`
- `miningDirectivePaused` — a pause stops retargeting, so the drones fall to
  `idle` and the paused branch fires a cycle later than before

## Reads of a controller row are not on the engine's cadence

`StalenessTracker`'s drain (`GameSync` arms it; 5s loop) reads devices
INDIVIDUALLY off stream marks and UI visibility, entirely separate from the
engine's `refreshFleet` walks. A tag walk stamps controller and drones with one
`issuedAt`; the drain does not, so the two rows routinely disagree in age by
minutes. Any predicate mixing a gated row with an ungated one is reading two
different instants.

## What the server actually reports

Probed live: `ami_directive_status` flips to `active` within ~0.3s of
`set_directive`, before the controller's own evaluator has populated
`_eval_state`. The field does not lag the command, so a fresh read would have
answered correctly — the row's age was the whole defect.

`RepairFleet` (`currentDirective == "service" && currentDirectiveStatus ==
"active"`) reads a bot row the same ungated way; unexamined.
