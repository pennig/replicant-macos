# The brain's salvage goal — design

**Date:** 2026-08-07
**Status:** Approved, ready for planning
**Module:** `DirectiveEngine` (`Brain`, `SalvageRun`, `HaulRun`, `SalvageTargetPlanner`), plus two rows on the why-view

## Problem

The brain drives three directive kinds today — `.relayRun` and `.restockRun` for
`tendMesh`, `.surveyRun` for charting. Capability 2 of the five, *mining arrives
at any discovered salvage site*, is shipped code that the brain does not touch:
a `salvageRun` and a `haulRun` are alive right now only because the operator
launched them by hand. When either finishes, stalls, or is cancelled, nothing
relaunches it, and the hub stops being fed — which is what `tendMesh` spends.

Two shipped behaviours also contradict a locked decision. Automation-brain
ticket 10 made `tendMesh` the **sole mesh authority**, and the Salvage Run still
plants its own relays. `HaulRun.deliveryLocation` and `SalvageRun.baseSystem` are
still the string constants `AINALRAM-BELT-1` and `AINALRAM`, while ticket 06
defines the hub as a derived predicate.

## The fleet as it stands (2026-08-07, live)

| | |
| --- | --- |
| Salvage carrier | `C7836770`, Heaven Vessel, tagged `auto:salvage`, idle at `ALPAHARD-7-59` |
| Mining controller | `18CA7C99`, `ami_mining_controller`, `auto:salvage`, coordinating |
| Mining drones | six, all `auto:salvage`, all mining conductive at `ALPAHARD-7-59` |
| Service bots | `313F223A` repairing, `AD36227C` coordinating — both `auto:salvage` |
| Haul controller | `7D1569BF`, `ami_transport_controller`, `auto:haul`, at `ATIANFU-1-L4` |
| Hub | `43C9B54A`, the account's **only** autofactory, at `AINALRAM-BELT-1` |
| Mesh | 116 systems hold a relaying relay |
| Live rows | `760A30F8` `salvageRun` running at `verifying`; `2778DB10` `haulRun` running at `hauling` |

**The fleet is fully staged and working.** Nothing needs printing, adopting or
stowing for this capability. What is missing is an owner.

The salvage frontier, measured from `siteAssays` against the live mesh:

| | systems | units |
| --- | --- | --- |
| Undepleted salvage, meshed | 50 | 50,265 |
| Undepleted salvage, unmeshed | 9 | 15,170 |

The nine unmeshed are `SUBRA` (4,339), `ASELLUSUP` (3,681), `ACHERNARAN`
(2,618), `REGULU` (1,773), `CUSTOSUS` (779), `GNOMEN` (670), `SKET` (547),
`FORMISA` (443), `OTONATIUH` (320). These are the systems the relay surgery puts
temporarily out of reach — 23% of the frontier's units, behind `tendMesh` rather
than lost.

## Design

### Two live runs, kept alive — not a scheduler

Both `SalvageRun` and `HaulRun` are continuous and self-targeting. The Salvage
Run picks its next system through `SalvageTargetPlanner` and idles rather than
finishing when the frontier is empty; the Haul Run repoints one `auto:haul`
controller per tick at the richest reachable pile and has no finish line at all.

So the brain schedules nothing. It **ensures exactly one live row of each kind
exists**, launching one when absent — the `ensureSurvey` shape, for the same
reason: where an executor already ranks its own targets, liveness is the whole
job, and a second ranking layer above it would only be able to disagree.

### One shared liveness helper

`Brain` will have four call sites that keep exactly one row of a kind alive:
`tendRestock`, `ensureSurvey`, and the two new ones. They share an invariant both
prior build records call out — **the liveness read and the insert are separate
steps, so the check must run again inside the write transaction**, or a row
created by the previous tick lands in the gap and the fleet is double-committed.

