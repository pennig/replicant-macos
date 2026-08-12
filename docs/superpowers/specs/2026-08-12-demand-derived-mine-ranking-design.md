# Demand-derived mine-site ranking

**Date:** 2026-08-12
**Status:** Approved (approach B of three considered)
**Modules:** `DirectiveEngine`, `GameServices`, `GameDatabase` (one migration), `GameModels` (read-only consumers)

## Problem

`MineSitePlanner.scarceBonus` ranks candidate belts for a new permanent mine with
fixed constants: rares ≥ moderate scores +2, conductive ≥ moderate scores +1,
everything else nothing. The constants were calibrated once and cannot follow
demand as it shifts.

Measured 2026-08-12 against the live account:

- **Collections to date** (`haulYields` ledger): structural 40,779 · conductive
  16,048 · silicates 9,543 · carbon 5,801 · rares 4,805 · volatiles 1,239.
- **Hub stock** (`GET locations/AINALRAM-BELT-1`): structural 78,590 · carbon
  21,398 · conductive 19,161 · silicates 12,777 · rares 10,917 · volatiles 6,538.
- **Active location-event demand** (47 events, each priced at its cheapest
  option, requested devices translated through blueprint bills): conductive
  4,450 · silicates 4,140 · structural 3,890 · carbon 2,950 · rares 950 ·
  volatiles 590.

Coverage (stock ÷ event demand): silicates 3.1× and conductive 4.3× bind;
volatiles, the smallest pile, has 11.1×. The recurring print bills (`BrainCeiling.relayBill`
and the wider blueprint catalog) skew the same way. The ranking's blind spot is
therefore **silicates** — nearest its floor on both demand mixes and worth
nothing in today's bonus — while "volatiles last in collections" is the system
responding correctly to demand.

An intended near-term consumer raises the stakes: directives that fulfill
location events will draw down exactly the types events request, and the demand
arithmetic they need to pick options is the same arithmetic this ranking needs.

## Goals

1. Re-aim the mine-site scarcity bonus at whichever resource types have the
   least **headroom** — stock ÷ demand — derived per tick, not tuned by hand.
2. Land the per-type stockpile record that `brain-resource-hub-model` deferred,
   as the stock half of that ratio.
3. Shape the demand calculator so the future event-fulfillment goal consumes it
   unchanged (per-event priced options, not just an aggregate).

## Non-goals

- Event-fulfillment directives themselves (option picking, stock reservation,
  delivery planning) — approach C, its own effort. This design leaves it a
  clean consumer.
- Any change to `GrowRanking` / tendMesh belt tiers. Mesh growth wants
  reachable value, not type balance.
