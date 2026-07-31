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

Insert one new step, **`positioning`**, **ahead of** `configuring`. The *vessel*, not the
drones, does the traveling.

New mining loop:

```
[entry] → positioning → configuring → launching → awaiting → verifying → positioning → …
```

where `[entry]` is every step that used to hand into `configuring` (see the call-site list
below).

### Why positioning goes *before* configuring (and keys off `nextBody`, not `workedBody`)
`configure` re-issues `set_directive` on every body transition (body 1 never matches body 2),
and **nothing writes the controller's `currentDirectiveConfig` optimistically** — the
`ami_directive` block only reflects the new body once that command lands and the controller is
re-synced (confirmed: no production writer of that column). So a `positioning` step placed
*after* configure and keyed off `workedBody(controller)` would read the **stale previous body**
on every transition and mis-target the vessel. Putting `positioning` first and keying it off
the deterministic `nextBody(in:world:)` avoids the controller row entirely; `configure` then
runs **last**, at the body, dispatching `set_directive` for the same `nextBody` immediately
before `launch`. Server-side config and vessel location are established together, so `launch`
always deploys at the vessel's location. A body depleting mid-flight simply re-targets
`positioning` to the next-richest body — correct, not a divergence, because `configure` hasn't
issued anything yet.

### `positioning` (new step)
```
positioning(directive, vessel, world):
    switch nextBody(in: directive, world):
        case .finished:   advanceTarget                       // nothing live here — this target is done
        case .unresolved: unresolvedSystem(directive, world, target)   // blob not cached — bounded wait+read
        case .body(body):
            if vessel.location == body: advanceStep(.configuring)      // arrived — configure + launch locally
            if openOperation(for: vessel) != nil: wait                 // trip under way; guard the second dispatch
            dispatch(.travel, vessel, destination: body, nextStep: .positioning)
```

`.travel` is a tracked op kind (creates an `Operation` row), so the `openOperation` guard
actually fires and the same-step re-dispatch is the safe shape
([[same-step-dispatch-needs-tracked-op]]) — identical to `emplace`'s vessel travel and
`restock`'s. `positioning` inherits `configure`'s existing `.finished` / `.unresolved` handling
(`advanceTarget` / `unresolvedSystem`) verbatim, since it now owns the first look at the system.

### `configuring` (unchanged)
Still resolves `nextBody`, confirms-or-dispatches `set_directive`
(`gather_salvage`, `{location: body, recall: true}`), and hands to `launching`. Its terminal
`nextStep` stays `launching`. Its `.finished` / `.unresolved` branches remain as defensive
handling (now upstream-guarded by `positioning`).

### Call sites that change (`configuring` → `positioning`)
Every step that hands into the mining loop retargets its `nextStep` from `configuring` to
`positioning`:
- `travel` arrival, meshed arm (`advanceStep(meshed ? .configuring : .emplacing)`)
- `emplace`, the `currentTarget == nil` arm and the no-Lagrange-point arm
- `settle` (relay confirmed), both the `.setDeviceTags(nextStep:)` and `.advanceStep` exits
- `verify`, the "drones home, more bodies" arm (`advanceStep(.configuring)`)

### Why this is uniform
- **Unmeshed target with relay:** `emplace → activate → confirmRelay → settle → positioning`
  leaves the vessel at the Lagrange point; `positioning` pulls it to body 1 from there.
- **Unmeshed target, no Lagrange point** (degraded-but-fine): `emplace` advances straight to
  `positioning`; the vessel is pulled from wherever it is.
- **Already-meshed target:** today `travel` drops it into `configuring` with the vessel still
  at the **entry point**, and the drones ferry from there — the worst case. `positioning` fixes
  this for free.
- **Body → body within a system:** `verify`'s "more bodies here" arm routes to `positioning`,
  which re-targets the next body and flies the vessel there. One vessel tour of the system's
  sites, drones deploying locally at each.

Relay emplacement is untouched — it remains a one-time per-system setup ahead of the tour.

---

## Part B — Smart await backstop

The whole fix lives in `awaitCompletion`. **`verify` is unchanged**: once the blind backstop is
gone, `verify` is only ever reached when the drones are actually home (completion is held until
recall lands) or genuinely lost, so its existing single-refresh
`refreshFleet(thenStall: .dronesNotRecovered)` stays correct and remains the *one* place that
raises that stall. `awaitCompletion`'s job is narrowed: **wait until mining is done, then hand
to `verify` — never stall on its own.**

Delete the blind `backstopInterval → verifying` advance. `awaitCompletion` gains the `vessel`
it needs (it currently takes only `directive`, `world`; `nextAction` already holds `vessel`)
and becomes state-driven:

