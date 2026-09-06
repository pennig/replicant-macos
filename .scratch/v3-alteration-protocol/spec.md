# v3.0.0 "Alteration Protocol" — gap sweep

Swept 2026-09-06 against `https://replicant.space/docs/` (footer reads
`v3.0.0 · alteration build`, docs `last-modified: 2026-09-02`) and the live
swagger at `https://api.replicant.space/swagger/openapi.json`.

Pinned spec today: `openapi-2.5.1-edits.json` (symlinked as `openapi.json`).

## What the sweep established

### The OpenAPI spec barely moved

Live swagger vs pinned pristine `openapi-2.5.1.json`: **no new paths, no removed
paths, one new schema** — `app_schemas_device_commands_DetonateSchema`, added to
the `POST /v1/devices/{device_code}` command union (23 → 25 variants, counting
`TriangulateSchema` from 2.5.0).

So the spec is *not* where v3 lives. Terraforming has **zero** spec coverage:
`terraform`, `equilibrium`, `biosphere`, `hydrosphere`, `toxicity`, `tectonic`,
`oxygen`, `mass_class`, `composition`, `approach_angle` all return 0 hits across
the whole document. The docs site and live probes are the only sources.

### The simulation endpoints have been in the spec since 2.2.0 and were never built

`openapi-2.2.0.json` (fetched 2026-07-13) already carried all six:

    GET    /v1/devices/{device_code}/simulate            → ScenarioListResponseSchema
    POST   /v1/devices/{device_code}/simulate            → SimulationEnterResponseSchema (201)
    GET    /v1/devices/{device_code}/simulate/active     → SimulationActiveResponseSchema
    DELETE /v1/devices/{device_code}/simulate/{sim_id}   → *** no 200 declared ***
    GET    /v1/accounts/simulations                      → SimulationHistoryResponseSchema
    GET    /v1/leaderboards/simulations[/{scenario_code}]

Nothing in `app/Modules` references `simulate` or `scenario`; `git log --all -i
--grep=simulat` finds no feature commit. This is the work Matt means by "dig up
the simulation work again".

The DELETE is the [[undocumented-success-response-throws]] shape: `default`-only,
so a successful abandon decodes against the strict error schema and throws.

## Why this is now blocking, not optional

Terraforming devices cannot be *activated* in the real galaxy until the account
completes the `terraforming_training_1` scenario at the `replicant_interface`
inside the `MIRFAKA-OBJ-1` datacentre megastructure. Verified live:

    GET /v1/leaderboards/simulations →
      hunter_gatherer, mining_rush, mining_sprint, resource_hunter,
      terraforming_training_1        ← all completions: 0, best_time: null

Zero completions across every scenario, globally. The simulation feature is the
gate on the whole terraforming half of the season.

`GET /v1/locations/MIRFAKA-OBJ-1` confirms the datacentre exists and is
`status: completed`, `megastructure_type: datacentre`, `progress: 100`.

## Live decode breakage on main, today

### 1. `GET /v1/species` throws — the Civilisations screen is broken

`app_schemas_species_SpeciesSchema` is `additionalProperties: false`. The live
payload now carries an **`environment`** object we do not declare:

    "environment": { "hydrosphere":[0,10], "oxygen":[12,18], "gravity":[0.8,1.5],
                     "pressure":[0.3,0.7], "tectonic":[0,15],
                     "temperature":[300,340], "biosphere":[5,25],
                     "toxicity":[0,15] }

All 28 species carry it. `CivilisationsClient.swift:33` calls
`getV1Species().ok.body.json`, so every load throws.

Upstream declares neither `environment` nor `star_regions`; we already patch
`star_regions` locally, so this is one more key in the same slot. **This is a
one-line spec patch and the only unambiguously broken thing found.**

A live-payload sweep of 16 other GETs the app calls (`accounts/me`, `devices`,
`replicants`, `blueprints`, `messages`, `achievements`, `leaderboards`,
`tutorials`, `accounts/events`, `accounts/simulations`, `events`, four
`locations/{code}` shapes, two device shapes) found **no other unknown-key
throw**. `/v1/bobnet/channels` and `/v1/shops` declare no 200 at all — a
pre-existing `default`-only trap, not new.

