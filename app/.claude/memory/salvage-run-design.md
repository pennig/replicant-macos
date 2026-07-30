---
name: salvage-run-design
description: "Salvage Run + Haul Run: two directive kinds, not one convoy. Approved 2026-07-30, not yet implemented. The split works only because planting a relay makes the freighter commandable without the miner parked alongside; the frontier bootstraps itself (9 relays -> 10 of 13 systems). Also records the threads deliberately NOT built."
metadata:
  type: project
---

Spec: `docs/superpowers/specs/2026-07-30-salvage-run-design.md` (approved 2026-07-30, **not yet
implemented**). Read it before any implementation work.

Unattended salvage: the survey roam finds salvage, and an automation mines it and gets it home to
AINALRAM-BELT-1 with no operator input.

## The decisions, and why

- **Two directive kinds, not one convoy.** A Salvage Run (vessel: mine + plant relays) and a Haul Run
  (freighter: drain any reachable stockpile), with **no coordination between them**. An uncoupled
  split was rejected early and then revived: it fails only because a freighter at an off-mesh system
  cannot be commanded, and **planting a relay is exactly what fixes that** ([[ftl-authority-rule]]).
  So the relay is not an optimisation bolted on — it is what makes the clean split possible.
- **The miner never waits for the haul.** That was the whole cost of the convoy shape: a vessel idling
  through eight 500-unit round trips at ARCTURUSAN.
- **A dedicated third replicant**, not pennig-1 and not the survey roamer. pennig-1 must stay
  stationary to anchor the mesh; the roamer is in transit most of the time. Cheapest surge+cradle+stow
  hull is `heaven_vessel` (28,800s, 4,400 units) — `cargo_vessel` is 9,000 units and was priced out.
- **The frontier bootstraps itself.** Measured against the live catalog: relays planted *only at
  salvage systems*, richest-first, reach **10 of 13 systems and 15,650 of 20,471 units with 9 relays**
  and no side-trips — TOSLIT's relay brings ARCTURUSAN into range, which brings ABSOLUTN, and so on.
  Only POLARISUM / ASTELLIO / SOHIMU (4,821 units) need a waypoint relay at a non-salvage star.
  Hence the planner's ranking: already-meshed, then one-hop-from-mesh, then units, then distance.
- **The catalog is a moving target.** It grew ~400 units during the design session. The planner
  recomputes from `siteAssays` every evaluation and caches no ranking.
- **`verifyRecovered` replaces `recovering`.** v2.3.3 holds `directive.completed` until a
  recall-configured directive's drones finish travelling, so the blind 5-minute `recallGrace` wait is
  obsolete — one `.high` tag read confirms instead ([[device-tags-and-control-range]]).
- **Fleets resolve by tag** (`auto:salvage` / `auto:haul`), never by location probe.
- **The stall matrix still halts everything.** No auto-skip, same reasoning as the survey roam.

## Deliberately recorded, deliberately not built

The operator raised these; all are real direction with no current consumer, and each deserves its own
design rather than being smuggled into this one:

- **Engine-level printing, stowing, resource demand, and repair.** `awaitingRelayRestock` is the first
  place it pays off — it is the last stall in the design that needs a human. Note the salvage vessel
  itself has the `print` feature and mined output lands in the location stockpile, so printing a relay
  *in situ* from freshly-mined salvage is mechanically plausible; a single ~378-unit site rarely covers
  a relay's six-type bill, but a whole 1,000–3,500-unit system usually does.
- **Tag-driven automation without AMI controllers.** Tags make a fleet addressable regardless of state,
  which is most of what an AMI controller does for us. Weigh against the fact that AMI controllers run
  server-side and cost **no API budget** — that is why they keep earning their place.
- **Relay + beacon emplacement for location events.** An event wants a relay at an L4 *and* a beacon at
  the event site so future tasks arrive without re-scanning; the beacon needs the mesh to work, hence
  the relay. The spec shapes `emplaceRelay` as a sub-machine so this becomes its second consumer.
- **Waypoint relay errands** for the three deferred systems — the natural home for the long-planned
  Stage 5 Relay Run and its FTL-mesh incremental-add optimisation ([[directives-feature]]).

See [[salvage-resource-amounts]] for the assay store the planner ranks on, and
[[travel-is-cheap-vs-survey]] for why extra travel is affordable.
