---
name: post-launch-read-precedes-deployment
description: "A device read ISSUED after a step began can still return pre-launch rows, so `updatedAt >= stepStartedAt` proves a read happened, never that it observed the command's effect — the race behind three rounds of false dronesNotRecovered"
metadata:
  node_type: memory
  type: reference
---

**`Device.updatedAt` is the request-ISSUE time, not a server version.**
`DevicesClient.liveValue` stamps `issuedAt = date.now` *before* the round trip
(deliberately — it orders snapshots by when each read started, so a slow earlier
read cannot clobber a newer one). The consequence nobody costed: a read issued
one tick after a `launch` satisfies every `stepStartedAt` watermark in the engine
while its payload may still describe the world *before* the launch landed.

So `ctx.isFresh(device)` — `updatedAt >= directive.stepStartedAt` — answers "has
this row been read since the step began?" and **not** "does this row reflect what
the step did?" Those are different questions and only the first is answerable
from a timestamp.

## The window, measured live (2026-08-21, salvage run `760A30F8`)

    stepStartedAt (launch dispatched)   15:04:59.901
    drone rows still pre-launch         15:05:02.960  upd=15:02:54  stowedIn=VESSEL
    first post-launch read lands        15:05:04.471  upd fresh, stowedIn=[] mining

The deployment became visible ~4.5s after dispatch; the read that stamped the
rows fresh landed ~0.07s later. On another cycle the same read landed 85s after
dispatch (harmless). **Which side of the deployment that read falls on is a coin
flip on server latency**, which is exactly why the false stall fires a couple of
times a day rather than every cycle.

What arms it: `ConfirmRow`'s `readInterval` (`SalvageRun.reconcileInterval`,
120s). When the previous cycle's recall left the drone rows already older than
that, the ladder orders its read on the FIRST tick of `awaiting` — seconds after
the launch, inside the deployment window. When the rows are younger, the read is
throttled past the window and the cycle is safe.

## Why "all drones aboard" cannot be read as recovery

`stowedInDeviceCode == vessel` is ambiguous between *recalled home* (cycle over,
completion frame dropped) and *not launched yet*. A timestamp cannot separate
them. `SalvageRun.awaitCompletion` therefore consults `isMining(controller)`
first: a controller reporting `gather_salvage` **active** is proof the cycle is
not over, whatever the drone rows say.

That ordering is load-bearing because the controller reports the directive in
force from the instant the step begins — `set_directive` lands one step earlier.
Measured on the following cycle:

    stepStartedAt                       15:10:30.964
    controller row (upd 15:10:30.755)   status=stowed  dir=gather_salvage/active

The controller still reads `stowed` (it has not deployed itself yet) while
already reporting the directive active. The directive fields flip on
`set_directive`; `status` flips on deployment. **Gate on the directive fields,
not on `status`** — `status` flips too late to protect the window.

## Residual risk

The gate holds only while `set_directive` is observed before `awaiting` begins.
A read catching the controller before that lands would report no directive in
force, `isMining` would be false, and the old path would run. Not observed in
either measured cycle (`directive.set` arrived ~5-6s ahead both times).

See [[ami-drones-are-event-silent]] for why drone rows only move on an explicit
read at all, and [[relative-fixtures-hide-constant-drift]] for the testing
lesson: the two earlier fixes here were each pinned by tests that fixed rows
*before* `stepStartedAt`, so no fixture ever modelled a fresh row carrying stale
truth.
