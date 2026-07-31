<!-- wayfinder:map -->
# Automation brain — running the fleet unattended

## Destination

The app runs the fleet **without operator intervention.** A standing orchestrator
("the brain") observes global world state and pursues five standing capabilities
autonomously:

1. **Charting** — uncharted systems continually surveyed (survey roam, *shipped*).
2. **Mining** — mining arrives at any discovered salvage/belt site (Salvage Run, *shipped, not running*).
3. **FTL mesh** — grows where useful, bridging >7.5 ly gaps by planting relays at boring waypoint systems (*unbuilt*).
4. **Printing + delivery** — devices print automatically and are delivered where needed (*unbuilt; the `awaitingRelayRestock` human-stall is this hole*).
5. **Location events** — fulfilled with a few clicks + waiting (*unbuilt*).

Everything runs unattended **within a spend ceiling.** Location events are the one
seam that hands control back: the brain surfaces the fulfilment approaches and their
tradeoffs, the operator picks when there's no clear winner, then it executes and waits.

The brain is **additive** — it launches/retires the existing Survey and Salvage runs as
opaque executors and builds only genuinely-new behaviour on `print`/`deliver`/`shuttle`
primitives. **"Done" includes a robustness bar:** B (a global orchestrator) is the
fraught path, so no capability counts as complete until it clears an explicit
anti-fragility standard.

**This map stops at locked designs + handoff-ready plans.** Each capability is then
built in its own subagent-driven session, as every prior Directives stage was. The map
resolves *decisions*; it builds nothing.

## Notes

**Domain.** The automations feature is named **Directives**. It is mature: a clock-driven
(5s tick), per-directive engine (`DirectiveEngine`, non-TCA) over a pure `WorldSnapshot`;
bespoke `MissionStepMachine`s (Survey Run + continuous roam, Salvage Run) dispatched
through a `CommandGovernor` (60/min actions budget, per-device in-flight claim); a
unified Directives surface with stall-resolution verbs and a read-only step timeline.
Read these before any ticket:
- `app/.claude/memory/directives-feature.md` — engine architecture + every shipped stage + invariants.
- `app/.claude/memory/salvage-run-design.md` — the two-kind split, the frontier bootstrap, and **the four threads deliberately-not-built** (engine printing/stowing/repair; tag-driven non-AMI automation; relay+beacon emplacement for events; waypoint relay errands). This effort is largely those threads under one brain.
- `app/.claude/memory/ftl-authority-rule.md` — command authority + why a stationary anchor replicant and relays matter.
- `app/.claude/memory/architecture-review-v3.md` — the V3.9 automation blockers this design answers.
- `app/.claude/memory/travel-is-cheap-vs-survey.md`, `salvage-resource-amounts.md`, `device-tags-and-control-range.md`, `ami-drones-are-event-silent.md` — measured facts the policy layer will lean on.
- Specs/plans live under `docs/superpowers/`; `app/CLAUDE.md` holds the engine + backend-access rules.

**Skills every session should consult.** `/grilling` + `/domain-modeling` (default), `/prototype`
for the primitive/world-model tickets, `/research` for the AFK tickets, `probe-api`
(GET-only is safe; POST/PATCH/DELETE mutate the one live account and must be announced),
`swift-test-event-stream`, and the `pfw-*` skills for engine/TCA patterns.

**Standing preferences for this effort.**
- **Additive, always.** Never rewrite a shipped run to satisfy a purity goal. Re-expressing Survey/Salvage as primitives is a later cheap refactor, out of scope here.
- **Robustness is definition-of-done**, not a phase. Every capability design must state how it clears the bar (ticket 02).
- **Solo-operator.** One operator, ever. Authoring friction is the kill-risk; unattended + a few clicks beats flexibility.
- **Plan-only.** Tickets resolve to designs + plans; builds happen in separate subagent-driven sessions.

## Decisions so far

