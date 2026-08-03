# Mesh-tend policy: grow + prune worthiness heuristic

Type: grilling
Status: resolved
Blocked by: 01, 03, 05, 06
Labels: wayfinder:ticket

## Question

What is the `tendMesh` worthiness heuristic, in **both** directions — what makes a gap worth
bridging with a new relay, and when is a relay durably useless enough to reclaim?

This is the last open **decision** on the spine. The goal/decision policy (03) established
`tendMesh` as one goal with two directions sharing **one worthiness heuristic, inverted**; the
primitive contracts (05) established the **Relay Run** (`relayRun` kind) as its grow executor
(print + deliver); the hub model (06) established that the Relay Run **consumes hub stock**,
prints at the hub, and is bounded by the `R`/`N` spend ceiling. What remains is the ranking
function itself.

Resolve:
- **Grow worthiness.** What makes a >7.5 ly gap worth bridging? Downstream value folds *backward*
  into `tendMesh` worthiness (03, no cross-goal promoter) — so a gap's worth is a function of what
  meshing it unlocks (reachable salvage/mine units, survey frontier, event sites). How is that
  scored *without* a scalar utility (03 keeps the why-view legible)? What is the within-kind key
  (03's `reachable-now → cheap-to-reach → value → cost → stable-tiebreak`) concretely for a gap?
- **Prune worthiness (the inversion).** When is a relay durably useless enough to reclaim —
  salvage-exhausted + **not load-bearing for reachability** + **hysteresis against churn**? How is
  "load-bearing" computed (removing it must not strand a downstream mesh subgraph)? What sets the
  hysteresis so a relay isn't planted and reclaimed in a thrash?
- **The `critical` promotion flag.** 03 promotes `tendMesh` into production priority only via its
  own "critical" worthiness flag. What makes a specific grow worth that promotion (e.g. it unblocks
  a starved production goal)?
- **Waypoint errands.** The three deferred non-salvage systems (POLARISUM / ASTELLIO / SOHIMU) and
  the general FTL-mesh incremental-add optimisation — how do waypoint relays at *boring* systems
  score, since their worth is purely transit (they unlock reach, hold no local value)?
- **Interaction with `N` (06).** Reclaim feeds the idle-relay pool → auto-suppresses printing; a
  prune that yields a redeployable relay should be preferred over a fresh print. How does the
  heuristic sequence prune-then-redeploy vs print?

Consult `/grilling` + `/domain-modeling`, [[brain-goal-decision-policy]] (03),
[[brain-primitive-contracts]] (05), [[brain-resource-hub-model]] (06), [[salvage-run-design]]
(the frontier bootstrap + waypoint errands), [[ftl-authority-rule]] (load-bearing / closure mesh),
[[travel-is-cheap-vs-survey]]. Must cite 02 (a Robustness section: how the heuristic degrades
safely, stays a pure selection, and stays legible in the why-view).

## Answer

Resolved by grilling 2026-08-03. Canonical home: [[brain-tendmesh-worthiness]]. This is the
**last open decision on the spine** — with it, every capability is design-complete and the map
reduces to build plans.

### Structural pivot — `tendMesh` is the sole mesh authority

**Amends the map's "additive, never rewrite a shipped run" standing preference AND
[[salvage-run-design]].** Relay emplacement is removed from the Salvage Run; no production goal
plants *or* requests a mesh. The enablement chain is strictly one-directional:

- `survey` — a **mobile replicant** carrying its own presence-authority; **mesh-independent**, so a
  system being unscanned is never a reason to mesh toward it. Survey is the *discoverer upstream* of
  `tendMesh`, not a consumer downstream.
- `tendMesh` — **meshes ahead of demand** toward discovered, still-unreached value.
- `salvage` / `mine` / `fulfillEvent` — derive as candidates **only for already-meshed systems**
  (03's "implicit via derivability") and won't travel anywhere dark.

So 03's "downstream value folds backward into `tendMesh` worthiness" stops being a secondary effect
and becomes the **primary driver**. The salvage design's load-bearing insight ("planting a relay
makes the freighter commandable") still holds — `tendMesh` now does it *ahead of time* rather than
the run doing it inline. The mine executor's implied reachability likewise comes from `tendMesh`.

### Grow — pathfinding toward known value

Candidate generation is **pathfinding**, not a per-system scan (a per-system scan can't score a
boring waypoint — it has no local value). For each currently-unreachable system holding **known
value**, compute the cheapest relay chain (sequence of ≤7.5 ly hops out from the live mesh) to reach
it; the immediate grow action is **plant the first missing hop**. A waypoint inherits its worth from
the value at the end of the chain it serves ("value folds backward" made literal).

**Value set that pulls grow = salvage + mine + events.** Survey frontier is **excluded** (survey is
mesh-independent by construction).

**Ranking key** (lexicographic, highest-priority field first — generalises salvage's proven
`already-meshed → one-hop → units → distance`):

1. **Completes an unlock now** — planting R *immediately* meshes a value-system (chain finishes this
   hop). Low-hanging fruit first.
2. **Cheapest remaining chain** — fewest additional relays still needed to unlock the value R serves;
   total distance is a *minor* sub-tiebreak only (travel is cheap — measured).
3. **Value** — lexicographic within itself: **(i) best tier** any served system reaches, then
   **(ii) aggregate magnitude at that tier**. The tier is a **hard ordering**, never out-summed by
   volume:

   > **Event ▸ Rich belt ▸ Moderate belt ▸ salvage-sites-by-units ▸ Sparse belt**

   - Belt richness (Rich/Moderate/Sparse) is **knowable pre-mesh** from survey/census data; actual
     belt yields are *not* known until meshed-and-searched, so the class is the only pre-mesh signal.
     (Exact source field for the classification → confirm at build; doesn't change the decision.)
   - Magnitude-at-tier: salvage = summed units across served salvage systems; belts = count of
     served belts at that tier (a hop opening two Rich belts beats one opening a single Rich belt).
   - Events top the tier because they yield not just resources but **XP and permanent civilisation
     reputation**.
4. **Resource cost** — the relay's six-type bill (fixed 370×6 today, so effectively inert; kept for
   honesty).
5. **Stable tiebreak** — system designation.

**No `critical` promotion flag** (amends 03, which had posited one). Goal kinds run on **disjoint
device sets** (production has its fleet; the Relay Run has its dedicated `heaven_vessel` carrier; the
anchor stays put), so processing an earlier-ranked goal in the tick never consumes anything
`tendMesh` needs when the brain reaches it later in the same tick. The one genuinely shared resource
— hub stock — is governed by the `R` hard-rail veto, not by priority. Contention that the key
resolves is therefore **intra-grow only** (multiple candidate gaps vs the single relay-carrier — one
`heaven_vessel` ⇒ one Relay Run at a time), which is exactly what fields 1–5 order.

### Prune — the same pathfinding, read inversely

Grow and prune are **one stateless graph computation**: the set of cheapest **anchor→live-target
paths**, where a live-value target is any system holding un-depleted salvage / a worth-mining belt /
a live event, **whether already reached OR only reachable via a chain grow currently wants to
build.**

> **A deployed relay is *useless* iff it lies on that path-union for no live-value target.**
> On the union → **pinned** (load-bearing for reached value, *or* an in-progress hop toward
> unreached value). Off it → **reclaim inventory.**

This single predicate unifies the ticket's three separate prune conditions:

- **Load-bearing** — a live-value system routing through R keeps R on a path → pinned. Removing a
  useless relay never strands live value (bounded blast radius).
- **In-progress-chain protection (the thrash guard the operator flagged)** — a **brand-new hop W**
  toward not-yet-reached V is on the cheapest anchor→V path → **pinned by construction**, even with
  no outward edges yet. Grow re-derives that path every tick, so W stays pinned across ticks with
  **zero stored intent** (03 clause 2 stateless). Thrash is therefore *structurally impossible* — a
  relay can't be useless while it's on the path to value grow hasn't given up on.
- **Durable uselessness** — when V's salvage depletes (sticky `depleted` flag) it drops from the
  target set; W falls off the path-union and becomes reclaimable. A perpetual mine belt never
  depletes → its relay is essentially never prunable.

**Reclaim is lazy / demand-driven** (amends 06 — retires `N` as a buffer cap). A useless relay sits
harmlessly in place (its embodied rares are equally "stuck" deployed-in-a-dead-system or parked in an
idle pool). Reclaim fires **only when a grow needs a relay**: the brain sources it from the **nearest
useless relay (reclaim→redeploy) in preference to printing** — this *is* 06's "prefer redeploy over
print," and it's how the destination's "recover rare resources" is realised (reuse avoids spending a
fresh rare-bearing print; 03 confirms reclaim moves the relay with no refund, and decommission
refunds nothing either, so *reuse* is the only recovery). **Print is the fallback** — when no useless
relay is reachably close (build-time distance cutoff) or hub stock is short (the `R` floor blocks the
print).

**No temporal hysteresis.** A dwell timer would only force a rare-spending print while a good
reclaimable relay waited out an arbitrary clock. Thrash is prevented *structurally* (lazy reclaim is
monotone-positive: useless→live; permanent depletion means value never oscillates at a system). The
sole guard is **evidentiary, already mandated by 01**: before reclaiming relay U, the "useless"
judgment must rest on a **just-in-time `.high` confirm-read** of U's system (which repairs the row it
reads), never a stale `WorldView` belief. Residual churn — survey later discovers value near a
reclaimed system, so grow re-meshes it — is **genuine adaptation to new value, not thrash**: cheap
(travel), self-correcting, rare.

