# Brain `R` reserve-floor rail — verified bill, `BrainCeiling`, fail-closed decision

Automation-brain Task 20 (`BrainCeiling`, `DirectiveEngine/Sources/BrainCeiling.swift`):
arms the `R` reserve-floor rail that vetoes an FTL-relay print which would drop
the hub below the stock the rest of the fleet needs. Confirmed live 2026-08-03.
**Updated after review** with a corrected binding-type analysis and a
conservative (not naive-sum) aggregate proxy — see the two sections marked
below; the naive-sum version briefly shipped was a real gap, caught before
merge.

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
  5,069 / silicates 13,225 / structural 27,436 / volatiles 4,117; total 74,649.

## CORRECTED: the binding type is conductive, not volatiles

The first draft of this note claimed volatiles "bites first" because it's
both the cheapest bill line (10) and the scarcest live stock (4,117) — this
**conflates absolute scarcity with scarcity relative to consumption** and is
wrong. Computing relays-until-floor per type
(`(stock − K×bill) / bill`, `K=5`) against the live snapshot:

| type | relays until its own floor |
|---|---|
| **conductive** | **≈107 (binding — first to constrain)** |
| rares | ≈122 |
| silicates | ≈127 |
| structural | ≈338 |
| volatiles | ≈407 (LAST, not first) |
| carbon | ≈563 |

Volatiles actually has ~4× conductive's headroom. `BrainCeiling.reserveRelays`
(`K=5`)'s justification is anchored on conductive's 600-against-13,434 ratio,
which was already correct — only the "which type bites first" narrative was
wrong. `BrainCeiling.relaysUntilBindingTypeFloors` computes this live from the
bill + a reference snapshot rather than restating a hand-picked type, and
`BrainCeilingTests.conductiveIsTheBindingTypeUnderTheReferenceMix` pins it.

## `N` (idle-relay buffer cap) is RETIRED — confirmed, not rebuilt

`brain-tendmesh-worthiness.md` (ticket 10) already retired it: *"**Reclaim is
LAZY / demand-driven** (amends 06 — retires `N` as a buffer cap)."* Task 20
built no `N` cap and no idle-relay pool management — the only ceiling is `R`.

## `BrainCeiling` — the floor's shape

`floor(type) = K × relayBill(type)` — "keep `K` relays' worth of each resource
type in reserve," never a flat literal. `K = BrainCeiling.reserveRelays = 5`,
marked `// CALIBRATE` in source: the one knob a future tuning pass may
reasonably revisit (every other constant on the type is a verified game fact).
`resourceTypes` is now DERIVED from `relayBill.keys` (sorted) rather than
restated as a second literal — a seventh billed type with no matching
`resourceTypes` entry used to floor to zero and `printPermitted` would
silently PERMIT it (a fail-open hole inside a fail-closed predicate, caught in
review); deriving both from one source closes that by construction.

`BrainCeiling.printPermitted(hubStock: [String: Double]) -> Bool` — **this is
the real per-type `R`, as specified** — fails **CLOSED**: any of the six types
missing from `hubStock`, including the wholly-empty case, reads as zero, which
sits below every real floor and vetoes. Deliberate reversal of the general
"unknown is never zero" UI-display convention (salvage percentages, scan
completeness) used elsewhere in this codebase: those protect against
*overstating depletion* in a read-only view; this protects the fleet's actual
resources against a real, irreversible spend.

## CORRECTED: the aggregate proxy `RelayRun` actually arms

`RelayRun` cannot call `printPermitted(hubStock:)` yet — today's
`LocationFootprint` carries one TOTAL holdings count, no per-type breakdown
(brain-resource-hub-model, ticket 06's per-type stockpile record is a later
task; `printStockIsShort` is the one place that switches to calling
`printPermitted` directly once it lands). The first-shipped proxy for this,
`totalReserveFloor` (**the naive sum of the six per-type floors, ≈1,850**),
was a real gap caught in review: the bill spends in fixed, skewed proportions
while stock is skewed the OTHER way (structural's floor alone is 15× the naive
sum), so a flat-sum floor cannot fire before the binding type (conductive) is
already exhausted under any realistic mix — on the live account, conductive
hits its own floor at relay ≈107, by which point TOTAL stock is still
≈35,000, ~18× the naive sum. **`printPermitted` had no production caller** at
that point — the entire per-type deliverable was dead code.

Fixed: `BrainCeiling.aggregateSpendFloor` (renamed from `totalReserveFloor` —
the old name claimed to be `R` itself, which it never was) is now derived as
the TOTAL stock at the moment a reference mix's binding type would hit its OWN
floor: `totalReferenceStock − relaysUntilBindingTypeFloors × totalBill`,
rounded UP. Total stock drains by exactly `totalBill` (370) per print
regardless of mix, so this is provably the total reading at which the binding
type sits AT its floor under the reference snapshot (`BrainCeiling.
referenceHubStock`, the live 2026-08-03 measurement) — the coarse rail fires
no LATER than the true per-type rail would, the safe direction for a proxy to
be wrong in. Current value: **35,078** (pinned exactly in
`BrainCeilingTests.aggregateSpendFloorIsPinnedToItsDerivedValue`, so any
future recalibration of `K` or the reference snapshot shows up as a diff).
Still only a proxy — if the live mix drifts far from the reference snapshot,
the guarantee weakens — which is exactly why it is named for what it is
(`aggregateSpendFloor`) rather than `R`.

## Arming `RelayRun`

`RelayRun.reserveFloor: Int?` defaults to `BrainCeiling.aggregateSpendFloor`
instead of `nil` — the rail is live in production. The injection seam (`Int?`)
is unchanged, so an explicit `nil` still disarms the rail entirely for tests
that need to isolate a different code path — see
`unarmedRailNeverVetoesEvenOnUnknownStock`.

`RelayRun.printStockIsShort` fails closed on a MISSING footprint row for the
hub's location, once armed (previously: absence read as "not short" and
permitted the print) — but **in practice `acquire` no longer reaches that
branch**: it now gates on `footprintIsStale(at:_:)` FIRST (mirroring
`HaulRun.survey`'s freshness check on the same table, `world.now.
timeIntervalSince(fetchedAt) > pollInterval`, added in review) and issues
`.refreshFootprint(nextStep: Step.acquire)` on a missing OR stale row instead
of an immediate veto — a hub whose census row simply hasn't been fetched yet
gets one real chance to arrive before this one-shot run forms an opinion on
it, rather than escalating what one GET would clear. The missing-row veto
stays inside `printStockIsShort` as that function's OWN contract (defense in
depth for a caller that doesn't gate on freshness first), covered directly by
`printStockIsShortFailsClosedOnAMissingFootprintDirectly`. Trade-off accepted
deliberately: a footprint that NEVER resolves (a genuinely broken read, not
just "hasn't happened yet") now retries the refresh indefinitely (throttled to
once per `pollInterval`, never hammering) rather than eventually escalating to
a human via `.printStockShort`'s bounded-retry-then-escalate disposition —
judged acceptable because (a) it's still fail-safe (never prints), (b) a hub
location with a real print-capable device standing on it should always
eventually appear in a full census refresh, so permanent absence is a
theoretical edge rather than an expected production case, and (c) this
mirrors `HaulRun.survey`'s already-shipped, already-reviewed acceptance of the
same trade-off on the same table.
