---
name: brain-event-fulfilment-build
description: "Location-event fulfilment BUILT (not yet run live): the fulfillEvent goal + the three-hull eventRun convoy + the operator-invoked courier bootstrap. Carries the defect classes that recurred, the live-roster Critical every fixture hid, and the gates that arm later."
metadata:
  node_type: memory
  type: project
---

The automation brain's **sixth acting capability**, built 2026-08-14 across 52 commits on
`worktree-event-fulfilment-design`. Design: `docs/superpowers/specs/2026-08-14-brain-event-fulfilment-design.md`.
Plan: `docs/superpowers/plans/2026-08-14-brain-event-fulfilment.md`. **Built and reviewed
clean; never yet run against the live account.**

## What it is

`fulfillEvent` ranks the open-event backlog and launches one `eventRun` per theatre: a
`surge_carrier` bearing a `matrix_container` courier plus the option's devices and an
`ftl_beacon`, flying alongside a `cargo_freighter` bearing the resources. It delivers, commits
the event with the empty POST (which refuses unless a replicant stands on site — that is what
the courier is for), plants the beacon, sweeps the reward, and flies both hulls home.
`eventCourierPrint` is an operator-invoked bootstrap standing the courier up.

Schema: two nullable columns (`directives.freighterCode`, `locationEvents.chosenOption`).
Two `MissionAction` cases (`.refreshEvents`, `.completeEvent`) with engine resolvers.

## The premise that had gone stale

Ticket 08 measured **2 active events** and concluded fulfilment was a rare interrupt
(~0.5/day), so the operator seam would be occasional. Measured at build time: **60 active
events across 59 systems**, 51 of them single-option resource drops, and `tendMesh` had
already meshed **58 of the 59**. Fulfilment is a standing backlog, not an interrupt. Whole
backlog: 26,400 units out, 24,400 units plus 72,950 XP back — 19,950 of the returned units
are **rares**, against a 15,193-rares hub reserve.

## The Critical every fixture hid

`EventRun.convoy` and `EventCourierPrint.courierStands` disagreed about what a courier is, and
neither required ownership. On the live roster **`pennig-brain` is hosted by `831B5E49`, a
`matrix_container` standing at `AINALRAM-BELT-1`** — the one operational depot. So the courier
gate passed with nothing printed, the operator's bootstrap was dead (it reported no depot could
print), and the convoy would have bolted the account's own replicant host to a surge carrier and
flown it to an event. A **second** untagged container (`DA56188A`) already stood there too, so
the irreversible-spend path was live rather than conditional.

**Every fixture across five suites held exactly one `matrix_container`, named `COURIER`.** That
is why nothing caught it, through fifteen task reviews. Fixed by one shared ownership-bearing
predicate (`EventRun.isCourierHull` / `isCourier`) requiring **both** the `auto:event` root tag
and membership in `replicantHostDevices`, used by `convoy`, `courierStands` **and**
`EventCourierPrint.container` — tag-scoping the third was required, not optional: without it the
bootstrap tells the operator to replicate into a container the completion predicate can never
accept, a permanent stall.

**The rule this earns:** a selection fixture with one candidate proves nothing. Seed a second,
unrelated candidate of the same shape and assert the intended one wins.

## The defect class that recurred four times

**A step dispatching an IMMEDIATE verb at its own step is an unbounded loop.** `attach`,
`detach`, `collect_resources`, `deposit_resources`, `stow` create no `Operation` row, so an
`openOperation` guard on them is structurally nil, and `DirectiveExecutor` re-stamps
`stepStartedAt` on every accepted dispatch — so no deadline can ever accrue. The plan wrote this
shape in `staging`, `confirmingLoad`, `recovering` and `stowing`. Each was caught by review, not
by tests; a green suite says nothing about a loop that never terminates.

The bounds that work: a confirming step holding on `MissionConfirm.ladder` (which reaches
`.wait`, the only action leaving the step clock alone), or a **per-verb**
`MissionLogBudget.dispatchRounds(…, kind:)` counter when two legs share one dispatch step.
`lastDispatch` is not a bound — it returns the newest line and never counts.

`.refreshEvents` deliberately carries **no `nextStep`** for the same reason: both callers re-ask
on their own step, so a `nextStep` would collapse to `.advanceStep(<same step>)` and poll the
events endpoint every tick forever.