### Robustness (02) — how the heuristic clears the bar

1. **Selector-not-enactor** — a pure ranking function producing `Goal` candidates; the brain launches
   a Relay Run executor (grow) or drives reclaim→redeploy through the executor, and never issues a
   command itself.
2. **Stateless** — the path-union is re-derived every tick from `WorldView` + the mesh graph; no
   committed-intent, no lease, no ranking cache. The path-union *is* the "state," recomputed each tick.
3. **Pure-selection / API-vetoes-never-choose** — the `R` hard-rail (`printStockShort`) and
   authoritative `in_control_range` **veto enactment**; the heuristic never consults them to *choose*.
   Ranking picks the gap; the rail may refuse the print; that refusal degrades to idle, not a wrong
   pick.
4. **Staleness degrades efficiency, never safety** — grow/prune rank on best-effort `WorldView` (a
   depleted system may still rank; a fresh belt may be missing), but every plant/reclaim confirms
   `.high` before acting (evidence-before-reclaim; 01's confirm-at-dispatch). A stale belief wastes an
   evaluation or defers an action — it never strands live value.
5. **End-to-end testable through the real seam** — verified through `evaluateOnce` → the greedy pass →
   a launched directive, not as an isolated pure function (the salvage lesson: `SalvageTargetPlanner`
   had zero production callers while every unit test passed).
6. **Safe degradation** — no reachable value / no reclaimable relay → **idle** (surfaced, calm); a
   grow that can't complete (`noPrinterAtSite`, `deliveryWouldStrand`, a persistently `R`-blocked
   print) → **stall** (surfaced AND escalated). Prune never escalates — a useless relay left in place
   is harmless.