Extract that into one private `ensureOne(_ kind:snapshot:database:build:)`:
read-check, build a directive or decline, then insert under an in-transaction
re-check. `tendRestock` keeps its demand-maintenance branch on top; the other
three reduce to a verdict function each. The invariant then exists once rather
than four times.

### The salvage readiness verdict

`Brain.salvageReadiness(view:)` is a pure two-case verdict. **There is no stall
case, so this goal cannot escalate by construction** — the survey goal's rule,
and for the same reason: launching at an unstaged fleet only manufactures a
`noMiningControllerAboard` stall for a human to clear, so declining is correct.

`.launch(carrier)` requires all three:

- a `heaven_vessel` tagged `auto:salvage` (`Brain.salvageCarrierTag`), absent
  from `Brain.reservedDevices`, with **no fallback to any free vessel** — an
  untagged fleet means the brain launches nothing and says so;
- its mining fleet staged aboard, judged through **`SalvageRun`'s own queries**,
  so the brain and the mission can never disagree about what staged means;
- at least one candidate from `SalvageTargetPlanner.nextTarget` over the meshed
  frontier — a run launched into an empty frontier would idle immediately, and
  saying "no reachable salvage" is more legible than a row that does nothing.

`.idle(reason)` otherwise, with the reason naming which gate failed.

The row: `deviceCode` = the carrier, `fleetTag` = `auto:salvage`, `roamCentre` =
the hub's system so the run is continuous, `targets` empty, `step` `preflight`,
`returnToOrigin` false.

### The haul readiness verdict, and the shape `mine` will extend

`Brain.haulReadiness(view:)` launches when a device tagged `auto:haul` offers
`ferry` and a hub exists; otherwise it idles named. The row's `deviceCode` is
the lowest-coded such controller and its `fleetTag` is `auto:haul`.

**The liveness rule counts only rows whose `fleetTag == HaulRun.defaultFleetTag`.**
This is the one piece of forward shaping in the design. Ticket 06 gives `mine` a
*dedicated, persistent* Haul Run per active mine site, because a belt never
depletes and a shared round-robin would keep wandering off it. Those rows will
carry their own per-site tags, so a rule phrased over the general drainer's tag
neither counts them nor relaunches around them, and the `mine` build adds rows
beside this one instead of reopening it.

### Stall response widens by kind

`Brain.brainManagedStall` gates on `kind == .relayRun` today. It widens to
`{relayRun, salvageRun, haulRun}`. Nothing downstream changes: `retryEpisode`,
the budget of 3, the 15-minute interval, one retry per tick to the
longest-waiting candidate, and `DirectiveAttentionReason.brainDisposition` are
all already built, classified and tested.

What that buys, per the existing classification: `vesselPositionUnconfirmed`,
`salvageSystemUnresolved`, `salvageBodyNotDepleted` and `commandRejected` become
bounded auto-retries. `dronesNotRecovered`, `noMiningControllerAboard`,
`noMiningDroneAboard`, `launchDeployedNothing`, `repairUnfinished`,
`serviceBotNotArmed`, `serviceBotNotRecovered`, `miningDirectivePaused`,
`miningControllerNotRecovered` and `noHaulControllerTagged` escalate, as they
should — each needs a power the brain does not have.

Membership is by kind, not provenance. The consequence is deliberate and worth
stating plainly: **the operator-launched `760A30F8` and `2778DB10` come under
brain management on the first tick after this merges.** Recording provenance
instead would need a new column and would leave those two rows unmanaged until
they finish.

`surveyRun` and `restockRun` stay outside the set, unchanged.

### The relay surgery — `tendMesh` becomes the sole mesh authority

Removed from `SalvageRun`: the steps `emplacing`, `activating`, `confirmingRelay`
and `restocking`; the helpers `lagrangePoint(in:)`, `relay(aboard:in:)` and
`deployedRelay(near:in:)`; the `MissionAction.setDeviceTags` untag on
`confirmRelay`'s success branch; and the relay leg of `preflight`'s staging
check, including the branch that diverts to `restocking` when a target is
unmeshed and no relay is aboard.

