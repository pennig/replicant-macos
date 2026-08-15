# Blueprint components — cost calculation and printing

Some blueprints require other *printed devices* as ingredients, on top of raw
resources. The event-fulfilment capability does not know this. It under-prices
every option that touches such a blueprint, ranks the options in the wrong
order, and enqueues a print that can never start.

This design adds components to the data model, makes the cost calculation
expand through them, teaches the Event Run to print prerequisites before the
device that needs them, and stops the three places that currently report a
component blockage as either satisfied or invisible.

## 1. The live incident

This is not hypothetical. On 2026-08-15 the fleet is in exactly this state.

An `eventRun` directive (`4016FCDC-3A85-4583-9D87-A76D5470DA64`) targeting
`TABAT-4-EVT-007` has been sitting in `step: printing` since 05:08:03 — over
eight hours — with `status: running` and `attentionReason: null`. It has not
stalled. It is not going to.

It enqueued an `atmospheric_regulator` on autofactory `3C39631F` at
`AINALRAM-BELT-1`, which now reads:

```json
{
  "status": "waiting_for_resources",
  "print_queue": [{"device_type": "atmospheric_regulator",
                   "tags": ["auto:event:ainalram-belt-1"]}],
  "waiting_for": {"components": {"filtration_array": {"have": 0, "need": 1},
                                 "atmo_processor":   {"have": 0, "need": 2}}}
}
```

The `auto:event:ainalram-belt-1` tag is `EventRun.fleetTag(forTheatre:)`. The
brain queued this and cannot finish it. Three other autofactories are printing
`filtration_array` and 2× `atmo_processor` with empty tag arrays — the operator,
by hand.

## 2. Ground truth

Verified by live GET probes on 2026-08-15. `https://replicant.space/docs/`
never mentions components — not on `concepts/blueprints/`, not on
`autofactories/`, not on `api/replicants/print/`. The live payload and
`openapi.json` are the only sources.

### 2.1 The blueprint field

`GET /v1/blueprints` returns 49 blueprints (the same count at `limit=50`, `100`
and `200`, so this is the whole known catalogue, not a page). `components` is
a sparse `{device_type: count}` map, present and non-empty on four:

| device type | components | own resources | print time |
|---|---|---|---|
| `atmospheric_regulator` | 1× `filtration_array`, 2× `atmo_processor` | 850 | 3600 s |
| `biosphere_cultivator` | 2× `hydroponic_bay`, 1× `nutrient_synthesizer`, 1× `orbital_farm` | 750 | 3600 s |
| `climate_processor` | 1× `orbital_mirror`, 1× `terraform_controller`, 2× `atmo_processor` | 1000 | 4200 s |
| `processing_array` | 5× `compute_core` | 200 | 400 s |

It is already in the spec —
`app_schemas_blueprints_BlueprintSchema.components`, typed
`{"type": "object", "additionalProperties": {"type": "integer"}, "nullable": true}` —
and already decoded by the generated client as
`ComponentsPayload` (`additionalProperties: [String: Int]`). Nothing reads it.

**Nesting is one level deep today.** None of the eight referenced component
types carries components of its own. The schema does not promise this, so the
expansion is written recursively with a cycle guard, but no live data exercises
depth 2.

**Four component types have no blueprint at all**: `orbital_mirror`,
`terraform_controller`, `hydroponic_bay`, `nutrient_synthesizer`. They are not
in `GET /v1/blueprints` at any limit, and the account owns none of them.
Blueprints unlock through achievements, through decommissioning a device at an
autofactory, and through trading — none of which the brain can drive. A
component tree that reaches one of these is not expensive; it is impossible.

### 2.2 The `waiting_for` shape

`waiting_for` is one level deeper than the app believes. The real shape is
`{<kind>: {<name>: {need, have}}}` where kind is `components` (observed live)
or, by inference from the spec's own description, `resources`. `openapi.json`
types the whole object as `additionalProperties: {}` with the description
"Resources still needed for a queued print: `{resource: {need, have}}`", so the
description is stale and the type is open enough to carry either.

A component-blocked job holds its position in `print_queue` and does not start.

**Unverified**, and not settleable by reading: whether `have` counts devices at
the printer's *location* or anywhere on the account — the account owns zero of
both types, so `have: 0` is consistent with either rule; whether a blocked job
clears the moment the components land or needs a re-enqueue; and whether
`waiting_for` nests `resources` the same way when a job is short on raw material
instead. All three need a live print to settle, and all three will be observable
in the fleet within hours of the hand-queued components landing. The design
depends on none of them: it prints components at the depot, which satisfies a
location rule and an account rule alike. Section 9 records the rest.