### 2. The `atmosphere` Bool/String throw is still unmerged

The v3 moon payload sends `"atmosphere": false` (a Bool). On `main`,
`RawBodyPhysical.atmosphere` is `String?`, so every planet/moon body hydrate
throws. Commit `9d5a1f11` fixes it but lives only on
`worktree-catalog-moon-rows`. That branch has to land before any terraforming
work, or the screens that would show the new attributes cannot even decode.

## What the body payload gained

Planet and moon are `{"type":"object","additionalProperties":{}}` in the spec, so
new keys are **dropped silently, not thrown** — no spec patch needed for them,
but nothing reaches the UI either.

Seven environmental attributes, per the docs' scanned-moon example:

| wire key             | range      | in `BodyPhysical`? |
|----------------------|------------|--------------------|
| `surface_temp_k`     | 50–1200 K  | yes                |
| `atmo_pressure_atm`  | 0–100 atm  | **no**             |
| `atmo_o2_pct`        | 0–100 %    | **no**             |
| `atmo_toxicity`      | 0–100      | **no**             |
| `hydrosphere_pct`    | 0–100 %    | **no**             |
| `tectonic_index`     | 0–100      | **no**             |
| `biosphere_index`    | 0–100      | **no**             |

Plus three more new keys, also absent from the DTOs: `category` (`"barren"`,
`"frozen"`; present even on *unscanned* planets — verified on `SOL-3`, `DELTA-3`),
`parent_planet` on the moon block, and `location_type` repeated inside the body
block.

Each attribute also has a natural **equilibrium** it drifts toward, computed from
gravity/mass/orbit. The docs describe equilibrium as central to play (device
rates must beat drift; coupling effects scale with deviation from equilibrium),
but no probe has yet shown an equilibrium value on the wire. **Unknown: whether
`GET /v1/locations/{code}` exposes equilibrium, or only the `terraforming.status`
event does.** Needs a live terraforming site to answer, which needs the training
scenario, which needs the simulation feature.

`StarSystem` persists as a JSON blob in `systemDetails.systemJSON`, so widening
`BodyPhysical` needs **no schema migration** — new optionals decode as nil from
old blobs.

## What the device layer gained

**Terraforming components** (docs table). Four are already in my blueprint list
(`thermal_lance`, `atmo_processor`, `filtration_array`, `atmospheric_regulator`);
the rest are simulation-locked: terraform monitor, orbital mirror, orbital shade,
cryo disperser, gas separator, aquifer tap, bio seeder. Also present and
undocumented in the components table: `climate_processor`, `biosphere_cultivator`,
`seismic_monitor`.

**Device configuration gained operational settings.** `PATCH /v1/devices/{code}`
with `{"configuration":{"settings":{"strength":0.75,"direction":"increase"}}}`.
The spec already declares `settings` as free-form
(`DeviceConfigurationSchema.settings`, `additionalProperties: {}`), so no patch —
but **the app has no `settings` support at all**: zero hits for `settings` in
`DevicesFeature/Sources`, `GameModels/Sources`, `GameServices/Sources` outside
message/account settings. Strength is a 0.0–1.0 continuous control on up to five
monitors and an arbitrary number of components; this is a real UI surface, not a
toggle.

**Two new commands, and both will throw.**
`app_schemas_devices_DeviceCommandResponseSchema` is `additionalProperties: false`
and is missing:

- `detect_object` → `detect_target` (1 key)
- `detonate` → `approach_angle`, `approach_speed`, `composition`, `impact_eta`,
  `kuiper_object`, `mass_class`, `object_designation` (7 keys)

Same class as the `hub_bonus` throw of 2026-08-21: the command fires, the server
acts, the client cannot decode, and the op records `.failed`. Patch before the
first call, not after.

The docs' own command reference (`/docs/api/devices/command/`) does **not** list
`detect_object` or `detonate`, and the feature→command table omits them. They
appear only on the impacts page. Docs gap worth reporting upstream.

## Impacts: the offensive half of an existing feature