`travelling` stops branching on mesh membership and always advances to
`deployingBots`.

`SalvageTargetPlanner.nextTarget` narrows to already-meshed systems. `needsRelay`
comes off `Target` and the one-relay-hop tier comes out of the ranking, which
reduces to `units → distance from vessel → designation`. `relayRangeLY` stays —
`Brain.reclaimRangeLY` is derived from it.

`awaitingRelayRestock` loses its only producer. Its enum case stays; deleting a
case ripples through the disposition table and its tests for no behavioural gain,
so that is a separate cleanup.

**A row parked on a removed step is remapped forward to `deployingBots`**, not
left to `nextAction`'s `default:` branch. That default waits, which is the right
instinct for an unknown step and the wrong outcome here: an in-flight run would
freeze silently and hold its vessel and six drones. Today's live row is at
`verifying` and unaffected, but the merge instant is not something this design
gets to choose.

### The derived sink

`HaulRun.deliveryLocation` and `SalvageRun.baseSystem` stop being constants and
read `RelayRun.hubLocation(in:)` — the mission-side recognition rule that already
exists and is pinned by `HubRecognitionSeamTests`. **No second hub predicate is
written.**

The two are not the same kind of string, and conflating them is the mistake the
relay return leg already paid for once. `hubLocation` is a **location**
(`AINALRAM-BELT-1`), which is what `deliveryLocation` wants directly.
`baseSystem` is a **system** (`AINALRAM`), so it takes `hubLocation` projected
through `SiteAssay.system(of:)`. A location handed to the roam-centre slot lands
the census read at a site rather than a system; a system handed to the ferry
config delivers to a system entry point rather than beside the printer.

`deliveryLocation` has four call sites, and only one of them writes the ferry
config. The other three compare against it — `isInForce` twice and the config
builder's own check — so a controller configured under the old value would read
as not-in-force and be repointed once. That is correct behaviour rather than
churn, but it is a visible one-time repoint the first time the derived hub
differs from the constant, and the tests should pin it as expected rather than
discover it live.

`SalvageRun.baseSystem` is reached only as the last fallback in
`directive.roamCentre ?? Self.system(of: vessel) ?? Self.baseSystem`, and the
brain always writes `roamCentre`, so deriving it changes nothing for a
brain-launched row. It closes the hole under a hand-launched row that carries no
roam centre and whose vessel's system cannot be resolved.

With no hub on the mesh the haul run idles at `surveying` rather than hauling to
a stale constant, and `salvageReadiness` declines for want of a roam centre.

The values are identical today, since the one autofactory is at
`AINALRAM-BELT-1`. This is not a bug fix; it is what stops the sink from silently
pointing at the wrong place the first time the hub moves.

### The why-view

Two rows beside the shipped survey card, following its phrasing rule — **state a
status and a static fact, never a status and an active verb.** A salvage idle
that is waiting on the mesh must say so by name: with `tendMesh` now the only
thing that can widen salvage's reach, an idle reading merely "no reachable
salvage" would present a coupling as an absence.

## Non-goals

- **Ranking salvage targets in the brain.** The run's planner owns that.
- **Per-site haul rows.** Ticket 06 assigns them to `mine`; only the liveness
  rule is shaped to accept them.
- **`growFleet`, hub placement, multi-hub routing.** Reserved-future, unchanged.
- **Removing the `awaitingRelayRestock` enum case.** Separate cleanup.
- **`restockRun` and `surveyRun` stall management.** Out of the widened set.
- **The `BE846725` `noRelayCoLocated` relay run.** A live `tendMesh` stall, not
  this capability's.

## Robustness

Against the eight clauses of `brain-robustness-bar`:

1. **Selector, not enactor.** The brain gains two `Directive.insert` paths and
   two kinds in the stall set. It issues no command. The surgery *removes*
   commands from an executor rather than adding any to the brain.
2. **Stateless between ticks.** Both verdicts are pure functions of `WorldView`
   plus the directive rows. Continuity is the live row, never brain memory.
