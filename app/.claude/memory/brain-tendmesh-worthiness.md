---
name: brain-tendmesh-worthiness
description: "The automation brain's tendMesh grow+prune worthiness heuristic (wayfinder ticket 10 — the LAST spine decision; every capability now design-complete). Structural pivot: tendMesh is the SOLE mesh authority — relay emplacement is REMOVED from the Salvage Run, no production goal plants/requests a mesh (amends the map's additive preference + salvage-run-design). Chain is survey (mobile, mesh-independent — discovers) -> tendMesh (meshes ahead of demand) -> production (derives only for meshed systems). GROW = pathfinding toward known value (salvage + mine + events; survey EXCLUDED), ranked completes-unlock-now -> cheapest-chain -> [best-tier ▸ magnitude] -> cost -> designation; tier = Event ▸ Rich belt ▸ Moderate belt ▸ salvage-by-units ▸ Sparse belt (belt-class is pre-mesh-knowable, actual yields aren't). No `critical` promotion flag (goal kinds run on disjoint device sets — amends 03). PRUNE = the same pathfinding read inversely: a relay is USELESS iff it lies on the cheapest anchor->live-target path-union for NO target (targets include value only reachable via a chain grow still wants) — unifies load-bearing + in-progress-hop protection + durable-uselessness, so a brand-new hop is pinned by construction and thrash is structurally impossible. Reclaim is LAZY/demand-driven: source a needed relay from the nearest useless one before printing (retires 06's N buffer cap); NO temporal hysteresis, sole guard is 01's confirm-before-reclaim .high read. Amends map/salvage-run-design + 03 + 06."
metadata:
  type: project
---

The `tendMesh` grow+prune worthiness heuristic — the **last spine decision** of the automation-brain
wayfinder effort; with it every capability is design-complete and the map reduces to build plans.
Resolved in `.scratch/automation-brain/issues/10-mesh-tend-worthiness.md` (full detail there; map
`.scratch/automation-brain/map.md`). Sits on [[brain-goal-decision-policy]] (03),
[[brain-primitive-contracts]] (05), [[brain-resource-hub-model]] (06), [[brain-robustness-bar]] (02),
[[brain-executor-seam]] (04), and the domain facts [[ftl-authority-rule]] / [[salvage-run-design]] /
[[travel-is-cheap-vs-survey]].

## Structural pivot — `tendMesh` is the SOLE mesh authority
**Amends the map's "additive, never rewrite a shipped run" standing preference AND
[[salvage-run-design]]:** relay emplacement is **removed** from the Salvage Run; no production goal
plants *or* requests a mesh. The enablement chain is strictly one-directional:
- **`survey`** — a **mobile replicant** carrying its own presence-authority ⇒ **mesh-independent**;
  a system being unscanned is never a reason to mesh toward it. Survey *discovers* value upstream.
