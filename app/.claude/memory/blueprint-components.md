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

Four items shipped, exactly the ones reviewers flagged directly:
`ResourceDemand.swift`'s 8-line header trimmed to 6 (wrapped at the module's
usual ~78-82-character width, every fact preserved verbatim);
`WorldView.swift`'s stale "two columns" comment corrected beside the
three-column select it now sits above; `PrintComponentLine`'s doc corrected
to stop claiming an unreachable nil state (`resolve` always supplies a
concrete `Int` via `?? 0`); and `Printing.swift`'s over-commented private
`nestedKind` helper's 2-line `///` dropped in favour of the one-line body
reading on its own.

**A wider sweep was attempted and reverted.** A full hand-check turned up
fifteen more file headers over the 6-line budget elsewhere in this branch's
touched files (`BrainReport.swift` the worst, at 21 lines) and trimmed all of
them under a scope ruling that said a touched file's header must comply
"regardless of who put it over budget." That ruling was wrong: it is
internally inconsistent with the same task's other half, which says to leave
pre-existing violations in regions this branch never touched — a header this
branch never otherwise edited **is** exactly such a region. Worse, several of
the trimmed headers were load-bearing: `BrainReport.swift`'s explained why
its feed must stay `@Shared(.inMemory)`, why the report lives in Sharing's
store rather than on the actor (stateless between ticks), and why the
boundary is safe off-main without further synchronization — none of that is
recoverable from the code alone, which is exactly what `app/CLAUDE.md`'s
**Keep** list protects, and the same policy requires writing a load-bearing
fact to memory *before* deleting it, not after. The sweep was reverted in
full; those fifteen headers remain pre-existing over-budget debt, unresolved,
left for a future deliberate pass that budgets time to migrate what they
carry into memory notes first.

**The reusable lesson, not the incident:** `check-comments.sh` cannot catch
an over-length file header at all — it is eleven regexes over dates and
device codes with no line-counting of any kind. A header can run to 21 lines
declaring invariants nobody reads again, and the script exits 0 the whole
time. Treat "the linter is green" as proof of nothing here; a header-length
sweep is a hand-check with its own scope discipline (each file its own
load-bearing-content judgment call), not a mechanical trim.

## What only the whole-branch review could see

Eleven task reviews all came back clean, and the final whole-branch review
then found three Criticals — every one of them in `EventRun.printing`, and
every one an interaction between changes that were individually correct.
Reviewing a step machine task-by-task cannot find these; the spend path has
to be read as one system at least once.

**Preferring a free printer needs an in-flight subtraction.** Replacing "one
deterministic printer, wait if it is busy" with "the first printer with no
open operation" looks like a strict improvement, and is not: `missingTree`
counts only devices already STANDING at the depot, so consecutive ticks
recompute an identical bill and hand it to a second free printer. N free
printers meant N times the component bill. `EventRun.printsInFlight(in:)`
now subtracts what this directive already has out, reading
`world.dispatchedOperations` — directive-scoped, unlike the device-keyed
`world.openOperation`, which is why `RelayRun.printInFlight` uses the same
source.

**An unprintable subset must refuse, not print what it can.**
`BlueprintClosure.expand` emits no job for a device with no blueprint, so a
step that reads only `jobs` prints the printable part, sees an empty bill,
and advances — flying a three-hull convoy to an event it cannot satisfy.
`missingTree` returns the unprintable set alongside the jobs and `printing`
stalls `.eventOptionBlueprintMissing` (classified `.escalate`: no retry
unlocks a blueprint) before anything is spent.

**A deadline inherited from a sibling run was shorter than the prints it
bounded.** `printDeadline` was `RelayRun`'s 1800 s, calibrated for an ~800 s
relay; the component blueprints print in 3600-4200 s. Because `printing`
re-dispatches into its own step, `Brain.retryEpisode` never resets, so three
stalls anywhere in a multi-hour phase escalated permanently. It is now
`printSlack` plus the longest SINGLE print still queued — single, not the
phase sum, because `DirectiveExecutor` re-stamps `stepStartedAt` on every
accepted dispatch, making the longest single job the worst case a healthy
run can accrue.

**The fixture that hid all of it: every printing test had one printer.** The
live depot has four autofactories. A single-printer fixture makes the
correct and the buggy code agree, and it hid a Critical through eleven task
reviews, a whole-branch review and a scoped re-review — the last one only
because fixing the double-print removed the accident that was masking an
unreachable deadline check. When a fixture's cardinality is lower than the
fleet's, it is not a simplification, it is a blind spot. Multi-printer tests
now exist; check for the same shape wherever a mission queries a pool.

Related: [supervisor-adopts-row-whole-package-failure](supervisor-adopts-row-whole-package-failure.md),
[demand-derived-mine-ranking](demand-derived-mine-ranking.md),
[comment-policy](comment-policy.md).