```
awaitCompletion(directive, vessel, world):
    if completionSeen: advanceStep(.verifying)           // completion held until recall lands ⇒ drones home
    if emptyLaunchSeen: stall(.launchDeployedNothing)     // unchanged

    controller = claimedController(...) else wait         // transient stale row — a reconcile repairs it
    drones   = adoptedDrones(of: controller, in: world)   // WIDE query, wherever they are
    lastLook = drones.map(\.updatedAt).min() ?? .distantPast   // the DRONE rows only, and the OLDEST of them
    canRead  = now - lastLook >= reconcileInterval        // throttle: at most one read per interval

    // Fresh-evidence rule [[confirm-steps-need-fresh-evidence]]: never trust a drone row read
    // BEFORE launch (it still shows the drone stowed aboard from when it was staged). Key the
    // gate off the DRONES via min(), not off max([controller]+drones): AMI drones are
    // event-silent [[ami-drones-are-event-silent]] while the controller churns via its
    // `ami.*.digest`, so a fresh controller would otherwise vouch for a stale drone and read a
    // still-deployed fleet as recovered. Same shape as `SurveyRun.recover`. Read when the
    // throttle allows; the throttle is what stops a failing read looping every tick.
    if lastLook < directive.stepStartedAt: return canRead ? refreshFleet(tag, thenStall: nil) : wait

    stranded = drones.filter { $0.stowedInDeviceCode != vessel.deviceCode }
    if stranded.isEmpty: advanceStep(.verifying)                        // dropped completion frame — proceed
    if controller.currentDirective == "gather_salvage":                // STILL MINING — no stall, ever
        return canRead ? refreshFleet(tag, thenStall: nil) : wait       // periodic reconcile to catch completion
    // Controller idle, drones still out ⇒ post-mining recall (near-instant now the vessel sits at the body):
    if stranded.contains(where: { $0.activityDeadline != nil }):        // someone still flying home
        if let arrival = recallArrival(stranded), arrival > now: return wait   // wait out the farthest ETA
        return canRead ? refreshDevices(stranded.map(\.deviceCode), thenStall: nil) : wait
    advanceStep(.verifying)                                             // none flying, none aboard ⇒ let verify judge+stall
```

Key properties:

- **The still-mining gate is what kills the false stall.** `controller.currentDirective ==
  "gather_salvage"` means drones are out *by design* — the run waits (reconciling on the
  `reconcileInterval` cadence), never stalls, however long the cycle runs.
- **`currentDirective` is a *don't-stall-yet* gate, never a success signal.** Success is only
  ever `completionSeen` or a fresh read showing every drone aboard. So the design is robust to
  either interpretation of when the server clears the flag: if it clears at mining-done we fall
  to the recall branch; if it never clears, the drones-aboard reconcile still exits. Worst case
  of an unreliable flag is "wait a little longer."
- **`awaitCompletion` never stalls; `verify` owns `dronesNotRecovered`.** await hands to
  `verify` only when the drones aren't actively travelling (all aboard, or mining done with none
  en route). `verify` then does its one authoritative refresh and stalls only if the drones are
  genuinely stranded — the POLARISUM shape. Part A (vessel at the body) makes recall near-zero,
  so the recall branch is nearly vestigial, but it keeps a straggler mid-hop from ever reaching
  `verify`'s single-read stall prematurely.
- **`recallArrival`** is a small helper added to `SalvageRun`, mirroring SurveyRun's
  (`stranded.compactMap(\.activityDeadline).max()`).

New constant: `reconcileInterval` (2 min — long enough to keep steady-state mining reads cheap,
short enough to catch a dropped completion promptly). `backstopInterval` becomes dead once the
blind timed advance is removed, so it is deleted; `eventTimeSkewTolerance` stays (it backs the
issue-time-relative `completionSeen` / `emptyLaunchSeen` checks, which are untouched).

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

A fixture extension is needed: the `SalvageRunTests` `device()` helper has no travel-block
support, so add an `arrivesAt:` parameter (mirroring `SurveyRunTests`) that writes a `travel`
block (`arrives_at` / `final_arrives_at`) so a drone can report an `activityDeadline`.

**Part A**
- Existing entry-point transitions flip `configuring` → `positioning`: `travel` meshed arm;
  `emplace` no-Lagrange arm; `confirmRelay`/`settle` (relay-up, untag, preserve-other-tags,
  own-fleet-tag, already-untagged, parameterised-status); `verify` "more bodies" arm; and the
  loop-progress "different next body" / "no worked body" arms. Update each assertion.
- `configure` tests are **unchanged** (its terminal `nextStep` stays `launching`).
- New `positioning`: `.body`, vessel not at it → `dispatch(.travel, destination: nextBody)`;
  open op → `wait`; vessel at it → `advanceStep(.configuring)`; `.finished` → `advanceTarget`;
  `.unresolved` (uncached blob) → `wait`, then the one-read backstop past
  `systemResolutionDeadline`.
- Already-meshed regression: `travel` → `positioning` dispatches vessel travel off the entry
  point (guards the ferry-from-entry case).

**Part B** (`verify` untouched — its tests stay green as-is)
- Controller still `gather_salvage`, a drone deployed, rows fresh, **> 10 min** elapsed →
  `wait` (the core regression: no more false `dronesNotRecovered`).
- `completionSeen` → `verifying`; `emptyLaunchSeen` → `stall(.launchDeployedNothing)`.
- Fresh-since-launch rows, all drones aboard, no completion → `verifying` (dropped-frame path).
- Rows stale-since-launch (`updatedAt < stepStartedAt`) and older than `reconcileInterval` →
  `refreshFleet(thenStall: nil)`; stale-since-launch but read within `reconcileInterval` →
  `wait` (throttle guard against a read loop).
- Controller idle, a straggler with a live travel block and a future ETA → `wait`; idle with a
  stranded drone showing no travel block → `advanceStep(.verifying)` (hand off; `verify` refreshes
  and raises `dronesNotRecovered` if the fresh read agrees).