### 2.3 What it costs on the one event that needs it

`TABAT-4-EVT-007` "Planetary Reclamation", tier 4, active, at `TABAT-4`.
Rewards 30,000 XP, 15 civilisation points, 4,000 rares and 2,000 volatiles.
Two options, both needing 2× `climate_processor`:

| option | naive cost | expanded cost | print jobs | serial print time |
|---|---|---|---|---|
| `climate_biosphere_restoration` | 3,450 | **≥ 6,290** | 8 | 4.9 h |
| `atmospheric_climate_restoration` | 3,350 | **≥ 7,220** | 10 | 5.6 h |

The expanded figures are lower bounds: they exclude the four unknown
blueprints, whose cost is unknowable. Two things follow. The true bill is at
least double what the app reports, and **the cheaper option changes**: naive
picks option 2, expanded picks option 1. `ResourceDemand.compute` feeds "each
open event's cheapest option" into mine siting, so the wrong cheapest option
mis-aims the mining fleet as well as the operator's choice surface.

Both options need `orbital_mirror` and `terraform_controller`. Neither is
printable today at any price.

## 3. What is wrong today

Four distinct defects. Only the first is the feature as asked.

**D1 — the cost calculation stops at the first level.**
`EventPlan.price` (`app/Modules/DirectiveEngine/Sources/EventPlan.swift:56-68`)
computes `deviceUnits` as `Σ (bills[deviceType]?.total ?? 0) × count`, a single
map lookup. `ResourceDemand.price`
(`app/Modules/DirectiveEngine/Sources/ResourceDemand.swift:61-79`) does the same
at `:73`, expanding one bill through `wireDictionary`. Neither knows a device can
cost devices. There is no recursive expansion anywhere in the codebase.

**D2 — an unbuildable option is scored as cheap and ranked first.**
`EventPlan.price` scores a device with no blueprint as **0 units**, so an option
whose tree reaches an unknown blueprint looks *cheaper* than one that doesn't.
`EventRanking.precedes` orders `met → tier desc → round trip asc`, so a tier-4
event with an unpriceable tree ranks above everything. That is precisely how the
live run launched. (`ResourceDemand.price` is stricter — it returns `nil` and
drops the option — so the two pricing sites already disagree about what an
unbillable device means.)

**D3 — a component-blocked print parks the run silently and forever.**
`EventRun.printing` returns `.wait` at
`app/Modules/DirectiveEngine/Sources/EventRun.swift:207` whenever an operation is
open on the printer. The operation stays open while the job sits in
`waiting_for`. `EventRun.printDeadline` is declared at `:55` and referenced
nowhere else in the file, so nothing bounds the step. `.wait` neither advances
nor stalls, which is the eight-hour silence.

**D4 — the UI reports the blockage as satisfied.**
`Device.waitingForResources`
(`app/Modules/GameModels/Sources/Printing.swift:147-157`) maps the *top* level of
`waiting_for` as `{resource: {need, have}}`. Against the real nested payload it
produces one row named `components` with `need: nil, have: nil`, and
`isMet` is `(nil ?? 0) >= (nil ?? 0)` — **true**. `PrintQueueDetailView.swift:190`
draws `checkmark.circle.fill` in `.rcStatusReady` on the thing blocking the
print.

## 4. Design

### 4.1 Data model

`Blueprint` gains one stored property:

```swift
@Column(as: [String: Int].JSONRepresentation.self)
public var components: [String: Int]
```

Empty dictionary when the payload omits it, matching how `features` and
`directives` already coalesce. The memberwise `init` gains the parameter with a
`[:]` default so the 30-odd existing construction sites in fixtures and tests
compile untouched.

`Blueprint.init(schema:)` (`Blueprint.swift:209-225`) gains one line:

```swift
components: schema.components?.additionalProperties ?? [:],
```

Migrations are append-only, so this is a new `SchemaMigration` beside
`createBlueprints`, in the shape `LocationEvent.addChosenOption` already uses:

```swift
public static let addComponents = SchemaMigration("Add 'components' to blueprints") { db in
    try #sql(#"ALTER TABLE "blueprints" ADD COLUMN "components" TEXT NOT NULL DEFAULT '{}'"#)
        .execute(db)
}
```

