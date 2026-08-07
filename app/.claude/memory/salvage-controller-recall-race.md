---
name: salvage-controller-recall-race
description: "The 2026-08-07 live soft-stall: the mining controller flies its OWN recall leg after `directive.completed` (which tracks the DRONES), so `verify` released the vessel while it was still airborne; it chased, `set_directive`/`launch` landed mid-flight, and the stow that ended the chase PAUSED the directive. `awaitCompletion` then read the directive NAME alone as 'still mining' and waited 7h+ with no stall."
metadata:
  type: project
---

# A mining controller has its own recall leg, and a stow pauses its directive

Two independent defects, one incident. Sibling of
[[salvage-fleet-repair-build]] and [[salvage-run-design]], whose
`awaitCompletion` "never stalls, however long the cycle runs" line this amends.

## `directive.completed` tracks the DRONES, not the controller

The controller deploys itself at the first body of a system and stays out while
the vessel tours the rest. On a `recall: true` cycle the server holds
`directive.completed` until the *drones* are aboard — and the controller only
*then* departs on its own flight back. Measured live: completion and the
controller's `travel.departed` share a second, and its arrival landed 4m 35s
later, across two hops because the vessel moved meanwhile.

`verify` proved only `AMIFleet.adoptedDrones(...)` were stowed, so it released
the vessel three seconds after the controller took off. `positioning` flew out
from under it; the controller chased; `set_directive` and `launch` both landed
on a device in transit; and the `device.stowed` that ended the chase left
`ami_directive_status: "paused"` with six drones deployed and nothing mining.

**The gate is now `controllerNotAboard`**, deadline-before-staleness like every
other confirm step ([[confirm-steps-need-fresh-evidence]]), waiting out the
controller's own `activityDeadline` and surfacing
`miningControllerNotRecovered`.

**Still open:** a directive row with a nil `controllerCode` resolves its
controller through `SalvageRun.controller(aboard:)`, which only ever finds a
STOWED one. A controller that has flown out of the vessel is therefore invisible
to that fallback, and `verify` reads it as vanished and heads for `repairing` →
`.advanceTarget` — abandoning it. Live rows carry a `controllerCode`, so the
code path that saves them is the one the fallback does not take.

## A directive NAME is not a directive that is running

`awaitCompletion` concluded "still mining" from `currentDirective ==
"gather_salvage"` alone. A paused directive keeps its name, emits no
`directive.completed`, and that branch is documented never to stall — so the run
reconciled every 2 minutes for over seven hours with nothing to show for it.

This is exactly the trap `RepairFleet.isArmed` closes for service bots (name AND
`status == "active"`), which had already been found live twice — a deployed bot
lands paused, and re-sending its name never touches the status. `SalvageRun` now
has the matching `isMining`/`isPaused` pair; `awaitCompletion` proves a pause on
a fresh read and stalls `miningDirectivePaused`, and `configure` follows the
service-bot fix by dispatching `activate` when the name and config are right but
the status is not — without which Retry could never clear the state, since the
config match sent it straight back to `launching`.

**Both new reasons are `.escalate`.** A paused directive needs an operator to
resume it (the brain drives only `retry`/`cancel`, and a retry re-stalls), and a
controller left ashore is the same "a member of the fleet is out and the vessel
must not leave" judgement `dronesNotRecovered` already carries.

## What the fix does not cover

The pause is only *named*, never *resumed*. Resuming a controller that is by
then stowed aboard the vessel is unprobed server behaviour, and the halt matrix
halts rather than improvising. Recovering the live run is an operator action:
resume the controller so its `recall` brings the drones home. **Do not Skip the
target** — `skipTarget` bypasses `stowingBots`, which abandons the service bots
([[salvage-fleet-repair-build]]).
