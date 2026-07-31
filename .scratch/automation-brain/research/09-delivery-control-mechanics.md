# Research findings: device delivery / hand-off + control-range / tag mechanics

Resolves `.scratch/automation-brain/issues/09-research-delivery-control-mechanics.md`.

Method: `probe-api` (read-only `replicant raw GET` against the one live account, 2026-07-31)
+ https://replicant.space/docs/ + `app/Modules/API/Sources/openapi.json` (symlink →
`OpenAPI/openapi-2.3.3-edits.json`) + the linked `app/.claude/memory/` notes. **No mutation was
issued.** Every question below is answered from a GET probe, the docs, or the spec; anything that
would need a POST is flagged "unverifiable without a mutation".

Live fleet snapshot used throughout: `GET devices?limit=50` returned 50 rows (the page cap — there
are more); `GET devices/tags/auto:salvage`, `.../taxi`; and device details for `1F63E913` (SOL-3
beacon), `3AFC718C` (relay), `C7836770` (salvage vessel).

---

## 1. Delivery / hand-off — the real sequence and its events

**There are two distinct delivery patterns; the ticket's `stow → travel → deploy → activate` is the
*cradle* one.** Both are in live use on this account.

### A. Cradle / stow model (self-mobile carrier with the `cradle` feature)

This is the salvage-fleet path and the relay-emplacement path. Confirmed live: `C7836770`
(`heaven_vessel`) has `features: ["surge","cruise","system_scan","mine","cradle","print","census"]`
and holds 10 stowed devices in its `stowed_devices` block.

| step | command (`POST devices/{code}`) | response class | status / effect | event(s) |
|---|---|---|---|---|
| **stow** | `{"command":"stow"}` (optional `target` carrier; auto-picks nearest if omitted) | immediate / terminating | `{status:"stowed", stowed_in}`; **clears the device's `location` → null** | `device.stowed` |
| **travel** | `{"command":"travel", <destination>}` on the *carrier* | deadline (self-describing) | carrier `status:"travelling"`, `location:null`; carries `arrives_at` (leg) + `final_arrives_at` (route) | per-leg `device_cruise_arrived` / `device_surge_hop_arrived`; final `device_travel_arrived` on a multi-leg/interstellar route (a **single-leg** trip emits ONLY `device_cruise_arrived`) |
| **deploy** | `{"command":"deploy"}` | immediate | `{status:"deployed", deployed_from, location}`; **sets the device's `location` to the carrier's current location** — inverse of stow | `device.deployed` |
| **activate** | `{"command":"activate"}` | immediate / status-only, **no tracked op** | brings the device online — a relay → `relaying`, a beacon → `monitoring` | device-level quiet; the mesh-level `relay.*` event fires (see below) |

