# Goal & decision policy

Type: grilling
Status: resolved
Blocked by: 01
Labels: wayfinder:ticket

## Question

What is the brain's vocabulary of goals, and how does it choose and prioritise among them?

The brain turns global world state (ticket 01) into concrete work. This ticket defines
*what it wants* and *how it arbitrates* — the heart of the orchestrator.

Resolve:
- **Goal vocabulary.** What is a goal? ("survey outward from X", "mine this salvage",
  "bridge this gap", "print+deliver a relay to Y", "fulfil this event"). Are goals derived
  fresh each tick from world state (stateless policy) or are they persisted intents?
- **Prioritisation.** When multiple goals are live, what ranks them? (value, distance,
  unblocking-other-goals, operator-pinned priority?) The salvage planner's
  "already-meshed → one-hop → units → distance" ranking is a precedent to generalise.
- **Contention.** Two goals want the same vessel; many goals share the 60/min actions
  budget. How is a device assigned to at most one goal? How is budget apportioned so no
  capability starves? (Absorbs the deferred **multi-vessel coordination** gap — two roam
  runs currently pick the same target because neither sees the other.)
- **Spend ceiling.** The operator authorised "unattended within a ceiling." What is the
  ceiling's shape — a reserve floor (keep ≤ N idle printed relays), a rate, a per-tick
  cap? Where does it live?
- **Idle & backoff.** When nothing is worth doing, what does the brain do? (Ties to 02.)

Consult `/grilling` + `/domain-modeling`. Must cite the robustness bar (02). Feeds 04, 06,
and the mesh-growth policy.

## Answer

**Thesis.** The brain is a *pure selector* (robustness bar 02): each tick it derives goals
from `WorldView`, ranks them, and allocates free devices/budget to the top ones via a single
**greedy pass** — it never enacts. Goals are ephemeral derivations; the running-directive rows
are the only persistent truth (clause 2, stateless between ticks). Canonical vocabulary:
`app/CONTEXT.md`; design record: `app/.claude/memory/brain-goal-decision-policy.md`.

### 1. Goal vocabulary
A **goal** = a pure per-tick derivation `Goal(kind, target, rationale)` over `WorldView`, never
persisted. Continuity ("already doing this?") comes from matching a goal against running-directive
rows, not brain memory — the `evaluateOnce` shape.

**Five present goal kinds**, one detector each:
- `survey` — chart uncharted systems (Survey roam executor). Root of the enablement chain; always-on.
- `tendMesh` — **grow *and* prune** the FTL mesh. Grow: bridge a >7.5 ly gap by planting a relay at
  a boring waypoint. Prune: reclaim a relay from a system **durably useless** (salvage-exhausted AND
  not load-bearing for reachability to useful systems), reclaim = deactivate→stow→travel→deploy
  elsewhere (confirmed feasible). Prune is the same worthiness heuristic **inverted**.
- `mine` — belt mining; needs a survey controller + survey drones to find/maintain belt sites, plus
  mining devices.
- `salvage` — salvage-site mining; needs **only** mining devices. (Split from `mine` on device need.)
- `fulfillEvent` — the one **HITL** seam; surface fulfilment options + tradeoffs, operator picks when
  no clear winner, then execute (empty POST on-site).

**Engines (means, never goals):** `print`, `deliver`, `shuttle` (consolidate resources to a hub),
`repair`. Every printed/delivered/consolidated/repaired thing exists *in service of a goal*.

**Reserved-future goal:** `growFleet` (print+stage a new subfleet to relieve a starved goal). Not
built; the stateless-selector architecture makes it a cheap add (new detector + ranking entry). It
needs a **fleet-health / device-supply awareness** ("which goals are starved for devices") that also
owns **orphan-repair** (a drained device owned by no running executor) — a named future capability the
design leaves room for, not builds now.

The **hub** (where consolidated resources pool for printing) is a 06 concept — it's what made
consolidation *feel* like a goal.

