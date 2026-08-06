# Service-bot repair for the Survey Run — the build record (SHIPPED 2026-08-06)

Design: `docs/superpowers/specs/2026-08-06-fleet-repair-design.md`.
Plan: `docs/superpowers/plans/2026-08-06-survey-fleet-repair.md`.
Branch `worktree-fleet-repair-build`, 13 commits (`ffe1939..49853f9`), 8 tasks.
Additive: no migration, no schema change, no new table, no new poller.

## What shipped

**Repair is autonomous.** A service bot standing in the same system as a damaged
device repairs it with no command at all — the engine only handles placement and
timing. Nothing in this build issues `repair`.

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
vessel.** Survey Run never stows or adopts; staging is the player's job. The two
bots the account owns are untagged and sit at the print hub.

Related: [[directives-feature]], [[same-step-dispatch-needs-tracked-op]],
[[confirm-steps-need-fresh-evidence]], [[brain-tendmesh-build]],
[[operations-table-retention]], [[ami-drones-are-event-silent]].