Sources: command shapes and response classes — `app/.claude/memory/device-command-shapes.md`
(stow/deploy §"stow", travel §"travel", activate §"no-param lifecycle"). Travel events and the
single-leg-only-`device_cruise_arrived` trap — `app/.claude/memory/travel-block-leg-vs-route.md`
(the memory is the source of truth here; the docs' `moving-devices` page does not enumerate events).
Relay emplacement = "travel to `<STAR>-<n>-L4`, then `deploy`, then `activate`; an active relay
reports status `relaying`" — `app/.claude/memory/ftl-authority-rule.md`, corroborated by the docs
FTL-relays page ("Travel to the target system → navigate to an L4/L5 Lagrange point → issue an
activate command"; "an active relay reports status as `relaying`").

Live corroboration of the end state: relay `3AFC718C` reads `status:"relaying"`,
`location:"ATIANFU-1-L4"`, `in_control_range:true`, and every deployed relay in the fleet sits at a
`*-L4` designation (`AINALRAM-1-L4`, `SHERATANON-10-L4`, `ALPHERATOZ-8-L4`, …).

> **Activate ordering note (from the shipped Salvage Run):** the emplacement machine is
> deploy → activate → (un)configure, and the un-tag step is *best-effort* — it advances even if the
> PATCH throws, because "the relay is up and the mesh is what mattered". A relay that deployed but
> never came up keeps its `auto:salvage` tag on purpose. See
> `app/.claude/memory/salvage-run-design.md` §"A planted relay drops its tag".

### B. Attach / surge model (carrier with the `attach` feature — e.g. `surge_plate`)

The docs' `interstellar/moving-devices/` page describes a *different* path: `attach` the target
device(s) to a surge carrier (both must be at the same location), `travel` the carrier — "every
attached device travels with it as a single unit" — then `detach` at the destination to "release
every attached device with a single detach command". Large devices that can't be cradled are
`compact`-ed first (30% of print time) and `unfurl`-ed at the far end. `attach`/`detach` ship the
device codes under **`targets`** (a list), not `devices`. Sources: docs `moving-devices`;
`app/.claude/memory/device-command-shapes.md` §"attach / detach", §"compact / unfurl".

Live corroboration: the five `taxi`-tagged `surge_plate`s (`GET devices/tags/taxi`) are exactly these
attach-model carriers.

**So for the automation brain's `deliver` primitive:** a self-mobile drone/relay/service-bot delivers
via cradle (stow→travel→deploy→activate); a device too large or without cradle capacity delivers via a
surge/attach carrier (attach→travel→detach, with compact/unfurl bracketing). The brain must branch on
the carrier's feature (`cradle` vs `attach`).

### How command authority transfers / attaches on arrival

**It does not "hand off" as a per-device token.** Whether a delivered device is commandable is
governed entirely by the FTL-mesh authority rule, and the server reports the answer per-device as
`in_control_range` (§2). Concretely (`app/.claude/memory/ftl-authority-rule.md`):

- Authority to command at a location comes from **either** a replicant physically present in that
  system, **or** the target sitting in an FTL-mesh subgraph that also contains one **stationary**
  (not in interstellar travel) replicant.
- **Delivering + activating a relay is itself the hand-off**: a relay must physically be *in* a
  system for that system to join the mesh (7.5 ly is the relay-to-relay *edge*, not a coverage
  radius — docs FTL-relays confirm "a finite 7.5 light year range"). Activating a relay at a system's
  L4 is what makes every other device there commandable from the anchor replicant. "Planting a relay
  is what frees a vessel."
- Within a connected subgraph there are **no hops**; `ftlLinks` stores the *closure*, so do not
  compute hop counts from it.
- A beacon **needs the mesh to function** — it reports status but cannot carry commands without a
  relay. "Deliver a beacon" therefore implies "deliver a relay first".

---

## 2. `in_control_range` — what it actually reports, and can the brain trust it

**Yes — it is the server's own authoritative answer to "can I command this device right now", and the
brain should read it instead of recomputing the mesh geometry.**

**Where it lives (spec):** a plain `boolean` on *both* device schemas — the list schema
(`openapi.json` line 1707, `DeviceListItemSchema`) and the status/detail schema (line 2127,
`DeviceStatusSchema`). Because it is on the *list* schema too, it **survives a list sync**, unlike
`controlled_devices` which is detail-only and gets erased by a list rewrite
(`app/.claude/memory/controlled-devices-detail-only.md`,
`app/.claude/memory/device-tags-and-control-range.md`). It is already decoded
(`Device.inControlRange` / `isOutOfControlRange`), test-covered, and `DevicesFeature/CommandGrid`
already disables commands on an out-of-range device — so the brain can read it today with no
migration.

**What it reports, from live probes (2026-07-31):**

- **`true`** on every settled device in a meshed system — the whole ATIANFU/AINALRAM salvage & haul
  operation, deployed relays, hub-adjacent beacons, etc.
- **`false` case 1 — a device in interstellar transit.** The travelling `heaven_vessel` `F2908E6E`
  (`auto:survey`, `status:"travelling"`) reads `in_control_range:false`. A device mid-cruise is
  out-of-range as a matter of course.
- **`false` case 2 — a stationary device in an *unmeshed* system.** Beacon `1F63E913` at `SOL-3`,
  `status:"monitoring"` (not travelling), reads `in_control_range:false`. SOL has no relay and no
  replicant present, so it is off-mesh — a clean live confirmation of the FTL-authority rule.
- **Per-device, NOT inherited from the carrier.** The controller and six drones stowed *inside* the
  travelling vessel `F2908E6E` all read `in_control_range:true` while their carrier reads `false`.
  (Matches the 2026-07-30 probe in `device-tags-and-control-range.md`.)

**Caveats the brain must encode (all from `device-tags-and-control-range.md` /
`ftl-authority-rule.md`, and consistent with the probes):**

1. **Never gate a mission on the *mover's* flag.** A freighter merely en route reads `false`; a
   survey vessel carrying its whole fleet reads `false` while the cargo reads `true`. Gate on the
   **destination**, or on the **fleet's settled members**, not the vehicle in flight.
2. **Treat `nil` as "not yet read", never as unreachable.** Prefer `isOutOfControlRange` (a missing
   field is *not* "out of range") over spelling out `inControlRange == false`.
3. **It is a snapshot** — it needs a fresh read to be current (an AMI-adopted drone is event-silent,
   so its row, `in_control_range` included, only moves when something reads it —
   `app/.claude/memory/ami-drones-are-event-silent.md`).

**One more finding worth recording:** `available_commands` is **not** filtered by control range. The
out-of-range SOL-3 beacon still lists `["change_owner","deactivate","decommission","deploy","stow"]`.
The server returns the device's *intrinsic* verbs regardless of reachability; the app is what disables
the buttons. So the brain **cannot** infer reachability from `available_commands` — it must read
`in_control_range`.

**Bottom line:** `in_control_range` is a strictly cheaper and more correct "can I command this?"
signal than recomputing the `ftlLinks` mesh + present-replicant set, because it already folds in
transit state, mesh membership, and the stationary-anchor rule. Recomputing the mesh in the app is
redundant work that the shipped code has already been migrated *away* from.

---

## 3. Tags as addressing — how far it substitutes for an AMI controller

**Endpoint (spec + live):** `GET /v1/devices/tags/{tag}` — openapi.json line 6256, summary *"List all
owned devices matching a tag, with full device status."* Returns `DeviceTagListResponseSchema`;
`cursor` + `limit` pagination, **`limit` max 50, default 10** (docs tagging page + spec). The plain
`GET /v1/devices` also carries `tag=` and `untagged=` filters (openapi lines 6362–6382). Tags are set
via `PATCH /v1/devices/{code}` with a `configuration` body (`tags` / `add_tags` / `remove_tags`,
mutually exclusive; ≤32 chars, lowercase+digits+hyphen+underscore) — **mutation, not probed here.**

**"Owned" = account-wide, not replicant-scoped.** The endpoint takes no `replicant_code` filter and
the spec summary says "all *owned* devices". (The docs page hedges toward per-replicant, but the spec
and the memory both say fleet-wide; the spec wins.)

**Why it is the missing primitive (confirmed live 2026-07-31):**

- `GET devices/tags/auto:salvage` returned the entire salvage fleet in **one request** — vessel
  `C7836770` plus its `ami_mining_controller`, 3 `mining_drone`s and 5 `ftl_relay`s — **all stowed,
  every one with `location:null`**. A `?location=` query is structurally blind to these: stowing
  clears location (`app/.claude/memory/location-scope-cannot-see-stowed.md`), so a location scope
  returns an empty set for a stowed fleet. The tag query is immune because it filters on *tag*, not
  *location*, and still sees `stowed`/`travelling` devices. Containment (`stowed_in_device_code`)
  survives intact.
- `GET devices/tags/taxi` → the 5 `surge_plate` carriers. A nonexistent tag → `count:0` (empty list,
  not an error).
- Tagging is *selective*: the salvage vessel also cradles an untagged `replicant_matrix`
  (`30790F27`), which does **not** come back on the `auto:salvage` query but does appear in the
  vessel's `stowed_devices`. So the tag roster is precisely the devices you tagged, independent of
  containment.

This is the root fix for both directive-engine incidents (a Survey Run frozen in `recovering`
re-probing drones already aboard; a run that lost its whole drone complement to a stale
"still-aboard" row). Any automation that needs "where is my fleet" should **resolve by tag, not by
location probe** — the shipped Survey Run and Salvage Run both do (`auto:survey` / `auto:salvage`).

**How far tags substitute for an AMI controller — and the cost.**

A tag endpoint gives an automation the *addressing* half of what an AMI controller provides: a
reliable, one-request roster of a named fleet regardless of idle / travelling / stowed. It does **not**
give the *actuation / coordination* half. The trade is budget vs. visibility:

| | Tag-driven (non-AMI) brain automation | AMI controller (`ami_*_controller`) |
|---|---|---|
| Fleet addressing | `GET devices/tags/{tag}`, sees all states | adopts drones under `controller_device_code` |
| Where it runs | client-side (the brain) | **server-side** |
| API / actions budget | **every** travel/deploy/scan/mine/recall command the brain issues costs budget, plus polling reads | coordination is **free of the actions budget** |
| Observability | full — each device's own row + `in_control_range` are readable | opaque: adopted drones are **event-silent**, all movement rolled into `ami.*.digest`; `controlled_devices` is detail-only and erased by a list sync |
| Autonomy | none — the brain must issue and track every command itself | autonomous cycle-by-cycle coordination |

So tags let a non-AMI automation reliably *find and command its own fleet* without an AMI controller —
which removes the single most expensive failure mode (the "where is my fleet" blind spot) — but it
pays API budget for every action the controller would otherwise perform server-side for free, and it
takes on the polling/reachability bookkeeping AMI hides. **This is exactly why
`app/.claude/memory/salvage-run-design.md` recorded "tag-driven automation without AMI controllers" as
a real direction left deliberately unbuilt: "AMI controllers run server-side and cost no API budget —
that is why they keep earning their place."** Net: tags substitute for the *addressing* role of an AMI
controller, not its *coordination* role.

---

## 4. Delivery targets — addressing a Lagrange point / L4 / event site

- **A Lagrange point is a first-class addressable location.** `location_type: "lagrange"`, with
  `lagrange.parent_planet` and `l_point` fields (`app/.claude/memory/ftl-authority-rule.md`). In the
  spec, the census location schema carries a `lagrange` object (openapi.json line 3310, opaque
  `additionalProperties`).
- **The travel destination is the designation string `<STAR>-<n>-L4`** (e.g. `ATIANFU-1-L4`). Live
  relays sit at exactly these designations. The `GET /v1/devices` `location` filter doc names
  `SOL-3-L4` as a valid "specific code … exact location" (openapi line 6354) — the same designation
  grammar is what you pass to `travel`.
- **Relay emplacement** = travel the carrier to `<STAR>-<n>-L4`, `deploy` the relay there, `activate`
  → `relaying` (docs FTL-relays; ftl-authority-rule; live end-state on `3AFC718C`). Relays must be at
  an L4/L5 because "the FTL relay needs to be in a gravitationally stable location in order to
  operate" (docs).
- **Event / mission site** is addressed by its own designation as a travel destination. A full event
  emplacement wants a **relay at the system's L4** *and* a **beacon at the event site** so later tasks
  arrive without re-scanning — and the beacon needs the mesh, so the relay goes first. This is the
  deferred "relay + beacon emplacement for location events" thread; the Salvage Run spec shapes
  `emplaceRelay` as a reusable sub-machine for exactly this second consumer
  (`app/.claude/memory/salvage-run-design.md` §"Deliberately … not built"). *No live event-site
  probe was run — this is doc/memory-sourced.*
- **Designation grammar caveat for travel targets:** a **bare** system code with no hyphen (`ATIANFU`)
  is a *proxy* for that system's entry point, not a precise location; a hyphenated designation
  (`ATIANFU-1-L4`) is exact. `app/.claude/memory/travel-system-proxy-codes.md`.

---

## Drift / caveats flagged

- **`in_control_range` is present and correct in `openapi.json`** (lines 1707 & 2127, both schemas) —
  *not* drift. The 2026-07-30 salvage design initially mis-read it as "generated but unused" off a
  `grep | head`-truncated search and speced a needless `ALTER TABLE`; it is in fact already decoded,
  persisted, and read by `CommandGrid`. Do not re-open that.
- **`available_commands` is not control-range-filtered** (new observation this session, from the
  SOL-3 beacon) — the app disables buttons, the server does not omit verbs.
- **Events are memory-sourced, not doc-sourced.** The docs' `moving-devices` page documents the
  *commands* but not the event catalogue; the per-leg-vs-final travel-event distinction and the
  single-leg-only-`device_cruise_arrived` trap live in `travel-block-leg-vs-route.md`. Treat that memory
  as the source of truth over the docs for events.
- **The docs describe the attach/surge delivery path prominently and the cradle/stow path only under
  FTL-relays** — the ticket's "stow→travel→deploy→activate" is the cradle path. Both are real; branch
  on carrier feature (`cradle` vs `attach`).
- **Tag endpoint default `limit` is 10** — under-asking silently truncates (`auto:salvage` returned
  exactly 10 = the whole fleet here, but a larger fleet would be cut). Always send `limit=50`.
  (`app/.claude/memory/paged-endpoint-maxima.md`.)
- **Anything requiring a POST/PATCH was not verified** — the exact `stow`/`deploy`/`activate`/`travel`
  response *envelopes* are taken from `device-command-shapes.md` (probed on prior sessions), not
  re-issued here. The tag *write* path (`PATCH …/{code}` config) is likewise unverified-by-mutation.
