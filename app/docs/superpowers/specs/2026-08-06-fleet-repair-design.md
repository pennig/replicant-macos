# Fleet repair — design

**Date:** 2026-08-06
**Status:** Approved, ready for planning
**Modules:** `DirectiveEngine` (the step + the staging query), `GameModels` (nothing new — capacity is already a column)

## Problem

Devices wear out and nothing in the app repairs them. Wear is not only a failure
risk: operational capacity is a **speed multiplier** — the docs state degraded
devices "slow down, affecting mining speed, scan duration, and engine power" and
that devices "will eventually degrade to stop working". A survey fleet at half
capacity surveys at roughly half speed, and no shipped run notices.

This lands ahead of brain-driven `survey` deliberately. Survey is the workload
that degrades survey drones, so handing the brain an unattended survey loop
without repair builds a fleet that grinds itself down with nobody watching.

## The fleet as it stands (2026-08-06, live DB + API probes)

Design decisions below are argued from this, not from a hypothetical fleet.

| Dimension | Reality |
| --- | --- |
| Repair devices owned | Two `service_bot`s — `0CABDA47` (100%), `69F1D04C` (92%) — both at `AINALRAM-BELT-1`, both **untagged**, both idle |
| Their state | `ami_directive: {name: "service"}`, `ami_directive_status: "active"`, `_eval_state: "idle"`, `controlled_devices: []` |
| Their vocabulary | `available_directives: ["patrol", "service"]`; `features: [cruise, repair, stow, ami]`; `repair` among `available_commands` |
| Degraded devices | Four mining drones — `32658E70` 28%, `920A191D` 29%, `304F6EC1` 32%, `7C79FCE1` 44% — adopted by `18CA7C99`, currently stowed aboard `C7836770` mid-salvage-run |
| Survey fleet | `F2908E6E` (Heaven Vessel, `auto:survey`, idle at the hub), two `ami_survey_controller`s, 8 `survey_drone`s — **all 8 at 100%**, because survey has not run |
| Everything else | ≥90% |

Two facts drive the design. **The bots have never been near a damaged device** —
they sit at the hub while the only degraded devices ride a carrier three systems
away, which is why an active `service` directive reads `_eval_state: "idle"`. And
**the survey drones are at 100% only because survey is not running**; the moment
the brain takes survey over, they become the fleet that degrades.

## What the game actually provides

Verified against the live blueprint list and the maintenance docs, not assumed.

- **`service_bot`** — 235 units (`carbon 25, silicates 30, structural 100,
  rares 15, conductive 60, volatiles 5`), 667s print. Offers **both** `patrol`
  and `service`.
- **`maintenance_drone`** — 335 units, 900s print, offers `patrol` only.
  **Rejected: strictly dominated.** It costs 43% more, prints 35% slower, and
  does less.
- **`patrol`** — autonomous; the bot "cruises to any of your damaged devices in
  the system and repairs them in turn", deactivating each device, restoring it to
  **100%**, reactivating it, then moving on.
- **`service`** — autonomous; "hot repairs without deactivation, bringing each
  device up to **a functional level** before moving on to the next". The level is
  **not quantified anywhere in the docs**, and that unknown shapes the exit gate
  below.
- **Co-location is the whole trigger.** A damaged device standing beside an
  active bot is repaired with no command at all (operator-confirmed, 2026-08-06).
- A per-target `repair` command also exists and is already wired
  (`CommandClient.repairBody`, `CommandClient+Utility.swift:36`; `repair` carries
  a tracked deadline via `CommandClient+Lifecycle.swift:46`). **This design does
  not use it** — see Rejected alternatives.

For scale: a bot is 235 units against an FTL relay's 370. Supply is not a
constraint. The docs claim the service bot blueprint is off-catalogue and sourced
from an NPC; that is **stale** — it is on the account's live blueprint list today.

## Goals

- A fleet working unattended keeps itself repaired without operator intervention.
- A repair that cannot converge is **visible and escalated**, never a silent hang.
- Zero new tables, zero new pollers, no new command vocabulary.
- The mechanism is identical for survey, mine and salvage; only the *placement*
  differs.

## Non-goals

- Repairing devices that are not part of a running fleet. A relay sitting alone
  in a meshed system degrades and this design does not help it. That is
  `growFleet`'s orphan-repair concern.
- Auto-printing replacement bots. The two owned bots equip the survey fleet
  today; the mine and salvage fleets will need four more, and extending
  `restockRun` to print them is recorded for those builds, not built here.
- Choosing repair targets, ordering them, or budgeting them. The directive does
  all of that server-side.

## Architecture

### Fleet composition: two bots, not one

Every automated fleet stages **two `service_bot`s** aboard its carrier, alongside
the AMI controller and the drones.

Two rather than one because **a lone bot has no way to repair itself**. It wears
down like everything else and eventually crosses the floor below which it can no
longer repair others, at which point the fleet degrades silently with a repair
device aboard. A pair repairs each other.

The residual is both bots crossing that floor at once. The design does not
prevent it — it makes it **loud**, via the step deadline and an escalation reason
that names bot capacity.

Staging is unchanged and remains the operator's job: Survey Run never stows or
adopts. The bots are found by the **existing** query,
`AMIFleet.stowed(aboard:in:offering:)` (`AMIFleet.swift:28`), asking for devices
stowed aboard the carrier that offer the `service` directive. That query already
identifies AMI devices by **capability rather than `device_type`**, and its own
doc comment notes the fallback vocabulary behind `availableDirectives` covers
only repair devices — so it matches service bots and nothing else, with no
changes.

