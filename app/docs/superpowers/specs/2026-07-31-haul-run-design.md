# Haul Run — design

**Supersedes §6 of `2026-07-30-salvage-run-design.md`.** That section assumed our engine would hand-drive
a `cargo_freighter` through travel → collect → travel → deposit. Probing the live API on 2026-07-31
showed the game already does that work server-side, for free, through the AMI transport controller. The
goal is unchanged; the mechanism is entirely different, and much smaller.

## 1. Goal

The Salvage Run mines a body and moves on, leaving the resources piled where they fell. The Haul Run
brings them home to `AINALRAM-BELT-1` with no operator input, and keeps doing it until cancelled.

It is deliberately generic: it drains *any* stockpile it can reach, so belt-mining output and the
leavings of hand-run operations come home too, not just salvage.

## 2. The mechanism

An `ami_transport_controller` runs a **`ferry`** directive — a continuous interstellar supply line
configured with a `collect` location and a `deliver` location. Per the docs:

> Every tick, the controller reviews the available drones and the configured directive, then issues the
> right sequence of collect and deposit commands to keep the route flowing.

So the engine never issues a `collect_resources` or a `deposit_resources` at all. It chooses *what to
collect* and issues one `set_directive`. That is roughly **one command per pile drained**, against the
~28 per rich system the superseded §6 would have cost.

Two constraints come with `ferry`, both quoted from the docs:

- > Requires the two systems to be linked over the FTL network.

  This is the same FTL-authority rule the Salvage Run already lives under, and the relay the Salvage Run
  plants at each system it works is exactly what satisfies it. The coupling that made the two-directive
  split possible pays off a second time.
- > Cruise transports without their own surge drive will need a supply of surge plates tagged `taxi` at
  > both ends of the route.

  A `cargo_freighter` carries its own `surge` feature, so it is exempt. A `transport_hauler` is
  `cruise`-only and is not. The run does not manage taxi plates; see §8.

**`shuttle` is the same directive for a collect and deliver in the same system.** When a pile happens to
sit in the delivery system, `shuttle` is the correct verb — a `ferry` whose two ends share a system is
malformed. This is the only branch in the dispatch.

`consolidate` was considered and rejected: it takes only a `deliver` and sweeps every location holding
resources, which would remove the need to choose at all — but it is single-system by definition
(*"for cleaning up a system with resources scattered all over the place"*), so it cannot reach salvage in
another star. It remains the right tool for tidying a system, and is not this run's job.

## 3. Verified API facts

All probed live 2026-07-31 unless noted.

- **A `cargo_freighter` can be adopted by an `ami_transport_controller` and participates in `ferry`.**
  Verified by the operator directly, not inferred: `5187CFCF` (`cargo_freighter`, 500 cargo) now appears
  in controller `7D1569BF`'s `controlled_devices` and was observed `depositing` at `AINALRAM-BELT-1`.
  This was the design's one load-bearing unknown — the docs say only that a controller adopts "most
  other non-AMI devices", and our own `DeviceCommand.controllableType` maps a transport controller to
  `transport_drone`, which is not even the type the live controller actually commands.
- **`GET /v1/locations` returns the entire stockpile census in one request** — a map of designation →
  `{devices, resources, resource_sites, location_events, replicants}`. 29 known locations today, 5
  holding resources. `resources` is a **total unit count**, which is all the planner needs; the
  per-resource `GET /v1/locations/{designation}/inventory` breakdown is never required, because the
  controller decides what to load.
- **That census is already persisted locally** as `LocationFootprint` (`UniverseModels`), with a
  `resources: Int` column and a `fetchedAt` stamp, written by `LocationsClient.refreshFootprint()`. No
  new client and no new table are needed — only a way for the engine to trigger the refresh, since today
  the only caller is `LocationsFeature` opening the Locations view.
- **`set_directive` takes `{command, directive, configuration}`** and is already fully wired through
  `CommandClient` (`CommandClient+Lifecycle.swift`), including the loosely-typed configuration bridge.
  `SurveyRun` already dispatches it.
