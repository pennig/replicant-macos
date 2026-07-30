# Salvage Run + Haul Run — design

Status: **approved 2026-07-30**, not yet implemented.
Supersedes nothing. Builds on `2026-07-24-directives-design.md` (v2, the engine) and the continuous
survey roam. Read those first — this spec assumes `DirectiveEngine`, `MissionStepMachine`,
`WorldSnapshot`, `CommandGovernor`, the stall-resolution verbs and the step timeline all exist.

## 1. Goal

When the continuous survey roam uncovers salvage, an automation should already be running that goes
there, mines the site, gets the resources home, and never asks the operator anything. Delivery
destination is **AINALRAM-BELT-1** (the autofactories — resources are wanted where printing happens).

Non-goals: hauling for its own sake, multi-vessel coordination, and anything that requires the
operator to choose a system.

## 2. The rule that shapes everything

A command needs **authority** at the target. Authority comes from either

- a replicant physically present in the system, or
- the target being in an FTL-mesh subgraph that also contains **one stationary replicant** —
  stationary meaning not currently in interstellar travel.

A relay must physically sit in a system for that system to be on the mesh; 7.5 ly is the
relay-to-relay edge range, not a coverage radius. Within a connected subgraph there are no hops —
everything is mutually reachable however many edges the subgraph contains. `ftlLinks` stores that
closure, which is why it reads as a 7-clique containing 12.5 ly pairs.

Two consequences the design leans on:

- **`pennig-1` must not travel.** It is the stationary replicant anchoring the main subgraph, and the
  mesh goes dark for commands while its anchor is in transit. This is why the salvage vessel is a
  *dedicated third replicant* rather than pennig-1, and why the roaming survey replicant — in transit
  constantly — is never an acceptable anchor.
- **Planting a relay at a salvage system is what lets the miner leave.** Once the system joins the
  mesh, the freighter there is commandable from the anchor, so the mining vessel does not have to
  park and babysit the haul.

## 3. Verified API facts

Probed live 2026-07-30 unless noted. Load-bearing for §5–§7; if any drifts, the affected step changes.

- **`GET /v1/devices/tags/{tag}`** — "List all owned devices matching a tag, with full device status."
  Returns the fleet-wide list filtered by tag, carrying `stowed_in_device_code`,
  `controller_device_code`, `attached_devices`, `available_commands`, `features`, `status`,
  `location`, `in_control_range`. Confirmed to return `travelling` devices (null `location`). Because
  it filters on tag rather than location it is **structurally immune** to the trap that
  `GET devices?location=X` falls into — stowing clears location, so a location query cannot see a
  device aboard a vessel. `GET /v1/devices` also accepts `?tag=` and `?untagged=`.
- **`in_control_range: Bool`** ships on every device in both `DeviceListItemSchema` and
  `DeviceStatusSchema`. **Correction (2026-07-30, during planning): the app already reads it.**
  `Device.inControlRange` is a computed property over the `detail` blob, with `isOutOfControlRange`
  beside it; both are covered by `SchemaMappingTests` and `DeviceActivityTests`, and `CommandGrid`
  already uses them. No migration and no model change are needed — §4.1's task was written on a bad
  grep and has been struck. It survives a list sync because `in_control_range` is on the *list* schema
  too, so the `detail` rewrite that erases `controlled_devices` does not erase this.
- **`GET /v1/locations/{designation}`** returns `inventory: [{quantity, resource_type}]` — the
  location stockpile. AINALRAM-BELT-1 currently holds 51,150 units across the six types.
- **A salvage body carries its sites.** `TOSLIT-3-2` (a moon) returns
  `resource_sites: [{designation: "TOSLIT-3-2-SAL-1", site_index, resources_remaining_pct, site_type}]`
  with `inventory` on the **body**. So `gather_salvage`'s `location` is the **body**, matching the
  existing composer picker (`StarSystem.salvageBodies`), and mined output accrues to the body's
  inventory.
- **Lagrange points are addressable locations.** `ATIANFU-1-L4` returns `location_type: "lagrange"`
  with `lagrange.parent_planet` and `lagrange.l_point`, and holds our active relay at status
  `relaying`. A relay is emplaced by travelling the vessel to `<STAR>-<n>-L4`, then `deploy`, then
  `activate`.
- **Mined output lands in the location's stockpile**, never in a drone (docs: the drone "leaves the
  result in nice organised piles"). Only `transport`-featured devices carry cargo.
- **`gather_salvage`** dispatches all of the controller's adopted mining drones to one salvage
  location, depletes it, and recalls the fleet to the vessel when `recall` is set. Requires
  `location` in its configuration.
- **`directive.completed` now waits for the recall** (v2.3.3, operator). When the directive is
  configured with recall, the event is held until the drones have finished travelling. This obsoletes
  the blind `recallGrace` wait — see §5.6.