### The survey repair step

Placement, in `SurveyRun`'s step machine:

    travel → deploy/launch → [REPAIR] → search bodies → recall → stow → travel

**At the start, after deploy, before the first search dispatch.** Drones carry
damage *in* from the previous system, so repairing before dispatching searches
means every scan in this system runs at restored speed. Repairing at the end
would leave the current system's scans running on damage already taken and add
pure latency before travel.

**Entry gate.** Any fleet device below **50%** capacity — the drones *and the
bots*. A degraded bot is included deliberately: it is the failure that silently
disables everything downstream, and its partner is the thing that fixes it.

**Exit gate — progress-based, not threshold-based.** The step leaves when:

1. the bots report idle, **and**
2. no fleet device's capacity rose between two consecutive polls,
3. with a step deadline behind the whole thing.

This is the load-bearing decision in the design. The obvious gate — "wait until
everything reads ≥90%" — **cannot be written safely**, because `service` repairs
to an unquantified "functional level" that may sit below 90%. A threshold gate
against an unmeasured threshold is a permanent stall. A progress gate asks the
only question that is always answerable — *is repair still accomplishing
anything?* — and is correct under `service` and `patrol` alike, so switching
directives later changes no code.

**No commands are issued by this step.** Co-location is the trigger and deploy
already achieved it. The step is a *gate*, not a dispatcher: it observes and
waits. That is what makes it nearly free against the 60/min `CommandGovernor`
budget.

**Degradation.** No bot aboard → the step is **skipped with a named reason**, and
the survey proceeds unrepaired; a missing bot must not stop a survey. Deadline
expiry → **escalate, do not retry**, with the reason naming the bots' own
capacity, because the case worth an operator's attention is precisely "both bots
are too worn to work".

### Mine and salvage: no step at all

Mining and salvage fleets work from a **single location** for the duration of the
run. The bots deploy and stow with the drones, co-location holds continuously,
and repair therefore runs in the background for the whole run with no step, no
gate, and no polling.

This is why the survey case needed designing and these do not: survey is the only
fleet whose devices scatter and then leave.

Built when those capabilities are built. Each needs two more bots (four total,
940 units — about 2.5 relays).

## Rejected alternatives

**Assembling the drones before repairing.** The original sketch gathered the
survey drones to one location and waited. Unnecessary: `patrol`/`service` are
**system-scoped and the bot cruises to each damaged device itself**. The drones
are already spread across exactly the system the directive covers.

**Driving `repair(target:)` explicitly.** Deterministic and already wired, but
the bot must be co-located with each target, so the engine would have to fly the
bot drone-to-drone — rebuilding the cruise logic the directive performs for free
— at one action per drone. With 8 survey drones that is up to 8 repairs plus 8
travels per system against a 60/min budget, versus zero commands. Kept in reserve
as a fallback if the progress gate proves to trip in the field; not built on
speculation.

**Using `patrol` for its documented 100% restore.** Tempting, because it makes a
≥90% gate provably reachable. But it deactivates each device to repair it, both
bots already run `service`, and the progress gate removes the only reason to
care. Revisit only if measured `service` levels prove too low to be useful.

## Robustness

Against the eight clauses of `brain-robustness-bar`:

| Clause | How this clears it |
| --- | --- |
| 1 Selector, not enactor | The step issues **no commands at all**. It is a gate over `WorldSnapshot`. |
| 2 Stateless between ticks | The gate re-derives from capacity readings each evaluation; the only carried value is the previous poll's capacities, held in the step's own state exactly as other polling steps hold a watermark. |
| 3 Pure selection; API vetoes | Nothing to select. The directive chooses targets server-side. |
| 4 Snapshot fidelity | Capacity is read from device rows; the step must prove freshness against its own `stepStartedAt` before judging, per `confirm-steps-need-fresh-evidence` — a pre-deploy reading must never satisfy the gate. |
| 5 Determinism / e2e | A fleet entering below 50% and rising to a plateau exits; one that never rises hits the deadline and escalates. Both are assertable end-to-end against a fixture fleet. |
| 6 Safe degradation | The two failure modes are *no bot aboard* (skip, named, survey continues) and *repair not converging* (escalate, named, surfaces the bots' capacity). Neither hangs and neither burns budget — the step dispatches nothing. |
| 7 Bounded blast radius | Additive: one new step, no schema change, no new table, no new command. |
| 8 Live why-view | The skip and escalation reasons render through the existing `DirectiveAttentionReason` path with no new surface. |

## Companion work: directive log retention

Shipping alongside, separately reviewable.

`directiveLogEntries` has **no retention policy** while `WorldSnapshot.read`
re-fetches a directive's entire log every 5-second tick. Live today: **9,442 rows
total, 8,394 of them on the single running `haulRun`** (`salvageRun` 664,
`restockRun` 256). The persistent runs never terminate, so this only grows, and
the tendMesh build record already names it as the amplifier behind a whole defect
class.

Model on the existing `OperationRetention`, which drops terminal operations older
than 7 days hourly off `DeadlineScheduler.run()`. The open-directive case needs
care: an open run's log cannot simply be aged out from under a step that reads it.

## Build-time probes

Cheap to answer once, and each changes a value rather than the design:

1. **What level does `service` actually restore to?** Observe a repair in the
   field. If it proves high enough, `patrol` never needs revisiting.
2. **What is the capacity floor below which a bot stops repairing?** The user's
   premise for pairing. Only the escalation message's wording depends on it.
3. **Does a bot repair a device that is stowed rather than deployed?** Affects
   only whether the mine/salvage fleets stay covered between runs.