- **`set_directive` classifies as `.immediate`** — `CommandClient.completion(for:)` falls through to the
  default branch, so **no `Operation` row is created**. This is the exact trap recorded in
  `same-step-dispatch-needs-tracked-op`: a step that dispatches it naming *its own* step as `nextStep`
  re-issues forever, because the `openOperation` guard is structurally nil and every accepted dispatch
  re-stamps `stepStartedAt`. §6 of this spec addresses it directly.
- **A controller's in-force directive is readable**: `ami_directive: {name, _eval_state, config}` maps to
  `Device.currentDirective` / `currentDirectiveConfig`. This is the server's own record of what each
  controller is working, so the run needs **no new column** to remember its assignments.
- **`_eval_state` reporting `blocked:` does not mean the directive is dead.** Controller `7D1569BF` reads
  `blocked:[('no_taxi_plate', 1)]` — a genuine shortage for its cruise-only haulers — while the freighter
  hauls normally on the same directive. Treating `blocked:` as a fault would halt a healthy run. It is
  never read as a stall signal.
- **Costs** (`GET /v1/blueprints`): `cargo_freighter` 1,245 units / 500 cargo / `surge,cruise,transport`;
  `transport_hauler` 240 / 80 / `cruise,transport`; `surge_plate` 260. Delivery-end stock at
  `AINALRAM-BELT-1` stands at 59,230 units.

## 4. Fleet — resolved by tag, plural

The run drives **every controller tagged `auto:haul`**, resolved by one `.refreshFleet(tag:)` read. The
operator's act of tagging is the consent: an untagged controller is untouched, and untagging one hands it
straight back. That is why there is no capture-and-restore of a controller's prior directive — the tag
already expresses the intent, and a run that silently reverted a controller would fight the operator.

The adopted transports need no tags of their own. A controller reports them inline in
`controlled_devices`, so unlike the Salvage Run — where stowing erases `location` and only a tag read can
see the fleet — one controller read is sufficient.

`Directive.fleetTag` and `Directive.controllerCode` already exist from the Salvage Run, so **this feature
adds no migration.**

## 5. Planning — rank, then assign

A pure function over the local footprint and device rows, mirroring `SalvageTargetPlanner`:

1. **Candidates** — every `LocationFootprint` with `resources > 0`, excluding `AINALRAM-BELT-1` itself.
2. **Reachable** — keep only those whose *system* is in the FTL mesh, reusing
   `SalvageTargetPlanner.meshSystems(in:)` (derived from device rows: a device with the `relay` feature
   in `relaying` status). This replaces §6's `in_control_range` rule, which cannot work — a bare
   stockpile has no device on it to read a flag from. The mesh test is also exactly the condition
   `ferry` itself imposes, so the planner and the server agree by construction.
3. **Rank** by `resources` descending.
4. **Assign** distinct piles to controllers in rank order — the *k*-th controller takes the *k*-th pile.
   Two controllers are never pointed at the same pile, which would put their drones in contention for
   the same units.

If controllers outnumber reachable piles, **the surplus are left as they are** rather than doubled up.
A controller pointed at a drained pile idles harmlessly, and contention seemed the worse failure.

Against the census as it stands, that yields: `ATIANFU-BELT-1` (3,537) → `SHERATANON-6-1` (294) →
`SHERATANON-7-4` (61), then idle. `TENEGSHE-3` (80) is excluded — `TENEGSHE` holds no relay — and
becomes reachable the moment one is planted there, with no change to the run.

**An empty frontier is a lull, not an ending**, exactly as for the Salvage Run: the run answers idle and
re-checks on a backoff rather than completing. The Salvage Run keeps mining and the survey roam keeps
finding salvage, so piles appear under it continuously.

## 6. The machine

Steps, with the dispatch/confirm split the `.immediate` classification forces:

1. **`preflight`** — one `.refreshFleet(tag: "auto:haul", thenStall: .noHaulControllerTagged)`. No tagged
   controller is a configuration error, so it stalls rather than idling. Otherwise advance to
   `surveying`.
2. **`surveying`** — trigger a footprint refresh (`GET /v1/locations`, one request) so both discovery and
   drain-detection come from the same read. Freshness-gated on `LocationFootprint.fetchedAt`, so the
   engine's 5s tick does not multiply into requests, then advance to `assigning`.
