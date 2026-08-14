# Brain capability: location-event fulfilment

Design for the automation brain's sixth acting capability — the `fulfillEvent` goal
and the `eventRun` executor that delivers resources and devices to a location event,
commits it, plants an FTL beacon, and brings the convoy home.

This is the capability the map has carried as "design-complete, needs a build plan"
since ticket 08. It is no longer design-complete: the world changed underneath it,
and this document is the design that replaces the 2026-07-31 research assumptions.

## 1. What changed since ticket 08

The research note (`.scratch/automation-brain/research/08-location-event-fulfilment.md`)
was written against 2 active events and concluded fulfilment was "a rare bursty
interrupt (~0.5/day)", so the operator seam would be occasional. Measured live
2026-08-14:

| | 2026-07-31 | 2026-08-14 |
|---|---|---|
| Active events | 2 | **60** |
| Distinct systems | 2 | 59 |
| Multi-option events | 5 of 16 all-status | **6 of 60 active** |
| Event systems with a relay | — | **58 of 59** |

The survey and `tendMesh` automations are what changed it: discovery is a scan
side-effect, and `ValueTier.event` already ranks events top of the grow key, so the
mesh has been building roads to events for two weeks. Only `OMEROPE` lacks a relay,
and that is where `pennig-1` already sits.

Fulfilment is therefore a **standing backlog**, not an interrupt. That inverts the
seam's design pressure: an operator decision per event would be a chore, not a rarity.

## 2. What the backlog is worth

Whole-backlog arithmetic, cheapest criteria option per event:

- **Spend** — 18,380 units of resources, plus 5,040 units of option devices and
  3,000 units of beacons (60 × 50). Call it 26,400 units. Only 6 events want devices
  at all; `TABAT-4-EVT-007` alone accounts for 2,750 of the 5,040.
- **Return** — 72,950 XP, 88 civilisation points, and **24,400 units of resources**:
  rares 19,950, volatiles 3,650, structural 550, conductive 250.

So the backlog is roughly unit-neutral in bulk and strongly positive in the scarce
type. The hub holds 15,193 rares; the backlog returns 19,950 and consumes 600.
Draining it more than doubles the rares reserve.

Against hub stock at `AINALRAM-BELT-1` (carbon 29,319 · conductive 37,111 ·
rares 15,193 · silicates 23,776 · structural 144,315 · volatiles 7,841 = 257,555),
the whole backlog is ~10% of holdings and `BrainCeiling.aggregateSpendFloor` (35,078)
is nowhere near binding. The reserve rail stays as the only brake and will not fire.

`TABAT-4-EVT-007` is the outlier worth naming: tier 4, 30,000 XP, 15 cp, and
rares 4,000 + volatiles 2,000 returned. Its two options price differently —
`climate_biosphere_restoration` at 2,750 units of devices + 700 of resources,
`atmospheric_climate_restoration` at 2,850 + 500 — and the second is the one the
freighter can actually carry in a single trip.

## 3. Locked decisions

Settled with the operator during requirements gathering. Do not relitigate.

1. **Courier hull = `matrix_container`**, riding the surge carrier's attach grid.
   880 units / 4,800 s, against a heaven_vessel's 4,400 units / 28,800 s. Consequence:
   the carrier flies on **every** event, including resource-only ones, because the
   container has `cruise` but no `surge`.
2. **The operator seam fires only on real choices** — the ~6 multi-option events.
   Single-option events are unattended end to end.
3. **The beacon travels in every convoy**, planted at the event location as part of
   the same trip rather than a later sweep.
4. **Work the whole backlog, ranked**, with the existing per-type reserve floor as
   the only spend brake. No reward-per-unit bar.
5. **One convoy at a time to start**, with concurrency a constant to lift later
   rather than a redesign.
6. **One event per convoy.** No touring. The freighter's 500-unit cap means a typical
   350–500-unit event fills it anyway, so batching buys little on the resource side.

## 4. Why two ships, and why they are not interchangeable

Verified from `GET /v1/blueprints` and live device reads:

| | cargo | stow | attach | features | commands |
|---|---|---|---|---|---|
| `cargo_freighter` | **500** | 0 | 0 | surge, cruise, transport | `collect_resources`, `deposit_resources`, `travel`, `recall` |
| `surge_carrier` | 0 | 0 | **9** | surge, cruise, attach | `attach`, `detach`, `travel`, `recall` |
| `matrix_container` | 0 | 1 | 0 | cruise, cradle | `travel` |
| `ftl_beacon` | 0 | 0 | 0 | stow, audit, comms | — |