### 2. Prioritisation — a greedy allocation pass over a lexicographic key
Ranking *is* contention resolution: one greedy pass per tick.
1. Derive all candidate goals from `WorldView`.
2. Reserve devices/budget held by running executors; drop goals they satisfy (continuity); mark any
   executor whose goal is no longer derivable for **retirement** (→ 04).
3. Sort remaining candidates by the lexicographic key.
4. Walk greedily; allocate free devices/budget if available, else **skip** (re-derives next tick —
   `.deferred`).

**No scalar utility** — a lexicographic key keeps the clause-8 why-view legible.

**Dependencies are implicit via derivability:** a goal whose precondition isn't met (unreachable
system, unstaged devices) simply isn't a candidate; it becomes one when the world changes. Downstream
value flows *backward* into `tendMesh` worthiness ("worth bridging"), so the ranker needs **no
cross-goal critical-path promoter**.

**Acquisition order** (most-significant first; used only under genuine cross-kind contention, which is
rare — executors run on disjoint device sets and budget rarely saturates):
1. **protect committed value** — never start work that strands/abandons an in-flight commitment
   (losing > gaining).
2. **`fulfillEvent`** — rare (~0.5/day), time-boxed, rewarding, the operator seam. Bounded by
   operator-pick + don't-strand.
3. **production** — `mine` / `salvage`.
4. **`tendMesh`** — investment; below production by default, promoted into production only by its own
   "critical" worthiness flag (owned by `tendMesh`, not the ranker).
5. **`survey`** — lowest-for-contention but **always-on** ("most resumable," not "least important").

**Within-kind key:** `reachable-now → cheap-to-reach → value → cost → stable-designation-tiebreak`,
where "value" is kind-specific (units / reward / worthiness / coverage-gain). Generalises the salvage
planner's `already-meshed → one-hop → units → distance`.

### 3. Contention — two priority axes
**Device → one goal** falls out of the greedy pass (in-tick reservation; running executors reserve
first). The *claim* mechanism (directive `controllerCode: nil`, claims at preflight; the brain must not
offer one free device to two goals in a tick) → **04**. Structurally closes the deferred
**multi-vessel-coordination gap** (two roam runs pick the same target only because neither sees the
other; one selector sees all).

**Two distinct priority axes:**
- **Acquisition** (grab surplus value) — the order above.
- **Sustenance — a conservative *inverted* liveness floor.** The enabling chain (`survey`, `tendMesh`,
  and the repair that sustains them) is protected **first**, because starving it is a **deadlock**
  (terminal loss of the capacity to grow), not an inefficiency. Mechanism: **repair-priority inverted**
  (enabling-chain fleets serviced before production fleets when `service_bot`s are scarce) + a
  **resource-reserve floor** (§4). Floor is keep-alive-minimum, so production still wins the *surplus*
  and isn't starved.

This is a **different pool** than 01's API-budget no-carve-out: physical devices/resources, where
starvation is structural/permanent. **API budget:** priority-order, self-limited concurrency, no
carve-out; persistent starvation is **surfaced and escalates** (never silent) — also the natural
`growFleet` trigger.

**Repair's brain role:** the brain **prioritizes** repair (pure selection = the liveness floor); it
never **enacts** it (the executor does, via the repair engine).

### 4. Spend ceiling
**"Spend"** = autonomous consumption of finite resources on growth. Present consumer: `tendMesh`
printing relays (370 units × six types, incl. the two rarest — Rares, Volatiles). `mine`/`salvage`
**produce**; `survey` is cheap; **`fulfillEvent` consumes staged resources but is HITL-gated → outside
the autonomous ceiling by construction.** Future consumer: `growFleet`.

**Shape — a per-type resource *reserve floor*, enforced at the enactment rail** (02 clause 7's
sibling-to-`CommandGovernor` gate; unbreachable by a buggy brain). The gate refuses any autonomous
spend that would drive any of the six types below its reserve. Emergent property: **expansion is tied
to production surplus** ("grow only as fast as you mine above the reserve"); a runaway hits the floor
and stops (bounded blast radius). **Not** a rate/per-tick cap — redundant with `CommandGovernor`
(rate) + the reserve floor (economic).

