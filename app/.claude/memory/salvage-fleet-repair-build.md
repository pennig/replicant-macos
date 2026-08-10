---
name: salvage-fleet-repair-build
description: "Service bots tour with the Salvage Run (branch worktree-salvage-fleet-repair). Bots deploy ONCE PER SYSTEM, not per body, because `service` is system-scoped and the bot cruises itself — so they repair the mining drones across the whole site tour and are recalled before the vessel leaves. Also closes the cross-fleet bot-ownership residual the Survey Run build left armed, via an `auto:`-tag predicate. Records why the fleet-repair design's 'mine and salvage need no step at all' was already stale when it was written."
metadata:
  type: project
---

# Service-bot repair for the Salvage Run

Mechanism, constants and traps are all inherited from
[[survey-fleet-repair-build]] — read that first. This note records only what is
different, and one correction to the design it was built from.

## The design doc's premise for salvage was stale on the day it was written

`docs/superpowers/specs/2026-08-06-fleet-repair-design.md` says under **Mine and
salvage: no step at all**: "Mining and salvage fleets work from a **single
location** for the duration of the run… co-location holds continuously, and
repair therefore runs in the background for the whole run with no step, no gate,
and no polling."

That was true of the Salvage Run as first shipped and false by the time the
design was written. The 2026-07-31 site-tour amendment ([[salvage-run-design]])
put a `positioning` step ahead of `configuring` so the **vessel** flies to each
salvage body rather than ferrying drones out from a parked vessel. A salvage
fleet therefore scatters and then leaves, which is exactly the property the
design named as the reason survey alone needed steps. Salvage needs the same
steps, for the same reason.

## Deploy once per SYSTEM, not once per body

Bots go out after arrival and stay out for the whole site tour. `service` is
system-scoped and the bot cruises to each damaged device on its own, so
redeploying per body would buy nothing and cost two commands a hop. The vessel
moving between bodies does not disturb them — `RepairFleet.bots(deployedNear:)`
resolves through `SiteAssay.system(of:)`, so a bot at `TOSLIT-9` still answers a
query anchored on a vessel at `TOSLIT-3`.

That gives the run one funnel in and one funnel out:

    arrival (meshed travel / relay confirmed / no L-point)
        → deployingBots ⇄ confirmingBotDeploy
        → armingBots ⇄ confirmingBotArm
        → positioning → configuring → launching → awaiting → verifying
                            ↑ next body in the same system ┘
    every exit from the system (position/configure/verify `.finished`,
    vanished controller, exhausted queue)
        → repairing → stowingBots ⇄ confirmingBotStow → .advanceTarget

**No exit from a target system may reach `.advanceTarget` directly.** The whole
correctness argument is that `stowingBots` is the single door out. Adding a new
terminal branch to `position`, `configure` or `verify` without routing it
through `repairing` abandons the bots in that system permanently.

## The `restocking` detour is safe only because deploy happens late

`restock` flies the vessel home to `AINALRAM-BELT-1`, which leaves the system.
It is reachable from `preflight` (unmeshed target, no relay aboard) and from
`emplace` (no relay aboard). Both sit BEFORE `deployingBots`, so no bot is ever
out on that path. This is the reason deploy sits after the relay chain rather
than on arrival, and it stops being true the moment anything routes to
`restocking` from later in the run.

## Bot ownership: the `auto:` tag, and what it does not close

The Survey Run build left this armed and explicitly flagged: `bots(deployedNear:)`
matched ANY deployed service bot in the system, including another fleet's, and it
is the query that issues `recall`. A second bot-carrying fleet is what arms it,
and this build is that fleet.

`RepairFleet.answers(_:to:)` is the ownership signal:

- a bot wearing any `auto:`-prefixed tag answers ONLY to a run whose fleet tag is
  among them;
- a bot wearing no `auto:` tag answers to whoever asks.

Salvage passes `SalvageRun.fleetTag(directive)`; Survey passes nil, which is the
parameter default and is why the shipped Survey Run is untouched — today's pair
is untagged, so it still matches. Both ends of the round trip use the SAME
predicate: `bots(aboard:owner:)` deploys and `bots(deployedNear:owner:)` recalls.
**They must never diverge** — a bot deployed under one predicate and recalled
under a narrower one is abandoned, which is worse than never deploying it.

