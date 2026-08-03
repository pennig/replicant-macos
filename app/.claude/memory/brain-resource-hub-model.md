---
name: brain-resource-hub-model
description: "The automation brain's resource-hub / inventory / supply model (wayfinder ticket 06 — the last spine ticket). A hub is a DERIVED, RECOGNISED predicate (a commandable location with a print-capable device + adequate per-type stock), NOT a placed/managed object — single hub this effort (the one autofactory's location, meshed by anchor co-location); placement/multi-hub → growFleet-future. Print-in-situ is REJECTED (salvage sites ≤3 types, a relay needs 6): printing is AT the hub with a HEAVEN Vessel co-located to auto-stow. Inventory: rank on per-type wherever known (SiteAssay + retained confirm-reads; totals fallback), a small additive per-type stockpile record beyond totals-only LocationFootprint, the .high per-type /inventory read is the printStockShort rail veto and is retained. Supply = mine/salvage ARE the supply line feeding the hub via the haul engine: salvage = shipped Salvage+Haul Run (sink→hub), mine = a dedicated PERSISTENT Haul Run per site (never depletes). The Relay Run = print+deliver, consuming hub stock, decoupled from resupply through the hub buffer. D4 answered: shuttle collapses into a generalised Haul Run and is the RESUPPLY EXECUTOR, not a Relay-Run co-engine (amends 05). Spend ceiling: R = per-type reserve floor rail, N = reclaim-fed idle-relay cap; literals deferred. Off-mesh hub → escalate. Amends 04 + 03."
metadata:
  type: project
---

The resource-hub / inventory / supply model for the automation brain — the **last spine ticket** of
the automation-brain wayfinder effort. Resolved in
`.scratch/automation-brain/issues/06-resource-hub-model.md` (full detail there; map
`.scratch/automation-brain/map.md`). Glossary terms in `app/CONTEXT.md`. Sits on
[[brain-goal-decision-policy]] (03), [[brain-primitive-contracts]] (05), [[brain-executor-seam]] (04),
[[brain-robustness-bar]] (02), and [[salvage-run-design]] / [[haul-run-design]] / [[ftl-authority-rule]].

## A hub is a derived predicate, not a thing you build
A hub = *a commandable location holding a print-capable device (autofactory) + adequate per-type
stock* — a **derived predicate over `LocationFootprint` + device rows**, no new table/tag/placed
object. **One hub this effort**, derived at runtime from the single autofactory's location, **meshed by
construction** (co-located with the stationary anchor replicant). Multi-hub routing and deliberate hub
**placement** (siting + meshing a new autofactory) are `growFleet` / managed-hub **reserved-future** —
the operator's "emergent as fleet numbers and distances grow." *Mechanics on one hub first.*

