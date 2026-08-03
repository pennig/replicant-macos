# Resource-hub model

Type: grilling
Status: resolved
Blocked by: 01
Labels: wayfinder:ticket

## Question

How does the brain model resource hubs, inventory, and supply?

The operator expects hubs to be an **emergent** need as fleet numbers and distances grow —
places where inventory accumulates and from which printing/supply draws. This ticket builds
the domain model the brain reasons over for material.

Resolve:
- **What is a hub?** A designated location, an emergent property of where stock/autofactories
  sit, or an operator-tagged role? Inventory is location-bound and only `transport` devices
  carry cargo (see [[directives-feature]] "print-if-missing is permanently out") — so a hub
  is a *place*, and material at the wrong place is unusable. How is that represented?
- **Inventory accounting.** How does the brain know what material sits where, how fresh that
  is, and what a print will consume? (Ties to ticket 01's freshness question and research 07.)
- **Supply.** Autofactory feeding and restock (`awaitingRelayRestock` is the current human
  hole) — a hub is drained/filled by `shuttle` (ticket 05). What triggers a resupply goal
  (ticket 03), and what's the reserve policy?
- **Placement.** Do hubs get *placed* deliberately (a goal), or only recognised where they
  form? Interaction with mesh growth (a hub off-mesh can't be commanded).

Consult `/domain-modeling` + `/grilling` and research 07/09. Feeds the `shuttle` primitive
(05), the auto-print+deliver build, and mesh growth. Must cite 02.

## Answer

The brain does **not** model hubs as a managed or placed domain object. A hub is a **derived,
recognised predicate**, supply is the standing job of the `mine`/`salvage` goals, and printing
happens **at the hub** — never in situ. Canonical home: `app/.claude/memory/brain-resource-hub-model.md`;
glossary terms in `app/CONTEXT.md`.

### 1. What a hub is — recognised, not placed (single hub this effort)
A hub is *a commandable location holding a print-capable device (autofactory) + adequate per-type
stock* — a **derived predicate over `LocationFootprint` + device rows**, not a new table, tag, or
placed object. **One hub this effort**, derived at runtime by finding the (single) autofactory and
reading its location; it is **meshed by construction** because it is co-located with the stationary
anchor replicant ([[ftl-authority-rule]]). Multi-hub routing and deliberate hub *placement* (siting
+ meshing a new autofactory) defer to the `growFleet` / managed-hub **reserved-future** bucket —
which is exactly the operator's "emergent as fleet numbers and distances grow" framing. *Get the
mechanics right on one hub before scaling.*

### 2. Inventory accounting — keep the per-type precision you already paid for
Rank on **per-type stock wherever known** — `SiteAssay` already holds per-type composition for
salvage systems (the main producers), plus whatever the **last confirm-read retained** — falling
back to `LocationFootprint` **totals** only for never-read locations. The `print` step's `.high`
per-type `/inventory` read at the hub is the **authoritative dispatch veto** (`printStockShort`,
already in 05), and **its result is retained** (the confirm-read repairs the row it reads, per 01) so
no fetched precision is ever discarded. Consequence, consciously accepted: a **small additive
per-type stockpile record** beyond today's totals-only `LocationFootprint` (append-only migration, no
new *concept*). Totals-only ranking was **rejected** — "why opt into less precise data we already
have?" A relay bill is fixed (370 units × six types, research 07), so per-type matters: a lopsided
hub (healthy total, one rare type dry) must still block, the same reason totals-only fails.

### 3. Print-in-situ is dead; printing is at the hub
Salvage sites carry **≤3 resource types**; an FTL relay needs **all six**, so a relay can never be
printed from one site's stock. (Asteroid-belt mining might cover small prints — not the relay path.)
Printing happens **at the hub**, with a **HEAVEN Vessel co-located** at the autofactory so the finished
relay auto-stows for carriage. This is 05's autofactory-carrier composition, not its print-vessel one.

### 4. Supply — `mine`/`salvage` ARE the supply line, feeding the hub through the haul engine
Resupply is **standing**, and it is what the `mine`/`salvage` goals are *for*: they leverage the haul
engine to shuttle their output **back to the hub**. There is **no separate `resupply` goal**.
- **Salvage** → the shipped **Salvage Run + Haul Run** ([[salvage-run-design]], [[haul-run-design]]),
  already decoupled, **sink generalised from hardcoded home to the derived hub**. Salvage depletes, so
  the Haul Run's round-robin drain of a finite frontier winds itself down per site — nothing new but the
  sink parameter.
- **Mine** → a **dedicated, persistent Haul Run per active mine site.** Mining never depletes, so a
  hauler can never finish and move on; each site needs a controller more-or-less permanently ferrying
  site → hub. The brain **derives this statelessly**: *mine site S active ∧ no dedicated haul draining
  S → hub ⇒ launch one*. It is a **separate, decoupled** Haul Run executor (buffered through the site
  pile + the hub), owned via 04's lease rules (its controller `deviceCode` + `auto:haul` tag), **not** a
  step-library inside the mine executor — matching the shipped Salvage/Haul decoupling (the miner never
  waits on its hauler). **Consequence:** each mine site permanently consumes a transport controller +
  freighter, so device starvation here is a **`growFleet` (reserved-future) trigger**.
- **Relay Run** (the `tendMesh` grow executor) = **print + deliver**, **consuming** hub stock, and
  **decoupled from resupply through the hub's stockpile as a buffer** — exactly the shipped
  Salvage/Haul decoupling. If the hauls have not pooled enough six-type material yet, the print step's
  `printStockShort` → **idle**, and it prints once the buffer fills. No coordination, no convoy.

### 5. D4 (05's handed question) — `shuttle` collapses into a generalised Haul Run
No new `DirectiveKind`. The Haul Run is already the multi-source drain; we generalise its **sink** to
the derived hub and add an intra-system directive branch (`ferry` is cross-system; the API's
`shuttle`/`consolidate` cover a source sharing the hub's system — a build detail if intra-system
sources are rare early). **`shuttle` is therefore the resupply executor, NOT a Relay-Run co-engine** —
this **amends 05's** three-engines-in-one-machine picture: the Relay Run's engine set is **print +
deliver only**; shuttle stands beside it as Haul Run.

### 6. Spend ceiling — 03's `R`/`N`, grounded in the hub model (shape here, literals deferred)
"Spend" now has a concrete referent: the Relay Run's `print` consuming the hub's per-type stock while
`mine`/`salvage` hauls refill it. Three bounds, three mechanisms:
- **`R` — per-type reserve floor, the hard rail (02 clause 7).** The enactment rail refuses any
  autonomous print that would drive **any** of the six types at the hub below `R_type` → "expansion
  from surplus only"; a burst of relay demand cannot drain the **rarest** type to zero. Per-type for
  the same reason totals-only ranking was rejected. *Honest early weight:* relays are essentially the
  only autonomous consumer this effort (repair / `growFleet` / non-relay prints are future or HITL), so
  the **binding** early constraints are `N` + worthiness; `R` is the rail that matters the moment
  shared/non-growth draws (repair, operator prints, `fulfillEvent`) arrive — kept in the design as that
  rail.
- **`N` — soft reclaim-fed idle-relay cap (selection-side).** Don't keep more than `N` printed-but-
  undeployed relays; **prune/reclaim feeds this pool → auto-suppresses new printing** (prefer redeploy-
  from-reclaim over print).
- **Sprawl** (relays *deployed*) stays bounded by **`tendMesh` worthiness**, not by `R`/`N`.
- **Literals `R`/`N` are deferred** to build/runtime calibration (they depend on real haul-throughput
  vs relay-demand) and **surfaced in the why-view**, not frozen here (plan-only ticket).

### 7. Placement & mesh interaction
Hub commandability is a **precondition**, met this effort by anchor co-location (the anchor never
travels). An **off-mesh hub → escalate / unsupported**, never silently worked around. Haul **sources**
must be reachable for the ferry to FTL-link — which is precisely `tendMesh`'s job; unreachable sites
are simply **not drained yet** (derivability-gated, not a stall; the Haul Run planner already filters
unmeshed piles). This closes the supply loop: `tendMesh` grows reach → more sites drain → more hub
stock → more relays. Siting a *new* autofactory = `growFleet`-future.

### Amendments to prior decisions
- **05** — `shuttle` is the resupply executor (a generalised Haul Run), **not** a Relay-Run co-engine;
  the Relay Run's engine set is **print + deliver only**. Print-in-situ is rejected; printing is at the
  hub with a co-located carrier.
- **04** — its "supply is executor self-composition, never brain-orchestrated" is scoped to the **Relay
  Run** self-composing print→deliver; the hub's **raw-material** supply is legitimately the `mine`/
  `salvage` **goals** composing the haul engine (those are goals, not brain runtime orchestration).
- **03** — `R`/`N` shape grounded in the hub buffer; the **per-mine-site persistent Haul Run** is added
  as `mine`'s standing composition; per-site device starvation is a `growFleet` trigger.

### Robustness (cites [[brain-robustness-bar]] / ticket 02)
- **Selector-not-enactor (c1):** the brain derives goals and **launches** Haul Runs / the Relay Run
  (as it launches Survey Run); executors enact; every print/haul command flows executor →
  `CommandGovernor` → engine. It never hand-drives a collect/deposit.
- **Stateless (c2):** the per-mine-site haul and the hub predicate are **re-derived each tick** from
  running-directive + device rows and `LocationFootprint`; no brain-held material memory.
- **Pure-selection / API-vetoes-never-chooses (c3):** ranking uses best-effort per-type; the
  `.high` per-type `/inventory` read is a **rail veto** (`printStockShort`), never a selection input.
- **Three-tier fidelity (c4):** totals / known-per-type for ranking, `.high` per-type confirm at the
  print dispatch; a stale ranking costs at most one **deferred** tick when the veto fires —
  *staleness degrades efficiency, never safety.*
- **Bounded blast radius (c7):** the `R` per-type rail *is* the spend ceiling; additive per-type
  writes; don't-strand holds (the relay rides stowed, deploy+activate in-situ); the hub buffer
  decouples fill from consume.
- **Safe degradation (c6):** `printStockShort` → **idle** (surfaced, not escalated) until the buffer
  fills; **off-mesh hub → escalate**; a device-starved mine haul → escalate / `growFleet`. Idle-calm
  (buffer filling) stays distinct from a stuck stall in the why-view.
- **Live why-view (c8):** hub stock + buffer state, `R`/`N` limits, and per-mine-site haul status are
  the derived "why" for every print/idle decision.