## Wire facts worth not rediscovering

- **`collect_resources` REQUIRES a non-empty resource map** (`CommandClient+Cargo.swift:25`
  throws `missingParameter`, and the OpenAPI schema marks it required); `deposit_resources`
  treats nil as "empty the whole hold". The asymmetry is deliberate and undocumented centrally.
  The reward sweep therefore builds its map from `LocationEventDetail.rewardResources`.
- **`replicate` is not engine-dispatchable at all** — `CommandClient.makeBody` has no case, and
  the real path is `ReplicantsClient.replicate(sourceMatrixCode:targetCode:name:)`. Deliberately
  left to the operator: it fires once per courier, its source/target semantics are unverified,
  and it is irreversible against the account's one spare matrix.
- `OperationKind` is a `RawRepresentable` **struct of constants**, not an enum: `.collectResources`,
  `.depositResources`, `.attach`, `.detach`, `.stow`. No `.replicate` — use `simple(_:)`.
- `Device.replicantCode` records **ownership, not hosting**. Hosting is a roster fact
  (`Replicant.hostedDeviceCode` → `WorldView`/`WorldSnapshot.replicantHostDevices`).
- `Device.cargoUsed` is a non-optional computed `Double`.

## Gates that arm later

- **A second operational theatre.** `ensureEvent` loops theatres against a pre-tick snapshot with
  no target-collision check inside the write transaction, so two theatres sharing one backlog
  could both launch on the same event in one tick — different depots mean different hulls, so
  neither lease guard fires. `ensureMine` has the identical shape. Latent only because the
  account recognises one operational theatre (no `theatrePins`, one print site). **Must land
  before a second theatre is recognised** — the loser's delivery is irreversible spend.
- **A second courier.** Needs a printed `empty_replicant_matrix` (1,000 units / 14,400 s) first;
  the account's one spare is consumed by the first replication.
- **The shared `auto:carrier` pool.** `EventRun.carrierTag` and `MineRecipe.carrierTag` are the
  same string over three live carriers, and nothing records which carrier a courier is bolted to.
  If a mine run takes the carrier an event run used, the next convoy's courier is rejected by the
  attached-branch and the run stalls `loading`.

## Known residuals

- The `fulfillEvent` goal has **no why-view status**: `EventReadiness.idle(reason:)`'s four
  reasons and `EventCandidate.rationale` are computed every tick and discarded. Robustness
  clause 8 ships half — pending option choices render, the goal's own state does not.
- **Clause 6's "clean abort with devices recovered" does not recover devices.** A
  `confirmingProgress` abort routes to `recovering`, but `staging` has already detached the
  devices and beacon and deposited the resources; `recovering` re-attaches only the courier. The
  step order makes it unavoidable — a design inconsistency the build inherited.
- `.eventCommitRejected` is `.retry`-classified but `collecting` has no edge back to `committing`,
  so Retry re-enters `collecting` (a fresh 15-minute poll) three times and escalates. The operator
  copy promises something Retry structurally cannot do.
- `.refreshEvents` has **no read-interval floor** — a full paged `accounts/events` walk every 5 s
  tick, ~180 per deadline window, against `MissionConfirm.readInterval = 30 s` everywhere else.
  The commit path also refreshes twice back to back (`LocationEventsClient.complete` already
  refreshes, then `resolveEventCompletion` refreshes again).
- The untagged spare `matrix_container` at the depot is now ignored and will be printed past
  (880 units) unless tagged `auto:event` by hand.
- `awaitingCourierReplication`'s `detail:` carries only the depot. With two containers standing
  there, an operator replicating into the wrong one gets a stall that never clears.

## Unverified against the live server

The beacon is assumed **not** consumed by the commit (no criteria names it). Whether a
per-theatre tag is accepted as a **print tag** is untested — the known drift is that per-theatre
tags fail as *tag queries* (`GET devices/tags/{tag}`), and `EventRun.printing` stamps a scoped
tag it later reads back. Whether the server clamps or refuses an over-capacity
`collect_resources` is unprobed; the sweep clamps as a hedge. Where the reward physically lands
was established by the operator, not by this build.