3. **`assigning`** — pure. Compute the assignment from §5. For the first controller whose in-force
   `config.collect` differs from its assigned pile, dispatch `set_directive` (`ferry`, or `shuttle` when
   the pile is in the delivery system) and move to `confirming`. When every controller already matches,
   advance to `hauling`. One controller per evaluation keeps the one-action-per-tick contract; N
   controllers settle over N ticks.
4. **`confirming`** — poll the controller's in-force `currentDirective` / `currentDirectiveConfig` until
   it reflects the dispatch, then return to `assigning` for the next controller. This step exists solely
   because `set_directive` creates no tracked `Operation`; folding it back into `assigning` is the
   documented infinite-dispatch bug.
5. **`hauling`** — `.wait` until the **poll interval of 60 seconds** has elapsed, then back to
   `surveying`. `.wait` is the only action that lets `stepStartedAt` accumulate honestly, which is what
   makes the interval real; 60s matches the Salvage Run's idle backoff.

A pile counts as **drained** when its `LocationFootprint` reads `resources == 0`, or when it has
vanished from the footprint entirely. Each pile is appended to `Directive.targets` when first assigned —
append-only history, exactly as the roams use it — which is what makes "3 piles drained" computable in
§9 without a new column.

Steady-state cost is therefore one `GET /v1/locations` per 60s, plus one `set_directive` each time a
pile drains — nothing per round trip, and nothing per unit moved.

## 7. Stalls

The run halts on configuration errors only, and never on a quiet hauler.

| Reason | Raised when |
| --- | --- |
| `noHaulControllerTagged` | a fresh tag read finds no `auto:haul` controller (**the only new reason**) |
| `unreachableDevice` | every tagged controller reports `in_control_range == false`, so no `set_directive` can land — after a bounded wait, since a stationary replicant moving is transient |
| `commandRejected` | the server refuses `set_directive` |

Explicitly **not** stalls: no reachable pile (idle and re-check); `_eval_state: blocked:` (see §3); a
pile that drains slowly. Per the ruling carried over from §6 and §7 of the superseded spec, a quiet
hauler with the miner still working is healthy.

## 8. Deliberately not built

- **Taxi-plate management.** Cruise-only haulers need `taxi`-tagged surge plates at both ends, and the
  live controller is short one right now. Since a `cargo_freighter` is exempt and is the vessel this
  design is built around, the run neither ships nor deploys plates. The natural home is the same future
  emplacement errand that §10 of the superseded spec records for relays and beacons.
- **`priority` resources.** `ferry` accepts an ordered resource preference. There is no current need to
  prefer one resource over another when the goal is "drain the pile", so it is not exposed.
- **Clearing a directive on cancel.** Cancelling leaves each controller pointed wherever it was last
  set. Untagging is the operator's off-switch; see §4.
- **Fixing `DeviceCommand.controllableType`.** It maps `ami_transport_controller` → `transport_drone`, so
  the device inspector's adopt picker offers none of the `transport_hauler`s actually in the fleet. A
  real bug, found while verifying §3, but unrelated to this run and better fixed on its own.

## 9. UI

One launcher sheet, following `NewSalvageRunSheet`: it lists controllers carrying `auto:haul` and offers
a distinct empty state naming an untagged transport controller, so a staged-but-untagged fleet says so
instead of showing an empty picker. Row subtitle reports work done rather than *m/n*, matching the roam
precedent — "3 piles drained · hauling `ATIANFU-BELT-1`". List rows, detail pane, stall panel and step
timeline all come free from `DirectivesFeature`.

Location and system designations render in a mono token, per the house rule.

## 10. Build order and testing

1. `DirectiveKind.haulRun`, the `noHaulControllerTagged` reason, and the footprint refresh action.
2. `WorldSnapshot.footprints`, read in the same transaction as everything else.
3. The planner — pure, tested against a fixture footprint plus fixture device rows, including the
   mesh exclusion, the same-system `shuttle` branch, distinct assignment across controllers, and the
   surplus-controller case.
4. The step machine, tested as `(directive, world) → action` under `TestClock` with no network, with
   explicit coverage of the dispatch/confirm split (a re-entry must never re-dispatch).
5. The launcher sheet.

No migration. No new domain client. `DevicesClient.fetchByTag` and `set_directive` both already ship.
