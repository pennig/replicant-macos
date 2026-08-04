# Brain `R` reserve-floor rail — verified bill, `BrainCeiling`, fail-closed decision

Automation-brain Task 20 (`BrainCeiling`, `DirectiveEngine/Sources/BrainCeiling.swift`):
arms the `R` reserve-floor rail that vetoes an FTL-relay print which would drop
the hub below the stock the rest of the fleet needs. Confirmed live 2026-08-03.

## Verified facts (probed live, not the plan's assumptions)

- **Inventory lives at the LOCATION, not the device.** `GET locations/<code>`
  returns `inventory: [{"quantity": N, "resource_type": "..."}]` — an array of
  objects, never a `[String: Double]` dictionary. `GET devices/<autofactory>`
  carries no inventory at all (`print_queue` instead).
- **The six resource types** (see also [[belt-value-vocabulary]], confirmed a
  third way here): `carbon`, `conductive`, `rares`, `silicates`, `structural`,
  `volatiles`. **Not** `metal`/`silicon` — an earlier plan draft invented those
  and they must not be encoded anywhere.
- **The real FTL-relay blueprint bill** (`GET blueprints`, `device_type:
  ftl_relay`): `carbon 20, silicates 100, structural 80, rares 40, conductive
  120, volatiles 10`. **Sums to 370 total across all six types — NOT 370 per
  type.** A flat per-type floor of 370 is incoherent: 37× the volatiles bill,
  only 3× the conductive bill; it would veto on volatiles long before
  conductive ever mattered. `print_time: 800`, irrelevant to the rail.
- **Live hub stock (2026-08-03):** carbon 11,368 / conductive 13,434 / rares
  5,069 / silicates 13,225 / structural 27,436 / volatiles 4,117 — volatiles is
  both the cheapest type in the bill AND the scarcest in the hub, so it is the
  type that will bite first if the rail is ever going to fire.

## `N` (idle-relay buffer cap) is RETIRED — confirmed, not rebuilt

`brain-tendmesh-worthiness.md` (ticket 10) already retired it: *"**Reclaim is
LAZY / demand-driven** (amends 06 — retires `N` as a buffer cap)."* Task 20
built no `N` cap and no idle-relay pool management — the only ceiling is `R`.

## `BrainCeiling` — the floor's shape

`floor(type) = K × relayBill(type)` — "keep `K` relays' worth of each resource
type in reserve," never a flat literal. `K = BrainCeiling.reserveRelays = 5`,
marked `// CALIBRATE` in source: the one knob a future tuning pass may
reasonably revisit (every other constant on the type is a verified game fact).
Chosen because 5 relays' worth of the scarcest type (volatiles, 50 units) is a
real reserve rather than a rounding error, while staying far below the live
hub's actual holdings across every type — the rail protects the floor without
becoming a wall tripped during ordinary operation.

`BrainCeiling.printPermitted(hubStock: [String: Double]) -> Bool` fails
**CLOSED**: any of the six types missing from `hubStock` — including the
wholly-empty case — reads as zero, which sits below every real floor and
vetoes. This is a deliberate reversal of the general "unknown is never zero"
UI-display convention (salvage percentages, scan completeness) used elsewhere
in this codebase: those protect against *overstating depletion* in a read-only
view; this protects the fleet's actual resources against a real, irreversible
spend. "We couldn't read the stock" is not the same claim as "the stock is
fine."

## Arming `RelayRun`

`RelayRun.reserveFloor: Int?` now defaults to `BrainCeiling.totalReserveFloor`
(the sum of the six per-type floors) instead of `nil` — the rail is live in
production. It is a SUM, not the true per-type check `R` is specified as:
today's `LocationFootprint` carries one TOTAL holdings count, not a per-type
breakdown (brain-resource-hub-model, ticket 06's per-type stockpile record is
still a later task); `RelayRun.printStockIsShort` is the one place that
changes to call `BrainCeiling.printPermitted(hubStock:)` directly once that
record lands. The injection seam (`Int?`) is unchanged, so an explicit `nil`
still disarms the rail entirely for tests that need to isolate a different
code path — see `unarmedRailNeverVetoesEvenOnUnknownStock`.

`RelayRun.printStockIsShort` was also flipped to fail closed on a MISSING
footprint row for the hub's location, once armed (previously: absence read as
"not short" and permitted the print). Not a deadlock risk in practice:
`.printStockShort` already carries `BrainDisposition.retry` (bounded
auto-retry, then escalate — see `Directive.swift`'s `brainDisposition`), and
the footprint census this reads is refreshed by other missions
(`HaulRun.survey`'s periodic `.refreshFootprint`) and by the Locations
feature — a row this mission never writes itself still arrives from elsewhere.