The app already models the *defensive* case — `GameModels/Sources/Diversion.swift`
reads the `object` block of `GET /v1/locations/{code}` for a `diverting` propulsor
(impact target, ETA, likelihood, progress, thrust/hr, active plates), and
`ActiveTaskCard` renders it.

v3 makes the same machinery offensive: `detect_object` from a `sensor_array` or
vessel finds a Kuiper body (24-hour window), a `vector_charge` `detonate`s it
toward a planet, then propulsors (`increase`/`decrease`) and trajectory
deflectors (`steepen`/`shallow`) steer speed and angle. The rock becomes a
trackable `object_designation` and emits `diversion.detected` / `diversion.impacted`.

`SpecialSiteKind` already has `.object` and `.kuiper`. `DiversionSnapshot` needs
widening for approach angle/speed and composition/mass class, not replacing.

## Events

`terraforming.status` is named on the terraforming overview page and on the
strategy page, and the docs point at an Event Stream "Terraforming Update"
section for a graph/delta/anomaly dashboard. **It is not in the event catalogue
and its payload is undocumented.** The catalogue also omits `diversion.detected`,
though it lists `diversion.activated/deactivated/diverted/impacted/partial`.

Catalogue types the app has no handling for: `simulation.started`,
`simulation.completed`, `simulation.abandoned`, `simulation.expired`,
`system.object_detected`.

## UI taxonomy gaps

`DeviceStatus.tone(for:)` in `UI/Sources/DesignSystem.swift` is a closed switch
defaulting to `.offline`. New statuses seen in the docs — `detect_started`,
`launched`, `active` — fall through to offline, which reads as "broken device"
rather than "working". Same for `DeviceStatus.label(for:)`.

`BodyFacts.rows(moon:)` promotes at most five facts and stops at
radius/gravity/surface temp/atmosphere. Seven live attributes with targets,
deltas, and equilibrium do not fit a fact list — that is a panel, not a row.

Sidebar (`SidebarFeature/Sources/SidebarItem.swift`) has 13 items and no natural
home for either Simulations or Terraforming.

## Season context