appended to `GameDatabase.manifest`, with `SchemaManifestTests`' frozen
identifier list extended and the golden schema regenerated under
`RC_REGENERATE_SCHEMA_FIXTURE=1`.

`ResourceCost` is **not** touched. It is a closed six-field struct describing
raw material, and a component requirement is not raw material. Keeping them
separate is what lets the expansion return both a `ResourceCost` and a job list
without inventing a union type.

### 4.2 `BlueprintClosure` — the expansion

A new pure type in `DirectiveEngine`, alongside `EventPlan`:

```swift
public enum BlueprintClosure {
    public struct Expansion: Equatable, Sendable {
        /// Raw material for the whole tree, this device included.
        public let resources: ResourceCost
        /// Every print to run, prerequisites first. Parents never precede children.
        public let jobs: [Job]
        /// Serial print seconds for `jobs`.
        public let printSeconds: Int
        /// Device types in the tree with no blueprint. Non-empty ⇒ not printable.
        public let unprintable: Set<String>
    }

    public struct Job: Equatable, Sendable {
        public let deviceType: String
        public let quantity: Int
        /// 0 for the requested device, 1 for its components, and so on.
        public let depth: Int
    }

    public static func expand(
        _ wanted: [String: Int],
        bills: [String: ResourceCost],
        components: [String: [String: Int]]
    ) -> Expansion
}
```

Depth-first post-order over the component map, accumulating quantities
multiplicatively (2× `climate_processor` each needing 2× `atmo_processor`
yields 4× `atmo_processor`, one job). Jobs are emitted deepest-first and merged
by device type, taking the maximum depth so a type required at two levels still
sorts behind everything it depends on. A device type already on the current
path is a cycle: it is added to `unprintable` and its subtree is abandoned,
never recursed into. A device type with no entry in `bills` is added to
`unprintable` and contributes no resources — so the totals are explicitly a
lower bound whenever `unprintable` is non-empty, which is why callers must
check the set rather than the number.

`ResourceCost.add` (`Blueprint.swift:185`) is the accumulator; no new cost
arithmetic is introduced.

### 4.3 Pricing

`WorldView` gains `blueprintComponents: [String: [String: Int]]` beside
`blueprintBills`, loaded from the same select at `WorldView.swift:172-173`
(a third column, not a second query).

`EventPlan.Option` gains two fields:

```swift
/// Device types in this option's component tree with no blueprint.
public let unprintable: Set<String>
/// Prints this option needs, prerequisites first.
public let jobs: [BlueprintClosure.Job]
```

`EventPlan.price` calls `BlueprintClosure.expand` and sets `deviceUnits` from
`expansion.resources.total`. `EventPlan.resolve` gains a `components:` parameter
alongside `bills:`.

`ResourceDemand.price` expands the unmet remainder the same way. It keeps its
existing "return `nil` and drop the option" contract for an unbillable device —
which now means *anywhere in the tree*, not just at the top.

Four `EventRun` call sites pass `bills: [:]` today (`:185`, `:256`, `:309`,
`:402`) because the run needs the device and resource maps, not the price. They
pass `components: [:]` for the same reason and keep working; only `printing`
(§4.5) needs the real map.

### 4.4 The feasibility gate

An option with a non-empty `unprintable` set cannot be built. `EventPlan.resolve`
returns `.decided` only for options that are printable:

- Every option unprintable → a new `.blocked([Option])` resolution case.
- One printable option → `.decided`, whatever the others are.
- Several printable options and no recorded pick → `.needsChoice`, listing only
  the printable ones.

`EventRanking.rank` already keeps `.decided` alone, so `.blocked` never reaches
ranking and no run launches — which is the whole point. `EventRanking.pendingChoices`
gains a sibling for blocked events, and `BrainReport.eventChoices` surfaces them
with the missing blueprints named, so the why-view says *"blocked — needs
`orbital_mirror`, `terraform_controller`"* rather than showing nothing.

This is the decision that would have prevented the live incident.

### 4.5 `EventRun.printing`

Three changes to `app/Modules/DirectiveEngine/Sources/EventRun.swift`.

**Print the tree, not the top.** `missingDevices` (`:160-171`) keeps its current
job — what the option still needs standing free at the depot under the fleet tag
— and its result is fed through `BlueprintClosure.expand`. The dispatch order at
`:219` becomes the expansion's `jobs` order (deepest first), with the beacon
still last. One job per tick, as now.

