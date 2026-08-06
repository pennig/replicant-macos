# The brain's survey goal — design

**Date:** 2026-08-06
**Status:** Approved, ready for planning
**Module:** `DirectiveEngine` (`Brain`), plus one line on the why-view

## Problem

The brain builds exactly one `Goal` kind today — `.tendMesh` — and inserts two
directive kinds, `.relayRun` and `.restockRun`. Charting is the first of the
five destination capabilities and the root of the enablement chain, and nothing
drives it: no `surveyRun` row exists, the `auto:survey` vessel sits idle at the
hub, and **142 of 14,122 known systems are surveyed**.

That ceiling is not only survey's own. `tendMesh` grows toward *known* value and
pins any relay whose system nobody has surveyed, so a frozen survey frontier caps
the capability already running.

## The fleet as it stands (2026-08-06, live)

| | |
| --- | --- |
| Carrier | `F2908E6E`, Heaven Vessel, tagged `auto:survey`, idle at `AINALRAM-BELT-1` |
| Controller | `B2CBDEC6`, `ami_survey_controller`, stowed aboard, tagged `auto:survey` |
| Drones | six `survey_drone`s, all adopted by `B2CBDEC6`, all stowed aboard, all 100% |
| Service bots | **none aboard** — the repair phases degrade quietly, so this does not block |
| Anchor | `831B5E49` at `AINALRAM-BELT-1`; `AINALRAM` is present in the census |
| Coverage | 142 surveyed of 14,122 known |

**The fleet is already staged.** Nothing needs printing, adopting or stowing for
this capability to work.

## Design

### One live roam, kept alive — not a scheduler

Survey Run's continuous roam is unbounded and self-targeting: given a
`roamCentre` it expands in 5-ly sliding bands and never finishes. So the brain
does not schedule surveys. It **ensures exactly one live `surveyRun` exists**,
launching one when absent, exactly as it already keeps the hub's restock alive.

This is ticket 03's "lowest-for-contention but always-on — most resumable, not
least important" expressed structurally: nothing preempts survey because nothing
competes with it.

The launch re-checks for a live row **inside the write transaction**. The read
and the write are separate steps and a row created by the previous tick can land
between them; `Brain.ensureRestock` already carries this guard and the survey
launch mirrors it.

### No contention logic

Survey's carrier, controller and drones are tagged `auto:survey`; tendMesh's
carrier is `auto:tendmesh`. The fleets are **disjoint**, so the greedy allocation
pass has nothing to arbitrate and no priority ordering needs implementing. If a
future fleet ever shares devices, that is when ordering earns its complexity.

### Two gates before launching

**The carrier tag**, mirroring `Brain.carrierTag`. A vessel the operator has not
opted in is never flown. `F2908E6E` already carries the tag, so this asks nothing
of the operator today — but an untagged fleet must produce a named idle reason,
not silence, per the tag-gating lesson from the tendMesh incident.

**Staging.** Survey Run never stows and never adopts, so launching at an unstaged
vessel yields an instant `noSurveyControllerAboard` stall. The brain must not
manufacture work for the operator: it checks for a controller aboard offering
`survey_system` and at least one adopted drone aboard, using `SurveyRun`'s own
fleet queries so the brain and the mission cannot disagree about what "staged"
means. Unstaged is an **idle reason**, never a stall.

### Roam centre: the anchor's system

`AINALRAM` — where the stationary anchor replicant and the print hub both sit,
and the point the mesh grows from. Charting outward from home is also what makes
`tendMesh`'s candidates appear in a useful order.

The centre must be a designation the census knows, or `SurveyRun.plan` returns
`.exhausted` on the first evaluation and the run finishes having done nothing.
Derive it from the anchor's location through `SiteAssay.system(of:)` rather than
hard-coding a designation, and treat "the census does not know the centre" as an
idle reason rather than launching a run that cannot plan.

## Non-goals

- **Scheduling, prioritising or preempting surveys.** One roam, always on.
- **Staging the fleet.** Survey Run never stows or adopts; that stays the
  operator's job, and this design only refuses to launch without it.
- **Multi-fleet survey.** One carrier, one roam. A second survey fleet is a
  `growFleet` concern.
- **Touching the shipped roam planner.** `SurveyRoamPlanner` and
  `SurveyRun.plan` are unchanged; this design only launches what already works.

## Robustness

| Clause | How this clears it |
| --- | --- |
| 1 Selector, not enactor | The brain inserts one directive row and drives nothing. Every command still flows executor → `CommandGovernor` → engine. |
| 2 Stateless between ticks | Liveness is re-derived each tick from the directive rows; nothing is remembered. |
| 3 Pure selection | There is nothing to rank — one roam, or none. |
| 4 Snapshot fidelity | Staging is judged from device rows through `SurveyRun`'s own queries; a stale row costs one deferred launch, never a wrong one. |
| 5 Determinism / e2e | A staged, tagged fleet with no live row launches exactly one; a second tick launches nothing. Both assertable end to end. |
| 6 Safe degradation | Untagged, unstaged, or an unknown roam centre each produce a **named idle reason** and no row. Nothing stalls and nothing escalates — a survey that cannot start is not an incident. |
| 7 Bounded blast radius | Additive: one directive row of an already-shipped kind. No schema change, no new table, no new poller. |
| 8 Live why-view | The idle reasons above render through the existing brain report, so "why is nothing charting?" is answerable on screen. |

## The clock this starts, deliberately

`WorldView.read` decodes the `systemJSON` blob of **every surveyed system on
every tick** — 142 today, which is free. The tendMesh build record names "a few
thousand surveyed systems" as the point where the `belts` index-table escape
hatch stops being YAGNI, and **survey is the automation that drives that number**.
It is pinned today only because survey is not running.

Shipping this starts that clock. The escape hatch is deliberately NOT built here:
building it now would be speculative work against a threshold two orders of
magnitude away. Watch the surveyed count; re-measure when it passes ~1,000.