Season 3 "Alteration Protocol": the Exodus Ark distributes humanity to twelve new
locations, terraforming is underway, a new NPC cohort, the Delta wormhole under
investigation. Riker at `SOL-3` is terraforming Earth and is the story entry
point. Every body I probed reports `scanned: false` — including `SOL-3`, where I
still hold an `ftl_beacon` — which may mean the season reset survey state.
**Unverified; worth confirming before assuming the local cache is merely empty**
(the app's sqlite file is 0 bytes, so the app itself has been reset).

## Decisions (2026-09-06, with Matt)

The three questions this sweep raised resolved into one ordering, because each
answer depends on measurements only the simulation can supply.

### 1. Terraforming is driven by hand first, automated second

A terraforming run is a control loop — read seven attributes, compare against a
species' eight target ranges, adjust N device strengths — and that is what
`DirectiveEngine` is for. It is **not** built as a directive yet, for one reason:
the gains are unmeasured. The docs are explicit that greenhouse runaway is
*causal*, firing at +1.0/tick at full strength once pressure passes 10 atm
regardless of drift, and "very difficult to recover from". A controller written
against guessed gains oscillates into exactly that.

There is also a shape mismatch. All eight existing run machines are **step**
machines — dispatch, confirm arrival, dispatch, confirm completion. Terraforming
has no steps; it converges and never completes. `MissionStepMachine` is the wrong
scaffolding, and the engine's outer tick loop is the right one. A `TerraformRun`
needs new continuous-controller scaffolding, which is a second-pass job.

**First pass:** a per-world control panel with its own sidebar item under the
**Operations** section (which holds 5 of the sidebar's 13 items today; Simulations
and Terraforming take it to 7, which the existing three-section grouping absorbs
without redesign). Shows current / target / equilibrium per attribute, a 0.0–1.0
strength control and a direction toggle per device, and anomaly warnings. The
account cap of **5 terraform monitors** bounds this to a five-row dashboard, which
is why it does not want to be scattered across five location rows nobody remembers
to visit.

**Also first pass, and independent:** the seven attributes plus `category` land in
`PlanetInspector` / `MoonInspector` in `LocationDetailView`. Those are body facts,
the view already dispatches per location type, and they are how you *choose* a
world before committing to a multi-hour operation.

**Second pass:** `TerraformRun`, written against constants measured in the sim.

### 2. The simulation ships in full, leaderboards included

Reframed from the original "full screen vs minimal unlock path", which was the
wrong axis. The simulation is three things at once:

- **A gate.** `terraforming_training_1` unlocks the terraforming components. There
  is no path around it.
- **A measurement instrument.** The training scenario runs a sped-up world where
  tick cadence, drift strength against body mass, anomaly frequency and device
  response curves are observable at zero risk to real devices. Every constant the
  `TerraformRun` controller needs is in there. **This is what makes the sim a
  prerequisite for automation rather than merely for device unlock.**
- **An integration environment for `DirectiveEngine`.** A fresh galaxy with a
  fresh loadout on a fast clock is the testbed the engine has never had. Most of
  its serious defects were found by live fire — see `brain-salvage-build`,
  `brain-mine-build`, `blueprint-components`. Caveat worth keeping honest: the sim
  loadout has no autofactory and runs under a speed modifier, so absolute timings
  do not transfer and it exercises the **bootstrap-shaped** runs (survey, mine,
  haul) rather than event fulfilment, the relay mesh, or restock.

Scope is full because the marginal cost is near zero: list / enter / active /
history are all required to run the training scenario at all, and the competitive
layer adds only two unauthenticated GETs and a ranking table. All five scenarios
currently show **0 completions globally**.

### 3. Impacts — patch the spec now, defer the feature

The two halves decouple cleanly, so they are being taken at different times.

**Now:** declare the eight undeclared keys on
`app_schemas_devices_DeviceCommandResponseSchema` — `detect_target` for
`detect_object`, and `approach_angle` / `approach_speed` / `composition` /
`impact_eta` / `kuiper_object` / `mass_class` / `object_designation` for
`detonate`. The schema is `additionalProperties: false`, so without this the first
attempt throws *after* the server has acted and the op records `.failed`, which
`CommandGovernor` reads as safe to re-POST. Same class as the `hub_bonus` throw
that cost three hours on 2026-08-21.

**Later:** the feature. The effect sizes justify eventually building it — a giant
ice body at fast-and-steep delivers Hydro +100 against an aquifer tap's
+0.6/tick, roughly 167 ticks of the dedicated device in one throw — but
`vector_charge` and `trajectory_deflector` are both absent from the blueprint list
(simulation-locked), the 24-hour detection window is real logistics pressure, and
the strategy guide describes a complete device-only path. `DiversionSnapshot` and
`ActiveTaskCard` already model the defensive half, so the offensive case widens an
existing model rather than adding one — it does not get cheaper by waiting, and it
does not get more urgent either.

## Build order that falls out

1. **Simulation feature** — full, including leaderboards. Unblocks everything.
2. **Run `terraforming_training_1`** — unlocks the components, and measures the
   constants §1 is waiting on. Record what it measures back into this directory.
3. **Body attributes** into `PlanetInspector` / `MoonInspector`. Independent of
   1 and 2; can land in parallel.
4. **Terraforming control panel** — device `settings` support (`strength`,
   `direction`) plus the per-world readout.
5. **`TerraformRun`** — the continuous controller, against measured gains.
6. **Impacts** — feature only; the spec patch is separate and earlier.

## Still unknown, and worth answering early

- **A tick's wall-clock duration is documented nowhere.** All six terraforming
  pages give rates per tick and none says what a tick is. It decides whether the
  control panel is a live dashboard or a twice-a-day check, and whether a 6-tick
  solar flare warning is ten minutes of notice or a day. Measurable in the
  training sim, and worth measuring first.
- **Whether equilibrium values reach the client at all.** The docs make
  equilibrium central (device rates must beat drift; coupling scales with
  deviation from it) but no probe has shown one on the wire. It may be on
  `terraforming.status` rather than `GET /v1/locations/{code}`.
- **`terraforming.status`'s payload.** Named on two docs pages, absent from the
  event catalogue.
- **Whether the season reset survey state.** Every body probed reports
  `scanned: false`, including `SOL-3` where an `ftl_beacon` is still held.