- **`relay.activated`** is the SSE event when a relay comes up; existing code already refreshes the
  network on it.
- Only the **cargo freighter** (500 units) among transports has its own surge drive; transport drones
  and haulers are cruise-only and need taxi-tagged surge plates to cross systems. Five surge plates
  are already tagged `taxi`.

## 4. Pre-work

One addition. It fixes a live wound rather than anticipating a future one.

### 4.1 `Device.inControlRange` — STRUCK

Planned as a migration; unnecessary. See §3 — the property already exists, is tested, and is already
used in the UI. Missions can read `device.inControlRange` today with no schema change at all.
`nil` still means *not yet read*, never *unreachable*, and callers must treat it that way.

### 4.2 Tag-resolved fleets

- `DevicesClient.byTag(_:)` over `GET /v1/devices/tags/{tag}`, persisting the returned rows through
  the existing device upsert path so stow/controller/location columns move for devices a
  location-scoped read can never see.
- A `fleetTag` on the directive row (`auto:salvage`, `auto:haul`). A mission resolves its own devices
  by tag instead of by location probe.

This is the missing primitive behind two of this codebase's most expensive incidents: a Survey Run
frozen in `recovering` for 20 minutes re-probing drones that were already aboard, and a run that lost
its whole drone complement because a stale row read as "still aboard". Staging remains the operator's
job — only *finding* the staged devices changes.

**Follow-up, not in scope:** the shipped Survey Run's `recovering` step can be simplified the same way
(§5.6). Left alone here to keep this change set honest.

## 5. Salvage Run — the vessel

One directive, one vessel, one serial executor. It makes piles and extends the mesh. **It never
hauls and never waits for hauling.**

Staged by the operator, verified by the engine: a surge+stow+cradle vessel hosting the dedicated
third replicant, tagged `auto:salvage`; aboard it one AMI mining controller with mining drones adopted
and stowed; and ≥1 `ftl_relay` stowed.

Steps, per target system:

1. **`planTarget`** — §7. Appends to `targets`, which is **append-only history** for this run exactly
   as for the survey roam, and for the same two reasons: a body that can never report itself complete
   would otherwise pin the planner forever, and the operator's Skip would be a no-op.
2. **`preflight`** — one tag query resolves the run's fleet. Require the controller aboard, ≥1 mining
   drone adopted *and* stowed, and a relay aboard if the target needs one. Positive staging findings
   are re-verified for freshness (`stagingFreshness`), because a row staling into a false "still
   aboard" is the direction that loses a fleet.
3. **`travel`** — vessel to the target system.
4. **`emplaceRelay`** — skipped when the system is already meshed. Otherwise travel to an L4 in the
   system, `deploy` the relay, `activate` it, wait for `relay.activated`. On success the system joins
   the mesh and every device there becomes commandable from the anchor.
5. **`mine`** — for each salvage body in the system, in descending assayed units:
   `set_directive gather_salvage {location: <body>, recall: true}` on the controller, then `launch`,
   then wait for `directive.completed`. Re-issue `set_directive` unless the in-force config matches
   exactly — a leftover config from manual use would otherwise silently work the wrong body.
6. **`verifyRecovered`** — **not** a timed wait. Because `directive.completed` is now held until the
   recall finishes (§3), the step is a single `.high` read of the tags endpoint confirming the drones
   are stowed aboard the vessel. Agreement advances; disagreement stalls `dronesNotRecovered` rather
   than departing. The old `recallGrace` blind wait existed only because adopted drones are
   event-silent *and* a location-scoped read cannot see a stowed device; the tag endpoint removes both
   halves of that problem.
7. **`advance`** — next target immediately. The pile and the mesh membership are left behind for the
   Haul Run.
8. **`restock`** — when no relay is aboard and the next target needs one, travel to AINALRAM-BELT-1
   and stall `awaitingRelayRestock`. The operator stows relays and hits Retry. The engine does not
   stow: that would loosen the never-stow contract, and §10 records it as its own future design.

## 6. Haul Run — the freighter

A separate directive with no coordination with the Salvage Run whatsoever. Continuous; ends only when
cancelled. Usefully generic — it drains belt-mining output too, not just salvage.

Staged: a `cargo_freighter` tagged `auto:haul`.

1. **`planStockpile`** — pick the largest known location stockpile that is not the delivery location
   and whose devices are `in_control_range`. `nil` control range is *unknown*, and unknown is not
   picked.
2. **`travel`** to it, **`collect_resources`** to fill, **`travel`** to AINALRAM-BELT-1,
   **`deposit_resources`** with the resources field omitted (empties the hold).
3. Repeat against the same stockpile until drained, then plan the next one. When nothing is
   reachable, **wait** — not stall. A quiet hauler with the miner still working is healthy.