<!-- one line per closed ticket: gist + link; detail lives in the ticket -->

- [Research: printing & autofactory](issues/07-research-printing-autofactory.md) — gate = the `print` feature (autofactory: 10-slot queue; the 3 print vessels: single-job); material = a blueprint's six-type `resources` bill drawn from the printer's **location stockpile** (short stock parks the job), `ftl_relay` = 370 units; lifecycle enqueue → `print_complete` (carries `new_device_code`) → **auto-deployed at the printer's location**, optionally adopted/oncomplete.
- [Research: location-event fulfilment](issues/08-research-location-event-fulfilment.md) — an event's `criteria[]` holds fulfilment *options* (devices+resources), `progress` mirrors them live with `met_option`; **the choice is real but a minority (5 of 16 offer alternatives)** and is authored in the payload, not selected by the call — you stage one option on-site, fulfil with an **empty POST** `locations/{code}/events/{designation}` (replicant must be present). Population is a **rare bursty interrupt (~0.5/day)**, so the HITL seam is occasional. Tradeoff axes are device/resource swaps only — never delivery-vs-command or explicit time/cost.
- [Research: delivery & control mechanics](issues/09-research-delivery-control-mechanics.md) — delivery = cradle `stow→travel→deploy→activate` or surge `attach→travel→detach`; authority never hands off per-device — **activating a relay at a system's L4 meshes the system**. **`in_control_range` is the server's authoritative per-device "can I command this now" bool** (already decoded/read by the app) — the brain should read it, not recompute the mesh, and never gate on a carrier's flag. Tags address a fleet account-wide (sees stowed/travelling) but, unlike an AMI controller, pay actions-budget per command. L4 is a first-class travel target (`<STAR>-<n>-L4`).
- [World model & global state](issues/01-world-model-global-state.md) — the brain never holds a fresh-*everything* picture: a derived in-memory `WorldView` (scaled-up `WorldSnapshot`, **no new table**) gives a **best-effort global for ranking** + **just-in-time `.high` confirm at every dispatch** — the shipped `preflight`/`.deferred` pattern lifted to global scope. Event-silent rows (AMI drones) are ranked-on freely but always confirm-read before acting, and the confirm-read *repairs the row it reads* (no staleness tracker). **No new poller, no budget carve-out** — planning rides the SSE drain, dispatches spend the shared `PollCoordinator`, executors own their own freshness; the rule is **exception-free** (location events are SSE-nudged, spend is self-metered, SSE-dropout → inherited gap-repair). Uncertainty ⇒ **defer, escalate if persistent — never guess, never silently hang** (deadlines/UX graduate to 02).

## Not yet specified

<!-- graduates as the spine (01–06) locks -->
- **Mesh-growth "where useful" policy** — what makes a gap worth bridging; ranking; the Stage 5 Relay Run + waypoint errands + the FTL-mesh incremental-add optimisation. Blocked on the goal/decision policy (03) and hub model (06).
- **Automatic print + deliver build** — closes `awaitingRelayRestock`. Blocked on the primitive contracts (05) and hub model (06).
- **Location-event fulfilment build** — detection → surface approaches/tradeoffs → operator pick → execute. World model (01) + research (08) done; now blocked on the seam (04).
- **Salvage Run activation + Haul Run disposition** — does Haul Run collapse into the `shuttle` primitive, or ship as its own kind? Blocked on the primitive contracts (05).
- **Per-capability build plans** — one handoff-ready plan per capability, once its design locks.

## Out of scope

<!-- ruled beyond the destination; never graduates -->
- **Device-list-at-scale UI revamp** — a real deferred need (fleet → hundreds), but a UI-scale concern, not automation autonomy.
- **Combat / defence automation** — not one of the five capabilities.
- **Multi-account** — one operator, one account, by principle.
- **Re-expressing shipped Survey/Salvage runs as primitives** — a later cheap local refactor, not a prerequisite this effort waits on.
