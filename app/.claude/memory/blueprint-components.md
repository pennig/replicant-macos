---
name: blueprint-components
description: SHIPPED 2026-08-15 — some device blueprints require other printed devices as ingredients; the build record and the ten defects it closed.
metadata:
  type: project
---

# Blueprint components (2026-08-15)

Plan: `docs/superpowers/plans/2026-08-15-blueprint-components.md`. Spec:
`docs/superpowers/specs/2026-08-15-blueprint-components-design.md`. Ten code
tasks (`ebf56e1`…`18f293e`) taught the app that a blueprint can consume other
*printed devices*, not just raw resources, in three places: event-run cost
scoring, the print confirmation sheet, and the Print Queue's blocked-print
readout. Full suite green at close: 3,286 parameterized test cases (409
suites, 2,877 test functions — the event-stream/console split), 0 failures,
including `theSupervisorAdoptsTheRowTheBrainLaunched` (the known
whole-package-only flake, see
[supervisor-adopts-row-whole-package-failure](supervisor-adopts-row-whole-package-failure.md))
passing clean on both pre- and post-comment-pass runs.

## The dropped field that started it

`components` shipped in `openapi.json` **and** the generated client the whole
time. It was dropped at exactly one line: `Blueprint.init(schema:)` mapped 13
fields off the generated schema and never read `schema.components`. Nothing
downstream could have known a blueprint needed printed ingredients, because
the value never left the network layer.

## The `waiting_for` nesting bug — a false green tick on a blocked print

The live `waiting_for` payload is one level deeper than the app believed:

```json
{"components": {"<device_type>": {"have": 0, "need": 1}}}
```

The old parser read `waiting_for` as a flat `{key: {need, have}}` map, so
`components` was read as if it were itself one resource row — producing a
single `WaitingResource` named `"components"` with `need: nil, have: nil`.
`WaitingResource.isMet` (unfixed) is `(have ?? 0) >= (need ?? 0)`, and
`nil ?? 0` on both sides is `0 >= 0` — **true**. The Print Queue drew a green
checkmark on the exact requirement blocking the print. Fixed by
`nestedKind(_:)`, discriminating `components`/`resources` as nested blocks
from a flat legacy row by key.

## `EventPlan.price` inverted the ranking

Before this build, a device with no known blueprint priced at **0 units** in
`EventPlan.price` — the absence of a bill was read as "free" rather than
"unknown/unbuildable". An option whose tree bottomed out on an unknown
blueprint therefore looked *cheaper* than a fully-priced, actually-buildable
option, and a tier-4 event ranked first in the brain's choice list ahead of
options the fleet could really complete. This inversion is the whole reason
the feature exists — see `EventRanking`'s `unprintable` set and the
printability filter in `EventPlan.resolve`.

## `EventRun.printDeadline` — declared, unused, an 8h20m silent stall

`EventRun.printDeadline` existed as a field before this build but was
referenced by nothing — no step compared the clock against it. One live run
sat in `printing` for **8 hours 20 minutes** with `status: running` and
`attentionReason: null`: not stalled, not escalated, just silently stuck
because nothing was watching the deadline that existed to catch exactly this.

## The live component graph (as surveyed during the build)

Four blueprints carry components: `atmospheric_regulator`,
`biosphere_cultivator`, `climate_processor`, `processing_array`. Four
component device types have **no blueprint on the account**: `orbital_mirror`,
`terraform_controller`, `hydroponic_bay`, `nutrient_synthesizer` — meaning
`TABAT-4-EVT-007` is unbuildable at any price until at least one of those
unlocks. `ResourceDemand`'s pre-existing contract already drops any option
needing an unbilled device rather than mispricing it (see the
`EventPlan.resolve` empty-catalogue hatch below, which `ResourceDemand`
deliberately does **not** copy).

## Netting order: top level BEFORE expansion

