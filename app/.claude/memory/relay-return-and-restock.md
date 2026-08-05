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

## Restock buys its own census read, and it HAS to

`RestockRun.stocking` gates on `RelayRun.footprintCensusIsStale` — the
table-wide `LocationFootprint.fetchedAt` gate, bound at `pollInterval` (60s).

The first cut WAITED there, reasoning that no carrier is standing by for the
answer and "the census refreshes on its own cadence". **There is no such
cadence.** `LocationsClient.refreshFootprint()` has exactly two production
callers: `DirectiveEngine`'s resolver for a mission's `.refreshFootprint` action
(`RelayRun.acquire`, `HaulRun.survey`), and the Locations catalog screen when a
human opens it. Nothing polls it. So restock could only print inside the ≤60s
window following some other mission's refresh — every individual decision
correct, the whole run inert. Caught by the e2e once its driver started
evaluating non-`relayRun` rows: restock was created on tick 1 with real demand,
correctly waited on an open print op, then the census went stale at t=65s and it
never printed across 90 ticks.

**Fixed by having it buy the read** — `.refreshFootprint(nextStep: .stocking,
thenStall: nil)`. Four things make that safe, and all four are load-bearing:

1. **Placement.** The read is bought only AFTER unmet demand, a pool below it,
   and no-print-in-flight have all said this run wants to print. Cost tracks
   wanting stock, not existing, so a converged fleet spends nothing.
2. **`reAsk`'s `paid: Set<RefreshKind>`** allows at most one footprint round per
   evaluation.
3. **The gate is TABLE-WIDE.** One successful refresh satisfies it for a whole
   `pollInterval`, and a refresh that succeeds while still not listing the hub is
   POSITIVE EVIDENCE — it falls through to `printStockIsShort`, which fails
   closed. This is why the step may name itself as `nextStep` without the
   unbounded self-loop that `brain-relay-reserve-floor` round 2 had to remove;
   that loop existed because the gate was then PER-LOCATION.
4. **`thenStall: nil`**, because restock must never escalate a top-up nobody is
   waiting on. The cost of that choice, stated plainly: a persistently FAILING
   refresh spends one census read per tick while demand is unmet — the same
   documented ceiling `Brain.confirmCarrier` carries, for the same reason (the
   alternative is remembering the refusal, which is state between ticks).

**Do not "fix" a future staleness complaint by widening restock's freshness
bound** — with nothing polling the table the census goes stale forever
regardless, so that only moves the dead line from 60s to 300s.

## `RestockRun.idleCap` = 10 — the arithmetic

Hand-tuned at build time; the calibration lived only in the source comment on the
constant, and is recorded here so a re-calibration has somewhere to start. The
comment now carries only the *rule* (it is a capital ceiling, not a throughput
throttle); the *number* is this:

**It is a ceiling on capital sitting in inventory rather than held as reserve.**
A relay is **370 units across six types** (`carbon 20, silicates 100,
structural 80, rares 40, conductive 120, volatiles 10` — 370 TOTAL, never per
type; see [[brain-relay-reserve-floor]]), so ten idle relays is **3,700 units
parked** in a pool nobody is flying yet.

**It is not a throttle on throughput, and must not be re-tuned as if it were.**
Two other limits bind first, in this order:

1. **Demand** — `desiredIdle = min(idleCap, directive.targets.count)`, and the
   brain writes `targets` from live grow demand, so on today's world the target
   count is the binding term and the cap is slack.
2. **The reserve floor** — `RelayRun.printStockIsShort` vetoes against
   `BrainCeiling.aggregateSpendFloor` (35,078, ~47% of live hub stock), which
   fires long before 3,700 units of parked stock is the fleet's problem.

So the cap exists for one case only: a world with dozens of reachable grow
targets, where demand would otherwise turn the whole stockpile into relays
ahead of any carrier able to fly them. If the relay bill or the reserve floor
moves materially, re-derive from the units-parked side, not from throughput.

Proven at the engine, not just on the pure function (`RestockEngineTests`), for
the reason round 4 records: the last bug of this shape was in the engine's
re-ask collapse rather than in any machine, and every `RelayRun` test at the time
was a pure-function table.

## Testing

- `BrainGrowLifecycleE2ETests` — the loop closing end to end. The headline now
  runs 36 ticks (first run home at 32, next target launched at 33);
  `theNextGrowGoesToTheNextCandidateNotTheMeshedOne` runs 80 and meshes BOTH
  candidates on one carrier with **no `server.place` call anywhere** — the
  absence of the hand-fly is the point of that test now. `seedGrowWorld` seeds an
  entry point for the runner-up too, or the second run parks in `emplacing`
  re-asking for a system nothing answers for.
- `RelayReturnAndRestockTests` — 26 cases over the return leg, restock's
  declining branches (every one `.wait`, never `.stall`), the hub seam, and
  `RestockEngineTests` driving the census refresh through the real
  `DirectiveEngineCore`.
- In the e2e the payoff is visible as an ABSENCE: the second grow's command
  sequence contains a `stow` and no `print`, because restock made that spare
  while the first run was still in flight. Two prints total for two relays.
- The driver in the e2e evaluates EVERY running directive, not just relay runs —
  restock is a running directive the brain writes, and a driver filtering on
  `.relayRun` leaves the printer inert in the test and nowhere else.
- `aTransientConfirmFailureDefersEveryTickAndWritesNothingUntilItClears` had to
  be narrowed: a deferred tick launches no run and gives the unconfirmed carrier
  no orders, but restock's prints DO go out. That decoupling is the feature —
  a carrier the API cannot confirm is exactly when you want spares already made.
