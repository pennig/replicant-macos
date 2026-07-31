# Salvage Run — vessel site tour + smart await backstop

**Date:** 2026-07-31
**Touches:** `app/Modules/DirectiveEngine/Sources/SalvageRun.swift` (+ its tests)
**Depends on nothing new** — no schema, no client, no new `MissionAction`. Reuses the
`.travel` / `.refreshFleet` / `.refreshDevices` / `.advanceStep` primitives already in the file.

## Problem

Two live-consequence defects in the shipped Salvage Run, both observed by the operator
running it:

1. **False `dronesNotRecovered` stall.** The mining loop is
   `configuring → launching → awaiting → verifying`. `awaitCompletion` waits for the
   `directive.completed` SSE — which, since v2.3.3, is held until the recall actually lands,
   so completion genuinely means "drones home." But it carries a **blind 10-minute
   `backstopInterval`** that advances to `verifying` regardless of whether mining finished.
   `verify` then sees drones still out and stalls `dronesNotRecovered`. Real mine cycles
   routinely exceed 10 minutes, so the backstop fires *mid-mining* on almost every cycle.
   Its only legitimate job is catching a *dropped* completion frame, but a fixed timer
   shorter than the work cannot tell "frame dropped" from "still mining."

2. **Drones ferry from a parked vessel.** `travel` sends the vessel to the bare system
   designation, which the backend resolves to the **system entry point**
   ([[travel-system-proxy-codes]]). `emplace` then moves it to the Lagrange point to plant
   the relay. From then on the vessel **never moves again** — the mining loop only re-points
   the controller's `gather_salvage` `location` at each body, and the drones ferry out from
   the Lagrange point to each site and recall back. That doubles the travel per site
   (out + recall), and it compounds with site count and entry-point-to-site distance.

## Decisions (locked with the operator)

- **Relay first, then tour.** Keep today's emplace-then-mine order; the vessel begins its
  site tour from the Lagrange point. Smallest change, mesh established early.
- **Smart backstop, not full ETA-driven recovery.** Keep the completion event as the primary
  signal; replace the blind timer with a state-driven reconcile that only stalls when a drone
  is genuinely stranded.
- **Command authority is not a concern.** The operator confirmed a vessel keeps command
  authority traveling to and resting at any location *within* a system, meshed or not. The
  mechanism itself is already proven in production: `emplace` **already** dispatches `.travel`
  to move the vessel to an in-system Lagrange point. No live probe required.