Netting stays tag-scoped: a component already standing at the depot under this
run's fleet tag counts, and nothing else does. The standing fleet is never
scavenged. That matters — the account's four autofactories and two matrix
containers are load-bearing, and a component print consumes what it takes.

**Read the server's own answer.** When the chosen printer reports
`waiting_for.components`, those counts are authoritative and take precedence
over the local expansion: the run prints what the server says is missing. This
is the self-healing path if the expansion and the server ever disagree.

**Bound the step.** `printDeadline` is wired into `printing`. Past the deadline
with the job still blocked, the run stalls with a new
`DirectiveAttentionReason.printBlockedOnComponents`, classified `retry` in
`brainDisposition` so the bounded auto-retry already built for
`brainManagedStall` kinds applies before it escalates to the operator. This
closes D3 for *any* permanently-blocked print, not only a component one.

### 4.6 The `waiting_for` parser

`WaitingResource` (`Printing.swift:93-108`) gains a kind:

```swift
public enum Kind: String, Equatable, Sendable { case resource, component }
public var kind: Kind
```

`Device.waitingForResources` (`:147`) parses the nested shape: for each
top-level key, if its value's values are themselves objects carrying
`need`/`have`, descend one level and tag the rows with the matching kind;
otherwise read the flat legacy shape as `.resource`. Both are handled because
the flat shape is what the spec still documents, and a payload short on raw
material has never been observed.

`isMet` keeps its meaning but stops answering `true` for a row it could not
parse: a row with neither `need` nor `have` is unmet, not met. That single change
is what removes the green checkmark from a blocking requirement.

`Device.waitingForComponents` is added for the Event Run's benefit (§4.5), so
the engine never re-parses the blob itself.

### 4.7 The interactive surfaces

**Print Queue.** The Waiting For card renders both kinds, components labelled by
device display name rather than resource display name, with the same
`hourglass`/`checkmark` treatment. `WaitingResource.kind` drives which name
lookup runs.

**Print preview.** `PrintRequirements` today models resource lines only. It
gains a parallel `components: [PrintComponentLine]`
(`deviceType`, `label`, `required`, `available: Int?`), resolved from device rows
at the printer's location the way `PrintResourceLine` resolves from inventory.
`allMet` extends to both. `LocationsClient.printRequirements`
(`LocationsClient.swift:116-135`) takes the component bill and the co-located
device counts. The two view-side builders — `PrintQueueDetailView.swift:332-341`
and `CommandGrid.swift:551-560` — read `blueprint.components` alongside
`blueprint.resources.lineItems`.

The preview stays advisory. `printPreviewConfirmed` still fires the command
regardless of `allMet`, because the server is the authority and a blocked job is
recoverable — it waits rather than failing.

**Blueprint detail.** `BlueprintDetailView` gains a Components section beside
the resource radar, listing each required device and count, shown only when
`components` is non-empty. Device type names render through the existing
display-name helper.

## 5. Data flow

```
GET /v1/blueprints
  → Blueprint.init(schema:)          components decoded (§4.1)
  → blueprints table                 new column (§4.1)
  → WorldView.read                   blueprintBills + blueprintComponents (§4.3)
      → BlueprintClosure.expand      resources, ordered jobs, unprintable (§4.2)
          → EventPlan.price          true deviceUnits, jobs, unprintable
              → EventPlan.resolve    .decided / .needsChoice / .blocked (§4.4)
                  → EventRanking     blocked options never ranked
                  → BrainReport      blocked options surfaced with reasons
          → ResourceDemand.price     true per-type demand → mine siting
          → EventRun.printing        prerequisites first, deadline armed (§4.5)
```

The device's own `waiting_for` (§4.6) is a second, independent input to
`EventRun.printing` — the server's answer to the same question the expansion
computes locally, and the one that wins on disagreement.

## 6. Degradation

Every new failure mode degrades toward doing nothing rather than toward
spending.

- **Unknown blueprint in the tree** → the option is not `.decided`, no run
  launches, the operator sees why. Costs nothing, guesses nothing.
- **Cycle in the component map** → treated as unknown, same path.
- **`blueprintComponents` empty** (cold catalogue, before the first fetch) →
  `expand` returns exactly today's flat behaviour. The feature is inert rather
  than wrong.
- **`waiting_for` in an unrecognised shape** → rows parse as unmet, never as
  met. The Waiting For card may say less than it could; it will not say the
  opposite of the truth.
- **Print blocked past the deadline** → bounded retry, then a named stall the
  operator can act on. Never an unbounded `.wait`.

## 7. Testing