The two hulls are strictly complementary: the freighter moves resources and nothing
else, the carrier moves devices and nothing else. A beacon cannot ride the freighter
(cargo is resources-only, and the beacon has no cargo capacity of its own); it rides
the carrier's attach grid, the same way `DeviceListContainmentTests` already models a
beacon attached to a `surge_plate`.

The carrier's 9 points are never tight. The largest single criteria option in the
backlog is 5 devices (`PIPIROMA-3-EVT-004`, 5× `electrodynamic_tether`), so the worst
case is 5 devices + courier + beacon = 7 of 9.

The freighter's 500 units bind exactly once: `TABAT-4-EVT-007`'s
`climate_biosphere_restoration` option wants 700 units. Its sibling option
`atmospheric_climate_restoration` wants exactly 500, so option selection resolves it —
one more reason the option choice must be able to see cargo capacity.

**Fleet on hand:** 3 `surge_carrier` idle at the hub tagged `auto:carrier`,
8 `cargo_freighter` (2 idle at the hub, 6 out on mine/haul), 8 `ftl_beacon` already
deployed and `monitoring`. Five of the 60 active events sit at already-beaconed
locations (`MAHOSATI-2`, `MENKENTAN-3`, `PIPIROMA-3`, `SANSUNU-2`, `TENEGSHE-3`), so
the beacon leg skips there.

## 5. The commit precondition

`POST /v1/locations/{location_code}/events/{designation}` takes no request body and,
per the current spec text, *"Requires the account to have discovered the event (via
scan) and to have a replicant at the event's location. Resolver replicant is
auto-picked: most recently arrived (LIFO) at the location."*

All 60 active events read `progress.replicant_present: false`. Neither the freighter
nor the carrier can host a replicant — only a cradle hull can. That is what the
courier exists for, and it is why the courier is in the convoy rather than the
capability being pure logistics.

Option selection is likewise not a parameter: you stage one option's devices and
resources on site, the server sets `progress.met` and stamps `progress.met_option`,
and the empty POST commits whatever was satisfied.

## 6. The goal

`fulfillEvent` already exists in the locked five-goal vocabulary at acquisition
priority #2 (protect-committed → **fulfillEvent** → production → tendMesh → survey).
The brain derives candidates each tick from the existing `LocationEvent` rows. No new
candidate table, no new poller — `LocationEventsClient.refresh` already runs off the
SSE route and the feature `.task`.

A candidate is an event that is `active`, is not already served by a running
directive, and whose option is decidable (single-option, or multi-option with a
recorded choice — see §9).

### Ranking

Lexicographic, in `GrowRanking`'s shape:

1. **`progress.met` already true** — something is already staged on site; the run
   reduces to courier + commit. No such event exists today, but a partially-delivered
   event left by an aborted run produces one, so the class must exist.
2. **tier desc** — tier 4 before tier 2 before tier 1. This is also value-density
   order: `TABAT-4-EVT-007` returns ~9 XP per unit spent against an
   `optics_request`'s 2.0 (500 XP for 250 units).
3. **round-trip cost asc** — `2 × distance × secondsPerLy` from the theatre depot,
   reusing `HaulTargetPlanner`'s `secondsPerLy = 30`.
4. **designation asc** — deterministic tie-break.

Ranking is contention resolution, per ticket 03's one-greedy-pass rule. With the
concurrency cap at one, the top-ranked decidable event is simply the one that runs.

## 7. The `eventRun` executor

One composing `MissionStepMachine`, one new directive kind `eventRun`, owned by the
surge carrier. It composes the `print` and `deliver` engines exactly as `RelayRun`
does, and adds staging, commit and collection.

| Step | What it does |
|---|---|
| `preflight` | Resolve theatre depot, carrier, freighter, courier. Confirm the event is still `active` and its option is decidable. Check the reserve rail. |
| `printing` | Enqueue the missing option devices and one `ftl_beacon` at the depot autofactory. Skip the beacon if the location already has one. |
| `loading` | `attach` courier + beacon + devices to the carrier; `collect_resources` into the freighter. |
| `departing` | `travel` both hulls to the event location. |
| `confirmingArrival` | Arrival watermark gate on both hulls. |
| `staging` | `detach` devices and beacon at the location; `deposit_resources` from the freighter. |
| `confirmingProgress` | Re-read the event until `progress.met` **and** `progress.replicant_present` are both true. |
| `committing` | The empty POST. |
| `collecting` | Read the location and `collect_resources` the reward pile into the now-empty freighter. |
| `recovering` | `attach` the courier back to the carrier. Leave the beacon deployed. |
| `returning` | `travel` both hulls to the theatre depot. |