7. **Bounded blast radius** — reclaim is load-bearing-safe by the path-union predicate (never strands
   live value); grow spend is bounded by the `R` per-type reserve floor; both are additive
   directive-row writes.
8. **Live derived why-view** — every pin/reclaim is a **graph fact**, never a scalar: grow —
   *"meshing X — routine investment toward 3,200 units at ARCTURUSAN, 2 hops"* / *"…CRITICAL-tier:
   event live at Y"*; prune — *"reclaiming U→G — U dark since depletion, G holds a Rich belt."*

### Amendments this ticket makes

- **Map "additive" standing preference + [[salvage-run-design]]** — relay emplacement removed from the
  Salvage Run; `tendMesh` is the sole mesh authority. (A real change to shipped code, done in the
  Salvage-Run-activation build session, not here.)
- **[[brain-goal-decision-policy]] (03)** — no `critical`-promotion flag (goal kinds don't contend);
  survey excluded from grow value; "value folds backward" is now the primary driver.
- **[[brain-resource-hub-model]] (06)** — `N`-as-idle-buffer-cap retired; reclaim is
  lazy/demand-driven, and "prefer redeploy over print" is realised as demand sourcing.

**Reserved-future unchanged:** deliberate hub placement / multi-hub routing and fleet-supply-driven
subfleet growth remain `growFleet`.
