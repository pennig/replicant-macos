---
name: haul-run-design
description: "Haul Run SHIPPED 2026-07-31. The engine issues NO collect/deposit at all — the AMI transport controller hauls server-side via `ferry`, so the run only picks which pile each auto:haul-tagged controller drains and issues one set_directive per repoint. Supersedes §6 of the salvage design, which had us hand-driving a freighter. Records the four live-fire defects the reviews caught and what deferred."
metadata:
  type: project
---

Spec: `docs/superpowers/specs/2026-07-31-haul-run-design.md`; plan:
`docs/superpowers/plans/2026-07-31-haul-run.md`. Merged to main 2026-07-31 as `30e234a`.
**Supersedes §6 of [[salvage-run-design]]**, which assumed our engine would hand-drive a
`cargo_freighter` through travel → collect → travel → deposit.

## The mechanism, and why it collapsed the feature

An `ami_transport_controller` already runs `ferry` — a continuous interstellar supply line — and the
docs are explicit: *"every tick, the controller reviews the available drones and the configured
directive, then issues the right sequence of collect and deposit commands."* Server-side, **no API
budget**. So the engine never issues a `collect_resources` or `deposit_resources`; it chooses the
target and issues one `set_directive`. About **one command per pile drained**, versus ~28 per rich
system for the superseded design.

Ferry's two constraints, both quoted from the docs, both load-bearing:
- *"Requires the two systems to be linked over the FTL network"* — which is exactly what the Salvage
  Run's planted relay provides. The coupling that made the two-directive split possible pays off twice.
- *"Cruise transports without their own surge drive will need a supply of surge plates tagged `taxi`
  at both ends"* — a `cargo_freighter` has `surge` and is exempt; a `transport_hauler` is not.

`shuttle` is the same directive within one system; a `ferry` whose ends share a system is malformed,
which is the only branch in the dispatch. `consolidate` was rejected: deliver-only and it would remove
the need to choose at all, but it is single-system by definition so it cannot reach salvage elsewhere.

**The one load-bearing unknown was settled by the operator, not inferred:** a `cargo_freighter` CAN be
adopted by an `ami_transport_controller` and does participate in `ferry` (`5187CFCF` observed
`depositing`). The docs only say a controller adopts "most other non-AMI devices", and our own
`DeviceCommand.controllableType` maps a transport controller to `transport_drone` — which is not even
the type the live controller commands. That mapping is a real, still-unfixed bug: the inspector's
adopt picker offers none of the `transport_hauler`s actually in the fleet.

## What it cost to build: nothing structural

No migration, no domain client, no table. `Directive.fleetTag`/`controllerCode` shipped with the
Salvage Run; `LocationFootprint` already persisted the whole stockpile census (`GET /v1/locations`
returns every location's total in ONE request — the per-resource `/inventory` breakdown is never
needed, because the controller decides what to load). The only new engine primitive is
`MissionAction.refreshFootprint`, modelled on `.refreshSystem`: best-effort I/O then a plain step move.

## Four live-fire defects the reviews caught, none catchable by unit tests

Every one lived in the seam between a tested function and the engine that calls it, and every one was
proven by *executing* a probe against the real engine rather than by inspection. All 20 original unit
tests passed through the first three.

1. **A two-controller wedge.** `confirm` polled the whole fleet but `assign` dispatched one controller,
   so it waited on a controller never dispatched, burned the deadline, stalled `.commandRejected`
   falsely, and could never haul again — with Retry a structural no-op.
2. **An unbounded `set_directive` loop.** The fix for (1) accepted "any haul config", so a controller
   whose local row lagged was re-pinned and re-dispatched every ~15s forever, and the deadline became
   structurally unreachable. Strictly worse than the bug it replaced.
3. **A budget that stalled a healthy fleet.** The re-entry bound counted per *pass*, not per controller,
   so a healthy 4-controller fleet false-stalled on its first pass. Fixed by threading the claimed
   device code through `DirectiveExecutor.entry` into `DirectiveLogEntry.deviceCode` — a field that
   existed and was always nil — so the count means what its doc claims. That in turn leaked step
   entries into the built-in row's History pane for Survey and Salvage Run too, because
   `DirectiveTimeline`'s device-keyed branch filtered on `deviceCode` alone.
4. **A repoint that re-commanded itself into a false stall.** See
   [[confirm-steps-need-fresh-evidence]] — the general lesson, and the one most likely to recur.

**Two vacuous regression tests** also shipped and were caught: they used piles in unmeshed systems,
which the planner filters out before the tested code sees them, so they passed against the broken
code. Since then every regression guard on this feature has had to be *demonstrated* failing against
the pre-fix commit — a guard nobody has seen fail is not a guard.

## Deliberately not built

- **Taxi-plate management** for cruise-only haulers (the live controller reads
  `blocked:[('no_taxi_plate', 1)]` today while its freighter hauls fine).
- **`priority` resources** on the ferry config — no need when the goal is "drain the pile".
- **Clearing a controller's directive on cancel.** Untagging is the operator's off-switch.
- **An "already running" guard on the launcher** — `NewSalvageRunFeature` has none either, but the
  tag-resolved fleet makes collision certain here rather than merely possible.
- **Bounding `WorldSnapshot`'s log read.** It fetches the directive's ENTIRE history every 5s tick and
  nothing prunes the table; a haul run writes ~4,300 entries/day. Cost, not correctness, but it grows.
- **Spec §6's "vanished from the footprint" drained rule is unreachable** — `LocationsClient` only
  upserts, never deletes, so a location leaving the census keeps its last-known value forever.
