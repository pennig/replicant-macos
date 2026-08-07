# Service-bot repair for the Survey Run — the build record (SHIPPED 2026-08-06)

Design: `docs/superpowers/specs/2026-08-06-fleet-repair-design.md`.
Plan: `docs/superpowers/plans/2026-08-06-survey-fleet-repair.md`.
Branch `worktree-fleet-repair-build`, 13 commits (`ffe1939..49853f9`), 8 tasks.
Additive: no migration, no schema change, no new table, no new poller.

## What shipped

**Repair is autonomous, but only once the bot is ARMED.** A service bot whose
`service` directive is ACTIVE repairs damaged devices in its system with no
per-device command — nothing here issues `repair`. **A freshly deployed bot is
not armed**: it lands with `ami_directive_status: "paused"`, verified against
the server on the first live run, so this build deployed both bots and they
stood idle for the whole survey while the gate read them as not-repairing and
released the vessel immediately. Silent no-repair, which is exactly what the
design meant to make loud.
Closed 2026-08-07 by the `armingBots` / `confirmingBotArm` pair — see the
arming section below.

- **`RepairFleet`** — the pure query namespace: `bots(aboard:in:)`,
  `bots(deployedNear:in:)`, `anyBotDeployed`, `isRepairing(_:)`,
  `needsRepair(_:)`, `fleet(of:in:)`. Sibling of `AMIFleet`, same contract.
- **Five new `SurveyRun` steps** interleaved into the existing eight:
  `deployingBots` / `confirmingBotDeploy` after arrival, `repairing` after
  `recover`, then `stowingBots` / `confirmingBotStow` before `.advanceTarget`.
- **`DirectiveAttentionReason.repairUnfinished`**, disposition `.escalate`.
- **`DirectiveLogRetention`** in `GameSync` — an hourly sweep beside
  `OperationRetention` on the same `DeadlineScheduler` branch.

**Two bots per fleet, not one**, because a lone bot cannot repair itself and
eventually crosses the floor below which it can no longer repair others.

## The three traps that cost fix rounds

1. **`Device.location` is a SITE, not a system.** `SiteAssay.system(of:)` splits
   on the first hyphen, so `TAU-2` and `TAU-9` are different locations in one
   system. The bot query originally matched `vessel.location` exactly — but
   `patrol`/`service` are system-scoped and the bot CRUISES to each damaged
   drone, so a bot doing its job vanished from the query: the gate released
   mid-repair and departure abandoned both bots permanently. Every test
   co-located bot and vessel at `SOL-3`, which is exactly the blind spot.
   Any "is my device still out there" query over a scattered fleet must scope
   by system.

2. **`DirectiveExecutor.move` re-stamps `stepStartedAt` on EVERY `.advanceStep`.**
   So a dispatch/confirm PAIR that ping-pongs — `deployingBots ⇄
   confirmingBotDeploy` — resets the very clock its deadline measures, and no
   deadline can ever fire. This is `same-step-dispatch-needs-tracked-op` one hop
   removed: splitting dispatch from polling is necessary but NOT sufficient when
   the two steps loop. The bound must come from something re-entry cannot
   rewind — here a walk of the directive's own `.stepStarted` log entries
   (`SurveyRun.dispatchRounds`, following `SalvageRun.stepEntryCount`), broken
   by any step outside the pair so each target gets a fresh budget.
   A test that hand-sets `stepStartedAt` to an unreachable past value will pass
   over this defect; drive real re-entries instead.

3. **A shared test helper at internal scope captures other suites' call sites.**
   `RepairTestSupport` first declared `device(...)` / `world(devices:)` at
   internal scope. Ten suites in `DirectiveEngine/Tests` declare PRIVATE helpers
   of those base names whose parameters after the first are all defaulted, and
   Swift's overload resolution prefers a candidate needing no defaulted
   arguments over a private one needing three — so `HaulRunTests` and
   `RelayReturnAndRestockTests` silently rebound to the new helper and lost
   their footprints census and their own `now`. Four unrelated tests broke.
   Shared fixtures in this module carry a prefix (`repairDevice`, `repairWorld`,
   `repairDirective`, `repairFixtureNow`).

## Preconditions and residuals, all latent on today's fleet

- **`bots(deployedNear:)` matches ANY deployed service bot in the system,
  including another fleet's — and it is the query that issues `recall`.** There
  is no per-fleet bot ownership signal. Inert while one survey fleet owns the
  only two bots; it ARMS the moment the mine or salvage fleets get bots, which
  the design explicitly plans. Close this before a second bot-carrying fleet
  exists.
- **`recall` stows on the NEAREST craft, not necessarily this vessel.** The
  departure path uses `recall` rather than `stow` because a cruised-away bot is
  not co-located and `stow` requires co-location. If another craft is nearer,
  the bot leaves the query as stowed and the vessel departs having put its bot
  in someone else's hold.
- **`confirmBotDeploy` has no deadline.** The dispatch loop is bounded, but if
  bot rows never refresh the confirm step returns `.refreshDevices` every tick
  and never re-enters the dispatch step, so the bound is never consulted. Same
  documented trade as the brain's transient-deferral path: one `.high` read per
  tick, no backoff.
- **A bot-recall failure escalates `.dronesNotRecovered`** — a drone reason for
  a bot problem, so the panel names the wrong hardware.
