# Orrery travel indicators: view-relative countdowns + one route source

Date: 2026-07-27

## Problem

The orrery's inbound/outbound transit callouts (`TransitCalloutLayer`, fed by
`SystemTransit` + `TransitProjection`) have two defects.

**1. The countdown answers the wrong question.** Each card shows `arrives in …`,
counting down to `ship.arrivesAt` — the *whole trip's* final arrival. What the
card is actually marking is a boundary crossing of the view you are looking at,
so the useful number is when the device enters (or leaves) *this* view, not when
it finishes its journey several legs later.

**2. A route to a bare system designation plants the riser on the sun.** Telling
a device to travel to `ASTELLIO` — a proxy for that system's entry point,
`ASTELLIO-1-L4` — produced an indicator anchored on the star, while the active
replicant sidebar and the device detail both correctly named the entry point.

### Root cause of (2)

Two independent causes compound.

**(a) Divergent route sources.** `NewStarMapView.ships` builds from
`device.travelSnapshot` alone — the live `travel` block, which lists only the
*remaining* legs and is observed to go stale (a surge plate reports
`route_progress_percent: 100` and a three-day-old `final_arrives_at` beside a
live leg; see `.claude/memory/travel-block-leg-vs-route.md`). Meanwhile
`ActiveTaskCard` and `SidebarProgress` prefer `operation.travelSnapshot` — the
whole route frozen at dispatch, which carries resolved location codes. Three
surfaces, two sources: the mismatch is structural, not a one-off.

**(b) Bare system codes resolve to the star.** `OrreryLayout.resolveExact`
returns `center` when a code equals `model.star.designation`. That is correct for
a device *located* at a system (e.g. an out-of-range freighter at `MEREDIANA`),
but a travel route code of `ASTELLIO` is a *proxy* for the entry point, and
resolving it to the centre plants the riser on the sun.

Confirmed against live data (device DB + `eventLogs` + a dispatch response):

| Payload | destination | final_destination | route leg `to` |
|---|---|---|---|
| `travel` dispatch, F2908E6E | `ASTELLIO` | `ASTELLIO-1-L4` | `ASTELLIO-1-L4` |
| `travel.departed` event, surge plate | `AINALRAM` | — | — |
| `travel.arrived` event, same plate | `AINALRAM` | — | (`location`: `AINALRAM-1-L4`) |

The backend speaks in bare system codes at the *destination* level and resolved
codes at the *leg* level, and does not always emit both.

## Design

### Part 1 — One shared itinerary

Two additions to `GameModels`, beside `TravelSnapshot`:

```swift
/// The itinerary to display: the whole route frozen at dispatch when we have it,
/// else the device's remaining-legs live block.
static func itinerary(stored: TravelSnapshot?, live: TravelSnapshot?) -> TravelSnapshot?

/// Replace bare-system proxy codes with the specific location this same itinerary
/// already names for that system.
var resolvingSystemProxies: TravelSnapshot
```

`itinerary` lifts the rule already written inline in `ActiveTaskCard.itinerary`:
prefer `stored` when it has legs, else `live`.

`resolvingSystemProxies` substitutes only codes the payload itself supplies. A
code is a *proxy* when it contains no hyphen (a bare system designation). For
each proxy, the substitute is the nearest code in the same system, searched in
this order:

1. Nearest-in-route: walk the leg endpoint sequence outward from the proxy's own
   position by increasing distance, taking the first specific code whose system
   matches. Ties (equidistant either side) prefer the downstream code.
2. `final_destination`, then `origin`, if either is in that system.
3. No match ⇒ the bare code is left alone (never invent an entry point).

Scanning outward rather than taking a global per-system map keeps a route that
visits one system twice deterministic and correct at each visit.

All three surfaces then read the same derivation:

- `NewStarMapView.ships` — gains an `@FetchAll` over `Operation`, matching the
  device's open op (the `operation_one_open_per_device` unique index guarantees
  at most one, so the match is unambiguous).
- `ActiveTaskCard.itinerary` — replaces its inline rule with the shared call.
- `SidebarProgress.row` — replaces its `??` chain with the shared call.

**Accepted consequence (confirmed desired).** The map now draws the *whole*
route, including completed legs, where today it draws only the remaining ones.
Ship position stays correct — `Ship.activeLeg` picks by time — and the galaxy
ribbon improves: a three-system trip bends through its real waypoints instead of
cutting straight from origin to destination.

### Part 2 — View-relative countdown

Per-leg wall-clock times, derived exactly as the renderer already derives
media-time: anchor the last leg at final arrival and walk backwards, subtracting
each leg's `time_seconds`.

- `Ship.Leg` gains `endsAt: Date`; `Ship` gains `departedAt: Date`.
- The walk-back lives in a pure helper (not inline in the renderer's buffer
  build) so it is unit-testable on its own.
- `TransitBoundary` gains `anchorIndex: Int` — the anchor's position in
  `orderedCodes`, which is what lets a boundary name a leg. `orderedCodes[i]` is
  the route start at `i == 0` and `legs[i - 1]`'s destination otherwise.
- The boundary's event date is simply **when the device is at the anchor**:
  `legs[anchorIndex - 1].endsAt`, or `departedAt` when `anchorIndex == 0`.

  Inbound and outbound share one computation. Legs in this model are contiguous
  with zero dwell (`end_j == start_{j+1}`), so arriving at a waypoint and
  departing it are the same instant; only the verb differs. That instant is the
  right number for both cases:

  - **inbound** — the ship's icon appears in this view when its first in-view
    leg begins, i.e. at the anchor's timestamp.
  - **outbound** — the ship's icon vanishes when it starts the leg *out* of the
    view, because `Ship.orreryPosition` requires both leg endpoints to resolve
    in the layer and the downstream one does not. Same timestamp.

  An outbound anchor at index 0 (the route's origin is the only in-view code)
  yields `departedAt`, which is already past for any in-flight device — so the
  line hides, correctly: it has already left.
- `ProjectedTransit.arrivesAt` becomes `eventAt: Date`.
- `TransitCard` renders **`enters in`** (inbound) / **`leaves in`** (outbound)
  and hides the line once the date is past. The final-arrival line is dropped —
  it remains available on the device detail's Active Task card and the sidebar
  progress bar.

### Part 3 — Tests

Pure-layer only; no GPU, no clock.

- `SystemTransitTests` — `anchorIndex` across inbound, outbound, and
  pass-through (two boundaries) routes.
- New `TravelSnapshotTests` (GameModels) — `itinerary` preference (stored with
  legs wins; stored without legs falls back; both nil); `resolvingSystemProxies`
  over the real `ASTELLIO` and surge-plate `AINALRAM` payloads, a route with no
  specific code to substitute (bare code preserved), and a route visiting one
  system twice.
- Leg-date walk-back helper — direct unit test of the backwards accumulation,
  including a leg missing `time_seconds` (falls back to no per-leg dates, as the
  renderer already does for media-time).
- Orrery-level — a route whose destination is a bare system anchors its riser at
  the entry point rather than the star.

## Out of scope

- Changing `OrreryLayout.resolveExact`'s star fallback. It is correct for device
  *placement* (a device located at a system centre); only travel route codes are
  proxies, and those are normalized upstream in `resolvingSystemProxies`.
- Inferring a system's entry point when the payload names none. If the backend
  gives us only `AINALRAM`, the bare code survives and the riser sits at the
  star — the honest rendering of what we know.
- The galaxy view, which draws ships directly and has no transit callouts.

## Delivery

Committed to local `main` — no PR, no push (standing preference).
