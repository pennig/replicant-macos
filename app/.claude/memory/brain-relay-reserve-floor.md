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
while STOCK is skewed the OTHER way (structural's stock ALONE, 27,436, is
~15× the naive sum), so a flat-sum floor cannot fire before the binding type
(conductive) is already exhausted under any realistic mix — on the live account, conductive
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

**Operational-wall note.** 35,078 is ≈47% of the hub's live total (74,649).
Because the check is TOTAL-only, ANY drawdown below that line vetoes ALL
relay printing regardless of per-type health — including a non-print
consumer moving stock around (e.g. a Haul Run relocating structural, which
alone is 27,436, more than a third of the whole hub). This is the
conservative direction on purpose (see above), but it is a real, plausible
operational wall the brain can hit well before any single type is actually
short, until the per-type stockpile record (ticket 06) lands and
`printStockIsShort` can call `printPermitted(hubStock:)` directly instead of
this proxy.

## Arming `RelayRun`

`RelayRun.reserveFloor: Int?` defaults to `BrainCeiling.aggregateSpendFloor`
instead of `nil` — the rail is live in production. The injection seam (`Int?`)
is unchanged, so an explicit `nil` still disarms the rail entirely for tests
that need to isolate a different code path — see
`unarmedRailNeverVetoesEvenOnUnknownStock`.

`RelayRun.printStockIsShort` fails closed on a MISSING footprint row for the
hub's location, once armed (previously: absence read as "not short" and
permitted the print) — but **in practice `acquire` no longer reaches that
branch as silence, only as positive evidence**: it gates on
`footprintCensusIsStale(_:)` FIRST.

