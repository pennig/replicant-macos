---
name: travel-system-proxy-codes
description: A bare system designation in a travel payload is a PROXY for that system's entry point; one shared TravelSnapshot.itinerary rule now feeds all three travel surfaces.
metadata:
  node_type: memory
  type: reference
---

**A bare system designation in a travel payload is a proxy, not a location.** Telling a device to travel to `ASTELLIO` means "that system's entry point" — an L4 Lagrange point of one of its planets. The backend then names the destination BOTH ways in the same payload, and which one appears where varies by field. Confirmed from live data 2026-07-27:

| Source | `destination` | `final_destination` | route leg `to` |
|---|---|---|---|
| `travel` dispatch (vessel `F2908E6E`) | `ASTELLIO` | `ASTELLIO-1-L4` | `ASTELLIO-1-L4` |
| `travel.departed` event (surge plate) | `AINALRAM` | — | — |
| `travel.arrived` event (same plate) | `AINALRAM` | — | (`location`: `AINALRAM-1-L4`) |

Every real location code carries at least one hyphen (`SOL-3`, `SOL-BELT-1`, `SOL-3-L4`), so the absence of one is the whole discriminator.

**Why it bit:** `OrreryLayout.resolveExact` maps a code equal to `model.star.designation` to `center` — correct for a device *located* at a system (an out-of-range freighter at `MEREDIANA`), but it planted the star map's transit riser on the **sun** whenever a route leg still carried the proxy. The sidebar and device detail named the entry point correctly, so the same trip rendered two different destinations.

**The rule now (`GameModels/Sources/TravelItinerary.swift`):**

- `TravelSnapshot.itinerary(stored:live:)` — the whole route frozen at dispatch when it has legs, else the device's remaining-legs live block. Lifted out of `ActiveTaskCard`, where it used to live inline.
- `TravelSnapshot.resolvingSystemProxies` — replaces a proxy among the **leg endpoints** with the nearest specific code in the same system (ties downstream), then `final_destination`/`origin`. No match ⇒ the proxy survives; **never synthesize an entry point**. `origin`/`destination` are read as sources but never rewritten, so existing labels are undisturbed.

**All three travel surfaces read that one rule** — `NewStarMapView.ships`, `ActiveTaskCard.itinerary`, `SidebarProgress.row`. The map previously read only the live block; it now fetches `Operation` too, which also means it draws the **whole** route (completed legs included), so a multi-system ribbon bends through its real waypoints.

Related: the orrery transit callout now counts down to *this view's* boundary crossing (`enters in` / `leaves in`) rather than final arrival — `TransitBoundary.anchorIndex` + `Ship.Leg.endsAt`, with `Ship.legEndDates(seconds:arrivesAt:)` walking back from final arrival in the date domain. Legs are contiguous with no dwell, so arriving at a waypoint and leaving it are one instant; only the verb differs.

See [[travel-block-leg-vs-route]] for the timing fields and the stale-route trap, and [[new-star-map-feature]].
