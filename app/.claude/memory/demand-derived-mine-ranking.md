---
name: demand-derived-mine-ranking
description: SHIPPED 2026-08-12 — mine-site ranking weights belts by stock ÷ demand instead of two fixed constants; records the measured mix and the coverage-vs-collections correction.
metadata:
  type: project
---

# Demand-derived mine ranking (2026-08-12)

`MineSitePlanner`'s scarcity bonus — previously two hardcoded constants
(`rares` ≥ moderate scores 2, `conductive` ≥ moderate scores 1), see
[brain-mine-build](brain-mine-build.md) — is now derived per tick from real
resource **headroom**: depot stock ÷ live demand, per type, computed fresh
every tick rather than hand-picked once. `ResourceHeadroom.siteWeights` takes
the top two types by lowest coverage and applies `[first: 2, second: 1]`
against `MineSitePlanner`'s existing `[rares, conductive]` slots — the
comparator and the belt-ranking pipeline are byte-identical to before; only
the two types feeding it changed from a literal to a computation.

## The pipeline

`LocationInventory` — a new per-type stock table (`404d4e6`), persisted on
every location read (`f3d39fd`) and swept hourly for every recognised theatre
depot (`58dee18`, `d0782c5`) — replaces the old totals-only
`LocationFootprint` reading as the ranking's stock source.
`ResourceDemand.compute` (`88187de`, `0ac7460`) prices every ACTIVE open
`LocationEvent` at its cheapest resolvable option, translating any device
line through the matching blueprint bill (`GET blueprints`, ~46 rows), and
adds the standing print reserve (`BrainCeiling`'s per-type floor, see
[brain-relay-reserve-floor](brain-relay-reserve-floor.md)) on top.
`WorldView.theatreStock` (`91b8f4b`) sums per-type stock across every
operational theatre's depot. `ResourceHeadroom` (`adbd6db`, `c27a190`)
divides the two and ranks. `MineSitePlanner` (`64b3eb7`) takes the resulting
weight table as a parameter instead of a literal. `Brain` wiring
(`402b263`, `e26841f`, `2c39aee`) threads `locationEvents` and
`blueprintBills` through `WorldView.read` (both already fetched or cheap —
events are read and discarded elsewhere, blueprints are one small table) so
`mineReadiness(view:directives:)`'s own signature is unchanged.

## The measured mix that motivated it (live account, 2026-08-12)

Collections to date (`haulYields`, see
[logistics-haul-yields](logistics-haul-yields.md)): structural 40,779 ·
conductive 16,048 · silicates 9,543 · carbon 5,801 · rares 4,805 · volatiles
1,239.

Depot stock (`GET locations/AINALRAM-BELT-1`): structural 78,590 · carbon
21,398 · conductive 19,161 · silicates 12,777 · rares 10,917 · volatiles
6,538.

Event demand across 47 active events, each priced at its cheapest option,
devices translated through blueprint bills: conductive 4,450 · silicates
4,140 · structural 3,890 · carbon 2,950 · rares 950 · volatiles 590.

Coverage (stock ÷ demand): **silicates 3.1× and conductive 4.3× bind.**
Volatiles — the smallest pile by far — sits at **11.1×**, the most covered
type of the six.

## The correction: least-collected is not the same question as least-covered

This effort began from the intuition that volatiles should be prioritised,
because it is a distant last in collections (1,239 against structural's
40,779). That is the wrong signal, and the measured mix shows why: volatiles
is last in collections **because it is last in demand** — every blueprint in
the catalog is volatiles-light, and its 590 units of event demand is
IDENTICAL whether every option is priced at its cheapest or every option in
the catalog is summed, meaning no alternative resolution path anywhere asks
for more of it. The types actually sitting near their floor are silicates
(scored **zero** under the old constants — no bonus at all) and conductive.
Absolute scarcity is not scarcity relative to consumption.

This is the same error already recorded in
[brain-relay-reserve-floor](brain-relay-reserve-floor.md) — where the first
draft claimed volatiles binds first on the FTL-relay reserve rail, when
conductive actually does — made a second time here, in the opposite
direction (this effort started by favouring volatiles instead of penalising
it). Two independent passes over the same six-type resource system have now
each arrived at the wrong binding type on the first attempt by reasoning
from a pile size or a collection total instead of from a ratio to
consumption. Treat any future "type X is scarce" claim on this account as
unverified until it is expressed as stock ÷ demand (or stock ÷ bill, for the
reserve rail), not as a raw quantity.

## The fallback contract

Unknown or >24h-stale depot stock makes `ResourceHeadroom` fall back to the
ORIGINAL static weights (`[rares: 2, conductive: 1]`) exactly — so degrading
never produces a worse ranking than the release this effort replaced, only a
less-informed one. Pinned by test at the exact staleness boundary.

## Deliberate scope calls

**Demand counts ALL active events, meshed or not.** An event's resource
draw is real regardless of whether the brain can currently reach it — narrowing
to meshed-only events would understate demand for exactly the types a
not-yet-meshed frontier needs, which is the opposite of what a headroom
signal is for.

**An unpriceable option is dropped WHOLE — its resource lines included —
rather than partially priced.** This was a live design question in Task 8,
settled by review rather than assumed: a partially-priced option (real
resource cost, silently-zeroed device cost because the device type had no
blueprint match) would look artificially cheap and could beat a fully-priced
option in the cheapest-option selection, corrupting the RANKING between
options, not just understating one option's magnitude. Dropping the whole
option only under-counts total demand, which is the safe direction — the
existing fallback-to-static-weights contract already covers "demand data is
incomplete," so under-counting degrades gracefully into that contract rather
than producing an actively wrong signal.

## Residuals for the user — both about the blueprint catalog, both open

**Blueprint bills have no dedicated fetch trigger.** The only caller of
`blueprintsClient.fetchAll()` is the Blueprints screen. The live account has
46 rows only because that screen has been opened at least once. After a
fresh local DB reset, the brain ticks with an EMPTY bill table, and
`ResourceDemand` drops every device-bearing event option (see above),
degrading demand to reserve-floors-only until a human opens that screen.
Same shape as the previously-recorded LocationFootprint no-poller bug.
Closing it needs a new fetch trigger — out of this effort's scope.

**An empty blueprint catalog does not set `isFallback`.** Demand computed
from zero blueprint rows still reads as ordinary (non-fallback) demand to
every downstream consumer — the debug log line is the ONLY place this
degraded state is visible. Closing it properly needs a new signal on
`ResourceHeadroom` (a reviewed, already-closed type) plus a why-view surface
to show it; pinned today only by a test proving the arithmetic
(`demand == reserveFloors` exactly when bills are empty).

Related: [brain-relay-reserve-floor](brain-relay-reserve-floor.md),
[brain-mine-build](brain-mine-build.md),
[theatre-recognition-model](theatre-recognition-model.md),
[logistics-haul-yields](logistics-haul-yields.md),
[brain-resource-hub-model](brain-resource-hub-model.md).
