# Relay Run return leg + demand-driven restock (SHIPPED 2026-08-04)

Spec: `docs/superpowers/specs/2026-08-04-relay-return-and-restock-design.md`.
Closes the two manual steps between the brain and an unattended mesh, both
recorded as known limitations in [brain-tendmesh-build](brain-tendmesh-build.md).

## What shipped

- **`RelayRun.Step.returning`** — entered from `settling` when the run carries
  `returnToOrigin`, which `Brain.launch` now sets true. Reuses the outbound
  leg's shape (open-op guard + `travelPositionUnconfirmed`) rather than
  inventing a deadline.
- **`RestockRun`** — a new `restockRun` directive kind, two steps
  (`stocking` → `printing` → back), owned by the HUB device and persistent.
  `idleCap = 10`. Demand is written onto the row's `targets` by
  `Brain.tendRestock`; `desiredIdle = min(10, targets.count)`.
- **`RelayRun.hubLocation(in: WorldSnapshot)`** — the one recognition rule,
  adapted for missions from `WorldView.hubLocation`. Pinned by
  `HubRecognitionSeamTests`.

## The one thing that will bite you

**The return destination is the hub LOCATION, re-derived every time — never
`directive.originDesignation`.** That field is `SiteAssay.system(of: hub)`, a
lossy projection: `AINALRAM` where the hub is `AINALRAM-BELT-1`. A bare system
designation travels to that system's ENTRY POINT, an L4
([travel-system-proxy-codes](travel-system-proxy-codes.md)), so a run using the
remembered field brings the carrier back to the right system and still leaves it
un-co-located with the printer — and `Brain.freeCarrier` demands an exact
location match. The manual step would move rather than disappear, and **every
other assertion in the e2e still passes** when you get this wrong. Verified by
mutation: swapping in `originDesignation` fails exactly three tests.

Re-deriving also means the carrier follows the hub if the hub ever moves, and it
guarantees the place a run flies home to and the place the next run launches from
cannot drift apart.

## Restock only prints opportunistically, and the reason is NOT in restock

`RestockRun.stocking` waits when `RelayRun.footprintCensusIsStale` — the
table-wide `LocationFootprint.fetchedAt` gate, bound at `pollInterval` (60s).
Its doc says waiting is fine because "the census refreshes on its own cadence".

**There is no such cadence.** `LocationsClient.refreshFootprint()` has exactly
two production callers: `DirectiveEngine`'s resolver for a mission's
`.refreshFootprint` action (`RelayRun.acquire`, `HaulRun.survey`), and the
Locations catalog screen when a human opens it. Nothing polls it. So restock can
only print inside the ≤60s window following another mission's census refresh —
it is opportunistic, not continuous, which is weaker than the spec's stated goal
("the printer should run continuously while there is unmet demand").

Demonstrated in `BrainGrowLifecycleE2ETests`' world: restock is created on tick
1 with real demand and correctly waits on an open print op, then the census goes
stale at t=65s and it never prints across 90 ticks. Every individual decision is
correct; the composite is inert.

Not fixed here — it is an implementation change beyond the e2e, and the options
have a real trade. Either restock buys its own refresh (`.refreshFootprint`,
bounded one-per-kind by `reAsk`'s `paid` set, mirroring `acquire`) at the cost of
API reads for a top-up nothing is waiting on, or something polls the footprint
table on a cadence. **Do not "fix" it by widening restock's own freshness bound**
— with no refresher the census goes stale forever regardless, so that only moves
the dead line from 60s to 300s.

## Testing

- `BrainGrowLifecycleE2ETests` — the loop closing end to end. The headline now
  runs 36 ticks (first run home at 32, next target launched at 33);
  `theNextGrowGoesToTheNextCandidateNotTheMeshedOne` runs 80 and meshes BOTH
  candidates on one carrier with **no `server.place` call anywhere** — the
  absence of the hand-fly is the point of that test now. `seedGrowWorld` seeds an
  entry point for the runner-up too, or the second run parks in `emplacing`
  re-asking for a system nothing answers for.
- `RelayReturnAndRestockTests` — 19 unit cases over the return leg, restock's
  seven declining branches (every one `.wait`, never `.stall`), and the hub seam.
- The driver in the e2e evaluates EVERY running directive, not just relay runs —
  restock is a running directive the brain writes, and a driver filtering on
  `.relayRun` leaves the printer inert in the test and nowhere else.
- `aTransientConfirmFailureDefersEveryTickAndWritesNothingUntilItClears` had to
  be narrowed: a deferred tick launches no run and gives the unconfirmed carrier
  no orders, but restock's prints DO go out. That decoupling is the feature —
  a carrier the API cannot confirm is exactly when you want spares already made.