## Print-in-situ is dead — printing is at the hub
Salvage sites carry **≤3 resource types**; an FTL relay needs **all six**, so a relay can never be
printed from one site's stock (asteroid-belt mining might cover small prints — not the relay path).
Printing is **at the hub**, with a **HEAVEN Vessel co-located** at the autofactory so the finished relay
auto-stows for carriage (05's autofactory-carrier composition, not its print-vessel one).

## Inventory — keep the per-type precision you already paid for
Rank on **per-type stock wherever known**: `SiteAssay` already holds per-type composition for salvage
systems (the main producers), plus whatever the **last confirm-read retained**; fall back to
`LocationFootprint` **totals** only for never-read locations. The `print` step's **`.high` per-type
`/inventory` read at the hub is the authoritative dispatch veto** (`printStockShort`) and **its result
is retained** (the confirm-read repairs the row it reads, per 01) — no fetched precision is discarded.
Consciously-accepted cost: a **small additive per-type stockpile record** beyond today's totals-only
`LocationFootprint` (append-only migration, no new *concept*). Totals-only ranking was **rejected** —
"why opt into less precise data we already have?"; a relay bill is fixed (370 units × six types), and a
lopsided hub (healthy total, one rare type dry) must still block.

## Supply — `mine`/`salvage` ARE the supply line, feeding the hub via the haul engine
Resupply is **standing** and is what `mine`/`salvage` are *for*; there is **no separate `resupply`
goal**.
- **Salvage** → shipped **Salvage Run + Haul Run**, already decoupled, **sink generalised from
  hardcoded home to the derived hub**. Salvage depletes → the round-robin drain of a finite frontier
  winds itself down. Nothing new but the sink parameter.
- **Mine** → a **dedicated, persistent Haul Run per active mine site** — mining never depletes, so a
  hauler can never finish; each site needs a controller ~permanently ferrying site → hub. The brain
  **derives it statelessly**: *site S active ∧ no dedicated haul draining S → hub ⇒ launch one*. A
  **separate, decoupled** Haul Run executor (buffered through the site pile + hub), leased via 04's
  rules (controller `deviceCode` + `auto:haul` tag), **not** a step-library in the mine executor.
  **Consequence:** each mine site permanently costs a transport controller + freighter → device
  starvation here is a **`growFleet` trigger**.
- **Relay Run** (`tendMesh` grow) = **print + deliver**, **consuming** hub stock, **decoupled from
  resupply through the hub's stockpile as a buffer**. Hauls not pooled enough yet → `printStockShort`
  → **idle**, prints once the buffer fills. No coordination, no convoy.

## D4 (05's handed question) — `shuttle` collapses into a generalised Haul Run
No new `DirectiveKind`. Generalise the Haul Run's **sink** to the derived hub + an intra-system
directive branch (`ferry` is cross-system; the API's `shuttle`/`consolidate` cover a source sharing the
hub's system — a build detail if intra-system sources are rare early). **`shuttle` is the resupply
executor, NOT a Relay-Run co-engine** — this **amends 05**: the Relay Run's engine set is **print +
deliver only**; shuttle stands beside it as Haul Run.

## Spend ceiling (03's `R`/`N`, grounded) — shape here, literals deferred
- **`R` — per-type reserve floor, the hard rail (02 clause 7):** the enactment rail refuses any
  autonomous print driving **any** of the six types at the hub below `R_type` → "expansion from surplus
  only"; a demand burst can't drain the **rarest** type to zero. *Honest early weight:* relays are
  essentially the only autonomous consumer this effort, so the **binding** early constraints are `N` +
  worthiness; `R` is the rail that matters once shared/non-growth draws (repair / `growFleet` /
  `fulfillEvent`) arrive.
- **`N` — soft reclaim-fed idle-relay cap (selection-side):** ≤ `N` printed-but-undeployed relays;
  **prune/reclaim feeds this pool → auto-suppresses new printing** (prefer redeploy-from-reclaim).
- **Sprawl** (relays *deployed*) is bounded by **`tendMesh` worthiness**, not `R`/`N`.
- **Literals `R`/`N` deferred** to build/runtime calibration (depend on real haul-throughput vs
  relay-demand), surfaced in the why-view.

## Placement & mesh
Hub commandability is a **precondition**, met by anchor co-location. An **off-mesh hub → escalate /
unsupported**, never silently worked around. Haul **sources** must be reachable for the ferry to
FTL-link — precisely `tendMesh`'s job; unreachable sites are **not drained yet** (derivability-gated,
not a stall; the Haul Run planner already filters unmeshed piles). Closes the loop: `tendMesh` grows
reach → more sites drain → more hub stock → more relays.

## Amends prior decisions
- **[[brain-primitive-contracts]] (05)** — `shuttle` = the resupply executor (a generalised Haul Run),
  **not** a Relay-Run co-engine; Relay Run engine set = **print + deliver only**; print-in-situ rejected.
- **[[brain-executor-seam]] (04)** — "supply is executor self-composition, never brain-orchestrated" is
  scoped to the **Relay Run** self-composing print→deliver; the hub's **raw-material** supply is the
  `mine`/`salvage` **goals** composing haul.
- **[[brain-goal-decision-policy]] (03)** — `R`/`N` grounded in the hub buffer; the **per-mine-site
  persistent Haul Run** added as `mine`'s standing composition; per-site device starvation = `growFleet`
  trigger.

## Downstream / fog
- **`tendMesh` grow+prune worthiness heuristic** — **RESOLVED (ticket 10, [[brain-tendmesh-worthiness]]);
  it was the last open spine decision, now closed.** **Amends this ticket's `N`:** the ≤`N`
  idle-relay buffer cap is **retired** — reclaim is **lazy/demand-driven** (a useless relay is sourced
  for a grow only when one is needed, redeploy preferred over print), so there is rarely a standing
  idle pool to cap. "Prefer redeploy over print" survives as demand-time sourcing, not pool management.
  `R` (the per-type reserve floor rail) is unchanged.
- **`growFleet`** (reserved-future) now also owns **hub placement + multi-hub routing**.
- **Location-event fulfilment** + **Salvage Run activation** are design-complete → build plans, not
  decisions.