- Any change to `MineSitePlanner`'s lexicographic order (`class → bonus →
  distance → designation`) or to the class-first term.
- Wiring `RelayRun.printStockIsShort` to the true per-type
  `BrainCeiling.printPermitted`. The new stock record is the prerequisite that
  was missing, but the rewire is a separate change with its own test surface.

## Components

### 1. `ResourceDemand` — pure calculator (DirectiveEngine)

Pure by contract, like every mission primitive: no I/O, no clock.

**Inputs:**
- Active `LocationEvent` rows, options decoded through the existing
  `LocationEventDetail.quest` accessor.
- Blueprint bills: `[String: ResourceCost]` keyed by device type, read from the
  persisted `Blueprint` table.
- `BrainCeiling.reserveFloors` as the recurring-print demand proxy.

**Per-event pricing:** each `Option` is priced as its **unmet remainder** —
`max(0, required − current)` on each resource line, plus `count − current`
still-missing devices each priced at its `Blueprint.resources` bill. An option
requesting a device type with no blueprint is unfulfillable by this account and
is skipped; an event whose every option is unpriceable contributes nothing. The
event contributes its cheapest priceable option, cheapest = smallest total
priced units.

**Outputs:**
- `total: [String: Double]` — per-type demand: Σ cheapest options + reserve
  floors.
- Per-event priced options (event designation → `[PricedOption]`), retained for
  the fulfillment goal. Not consumed by anything else in this design.

**Decisions:**
- Demand counts **all** active events, meshed or not. Fulfillment will drive
  mesh growth toward them anyway, and excluding unreachable demand would
  re-create the volatiles blind spot in reverse.
- Device progress (`current`) is trusted as delivered; no attempt to verify
  device presence — that is fulfillment's concern.

### 2. `locationInventories` — the per-type stockpile record

The "small additive per-type stockpile record beyond totals-only
`LocationFootprint`" that `brain-resource-hub-model` specified and deferred.

**Schema (append-only migration to `GameDatabase.manifest`):**

```sql
CREATE TABLE "locationInventories" (
  "location"     TEXT NOT NULL,
  "resourceType" TEXT NOT NULL,
  "quantity"     REAL NOT NULL DEFAULT 0,
  "fetchedAt"    TEXT NOT NULL,
  PRIMARY KEY ("location", "resourceType")
) STRICT;
```

**Write discipline:** wholesale replace per location — delete the location's
rows, insert the fresh reading, one transaction — so an emptied type disappears
rather than lingering. Stamped `fetchedAt` per row.

**Writers:**
- `LocationsClient.inventory(at:)` and the body-hydrate paths that already
  fetch per-type inventory persist what they fetched (today it is read and
  discarded).
- One deliberate owner: an hourly **depot-inventory refresh** alongside the
  retention sweeps on `DeadlineScheduler.run()` — one
  `GET locations/{designation}` per operational theatre depot per hour,
  budget-gated like the Logistics `.high` read (degrades to skipped under
  pressure, never blocks).

`SchemaManifestTests` gains the identifier; `GoldenSchemaTests` regenerated
with `RC_REGENERATE_SCHEMA_FIXTURE=1` (intended change).

### 3. `WorldView.theatreStock`

`WorldView` gains:

- `theatreStock: [String: Double]` — per-type quantities summed over the
  depot locations of operational theatres.
- `theatreStockFreshness: Date?` — the oldest `fetchedAt` among the depot rows
  read (nil when no depot has a reading).

Read as a plain column select over `locationInventories` joined against the
recognised depot designations — no blob decode, consistent with the
`json_each` projection discipline.

### 4. `MineSitePlanner` — re-aimed bonus

`scarceBonus(richness:)` becomes `scarceBonus(richness:weights:)`:

- `weights: [String: Int]` — resource type → bonus points. The same two-slot
  shape as today: the type with the **least headroom** scores +2, the second
  +1, applied when the belt's richness in that type is ≥ moderate
  (`atLeastModerate`, unchanged).
- Headroom per type = `theatreStock[type] ÷ demand.total[type]`, demand from
  `ResourceDemand`. Types with zero demand rank last (infinite headroom).
- **Fallback:** when `theatreStock` is empty or `theatreStockFreshness` is
  older than 24 h, weights fall back to the current constants
  (`["rares": 2, "conductive": 1]`). Degraded behaviour is exactly the shipped
  static ranking, never worse.

`Candidate` carries the applied weights and the headroom figures behind them,
so the why-view can render *"boosting silicates (3.1× covered), conductive
(4.3×)"* rather than a bare score. The sort in `site(view:occupiedBelts:)` is
untouched.

`Brain`'s mine path derives the weights per tick from `WorldView` — stateless
between ticks, like every other brain input.

### 5. Data flow

```
locationEvents ─┐
Blueprint bills ─┼→ ResourceDemand.total ─┐
reserveFloors ──┘                         ├→ headroom → weights ─→ MineSitePlanner
locationInventories → WorldView.theatreStock ┘                        ↓
                                                              Candidate (+why-view terms)
```

## Error handling

- Unknown/stale stock → static-constant fallback (§4). Never a stall, never an
  escalation: mine siting is an efficiency decision.
- Unpriceable option → skipped; fully unpriceable event → contributes nothing.
  Demand under-counts rather than guesses.
- Depot refresh failure → the hourly sweep skips; `fetchedAt` ages; the 24 h
  bound eventually flips the planner to fallback. No retry machinery.
- A depot location absent from `locationInventories` contributes nothing to
  `theatreStock` — absence is "unknown", and the freshness bound governs
  whether the aggregate is trusted.

## Testing

- `ResourceDemand`: pure table tests — remainder arithmetic, cheapest-option
  selection, unpriceable skips, device bills folded, reserve floors included.
  Fixtures shaped from real event payloads (the CUHECHIA-4 solar-storm shape).
- `MineSitePlanner`: existing tests keep passing with the fallback constants;
  new tables for weight-driven ranking and the staleness fallback.
- `WorldView`: `theatreStock` aggregation and freshness derivation against a
  seeded `locationInventories`.
- Schema: manifest freeze + golden-schema regeneration.
- Depot refresh: sweep writes rows; budget-pressure path skips without error.

## Robustness (eight-clause bar)

1. **Selector-not-enactor:** weights re-aim an existing rank; nothing new is
   enacted.
2. **Stateless:** demand, stock, weights all derive per tick from the DB.
3. **Pure selection:** the calculator and planner stay pure; I/O lives in the
   existing client/scheduler layers.
4. **Snapshot fidelity:** staleness degrades efficiency only — the fallback is
   the shipped static ranking.
5. **Testable through the seam:** every new unit is a pure function or a
   column select, table-testable without a live account.
6. **Safe degradation:** no new stall or escalation paths at all.
7. **Bounded blast radius:** one additive table; one bounded hourly GET per
   depot; no change to any dispatch path.
8. **Live "why" view:** `Candidate` carries weights + headroom, surfaced where
   the mine ranking is already explained.

## Residuals

- The hourly depot read means stock can lag up to an hour behind a big spend;
  acceptable because a mine is permanent and sited rarely.
- Demand's cheapest-option assumption may diverge from the option the
  fulfillment goal eventually picks; when fulfillment lands it can feed its
  actual picks back into the calculator it already consumes.
- `RelayRun.printStockIsShort` still arms the aggregate proxy; the per-type
  record now exists to retire it (follow-up, not in scope).
