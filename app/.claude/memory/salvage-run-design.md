---
name: salvage-run-design
description: "Salvage Run SHIPPED 2026-07-30 (Haul Run still unbuilt, its own plan). Two directive kinds, not one convoy. The split works only because planting a relay makes the freighter commandable without the miner parked alongside; the frontier bootstraps itself (9 relays -> 10 of 13 systems). Also records the threads deliberately NOT built."
metadata:
  type: project
---

Spec: `docs/superpowers/specs/2026-07-30-salvage-run-design.md`; plan:
`docs/superpowers/plans/2026-07-30-salvage-run.md`. **Salvage Run SHIPPED 2026-07-30** across 9 tasks
(1,196 tests green, 26 test products).

**Amended 2026-07-31** (spec/plan `2026-07-31-salvage-run-site-tour-and-backstop*`): two operator-reported
fixes to the shipped run. (1) **Vessel now tours the sites.** A new `positioning` step sits AHEAD of
`configuring` (`… → positioning → configuring → launching → awaiting → verifying → positioning`); the
VESSEL flies to each salvage body so drones deploy locally, instead of parking at the entry point /
Lagrange and ferrying drones out-and-back per site (which doubled travel, worst at far/ many-site
systems). `positioning` keys its destination off `nextBody` (deterministic), NOT `workedBody(controller)`
— nothing writes `currentDirectiveConfig` optimistically, so the controller row names the PREVIOUS body
until `set_directive` lands; `configure` runs last, at the body. Relay emplacement is unchanged
(relay-first). (2) **`awaitCompletion` no longer false-stalls `dronesNotRecovered`.** The blind
10-min backstop that dumped into `verify` mid-mining is gone; while the controller reports
`gather_salvage` the run waits however long mining takes, reconciling on a `reconcileInterval` (2 min)
cadence to catch a dropped completion, and hands to `verify` only once drones aren't travelling.
`verify` is unchanged and stays the ONE `dronesNotRecovered` staller. The fresh-evidence gate keys off
the DRONE rows via `min()`, never `max([controller]+drones)`: [[ami-drones-are-event-silent]] drones stay
stale after launch while the controller churns via its digest, so a `max` would let a fresh controller
vouch for a stale "still aboard" drone (the review-caught Critical). Blessed tradeoff: a server that
keeps `gather_salvage` asserted while a drone is truly lost waits forever rather than stalling
(Cancel-recoverable; false-stalls were the real pain). (3) **Relay emplacement actually works now**
(commit 649f38c): `lagrangePoint(in:)` read the always-empty `Planet.lagrange` and returned nil for
every system, so `emplace` silently skipped relay deployment and the run had NEVER planted a relay
live — it now emplaces at the system's `entry_point` (itself an L4, where the vessel already
arrives), falling back to a synthesised `<lowest planet>-L4`. See [[lagrange-points-and-entry-point]].

**Haul Run SHIPPED 2026-07-31 — see [[haul-run-design]], and note that §6 of this spec is SUPERSEDED.**
§6 assumed our engine would hand-drive a `cargo_freighter` through travel → collect → travel →
deposit. It never should have: the AMI transport controller already does exactly that server-side via
its `ferry` directive, at no API cost, so the shipped Haul Run only chooses which pile each
`auto:haul`-tagged controller drains. Two of §6's rules were wrong and are corrected there — the
`in_control_range` selection rule (a bare stockpile has no device to read a flag from) and the
`collect_resources` call (which requires an explicit `resources` map, so "collect to fill" was never a
single verb). The relay-plants-make-the-freighter-commandable insight below still holds; it is what
satisfies ferry's own FTL-link requirement.

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

## Built, and what the whole-branch review corrected (2026-07-30)

Five of these were live-consequence bugs that no unit test could have caught, because each lived in the
seam *between* a tested pure function and the engine that calls it.