**Round-2 correction — the freshness gate must be table-wide, not
per-location.** The first fix gated on `world.footprints[location]?.fetchedAt`
alone. Review round 2 found that unbounded: `.refreshFootprint(nextStep:
.acquire)` self-loops (unlike `HaulRun.survey`, which always advances to a
DIFFERENT step), `DirectiveExecutor.move` re-stamps `stepStartedAt`
unconditionally on every re-entry with no same-step exception (the same trap
`same-step-dispatch-needs-tracked-op` documents), and a row that is
persistently absent — the actual case being guarded against — by construction
never satisfies a per-location gate. That combination meant the engine's 5s
tick would issue `.refreshFootprint` roughly every tick, forever (~12/min),
for a hub location the API genuinely never lists — not the "throttled to
once per 60s" behaviour the round-1 fix claimed. Fixed by gating on the WHOLE
table's freshest read instead (`world.footprints.values.map(\.fetchedAt)
.max()`), the exact shape `HaulRun.survey` uses. `refreshFootprint()` upserts
every location the API returns in ONE request, so a genuinely-successful
refresh advances every row together, including locations the hub isn't — so
"the census is fresh and STILL doesn't list the hub" becomes POSITIVE
EVIDENCE rather than more silence, and `acquire` falls through to
`printStockIsShort` → veto → `.stall(.printStockShort)` →
`BrainDisposition.retry`'s bounded-retry-then-escalate, rather than looping.
Proven with a termination test
(`persistentlyMissingFootprintEscalatesRatherThanRefreshingForever`) that
drives `acquire` across repeated evaluations with a permanently-absent hub
row while the rest of the census refreshes normally, and asserts a stall is
reached rather than an unbounded refresh.

The missing-row veto stays inside `printStockIsShort` as that function's OWN
contract (defense in depth for a caller that doesn't gate on freshness
first), covered directly by
`printStockIsShortFailsClosedOnAMissingFootprintDirectly`. **The
never-resolves case now correctly ESCALATES** (via `.printStockShort`'s
bounded-retry-then-escalate disposition) rather than retrying forever — round
1's "retries indefinitely, never hammering" trade-off was itself a defect
(the retry WAS hammering, per the round-2 finding above), not a deliberate,
acceptable choice; that framing has been retired.

**Round 3 — `MissionAction.refreshFootprint` gained `thenStall`, closing the
whole-API-outage residual round 2 left explicitly out of scope.** Round 2's
own report predicted a gap: if `LocationsClient.refreshFootprint()` itself
always throws (not just "this one location is absent from an
otherwise-successful census" — an offline network, an expired/rotated token,
sustained 429/5xx, and judged in review to be the MORE common trigger, not
rarer), no row's `fetchedAt` ever advances, the table-wide gate stays stale
forever, and the same unthrottled ~12/min 5s-tick loop recurs. Round 3 closed
this by mirroring the ALREADY-SHIPPED shape `.refreshDevices` uses rather than
inventing new machinery:
- `MissionAction.refreshFootprint` is now `(nextStep: String, thenStall:
  DirectiveAttentionReason?)`.
- It is resolved by the ENGINE (`DirectiveEngineCore.resolveFootprintRefresh`,
  beside `resolveRefresh`/`resolveSystemRefresh`/`resolveFleetRefresh`), not
  by `DirectiveExecutor` doing a bare "I/O then move" — that bare shape is
  exactly what let `.refreshFootprint` self-loop unbounded in the first
  place. The resolver does the I/O once (best-effort, swallowed on failure),
  re-reads the world, and re-asks the SAME `reAsk` helper the device-refresh
  paths share — now generalised with an `orElse:` fallback (default `.wait`,
  unchanged for its three existing callers) so `.refreshFootprint`'s own
  fallback can differ per caller.
- `RelayRun.acquire` passes `thenStall: .printStockShort`: a persistently-
  failing census in front of an irreversible spend must escalate, so a
  repeat `.refreshFootprint` on the re-ask collapses to `.stall`.
- `HaulRun.survey` passes `thenStall: nil` and relies on `reAsk`'s `orElse:
  .advanceStep(nextStep: nextStep)` override to preserve its own,
  already-shipped "a transient failure must cost one cycle rather than
  stranding a continuous run" contract UNCHANGED — it always names a
  DIFFERENT step, so it was never at risk of the self-loop this whole
  mechanism exists to close, and this round's change is compile-compat only
  for it, not a behaviour change.
- `DirectiveExecutor.apply`'s `.refreshFootprint` case is now the same
  "the engine should have resolved this already" bypass fallback
  `.refreshDevices`/`.refreshDevicesInSystem`/`.refreshFleet` share.

Proven bounded end to end (through the REAL `DirectiveEngineCore.evaluateOnce`
+ `DirectiveExecutor.apply`, not a pure-function fixture) by
`RefreshFootprintTests.persistentlyFailingFootprintRefreshEscalatesAfterOneRound`
in `DirectiveEngineTests.swift`: a permanently-throwing `locationsClient
.footprint` escalates to `.stall` after exactly one I/O attempt, and a SECOND
`evaluateOnce` call makes zero further attempts (a stalled directive is
`.needsAttention`, not `.running`, so the executor never re-evaluates it
automatically).

**Round 3 minor — a stale-but-PRESENT hub row could be trusted.** Because the
refresh-trigger gate is table-wide (round 2), a hub row that simply stops
appearing in later census refreshes — while some OTHER location keeps the
table looking fresh — would not retrigger a refresh, and `printStockIsShort`
would read that row's arbitrarily old `resources` value at face value,
potentially permitting a print on stale "abundance." Considered reverting the
refresh-trigger gate to per-location scope (now that `thenStall`'s one-round
engine-level bounding makes ANY gate scope safe from the original self-loop),
but that would silently invalidate
`persistentlyMissingFootprintEscalatesRatherThanRefreshingForever`'s premise
(which proves termination by simulating OTHER locations refreshing while the
hub's never does — meaningless without table scope) and add an extra refresh
call on every evaluation where only the hub's own row is stale. Fixed instead
as a separate, read-time-only veto check inside `printStockIsShort`: a hub row
older than `RelayRun.hubFreshness` (5 min — the SAME "how old may a positive
finding be and still be believed" bound already used for the hub DEVICE row,
reused here for the identical reason, deliberately more generous than the
60s refresh-trigger gate) fails closed rather than being trusted. This cannot
reopen the self-loop risk — it is a veto decision, not another refresh
request. Covered by `staleHubRowIsNotTrustedEvenWhenTheCensusAsAWholeLooksFresh`.