**Soft companion (selection-side, not the rail):** **≤ N idle (undeployed) relays** — anti-hoarding of
finished goods. **Reclaim feeds this pool** (prune → idle relays), and printing is gated on idle-count,
so a healthy prune stream **auto-suppresses printing**: **prefer redeploy-from-reclaim over print**
(recovers rare resources).

**Not the sprawl bound:** the reserve floor bounds *resource exhaustion*; **sprawl** (relays into
useless space) is bounded by `tendMesh` **worthiness** (06/fog) — kept separate so each stays simple.

**Values:** 03 owns the *shape/rule*; concrete `R` (per-type reserve) and `N` (idle cap) **calibrate
with 06** (per-hub; depend on hub topology + the relay bill), not guessed now.

### 5. Idle & backoff
**Idle** = the greedy pass allocated no *new acquisition* work this tick. But `survey` stays
**always-on** and the **liveness floor** keeps running — idle-on-acquisition ≠ idle-on-sustenance; the
brain is never truly inert. **No speculative busywork** (preemptive repair-topup / resource pre-staging
= future, out of present scope). `.deferred` writes nothing, burns no budget, no thrash.

**Backoff is implicit & stateless** (preserves clause 2 — no per-goal timer in brain memory):
- precondition-blocked → **derivability** gates re-attempt (not a candidate until the world changes).
- confirm-read-blocked → the confirm-read **repairs the row it reads** (01 §3), stamping its timestamp;
  the **staleness horizon** on that row gates the next read → no confirm-read storm.

**Idle vs stall:** a healthy quiet brain (**idle-calm**, surfaced, not escalated) must stay
**distinguishable** from a specific goal persistently stuck (**stall**, surfaced *and* escalated) — the
clause-8 why-view carries per-goal gate reasons so the two never look alike (the ten-hour-hang lesson:
a stuck brain must not masquerade as a quiet one). Exact deadlines + escalation surface remain **02**'s.

### Robustness bar (02) — how this design clears each clause
1. **Selector-not-enactor** — brain only launches/retires directives; multi-step behaviour is
   executors; the spend gate is a rail, not brain enactment. ✓
2. **Stateless** — goals are per-tick derivations; continuity from directive rows; backoff is
   row-timestamp-implicit. ✓
3. **Pure selection / API vetoes never chooses** — ranking pure over `WorldView`; at-dispatch
   confirm-read only defers; the spend gate only vetoes. ✓
4. **Snapshot fidelity** — rank on best-effort rows; one-way facts (depleted/meshed) sticky;
   confirm-fresh before spend/emplacement/strand-risk; reachability from authoritative
   `in_control_range`. ✓
5. **Testability** — the greedy pass is exercised **end-to-end through the dispatch-to-rails seam**
   under `TestClock` (executors faked); a unit-test of the ranker alone does NOT satisfy the bar
   (→ 04/build plans).
6. **Safe degradation** — transient defer (no thrash); unknown left alone; persistent → escalate;
   idle-calm vs stall-escalated distinct; never silently hang. ✓
7. **Bounded blast radius** — additive launch/retire; don't-strand (prune + deliver contract);
   **rail-enforced per-type reserve floor** = the spend ceiling; worst case = a wasted trip or an
   operator-resolvable stall. ✓
8. **Inspectability** — the why-view: ranked goals + inputs; the gate on the top goal
   (dispatching/deferred/idle/stalled + reason); limit pressure (governor/ceiling headroom, 429). ✓

### Downstream
- **Unblocks 04** (brain↔executor seam) — its last blocker (03) clears. Hands 04: the claim mechanism,
  target-delivery to executors, and executor **retirement**.
- **Feeds 06** (hub model) — the reserve-floor values `R`/`N`, and the consolidation destination (hub).
- **Renames the fog** item "mesh-growth policy" → "mesh-tend policy (grow + prune)" — worthiness for
  both directions, still 06-blocked.
- **Destination amended** — capability #3 "grows where useful" → "grows *and prunes*."
- **Reserved-future** `growFleet` + its fleet-health/supply-awareness (also owns orphan-repair) noted
  in fog; nothing ruled newly out of scope.
