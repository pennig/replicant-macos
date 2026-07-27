---
name: travel-block-leg-vs-route
description: Device travel block has per-leg vs whole-route timing fields; device_travel_arrived completes the trip.
metadata: 
  node_type: memory
  type: reference
  originSessionId: 528a07f7-fb0a-46bd-9d20-3e4c1afc337a
---

The in-transit device `travel` block (in `detail`) carries TWO parallel sets of timing fields — confirmed from live payloads, not in the docs/openapi spec:

- Per **active leg**: `arrives_at`, `eta_seconds`, `progress_percent`, `destination` (current leg's target).
- Whole **route**: `final_arrives_at`, `route_eta_seconds`, `route_progress_percent`, `final_destination`.

On a multi-leg route the per-leg `arrives_at` is much sooner than the route's `final_arrives_at`. Prefer the **route-level** fields for an op's deadline/progress, or the trip ends a leg early. `started_at` is absent on travel — the block uses `departed_at`.

**BUT the route fields go stale, and a naive "route always wins" is a bug** (fixed 2026-07-27). A **surge plate** mid-hop reports a live leg alongside route fields left over from a journey it already finished — read off `DC2209EF`:

```
"arrives_at":       "2026-07-26T23:50:11-05:00"   // live leg, 45%, eta 86.7s
"final_arrives_at": "2026-07-23T21:11:01-05:00"   // THREE DAYS in the past
"route_eta_seconds": 0, "route_progress_percent": 100
```

Every travel op these plates produced was therefore stamped ~3 days overdue at birth, and `DeadlineScheduler` — which measures its give-up window from `completesAt`, not from dispatch — marked each `unknown` on its very first pass after spending one `.high` confirm-read. **215 bogus `unknown` ops across five plates in two days**, quietly draining the reads budget that `.low` staging refreshes depend on. The user-visible symptom is the log line `op …: still busy 268370s past its deadline with no fresh ETA — marking unknown`.

The rule is **the later of the two**, since a leg cannot outlast the route containing it: multi-leg behaviour is unchanged, and only impossible values are discarded. One shared `Device.travelDeadline(routeEnd:legEnd:)` serves all three sites (`activityDeadline`, `derivedActivity`, `CommandClient.parseDeadline`) — don't reintroduce the preference at a call site.

Relay arrival events (no arrival event type reliably means "trip done"):
- `device_cruise_arrived` / `device_surge_hop_arrived` fire **once per leg** — drive a confirm-read only, never complete a travel op on them.
- `device_travel_arrived` fires at the final destination of a **multi-leg/interstellar** route (payload has `location`, `star`, `from_star`) — but a **simple single-leg** trip emits ONLY `device_cruise_arrived`, no `device_travel_arrived`. So it's kept in `Reconciler.completionEventTypes` only as a snappy fast-path, not the primary signal.

Primary travel completion is **settle-based**: `Reconciler.ingest` closes an open deadline-bearing op (`completesAt != nil`) when the confirm-read shows the device settled (idle/stowed/inactive) — mirrors `DeadlineScheduler`'s `isSettled → complete`, but on the read. Handles single-leg, multi-leg, and early arrivals (server beating its own ETA). Continuous mining (no deadline) and site-tracking search are untouched.

Because `ingest` now always queries the `operations` table, any test DB driving ingest must register BOTH `Device` and `Operation` migrations.

Fixed in `CommandClient.parseDeadline`, `Device.activityDeadline`, `Device.derivedActivity`, `Reconciler.ingest` (settle path) + `completionEventTypes`. See [[device-command-shapes]], [[openapi-spec-drift-leniency]], [[running-package-tests]].
