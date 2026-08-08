# The brain's salvage + haul goals — the build record (2026-08-07)

Design: `docs/superpowers/specs/2026-08-07-brain-salvage-goal-design.md`.
Plan: `docs/superpowers/plans/2026-08-07-brain-salvage-goal.md`.
The brain's third and fourth acting capabilities, after
[brain-tendmesh-build](brain-tendmesh-build.md) and
[brain-survey-goal-build](brain-survey-goal-build.md). No schema change, no new
table, no new poller.

## What shipped

- **`Brain.ensureOne`** — the one-live-row helper the four liveness call sites
  share. Takes a kind plus a `matching` predicate, because the general haul
  drainer is one row among future per-site siblings.
- **`Brain.salvageReadiness` / `haulReadiness`** — two pure verdicts, neither
  with a stall case. Salvage gates on the `auto:salvage` tag, staging judged
  through `SalvageRun`'s own queries, a placeable roam centre, and at least one
  MESHED salvage system holding units.
- **`brainManagedKinds`** — `brainManagedStall` widened from `relayRun` alone to
  `{relayRun, salvageRun, haulRun}`. Everything downstream was already built.
- **The relay surgery** — `emplacing`/`activating`/`confirmingRelay`/`restocking`
  and their handlers are gone; `SalvageTargetPlanner` ranks meshed systems only.
- **Derived sinks** — `HaulRun.deliverySink(in:)` and `SalvageRun.hubSystem(in:)`
  replace the two `AINALRAM` constants.
- **Two why-view rows** through a shared `BrainGoalStatus`.

## Where the plan was wrong, and the live fleet with it

**The plan said to delete `SalvageRun`'s relay helpers. That would have broken
`tendMesh`.** `RelayRun` consumes six of them — `relay(aboard:)`,
`deployedRelay(near:)`, `lagrangePoint`, `relayDeviceType`, `relayPollInterval`,
`activationDeadline`. The steps came out; the queries stayed. They now belong to
`RelayRun` in everything but file location, and moving them is a clean follow-up
that should not ride along with a behavioural change.

**The planned planner regression was vacuous as written.** The plan proposed "a
rich unmeshed system loses to a poor meshed one" — but the shipped `RankKey`
already ordered `meshedRank` FIRST, so that assertion passed against the old
code. The behavioural difference only appears when NO meshed candidate exists:
old code returned the one-hop system, new code returns nil. That is the test
that was written, and it was demonstrated failing against the shipped planner.

**`Brain.Snapshot` and the `ensure*` methods did not need widening.** The plan
said make them internal for testability. The shipped suite drives `evaluateOnce()`
through the real `report()`, which is better; only the one test that must reach
the in-transaction guard with a deliberately stale snapshot needs direct access,
so `ensureOne` and `Snapshot` are internal and the three `ensure*` stayed private.

## The defect review caught, and why the tests had missed it

`ensureOne`'s duplicate check was scoped to a directive KIND, and the snapshot it
read predates the tick's own earlier launches — `decide`, `tendRestock` and
`ensureSurvey` all commit before `ensureSalvage` and `ensureHaul` run. **A hull
carrying two automation tags could be committed twice in one tick.** A `relayRun`
or `surveyRun` lands first; the salvage verdict, reading a ledger written before
either, still sees the vessel free.

Both checks now run against rows read INSIDE the write transaction, with a
device-reservation check beside them. **The two are not redundant, and the first
test written for them could not tell them apart:** with one carrier the
reservation guard fires first and the liveness check is never reached. Only when
readiness picks a DIFFERENT vessel does liveness do the refusing. The test now
names two vessels for exactly that reason, and each guard was mutated separately
and failed exactly one test.

Not reachable on today's fleet — the three carriers are singly tagged, which is
precisely the configuration that hides it.

## A refinement that was reverted for being unobservable

The carrier-blocker sentence briefly keyed its ", not the brain's to resolve"
clause on stall DISPOSITION rather than on membership. It is unobservable:
whenever a brain-managed row is escalate-classified, `respondToStalls` escalates
and `decide` reports the stall, so `carrierBlocker`'s sentence never renders for
that row at all. The two expressions agree on every reachable input. Reverted.

## What this cost the fleet, measured

Salvage throughput now depends on `tendMesh` arriving first. At the time of the
change, of 59 undepleted salvage systems, 50 were meshed (50,265 units) and 9
were not (15,170 units — `SUBRA`, `ASELLUSUP`, `ACHERNARAN`, `REGULU`,
`CUSTOSUS`, `GNOMEN`, `SKET`, `FORMISA`, `OTONATIUH`). Those 9 wait for grow
rather than being planted into.

## Carried forward, not fixed

- **Retry amplification.** Both mission-layer re-entry counters
  (`HaulRun.dispatchAttemptCount`, `SalvageRun.stepEntryCount`) terminate their
  backward walk on a `.resolved` entry and count it as one. The brain's auto-retry
  writes exactly that entry, so each retry RE-ARMS the mission's own budget. A
  `haulRun` on `commandRejected` can therefore spend roughly 3 dispatch attempts
  per brain retry × 3 retries. Bounded and operator-resolvable, but those counters
  were calibrated for a deliberate human retry and are now driven by a timer.
- **`salvageReadiness`'s first gate names the wrong thing.** A reserved carrier
  and a nonexistent one both read "no `auto:salvage` vessel"; there is no
  `salvageCarrierBlocker` to match `carrierBlocker`/`surveyCarrierBlocker`. The
  why-view dodges it by reading a live row before re-deriving, so the misleading
  string only surfaces when something ELSE holds the vessel.
- **Gate ordering puts demand last**, so an unstaged fleet with nothing meshed to
  salvage is told to stage a controller. Capability-before-demand is defensible;
  it was chosen rather than argued.
- **Two `DirectivesFeature` reads of `HaulRun.deliveryLocation`**
  (`DirectiveRow`, `DirectiveTargetsSection`) pass the fallback constant — neither
  has a `WorldSnapshot`. Visible at the call site rather than hidden in a default.
- **Three near-identical status types** (`BrainSurveyStatus`, `BrainGoalStatus`,
  and the two render types) want unifying.

## Sign-off (2026-08-07)

`swift build --build-tests` clean. Per-product event-stream runs, one output path
each:

| Product | Tests | Suites | Failed | Crashed |
| --- | --- | --- | --- | --- |
| DirectiveEngineTests | 835 | 119 | 0 | 0 |
| GameServicesTests | 219 | 28 | 0 | 0 |
| DirectivesFeatureTests | 173 | 17 | 0 | 0 |
| GameModelsTests | 98 | 16 | 0 | 0 |

**1,325 tests, zero failures, zero crashed targets.** Pruning the obsolete
emplacement coverage removed 425 lines from `SalvageRunTests.swift`.

Four guards were demonstrated failing before their fix landed: the planner
narrowing against the shipped ranking, the mesh-wait idle, the haul fleet-tag
scoping, and both halves of the `ensureOne` fix. The end-to-end seam test was
mutation-checked — forcing `salvageReadiness` to idle turns it red and leaves
both negative twins green.

Related: [salvage-run-design](salvage-run-design.md),
[haul-run-design](haul-run-design.md),
[brain-executor-seam](brain-executor-seam.md),
[brain-tendmesh-worthiness](brain-tendmesh-worthiness.md).