### Step notes that are not obvious

**`printing` must use the fresh-clone-evidence pattern** with the witness on
`stepStartedAt`, never on the op close — the close-poll refreshes the hub row, which
makes a close-derived watermark self-satisfying. This is the exact race that produced
`.scratch/automation-brain/issues/13` and `14`. The autofactory queue is shared and
**never leased**, per ticket 05.

**`staging` must leave devices deployed, not stowed.** `GET devices?location=X`
answers presence and stowing clears location, so a stowed device does not count
toward `progress`. Detaching from an attach grid leaves the device at the location,
which is what is wanted.

**`confirmingProgress` is a fresh-evidence gate, not a local-row read.** It must
prove the read post-dates `stepStartedAt` and it must sit after the deadline check,
or a failing read loops forever. It has three exits: met → `committing`; event
`status == "completed"` by a path this run did not take (the operator by hand, or
another account) → abort to `recovering` with the devices re-attached rather than
stranded; neither, past deadline → stall `eventCriteriaUnmet`.

The abort exit is ordinary error handling, not a hedge against competition. It costs
one branch and its absence costs a carrier's worth of hardware left on someone
else's planet.

**`collecting` exists because the reward lands as location inventory.** The freighter
is already on site with a hold it just emptied, so it sweeps there rather than
waiting for a census read to notice the pile. Anything above its 500-unit remaining
capacity falls to the general Haul Run drainer as backstop, which is also what
collects piles from events completed before this capability existed.

**`returning` must resolve the depot through `WorldView.theatre`, never
`originDesignation`** — that field is `SiteAssay.system(of:)`, and a bare system
designation lands the hull at an entry-point L4 away from the printer. This is the
trap `relay-return-and-restock` already paid for.

**`recovering` must not depart with a detached device left behind.** The
`recall-clears-the-bots-location` incident is the precedent: a convoy that advances
on an emptiness check computed from a set that structurally cannot contain the device
in question will leave it. The courier is the device that matters here, and losing it
costs the capability, not just a hull.

## 8. Leases and schema

`RelayRun` needed only the carrier `deviceCode` as its lease, because the relay was
held transitively by stow. Two things break that here.

**The freighter flies independently.** It is not attached to the carrier, so no
containment edge holds it. It gets a nullable **`directives.freighterCode`** column,
stamped at launch and swept by `reservedDevices` — the same move `claimedRelayCode`
made for the identical "which one is mine" problem, and consistent with
`sourceRelayCode` beside it.

**`reservedDevices` follows transitive stow, but not attach.** A courier bolted to a
flying carrier is invisible to the sweep today. That edge has to be closed or a second
run can commit a device that is already airborne. `DeviceListLayout.forest` already
models `attachedTo`, so the containment concept exists; the reservation sweep needs to
learn it.

**Schema changes, all additive:**

| Table | Column | Why |
|---|---|---|
| `directives` | `freighterCode TEXT NULL` | the second lease |
| `locationEvents` | `chosenOption TEXT NULL` | the operator's option pick |

Both are `ALTER TABLE ADD COLUMN` migrations appended to `GameDatabase.manifest`,
never edits to a shipped `CREATE TABLE`.

Fleet tags follow the theatre-scoped convention: `auto:event:<theatre>`, stamped on
the directive and resolved through `RepairFleet.root(of:)` before any tag reaches the
server, because `GET devices/tags/{tag}` knows only bare tags.

## 9. The operator seam

Multi-option events are **skipped in ranking until a choice exists**, and the pending
choice is surfaced in the brain's why-view rather than as a stalled directive.

Launching a run that immediately stalls on `.decisionRequest` would park the only
carrier behind one unanswered question and freeze the other 54 events. Skipping keeps
the convoy working and costs nothing, because the choice is a property of the event
and outlives any run.

The pick persists as `locationEvents.chosenOption` — the option's `name` string. The
surfaced comparison shows, per option: the device bill and what we already hold, the
resource bill against current hub stock, the slowest print time, and whether the
resource bill exceeds the freighter's 500-unit capacity (which is what decides
`TABAT-4-EVT-007`).

Ticket 04's `.decisionRequest` disposition still applies to any decision raised on a
*running* row; this seam simply raises the event-option choice earlier, before a
convoy is committed.

## 10. Growing the courier