TDD throughout, Swift Testing, results read from the JSON event stream per the
`swift-test-event-stream` skill.

`BlueprintClosureTests` — the pure core, as a table: flat blueprint (identity);
one level (`atmospheric_regulator`); shared component reached twice
(`climate_processor` ×2 → 4× `atmo_processor`, one job); synthetic depth 2 with
correct ordering; a synthetic cycle; an unknown leaf marking `unprintable` and
under-counting resources; and the two `TABAT-4-EVT-007` options over a fixture
carrying the live catalogue's four component-bearing blueprints and omitting the
four unknown ones, pinned at 6,290 and 7,220 units — so the ranking flip against
the naive 3,450 / 3,350 is a regression test rather than a description.

`EventPlanTests` — `.blocked` for an all-unprintable event; `.decided` when one
of several options is printable; `.needsChoice` listing printable options only;
a recorded pick naming a now-unprintable option falling back rather than
misfiring.

`ResourceDemandTests` — the cheapest option changes once components are counted,
asserted per resource type.

`EventRunTests` — `printing` dispatches the deepest job first; a component
standing at the depot under the fleet tag is netted and one standing under
another tag is not; a `waiting_for.components` reading overrides the local
expansion; the deadline fires
`.printBlockedOnComponents` rather than looping. Plus an engine-level test
driving `EventRun` through `DirectiveEngineCore`, not a fixture table — the
`RelayRunEngineTests` lesson, where a pure-function table missed a real stall.

`PrintingTests` — the nested payload parses to two component rows with correct
`need`/`have`; **an unparseable row is unmet**, the direct regression test for
D4; the flat legacy shape still parses as resources.

`SchemaManifestTests` / `GoldenSchemaTests` — the new identifier and column.

## 8. Robustness

Against the eight clauses in `brain-robustness-bar`:

1. **Selector, not enactor.** The brain still only ranks and launches.
   `BlueprintClosure` is pure. The printing change lives in the executor, where
   printing already lived.
2. **Stateless between ticks.** The expansion is recomputed per tick from
   `WorldView`. Nothing is memoised across ticks and no new column records a
   plan.
3. **API vetoes, never chooses.** The server's `waiting_for` overrides the local
   expansion when they disagree; the expansion never overrides the server.
4. **Snapshot fidelity.** A stale or empty catalogue degrades to today's flat
   pricing — less efficient, never less safe. A stale device row can only
   under-count what stands at the depot, which over-prints rather than
   under-prints, and the reserve rail still gates the spend.
5. **Testable through the seam.** The engine-level `EventRun` test drives the
   real `DirectiveEngineCore`.
6. **Safe degradation.** §6. Blocked is surfaced and not escalated; a blocked
   print past its deadline is escalated, as a stall the operator can read.
7. **Bounded blast radius.** One additive column, one additive migration. The
   spend path gains only refusals — the feasibility gate and the deadline both
   subtract launches. Component prints go through the same
   `BrainCeiling` reserve rail as every other print at `EventRun.swift:209-213`.
8. **Live why-view.** Blocked options appear in `BrainReport` with the missing
   blueprints named, next to the choices already surfaced there.

## 9. What this does not do

- **It does not acquire blueprints.** `orbital_mirror` and
  `terraform_controller` unlock through achievements, decommissioning, or
  trading. The brain will report `TABAT-4-EVT-007` as blocked and leave it
  blocked. That is the correct end state until those unlock.
- **It does not cancel the stuck run.** The operator is hand-feeding it and has
  asked for it to be left alone.
- **It does not settle whether a blocked job self-clears.** If it does, the
  run's next `printing` tick sees the job start and proceeds. If it does not,
  the deadline fires and the retry re-enqueues, which is also correct. The
  design does not depend on the answer, and the answer will be observable in
  the live fleet within hours of the components landing.
- **It does not add per-type stockpile records.** The reserve rail's
  totals-only proxy (`BrainCeiling.aggregateSpendFloor`) is unchanged, and
  component prints are gated by it exactly as relay prints are.
- **It does not change `ResourceCost`.** Six raw types, closed struct.

## 10. Residual risk

The expanded totals for any option touching an unknown blueprint are lower
bounds, and the design leans on `unprintable` being non-empty rather than on the
number being right. If a blueprint ever becomes known *while* its parent is
mid-print, the option's price changes underneath a running directive. Nothing
re-prices a launched run today, and this design does not add that — the run
proceeds on the plan it launched with, and the reserve rail is what stops it
overspending.