- **Tour order stays richest-first** (`nextBody`'s existing ranking). Distance-optimized
  routing within a system is explicitly out of scope.

---

## Part A — Vessel tours the sites

Insert one new step, **`positioning`**, between `configuring` and `launching`. The *vessel*,
not the drones, does the traveling.

New mining loop:

```
… → configuring → positioning → launching → awaiting → verifying → configuring → …
```

### `configuring` (changed: one line)
Unchanged in behavior — it resolves the richest live body (`nextBody`), and either confirms
the controller is already configured for it or dispatches `set_directive`
(`gather_salvage`, `{location: body, recall: true}`). Its **terminal `nextStep` changes from
`launching` to `positioning`** on both exits (the already-configured `advanceStep` and the
`dispatch`'s `nextStep`). Setting the directive does not deploy drones — `launch` does — so
configuring the controller before the vessel arrives is harmless.

### `positioning` (new step)
Flies the vessel to the body the controller was **just configured for**, resolved from
`workedBody(controller)` — the controller's own in-force `gather_salvage` `location`, the
server's record of the target. Deriving the destination from the controller (not a fresh
`nextBody`) guarantees the vessel's destination and the directive's `location` cannot disagree
if a body depletes mid-flight.

```
positioning(directive, vessel, world):
    controller = claimedController(...) else stall(.noMiningControllerAboard)
    guard let body = workedBody(controller) else advanceStep(.configuring)   // not configured yet — back up
    if vessel.location == body: advanceStep(.launching)                      // arrived — deploy locally
    if openOperation(for: vessel) != nil: wait                               // trip under way; guard second dispatch
    dispatch(.travel, vessel, destination: body, nextStep: .positioning)
```

`.travel` is a tracked op kind (creates an `Operation` row), so the `openOperation` guard
actually fires and the same-step re-dispatch is the safe shape
([[same-step-dispatch-needs-tracked-op]]) — identical to `emplace`'s vessel travel and
`restock`'s.

### Why this is uniform
- **Unmeshed target with relay:** `emplace → activate → confirmRelay → settle → configuring`
  leaves the vessel at the Lagrange point; `positioning` pulls it to body 1 from there.
- **Unmeshed target, no Lagrange point** (degraded-but-fine): `emplace` advances straight to
  `configuring`; `positioning` pulls the vessel from wherever it is.
- **Already-meshed target:** today `travel` drops it into `configuring` with the vessel still
  at the **entry point**, and the drones ferry from there — the worst case. `positioning` fixes
  this for free: the vessel is pulled to each body like any other target.
- **Body → body within a system:** `verify`'s "more bodies here" branch already routes back to
  `configuring`, which re-picks → re-configures → re-positions. One vessel tour of the system's
  sites, drones deploying locally at each.

Relay emplacement is untouched — it remains a one-time per-system setup ahead of the tour.

---

## Part B — Smart await backstop

Delete the blind `backstopInterval → verifying` advance. `awaitCompletion` gains the
`vessel` it needs (it currently takes only `directive`, `world`; `nextAction` already holds
`vessel`) and becomes state-driven.

```
awaitCompletion(directive, vessel, world):
    if completionSeen: advanceStep(.verifying)          // completion held until recall lands ⇒ drones home
    if emptyLaunchSeen: stall(.launchDeployedNothing)    // unchanged

    controller = claimedController(...) else wait        // transient stale row — a reconcile repairs it

    // Reconcile against fresh state. Deadline-then-staleness ordering per
    // [[confirm-steps-need-fresh-evidence]]: force a fresh read only when the row is stale,
    // and never let a failing read loop — the throttle is on the row's own updatedAt.
    if now - controller.updatedAt > reconcileInterval:
        refreshFleet(tag, thenStall: nil)                // one tag read: controller + drones + vessel

    // Fresh rows — judge recovery from them.
    stranded = adoptedDrones(of: controller, in: world)          // WIDE query, wherever they are
                 .filter { $0.stowedInDeviceCode != vessel.deviceCode }
    if stranded.isEmpty: advanceStep(.verifying)                 // dropped completion frame — proceed
    if controller.currentDirective == "gather_salvage": wait     // STILL MINING — no stall, no deadline
    // Controller idle, drones still out ⇒ post-mining recall (near-instant now the vessel sits at the body):
    if let arrival = recallArrival(stranded), arrival > now: wait     // wait out the farthest traveller's ETA
    if stranded.allSatisfy({ $0.activityDeadline == nil }):           // fresh read, yet none is travelling ⇒ lost
        stall(.dronesNotRecovered)
    refreshDevices(stranded.map(\.deviceCode), thenStall: nil)        // re-read the ones still flying
```

Key properties:

- **`controller.currentDirective == "gather_salvage"` is a *don't-stall-yet* gate, never a
  success signal.** Success is only ever `completionSeen` or a fresh read showing every drone
  aboard. So the design is robust to either interpretation of when the server clears
  `currentDirective` (at mining-done or at recall-done): if it clears early we fall through to
  the ETA-driven recall branch; if it never clears, the drones-aboard reconcile still exits.
  Worst case of an unreliable flag is "wait a little longer," never a false stall or a false
  success.
- **The genuine-stuck detector needs no durable timestamp.** A stranded drone that, *after a
  fresh read*, reports no travel block while the controller is idle is the real
  loss (the POLARISUM shape) — stall it. One with a travel block is en route — wait out
  `recallArrival` (reusing the `Device.activityDeadline` / farthest-ETA pattern SurveyRun's
  `recover` already uses; add a small `recallArrival` helper to SalvageRun mirroring it).
- **`verify` stops being a hard stall.** It is now reached only after recovery is established
  (completion, or a fresh drones-aboard read). If it nonetheless sees a stranded drone (a
  narrow race), it routes **back to `awaiting`** — the single owner of recovery logic — which
  converges (reconcile shows them home → `verify`) or stalls correctly. The `dronesNotRecovered`
  stall now lives in exactly one place.

New constant: `reconcileInterval` (~60 s, same scale as `relayPollInterval`). `backstopInterval`
becomes dead once the blind timed advance is removed, so it is deleted; `eventTimeSkewTolerance`
stays (it backs the issue-time-relative `completionSeen` / `emptyLaunchSeen` checks, which are
untouched).

Part A makes Part B's recall branch rarely exercised (drones deploy and recall locally at the
body, near-zero travel), but it remains the correct safety net for a genuinely lost drone.

---

## Out of scope

- Distance-optimized site ordering within a system (richest-first stays).
- Relay-last emplacement (rejected: larger reorder, mesh established late).
- Any change to `emplace` / `activate` / `confirmRelay` / relay tagging, the target planner,
  `restock`, or the Haul Run.

## Testing

`SalvageRunTests` is pure (`WorldSnapshot` in, `MissionAction` out) — every case below is a
table-style assertion with no I/O.

**Part A**
- `configuring` terminal `nextStep` is `positioning` (both the already-configured and the
  `set_directive` exits).
- `positioning`: vessel not at body → `dispatch(.travel, destination: workedBody)`; open op →
  `wait`; vessel at body → `advanceStep(.launching)`; controller not configured → back to
  `configuring`; no controller → `noMiningControllerAboard`.
- Already-meshed target: `travel` → `configuring` → `positioning` pulls the vessel off the
  entry point (regression guard for the ferry-from-entry case).
- Multi-body tour: `verify` next-body → `configuring` → `positioning` re-targets the next body.

**Part B**
- Controller still `gather_salvage`, drones out, **> 10 min** elapsed → `wait` (the core
  regression: no more false `dronesNotRecovered`).
- `completionSeen` → `verifying`.
- Fresh rows, all drones aboard, no completion event → `verifying` (dropped-frame path).
- Controller idle, a stranded drone with a live travel block → `wait` (ETA) then
  `refreshDevices`; with **no** travel block after a fresh read → `stall(.dronesNotRecovered)`
  (the real loss).
- Stale controller row → `refreshFleet(thenStall: nil)` before judging (fresh-evidence rule);
  throttled on `updatedAt` so a failing read does not loop.
- `verify` sees a stranded drone → routes back to `awaiting`, not a stall.