3. **Pure selection; the API vetoes.** Staging and mesh membership gate
   derivability only. The run's own `preflight` still vetoes at dispatch against
   an authoritative read, and a verdict of `.launch` never overrides it.
4. **Staleness degrades efficiency, never safety.** A stale assay can rank a
   drained system; `salvageBodyNotDepleted` plus the sticky `depleted` flag
   correct it, and the cost is one wasted evaluation. No new poller, no budget
   carve-out — both verdicts read the `WorldView` the tick already built.
5. **End-to-end through the real seam.** This feature is itself the reason the
   clause exists: `SalvageTargetPlanner` once had zero production callers while
   every unit test passed. The guard is an e2e driving `Brain` → the inserted row
   → `DirectiveEngineCore` → `SalvageRun` to a worked system, with a negative
   twin, never a planner unit test.
6. **Safe degradation.** Idle is surfaced and calm; a stall is surfaced and
   escalated after a bounded retry; auto-skip stays rejected. The salvage verdict
   has no stall case at all.
7. **Bounded blast radius.** Writes stay additive. Both carriers are gated by tag
   with no fallback. The surgery removes a spend path — salvage stops consuming
   relays entirely — so the rail's exposure shrinks.
8. **Live derived why-view.** Two rows, no new table, reasons named.

## The third carrier arms a deferred item

The tendMesh build record names three defects that all arm the moment a second
hub-co-located carrier exists. The fleet now has three tagged carriers —
`965AC2C3` (`auto:tendmesh`), `C7836770` (`auto:salvage`), `F2908E6E`
(`auto:survey`) — so they are armed already, and one of them lands directly on
this design.

`Brain.reservedDevices` closes its seed set to a fixpoint over stow in **both**
directions and over adoption, and its own doc records that it over-reserves
deliberately: spreading through a containment component costs a tick of patience,
while the opposite error strands a fleet. That trade is right. What it means here
is that a cross-link — a controller whose `controlledDeviceCodes` reaches a
device stowed aboard another fleet's carrier — can pull a second carrier into the
set, and `salvageReadiness` would then report "no `auto:salvage` vessel" while the
vessel sits idle in front of it. **The failure is silent and reads exactly like
the honest idle.**

This design does not change `reservedDevices`. It requires a test pinning that
the three tagged carriers fall into three disjoint reservation sets on a
live-shaped fixture, so the day a cross-link appears it fails in the suite rather
than as a fleet that quietly stops salvaging.

## What this costs

Salvage throughput becomes dependent on `tendMesh` arriving first. Ticket 10
folds salvage-by-units into grow value so the coupling self-corrects, but a rich
salvage system three hops out now waits behind belt-tier grow targets where the
old run planted its own relay and went. Today that is 9 systems and 15,170 units
against 50 systems and 50,265 already in reach, so the cost is real and small,
and it is the price of a single mesh authority.

The second cost is adoption: a mis-classified attention reason will now auto-retry
a run that is genuinely wedged. The budget of 3 bounds it to three attempts over
roughly 30 minutes before escalating.

## Testing

- Verdict tables for `salvageReadiness` and `haulReadiness`, one case per gate.
- `ensureOne`: two ticks against a lagging read insert exactly one row.
- Stall widening: a salvage `.retry` reason retried three times then escalated;
  an `.escalate` reason escalated on sight; a `surveyRun` stall still untouched.
- Planner narrowing: an unmeshed rich system is not offered, and the guard is
  **demonstrated failing against the pre-fix commit** — the Haul Run build's rule,
  that a guard nobody has seen fail is not a guard.
- Step remap: a row at `emplacing` advances rather than waiting.
- Sink derivation: `HaulRunTests` against a hub that is not `AINALRAM-BELT-1`,
  including the one-time repoint of a controller configured under the old value.
- Reservation disjointness: three tagged carriers, three disjoint sets.
- The clause-5 e2e and its negative twin.
