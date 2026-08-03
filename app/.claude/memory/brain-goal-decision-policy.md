---
name: brain-goal-decision-policy
description: "The automation brain's goal & decision policy (wayfinder ticket 03). The brain is a pure selector: each tick it derives goals from WorldView, ranks them with a lexicographic key, and allocates devices/budget via one greedy pass. Five goal kinds (survey/tendMesh/mine/salvage/fulfillEvent); print/deliver/shuttle/repair are engines not goals; growFleet reserved-future. Two priority axes: acquisition order vs an inverted liveness floor protecting the enabling chain from deadlock. Spend ceiling = per-type resource reserve floor at the enactment rail + soft ≤N idle-relay cap. Idle keeps survey + liveness running; backoff is implicit/stateless."
metadata:
  type: project
---

Goal & decision policy for the automation brain (the standing global orchestrator — "B").
Resolved in `.scratch/automation-brain/issues/03-goal-decision-policy.md` (full detail there;

**AMENDED by [[brain-tendmesh-worthiness]] (ticket 10):** the **`critical` promotion flag is
dropped** — goal kinds run on disjoint device sets, so nothing an earlier-ranked goal does starves
the mesh when the brain reaches `tendMesh` in the same tick (the acquisition order is just a
processing order over non-contending kinds). `tendMesh` is also the **sole mesh authority**
(relay-planting removed from executors), so "downstream value folds backward into `tendMesh`
worthiness" is now the **primary** driver; **`survey` is excluded** from grow value (mesh-independent
by construction).
wayfinder map `.scratch/automation-brain/map.md`). Sits on [[brain-robustness-bar]] and the
world model (ticket 01). Vocabulary glossary: `app/CONTEXT.md`. See [[directives-feature]],
[[salvage-run-design]], [[ftl-authority-rule]], [[ami-drones-are-event-silent]].

## Goals are per-tick derivations; the brain is a pure selector
A **goal** = `Goal(kind, target, rationale)` derived fresh each tick from `WorldView`, **never
persisted**. Continuity ("already doing this?") comes from matching against running-directive
rows, not brain memory (the `evaluateOnce` shape → clause 2, stateless). The brain **ranks,
never enacts**; every command still flows executor → `CommandGovernor` → engine.

## Five goal kinds + engines
- **`survey`** — chart uncharted systems; root of the enablement chain; always-on.
- **`tendMesh`** — **grow AND prune** the FTL mesh (one worthiness heuristic, two directions).
  Grow = plant a relay to bridge a >7.5 ly gap; prune = reclaim a relay from a durably-useless
  system (salvage-exhausted + not load-bearing + hysteresis), reclaim = deactivate→stow→travel→
  deploy elsewhere (confirmed feasible; `decommission` is NOT the path — it destroys for the
  blueprint, no resource refund).
- **`mine`** — belt mining (needs survey controller+drones to find/maintain sites + mining devices).
- **`salvage`** — salvage sites (needs only mining devices). Split from `mine` on device need.
- **`fulfillEvent`** — the one HITL seam; surface options+tradeoffs, operator picks, then execute.
- **Engines (means, never goals):** `print`, `deliver`, `shuttle` (consolidate to a hub), `repair`.
- **Reserved-future:** `growFleet` — cheap add (new detector + ranking entry); needs a future
  **fleet-health/device-supply awareness** ("which goals are starved for devices") that also owns
  **orphan-repair** (a drained device owned by no running executor).

## Ranking = a greedy allocation pass over a lexicographic key
One pass per tick: derive candidates → reserve running-executor devices & drop satisfied goals
(mark no-longer-derivable executors for **retirement**) → sort → walk greedily, allocate if free
else **skip** (`.deferred`, re-derives next tick). **No scalar utility** (keeps the why-view
legible). **Dependencies are implicit via derivability** — a blocked goal just isn't a candidate;
downstream value folds *backward* into `tendMesh` worthiness, so there's **no cross-goal
critical-path promoter**.

**Acquisition order** (cross-kind contention only, which is rare — disjoint device sets, budget
rarely saturates): protect-committed-value → `fulfillEvent` → production (`mine`/`salvage`) →
`tendMesh` (promoted into production only by its own "critical" worthiness flag) → `survey`
(lowest-for-contention but always-on, "most resumable"). **Within-kind key:** `reachable-now →
cheap-to-reach → value → cost → stable-tiebreak` (generalises salvage's `already-meshed → one-hop
→ units → distance`).

## Two priority axes — acquisition vs an inverted liveness floor
Device→one-goal falls out of the greedy pass (claim mechanism is 04's). Beyond acquisition, a
**conservative inverted liveness floor** protects the enabling chain (`survey`/`tendMesh` + their
repair) **first**, because starving it is a **deadlock** (terminal), not an inefficiency:
**repair-priority inverted** (enabling fleets serviced before production when `service_bot`s are
scarce) + a **resource-reserve floor**. This is a **different pool** than ticket 01's API-budget
no-carve-out (physical devices/resources, structural starvation); API-budget starvation is
priority-ordered, self-limited, and **surfaced/escalated, never silent** (also the `growFleet`
trigger). The brain **prioritizes** repair (pure selection); the executor **enacts** it.

## Spend ceiling = per-type reserve floor at the enactment rail (+ soft idle cap)
"Spend" = autonomous resource use on growth (present: `tendMesh` relays = 370 units × six types,
incl. the rarest Rares/Volatiles; `fulfillEvent` is HITL-gated → out; future: `growFleet`). The
**hard rail** (02 clause 7, sibling to `CommandGovernor`) refuses any autonomous spend driving any
of the six types **below its reserve** → expansion is tied to production surplus; a runaway hits
the floor and stops. **Not** a rate/per-tick cap (redundant). **Soft companion (selection-side):**
**≤ N idle relays** anti-hoarding — reclaim feeds this pool, so a healthy prune stream
**auto-suppresses printing** (prefer redeploy-from-reclaim over print). The floor bounds *resource
exhaustion*; **sprawl** is bounded separately by `tendMesh` worthiness. Concrete `R`/`N` calibrate
with the hub model (06).

## Idle & backoff
**Idle** = no *new acquisition* work this tick, but `survey` stays always-on and the liveness floor
keeps running (never truly inert); no speculative busywork (preemptive top-up/pre-staging = future).
**Backoff is implicit & stateless:** precondition-blocked → derivability gates retry;
confirm-read-blocked → the read repairs the row it reads, staleness-horizon gates the next read (no
read-storm). **Idle-calm** (surfaced, not escalated) must stay distinguishable from a **stuck-goal
stall** (surfaced AND escalated) via the why-view — a stuck brain must never masquerade as a quiet
one. Exact deadlines/escalation surface are 02's.