A one-time bootstrap, operator-invoked, shaped like the existing `MineFleetPrint`:

1. Print a `matrix_container` at the depot (880 units, 4,800 s).
2. `replicate` into the `empty_replicant_matrix` already owned (`1F6A12EB`, stowed
   aboard `965AC2C3` at the hub, with `replicate` live in its command list). The
   matrix half is therefore free.
3. Stow the new matrix in the container, mirroring `pennig-brain`'s hosting
   (matrix `6AAA133E` stowed in container `831B5E49`).

Until a courier exists the `fulfillEvent` goal reads **idle, never stalled** — the
same no-stall-case construction `Brain.surveyReadiness` uses, so it cannot escalate
to the operator for a condition only a print can fix.

Replication is gated on the `matrix` feature and an `empty_replicant_matrix` loses
that feature once replicated into, so this consumes the account's one spare. A second
courier needs a new `empty_replicant_matrix` printed first (1,000 units, 14,400 s) —
relevant when concurrency lifts above one.

## 11. Robustness

Answering `brain-robustness-bar`'s eight clauses. Each must be re-verified with
evidence at review.

1. **Selector, not enactor.** The brain ranks events and launches `eventRun` rows.
   Every command still flows executor → `CommandGovernor` → engine. The brain issues
   no `attach`, `travel`, `collect_resources`, or POST itself.
2. **Stateless between ticks.** Candidates re-derive from `LocationEvent` rows and
   running directive rows each tick. `chosenOption` lives on the event, not in brain
   memory. No accumulator, no backoff timer.
3. **Pure selection; the API vetoes, never chooses.** `printStockShort` and the
   reserve rail can veto a launch; neither can pick which event runs.
4. **Three-tier snapshot fidelity.** Ranking reads local `LocationEvent` rows;
   `confirmingProgress` and `preflight` buy fresh reads. A stale row costs a wasted
   trip, never a wrong commit — staleness degrades efficiency, not safety.
5. **End-to-end through the real seam.** `EventRunEngineTests` must drive `eventRun`
   through `DirectiveEngineCore`, not a pure-function table. Every `RelayRun` test was
   a table and the engine path was untested, which is how the `paid`-set regression
   reached production.
6. **Safe degradation.** No courier → idle, surfaced not escalated. Multi-option
   without a pick → why-view item, not a stall. Criteria unmet after delivery →
   `eventCriteriaUnmet`, escalate. Event already `completed` on arrival → clean abort
   with devices recovered, no stall.
7. **Bounded blast radius.** Two additive nullable columns; no rewrite of any shipped
   run. Don't-strand covers the courier at `recovering` and both hulls at `returning`.
   The reserve floor is the spend ceiling and is measured as non-binding for this
   backlog.
8. **Live derived why-view.** Names the ranked event, its tier and round-trip cost,
   the chosen or pending option, and any veto in force.

## 12. Risks and first-run verifications

**Attaching a `matrix_container` to a `surge_carrier` works** — established live
by the operator, 2026-08-14. This was the design's one load-bearing unknown: no
test could settle it, and a refusal would have forced the courier onto a
self-surging heaven_vessel and reversed §4's "carrier flies every event"
consequence. The courier rides the attach grid as designed.

**The beacon is assumed not to be consumed by the commit.** Consumption is scoped to
the met option's `criteria`, and no criteria names `ftl_beacon`. Watch it on run one.

**Where a new replicant is hosted after `replicate` is assumed, not verified** — that
it takes the device its matrix is stowed in. Watch it on the courier bootstrap.

**`secondsPerLy = 30` remains uncalibrated**, and this design makes it a second
consumer alongside `HaulTargetPlanner.roundTripRank`. Not a blocker; a standing debt.

**A brain retry re-arms the mission's own re-entry budget**, because both counters
stop their walk on the `.resolved` entry the retry writes. `eventRun` inherits this
residual from the salvage and mine builds; it is not made worse here.

## 13. Out of scope

- **Touring several events per convoy.** Decided against for the first build; revisit
  once real travel cost is measured rather than guessed.
- **Concurrency above one convoy.** The design admits it as a constant, not a
  redesign; a second courier needs a printed `empty_replicant_matrix` first.
- **Deliberate placement of beacons at locations with no completed event.** The docs
  are explicit that a beacon pays off where an event has *already* been completed, so
  a speculative beacon sweep has no value to chase.
- **Reward-per-unit worthiness bar.** Ruled out — the backlog is unit-neutral and
  rares-positive, so there is nothing to protect against.