- **`isRepairing` reads `detail["repair"]["target_device_code"]`, and the
  WORKING shape was never probed live.** Idle bots carry no `repair` block, so
  only the absence is confirmed. If the field is named otherwise the gate
  silently degrades to no gate.

## The retention sweep does NOT fix what motivated it

`DirectiveLogRetention` never prunes an entry owned by a directive in
`DirectiveStatus.openCases` (`.running`, `.needsAttention`, `.paused`), because
a live mission re-reads its own log every tick. But the growth that motivated it
is exactly on open rows: of 9,442 live entries, 8,394 belonged to the single
RUNNING `haulRun`, and the persistent runs never terminate. On today's database
the sweep deletes approximately zero.

It is a correct backstop for terminal runs and for orphaned AMI entries (whose
`directiveID` is nil and which age on time alone). It is **not** a bound on
`directiveLogEntries`.

**RESOLVED 2026-08-06, and not the way this note first proposed.** A
per-directive row cap was the wrong shape — see
[directive-log-window-and-timeline](directive-log-window-and-timeline.md). Rows
are ~132 bytes and disk was never the problem; the cost was re-reading them all
every tick. The fix bounds the QUERY (`WorldSnapshot.logWindow`) and deletes
nothing, which also keeps the timeline's full history. Suppressing the writes
would have been worse still: three loop bounds count exactly those rows,
including the one this build added.

## Verification at sign-off

Per-product event-stream runs, one output path each:
`DirectiveEngineTests` 709 functions / 95 suites, `GameServicesTests` 219 / 28,
`DirectivesFeatureTests` 139 / 14, `GameModelsTests` 81 / 15,
`GameSyncTests` 42 / 11 — **zero failures anywhere**, `swift build
--build-tests` clean.

**It ships INERT until an operator stages two service bots aboard the survey
vessel.** Survey Run never stows or adopts; staging is the player's job.

## Arming the bots (2026-08-07) — the first live run's finding

Deploying a bot is NOT enough. The first real survey deployed both bots at the
target system and neither repaired anything, because a deployed bot reads
`ami_directive_status: "paused"` — confirmed against the server, not a stale
local row. The failure was silent by construction: `repairing` reads a paused
bot as not-repairing and releases the vessel at once.

`armingBots` / `confirmingBotArm` now sit between `confirmingBotDeploy` and
`configuring`, dispatching only what a bot actually lacks:

    directive name ≠ service          → set_directive(directive: "service")
    name is service, status ≠ active  → simple("activate")
    name service and active           → armed, skip
    round bound exceeded              → stall(.serviceBotNotArmed)

**The run SETS the directive rather than inheriting one**, for the same reason
`SurveyRun.configure` puts its own `surveyConfig` in force: `available_directives`
is `["patrol", "service"]`, and `patrol` DEACTIVATES each device to restore it
fully while `service` hot-repairs without deactivation. A bot left on `patrol`
by manual use would switch off survey drones mid-survey.

A bot wrong on both facts is renamed on one round and activated on a later one —
a mission returns exactly one action. The loop is bounded off
`SurveyRun.dispatchRounds` (the directive's own `.stepStarted` log, immune to
`stepStartedAt` re-stamping), and the bound covers BOTH dispatch branches, so a
bot refusing to activate terminates the same way as one refusing `set_directive`.

## An instant command leaves an operation that never closes (2026-08-07)

The second live incident, and the more general lesson. A Survey Run entered
`stowingBots`, dispatched nothing for twenty minutes, and stalled — while every
drone sat safely aboard.

**`recall` takes its deadline from the recalled device's travel block.** A bot
already co-located with the vessel stows INSTANTLY, so there is no `arrives_at`,
so its `Operation` row is written `active` with **`completesAt: nil`**.
`DeadlineScheduler` has nothing to fire on, so that row stays open forever. The
command itself succeeded — the bots stowed, travelled, and redeployed. Only the
bookkeeping stuck.

`stowBots` gated on `world.openOperation(for:)`, so it waited on a row that
could never resolve and burned its backstop.

**The rule: an operation carrying no `completesAt` must never block a dispatch.**
It cannot resolve, so waiting on it is waiting on nothing. `stowBots` now uses a
narrow private predicate; `WorldSnapshot.openOperation(for:)` is deliberately
UNCHANGED, because the other twelve callers ask "is this device busy?" — a
different question — and every one of them guards a `.travel`/`.print` behind a
co-location check that prevents the instant-completion shape arising at all.

**The stuck row clears itself once the dispatch is unblocked**: `CommandClient`
allows at most one open op per device and supersedes the prior one when the new
command is CONFIRMED (a 4xx leaves the prior untouched), so re-issuing the recall
retires the dead row.

**A bot that will not come home is `serviceBotNotRecovered`**, not
`dronesNotRecovered`. Borrowing the drone reason told the operator their drones
were lost while all six were aboard, and cost a real diagnosis. A reviewer
flagged the misnaming as a minor the day it shipped and it was deferred; this is
what deferring it bought.

**Still unverified live:** whether `activate` actually clears
`ami_directive_status` for a `service_bot` the way it does for an FTL relay.
Establishing it needs a mutation. If the server no-ops it, every deploy burns
the round budget and stalls `serviceBotNotArmed` — correct and loud, but still
no repair.

Related: [[directives-feature]], [[same-step-dispatch-needs-tracked-op]],
[[confirm-steps-need-fresh-evidence]], [[brain-tendmesh-build]],
[[operations-table-retention]], [[ami-drones-are-event-silent]].