The freighter's own 500-unit capacity against a 1,000–3,500-unit system means several round trips per
system; that is expected and costs the miner nothing, which is the entire point of the split.

## 7. Target planning — the frontier expands itself

Rank candidate systems by, in order: **already meshed**, then **one relay-hop from the current mesh**
(within 7.5 ly of a system holding an active relay), then total assayed units, then distance from the
vessel. Exclude everything in `targets`.

This is measured, not guessed, against the live catalog as it stood on 2026-07-30: 53 sites across 13
systems, 20,471 units. Treat those as a **snapshot, not a constant** — the catalog grew by ~400 units
during the hour this design was written, because the survey roam keeps finding salvage. The planner
must recompute from `siteAssays` on every evaluation and must never cache a system ranking.

- Planting relays **only at salvage systems**, richest-first, reaches **10 of 13 systems and 15,650 of
  20,471 units with 9 relays** — with no side-trips. TOSLIT's relay brings ARCTURUSAN into range,
  which brings ABSOLUTN, and so on. The run bootstraps its own reachability.
- **POLARISUM (2,090), ASTELLIO (1,561) and SOHIMU (1,170)** — 4,821 units — need a relay at a
  non-salvage waypoint first. Those are deferred, not stalled; §10 records the waypoint errand as the
  natural home for Relay Run.
- Meshing every known salvage system, waypoints included, is 18 relays: 6,660 units and 14,400s of
  print against 20,471 units unlocked, roughly 3:1 and permanent. Five of the six waypoints are
  already fully scanned, so their L4 points are known; only CIHAMUKUY is unscanned.

Relays are cheap (370 units, 800s) against a base stockpile that already stands at 51,150 units.

## 8. Stalls

Every stall halts the run. **No auto-skip** — the continuous survey roam settled that, and for the
same reason: unattended uptime is not worth a vessel touring systems accomplishing nothing while the
run still reads as healthy.

| Reason | Raised when |
| --- | --- |
| `noMiningControllerAboard` | preflight finds no `gather_salvage`-capable controller stowed aboard |
| `noMiningDroneAboard` | preflight finds no adopted, stowed mining drone |
| `dronesNotRecovered` | `verifyRecovered`'s tag read disagrees with the completion |
| `awaitingRelayRestock` | no relay aboard and the next target needs one |
| `relayActivationFailed` | `activate` rejected, or no `relay.activated` before the backstop |
| `unreachableDevice` | the confirm reads themselves fail |

The Haul Run adds none — an empty reachable-stockpile set is a wait.

## 9. UI

Two launcher sheets. List rows, detail pane, stall panel and step timeline all come free from
`DirectivesFeature`; the timeline needs only new `DirectiveLogEntry` kinds. Row subtitles follow the
roam precedent of reporting *work done* rather than m/n, since a continuous run's `targetIndex` sits
at `targets.count` for most of its life: "9 systems drained" and "4,200 units delivered".

System and body designations render in mono tokens, per the house rule.

## 10. Recorded, not built

Written to memory rather than into this plan. Each has a real future but no current consumer, and
each deserves its own design:

- **Engine-level printing, stowing, resource demand, and repair.** The operator's stated direction.
  `awaitingRelayRestock` (§5.8) is the first place it would pay off, by closing the last stall that
  needs a human.
- **Tag-driven automation without AMI controllers.** Tags make a fleet addressable regardless of
  state, which is most of what an AMI controller is doing for us. Worth weighing against the fact
  that AMI controllers run server-side and cost no API budget.
- **Relay + beacon emplacement for location events.** A location event wants a relay at an L4 *and* a
  beacon at the event site, so future tasks arrive without re-scanning; a beacon needs the mesh to
  function, hence the relay. §5.4's `emplaceRelay` is deliberately shaped as a sub-machine so this
  becomes its second consumer rather than a rewrite.
- **Waypoint relay errands** for the three systems §7 defers — the natural home for the long-planned
  Relay Run (directives spec §4, Stage 5), plus its FTL-mesh incremental-add optimisation.
- **Simplifying Survey Run's `recovering` step** the way §5.6 does, now that the tag endpoint exists.

## 11. Build order and testing

1. Pre-work (§4) — migration, `DevicesClient.byTag`, `fleetTag`. Independently landable and
   independently useful.
2. Salvage Run (§5, §7, §8) with its launcher. Valuable alone: it drains systems and grows the mesh
   even with no hauler running.
3. Haul Run (§6). Valuable alone against existing stockpiles.

Both machines are pure `(directive state, world snapshot) → action` functions and are tested as such
under `TestClock`, with no network. The frontier planner (§7) gets its own tests against a fixture
census, including the bootstrap ordering and the three deferred systems. Clients use
`unimplemented` test values per the loud-defaults rule.