- **`tendMesh`** — **meshes ahead of demand** toward discovered, still-unreached value.
- **`salvage`/`mine`/`fulfillEvent`** — derive as candidates **only for already-meshed systems**
  (03's derivability) and won't travel anywhere dark.
So 03's "downstream value folds backward into `tendMesh` worthiness" becomes the **primary** driver.
The salvage insight ("planting a relay makes the freighter commandable") still holds — `tendMesh` now
does it *ahead of time*. This is a real change to shipped code, done in the Salvage-Run-activation
build session, not designed further here.

## GROW — pathfinding toward known value
Candidate generation is **pathfinding**, not a per-system scan (a scan can't score a boring waypoint —
no local value). For each unreachable system holding **known value**, compute the cheapest relay chain
(≤7.5 ly hops out from the live mesh) to reach it; the grow action is **plant the first missing hop**,
which inherits its worth from the value at the chain's end. **Value set = salvage + mine + events;
survey EXCLUDED.** Ranking key (lexicographic; generalises salvage's `already-meshed → one-hop → units
→ distance`):
1. **Completes an unlock now** — R immediately meshes a value-system.
2. **Cheapest remaining chain** — fewest additional relays still needed; distance is a *minor* sub-tiebreak (travel is cheap).
3. **Value** — **(i) best tier** any served system reaches, then **(ii) aggregate magnitude at that tier** (salvage = summed units; belts = count of served belts at that tier). Tier is a **hard ordering, never out-summed by volume:**
   > **Event ▸ Rich belt ▸ Moderate belt ▸ salvage-sites-by-units ▸ Sparse belt**
   Belt class (Rich/Moderate/Sparse) is **pre-mesh-knowable** from survey/census; actual yields are not (need mesh + a site search), so the class is the only pre-mesh signal. Events top the tier because they yield XP + **permanent civilisation reputation**, not just resources. (Exact source field for belt class → confirm at build.)
4. **Resource cost** — the relay bill: **370 units TOTAL across all six types, never 370 per type** (`carbon 20, silicates 100, structural 80, rares 40, conductive 120, volatiles 10`; see [[brain-relay-reserve-floor]]). An earlier draft of this line read "fixed 370×6", which is wrong — corrected 2026-08-05. **Still effectively inert as a tier, but for the reason rather than the number:** the bill is fixed per relay, so a candidate's cost is `370 × relays-still-needed` — a strictly increasing function of the very relay count key 2 already ranks on. It can therefore only ever be consulted on candidates key 2 has tied, where the counts are equal and the costs are equal with them. Kept for honesty.
5. **Stable tiebreak** — system designation.

**No `critical` promotion flag** (amends 03, which posited one). Goal kinds run on **disjoint device
sets** (production fleet vs the Relay Run's dedicated `heaven_vessel` carrier vs the stationary
anchor), so an earlier-ranked goal never starves the mesh when the brain reaches `tendMesh` in the
same tick; the one shared resource (hub stock) is governed by the `R` hard-rail veto, not priority.
Contention the key resolves is **intra-grow only** — many candidate gaps vs the single relay-carrier
(one `heaven_vessel` ⇒ one Relay Run at a time).

## PRUNE — the same pathfinding, read inversely
Grow and prune are **one stateless graph computation**: the set of cheapest **anchor→live-target
paths**, where a live-value target is any system holding un-depleted salvage / a worth-mining belt /
a live event — **whether already reached OR only reachable via a chain grow currently wants to build.**
> **A deployed relay is USELESS iff it lies on that path-union for no live-value target.**
> On the union → **pinned**; off it → **reclaim inventory.**
This single predicate unifies the ticket's three prune conditions:
- **Load-bearing** — live value routing through R keeps it on a path ⇒ pinned; reclaim never strands live value.
- **In-progress-hop protection (the thrash guard)** — a **brand-new hop** toward not-yet-reached V is on the cheapest anchor→V path ⇒ **pinned by construction**, with no outward edges yet and **zero stored intent** (re-derived every tick; 03 clause 2). A relay can't be useless while on the path to value grow hasn't given up on ⇒ **thrash structurally impossible.**
- **Durable uselessness** — when V's salvage depletes (sticky `depleted` flag) it drops from the target set; the hop falls off the union and becomes reclaimable. A perpetual mine belt never depletes ⇒ its relay is essentially never prunable.

**Reclaim is LAZY / demand-driven** (amends 06 — retires `N` as a buffer cap). A useless relay sits
harmlessly in place (embodied rares are equally "stuck" deployed or pooled). Reclaim fires **only when
a grow needs a relay**: source it from the **nearest useless relay (reclaim→redeploy) before
printing** — this *is* 06's "prefer redeploy over print," and is how the destination's "recover rare
resources" is realised (reuse avoids a fresh rare-bearing print; reclaim moves the relay with no
refund, decommission refunds nothing either, so *reuse* is the only recovery). **Print is the
fallback** — no useless relay reachably close (build-time distance cutoff — **now settled at 2 relay
hops / 15 ly as `Brain.reclaimRangeLY`; the arithmetic is in [[brain-tunable-calibrations]]**) or hub
stock short (`R` floor blocks it). **No temporal hysteresis** — a dwell timer would only force a rare-spending print
while a good reclaimable relay waited out a clock; thrash is prevented structurally. Sole guard is
**evidentiary, already mandated by 01**: reclaim only on a just-in-time `.high` confirm-read of the
candidate's system (which repairs the row), never a stale `WorldView` belief. Residual churn (survey
later finds value near a reclaimed system ⇒ grow re-meshes) is **genuine adaptation, not thrash** —
cheap, self-correcting, rare.

## Robustness (02) — clears the bar
Selector-not-enactor (ranks → launches Relay Run / drives reclaim, never commands) · stateless
(path-union re-derived each tick, no lease/cache) · pure-selection (`R` rail + `in_control_range`
**veto** enactment, never feed the *choice*) · staleness degrades efficiency not safety (ranks on
best-effort `WorldView`, confirms `.high` before every plant/reclaim) · testable end-to-end through
`evaluateOnce` (the SalvageTargetPlanner-zero-callers lesson) · safe degradation (no value/no
reclaimable relay → **idle** surfaced-calm; un-completable grow → **stall** escalated; prune never
escalates) · bounded blast radius (predicate never strands live value; grow spend bounded by the `R`
reserve floor; additive row-writes) · legible why-view (every pin/reclaim is a **graph fact**, never a
scalar).

## Amends prior decisions
- **Map "additive" preference + [[salvage-run-design]]** — relay emplacement removed from the Salvage Run; `tendMesh` is the sole mesh authority.
- **[[brain-goal-decision-policy]] (03)** — no `critical`-promotion flag; survey excluded from grow value; value-folds-backward is now primary.
- **[[brain-resource-hub-model]] (06)** — `N`-as-idle-buffer-cap retired; reclaim is lazy/demand-driven; prefer-redeploy-over-print realised as demand sourcing.

## Downstream — the spine is COMPLETE
Every capability is now design-complete; the map's terminal deliverable is one handoff-ready build plan
per capability (`tendMesh` grow+prune, auto-print+deliver, location events, salvage activation, mine +
per-site haul), each built in a separate subagent-driven session. **Reserved-future unchanged:**
deliberate hub placement / multi-hub routing + fleet-supply-driven subfleet growth remain `growFleet`.