- **Target planning is a `MissionStepMachine` requirement, not an engine switch.**
  `DirectiveEngineCore.resolveExtendQueue` used to call `SurveyRoamPlanner.nextTarget`
  unconditionally, for every `DirectiveKind` — so `SalvageTargetPlanner` had **zero production
  callers** and a Salvage Run planned with the exact inverse filter (`fullyScannedAt == nil`; salvage
  is only ever known in systems the survey already finished). It would have walked outward to the
  nearest UNSCANNED star, found no salvage, and still deployed and activated a 370-unit relay there
  before repeating until stock ran out. Now `plan(RoamContext) -> RoamPlan` — the engine gathers
  census/assays/devices/vessel in one read, each machine owns its ranking. **The regression guard has
  to be end-to-end through `evaluateOnce`**: a unit test of either planner passed the whole time.
- **`RoamPlan` distinguishes `.idle` from `.exhausted`.** A survey exhausts permanently (nothing puts
  a star back in its candidate set) so it finishes. A salvage frontier is a snapshot — the survey roam
  keeps uncovering salvage, and each relay widens reach — so it **idles and re-checks**, which is what
  the launcher ("until you cancel it"), the list row and §1 already promised. Idle re-checks are
  backed off 60s in the engine so an empty frontier does not scan the whole census on the 5s tick.
- **A re-entry budget read off the timeline** (`SalvageRun.stepEntryCount`) is the migration-free way
  to bound a step that re-enters itself. `DirectiveExecutor.move` already writes a `.stepStarted` row
  per transition and Retry/Skip write `.resolved`; counting backwards to the first non-matching entry
  gives an attempt counter that survives a relaunch. See [[same-step-dispatch-needs-tracked-op]].
- **A stall whose guidance names a verb must make that verb work.** `salvageSystemUnresolved` said
  "retry to fetch it again" on three branches that never issued `.refreshSystem`, against a `retry`
  that only re-stamps the clock — so Retry replayed the same snapshot forever and only Skip (which
  permanently forfeits the system) actually exited. The read now sits on the *terminal* branch, spent
  once per visit, with Retry re-arming the budget.
- **Two more stale-row stalls:** `confirmingRelay` polled a device row nothing refreshes (the
  `relay.*` route only invalidates FTL-mesh freshness), and `awaitingRelayRestock` — the one stall
  whose whole purpose is waiting on an operator changing a stow column — decided from local rows only.
- **The mining loop's only terminator was one `salvage.depleted` SSE frame.** A dropped one meant a
  real `launch` POST every cycle, unbounded. It now compares `nextBody` against the body the
  controller's own in-force `gather_salvage` config names — the server's record of what was worked, so
  no new column — reads the system once when they match, then stalls `salvageBodyNotDepleted`.
- **A planted relay drops its `auto:salvage` tag.** The tag earns its place while the relay is cargo —
  it is what lets `preflight` verify the relay's existence and stowed state in the SAME one-request
  `.refreshFleet` read as the controller and drones. Once deployed and activated it is permanent
  infrastructure, so keeping it tagged would make every later fleet read drag back a growing tail of
  planted relays. `MissionAction.setDeviceTags` (resolved in `DirectiveExecutor`, not
  `DirectiveEngineCore` — it needs no re-ask, so it sits beside `.refreshSystem`) untags on
  `confirmRelay`'s SUCCESS branch only: a relay that deployed but never came up keeps the tag because
  it is still the run's problem. Three properties are load-bearing — `updateTags` is DECLARATIVE, so
  the new set is `relay.tags.filter { $0 != tag }` and never `[]` (that would wipe operator tags);
  it is idempotent on `tags.contains(tag)`; and it is BEST-EFFORT, advancing to `configuring` even if
  the PATCH throws, because the relay is up and the mesh is what mattered.
- **`features.contains("relay")` is right for `meshSystems` and wrong for a dispatch query.** A
  `system_hub` carries the feature (integrated relay) and genuinely meshes its system, but a dispatch
  query gets `deploy` issued at whatever it returns — so `relay(aboard:)` / `deployedRelay(near:)` are
  narrowed to `deviceType == "ftl_relay"`. Both `"relaying"` comparisons go through `Device.statusBase`.