**Residual: two fleets whose bots are BOTH untagged still collide.** Tagging
either fleet's bots closes it. This is strictly better than the previous state
(no signal at all) but it is not nothing, and the fix is operator-side.

## Two unbounded-read holes review found, closed in BOTH runs

Neither is salvage-specific — the Survey Run shipped with both, and the fixes
landed there in the same commit.

**`confirmBotDeploy` and `confirmBotArm` had no deadline.** Their only escape was
a throttled `.refreshDevices`, and the throttle measures `updatedAt`, which only
advances on a read that SUCCEEDS. A bot row that 404s or is rate-limited pushes
`now − lastLook` past the interval once and never back, so the step bought one
`.high` read every 5 s tick forever — `.high` bypasses both the TTL and the
read-budget floor, and there is no global step watchdog. The dispatch round
budget cannot save it: that bound is consulted only in the DISPATCH step, which
a stuck confirm step never returns to. `botConfirmDeadline` (10 min) now bounds
both; deploy degrades to `armingBots` (repair lost, salvage kept) and arm stalls
`.serviceBotNotArmed` (a paused bot repairs nothing, so it must be loud).

**"Everything is armed" was concluded from rows nobody had read.** The freshness
proof sat only on the branch that FOUND a mis-armed bot; the conclusion that
skips repair entirely had none. `confirmBotDeploy` also advanced on
`aboard.isEmpty` without ever proving the DEPLOYED rows, which are exactly the
rows `armingBots` then judges. A row that is fresh by `updatedAt` but carries a
carried-over `ami_directive_status: "active"` reads as armed, both bots idle for
the whole system, and the gate releases at once — the same silent no-repair the
arm pair was built to close. Both conclusions now pay for the read first, via a
shared `probe(_:_:_:)` helper. **The deadline must be checked before the
staleness guard** in every one of these steps, or the escape is unreachable
exactly when it is needed.

## Residuals, and what was deliberately left

- **A REJECTED bot command still halts the mining run.** `deployBots`'s
  round-budget branch degrades to "mine unrepaired", but a 4xx on the `deploy`
  POST goes through `DirectiveExecutor` to `.stall(.commandRejected)`. Each
  arrival now traverses three dispatch pairs, so this build adds three new ways
  for a service-bot problem to stop salvage. Survey has the same shape; there it
  costs a survey, here it costs the mining that funds the mesh.
- ~~**`SurveyRun` has no `fleetTag` concept at all**, so it passes `owner: nil`
  forever. Tagging survey's bots `auto:survey` — the natural operator move once
  tagging is the ownership signal — makes them invisible to Survey at BOTH ends.
  Symmetric, so nothing is abandoned, but it is silent no-repair on the run that
  shipped first. Give `SurveyRun` a fleet tag before tagging its bots.~~
  **FIRED LIVE and CLOSED** — the bots were tagged and the survey fleet went
  unrepaired from 2026-08-07 05:14; see [[survey-repair-fleet-tag]].
- **No test drives `SalvageRun` through `DirectiveEngineCore`.** Every test calls
  `nextAction` directly and hand-builds the log for the round budgets, so nothing
  proves the production pair actually EMITS the `.stepStarted` rows those budgets
  count. This is the gap `RelayRunEngineTests` closed for `RelayRun`; it is
  pre-existing for the whole Salvage Run, not new here.

## Residuals inherited unchanged from the Survey Run

- **Operator `skipTarget` bypasses the recall.** It advances `targetIndex` and
  resets to `firstStep` directly, so a Skip taken with bots deployed abandons
  them. Not closed here: routing `preflight` back through `stowingBots` would
  need a return path that does not itself `.advanceTarget`, which would
  double-advance the queue.
- **`recall` stows on the NEAREST craft**, not necessarily this vessel. A bot
  stowed on someone else's hull leaves the query and the vessel departs clean,
  so all four `.advanceTarget`s still decide "no bots are out" from local rows.

## What it needs before it does anything

**It ships INERT.** The account owns two service bots and the survey fleet has
both. Salvage needs two more (~470 units), staged aboard the salvage vessel and
tagged `auto:salvage` — untagged bots aboard would be deployed but would also be
invisible to `preflight`'s `.refreshFleet(tag:)`, so they would go stale.

Related: [[survey-fleet-repair-build]], [[salvage-run-design]],
[[same-step-dispatch-needs-tracked-op]], [[confirm-steps-need-fresh-evidence]],
[[device-tags-and-control-range]].