Netting (subtracting devices already held from what's needed) must happen at
the top level **before** expanding through the component tree, spending each
held device once across both levels. Expanding first and then netting flat
re-prices a full component bill on every re-entry, because a completed parent
print *consumes* its components — the held count that should have cancelled
the parent's own top-level need gets counted again one level down. Get this
backwards and a mission re-orders components it already has.

**The test that guards this does not discriminate at a shared-pool size of
3** — flat netting, the correct top-then-expand fix, and the plausible wrong
expand-then-net fix all agree on the answer there. The fix only becomes
observable when the pool covers one demand but not both; size the fixture
past that boundary or the assertion is vacuous.

## Two maps named similarly, meaning different things

`WorldSnapshot.components` is the **FTL mesh** map (untouched by this build).
The blueprint components map is `WorldSnapshot.blueprintComponents` /
`WorldView.blueprintComponents`. Confusing them **compiles** (both are
`[String: ...]`-shaped) and is wrong at runtime — there is no type-level
guard, only the name.

## `Expansion.printSeconds` — computed, never wired

`BlueprintClosure.Expansion.printSeconds` is a real, tested computation, but
no production caller supplies a `printTimes` map to the function that would
populate it — it reads `0` everywhere outside tests. Wiring a
`blueprintPrintTimes` table through `WorldView` for a currently-nonexistent
consumer was a deliberate scope cut, not an oversight.

## Three exhaustive switches over `DirectiveAttentionReason`, not two

`Directive.swift` contains three, not two, exhaustive switches keyed on
`DirectiveAttentionReason`: `displayName`, `guidance`, and `brainDisposition`.
Adding a new reason case (this build added `printBlockedOnComponents`) means
touching all three or the build fails closed (correctly) rather than silently
defaulting.

## Testing the stall needs a backdated `stepStartedAt`, not clock advance

An engine-level test cannot reach the print-deadline stall by advancing a
`TestClock` past `printDeadline`: doing so also ages the footprint census out
from under its own 60-second freshness gate, so `.refreshFootprint` fires
before the deadline check ever gets a chance to fire the stall. Backdating
`stepStartedAt` directly (rather than advancing wall-clock time) reaches the
stall without collaterally invalidating the census.

## A criteria-only `LocationEvent` fixture decodes as `.undecodable`

`LocationEventDetail.init?` requires at least one of `progress`, `rewards`,
or `consumed` to be present — a hand-rolled fixture supplying only `criteria`
decodes to `.undecodable` rather than a populated detail. Costly to discover
blind; cheap to avoid once known.

## The empty-catalogue hatch is deliberately asymmetric

`EventPlan.resolve` deliberately **skips** the printability filter when
`bills` is empty, so a cold blueprint catalogue (nothing fetched yet) leaves
event-fulfilment inert rather than declaring every open event unbuildable —
mirrors the same "empty means unknown, not zero" contract
[demand-derived-mine-ranking](demand-derived-mine-ranking.md) established for
mine siting. **`ResourceDemand` does NOT copy that hatch.** Its pre-existing
contract already drops any option needing a device with no matching
blueprint, catalogue-empty or not — the two call sites answer different
questions (`EventPlan`: "what should the brain choose"; `ResourceDemand`:
"what does the fleet need") and only one of them has a reason to go inert on
a cold catalogue.

## Comment-pass note

Beyond the four items reviewers flagged directly (`ResourceDemand.swift`'s
8-line header, `WorldView.swift`'s stale "two columns" comment beside a
three-column select, `PrintComponentLine`'s doc claiming an unreachable nil
state, and `Printing.swift`'s over-commented private `nestedKind` helper), a
full hand-check of every file this branch touched turned up **fifteen more
file headers over the 6-line budget** — `BlueprintDetailView.swift`,
`CommandGrid.swift`, `DevicesFeature.swift`, `Brain.swift`, `BrainReport.swift`
(21 lines, the worst), `WorldSnapshot.swift`, `GameDatabase.swift`,
`SchemaManifestTests.swift`, `Blueprint.swift`, `Directive.swift`,
`PrintingSnapshotTests.swift`, `LocationsClient.swift`,
`PrintQueueDetailView.swift`, `PrintQueueFeature.swift`, `PrintPlanSheet.swift`
— all pre-existing debt from before this branch, none introduced by it, all
trimmed to 6 lines under this task's explicit scope ruling: a touched file's
header must comply regardless of who put it over budget, while inline/doc
comments in regions this branch never touched were left alone. No new
`///`/`//` budget violations were found inside any hunk this branch actually
added or modified.

Related: [supervisor-adopts-row-whole-package-failure](supervisor-adopts-row-whole-package-failure.md),
[demand-derived-mine-ranking](demand-derived-mine-ranking.md),
[comment-policy](comment-policy.md).
