# Research: location-event fulfilment endpoints + choice structure

Resolves ticket `.scratch/automation-brain/issues/08-research-location-event-fulfilment.md`.

**Method:** read-only live probes of `accounts/events` (GET only — no mutation attempted),
cross-checked against `app/Modules/API/Sources/openapi.json`, the shipped-feature memory
notes (`location-events-feature.md`, `experience-and-completion-events.md`), and
`https://replicant.space/docs/`. Trust order per ticket: docs → openapi (drifts) → live
probe (ground truth for shapes) → memory. Where they disagree the live probe wins on shape.

**Sources used**
- Live: `replicant raw GET accounts/events` and `...?status=all&limit=100` (captured 2026-07-31; 16 events on this account).
- Spec: `app/Modules/API/Sources/openapi.json` (paths + `app_schemas_location_events_*`).
- Docs: `https://replicant.space/docs/api/events/catalogue/`, `.../concepts/story/`.
- Memory: `app/.claude/memory/location-events-feature.md`, `.../experience-and-completion-events.md`, `.../undocumented-success-response-throws.md`.

---

## Q1 — What does a location event look like? Requirements vs rewards fields

Authoritative shape: `GET /v1/accounts/events?status=all` returns the whole account's
discovered events with full detail in one paged (`next_cursor`) call (live probe;
`location-events-feature.md`). Per-event top-level keys observed on all 16 rows:

`designation`, `location`, `location_name` (always `null` on all 16 — see drift), `event_type`,
`category`, `title`, `description`, `broadcast_message`, `tier`, `status`, `discovered_at`,
`criteria`, `rewards`, plus **`completed_at`** on completed rows and **`progress`** on active rows.
`progress` and `completed_at` are mutually exclusive in practice: the 2 active rows carry
`progress` and no `completed_at`; the 13 completed rows carry `completed_at` and no `progress`.

**Requirements** (what the event wants) live in **`criteria`** — an array of fulfilment
*options*, each `{name, devices:[{count, device_type}], resources:{<type>:<qty>}}`.
Example (live `SOL-3-EVT-001`, single option):
`{"name":"default","devices":[{"count":4,"device_type":"hab_module"},{"count":3,"device_type":"cargo_lifter"},{"count":1,"device_type":"orbital_farm"}],"resources":{"volatiles":200}}`.
The human-readable `description` restates the same requirements as an "Resolution options:
Option 1 - …" list — that text is narrative; `criteria` is the machine truth.

**Live progress** (active events only) lives in **`progress`**:
`{met:Bool, met_option:String?, replicant_present:Bool, options:[{met, name, devices:[{met,current,required,device_type}], resources:[{met,current,required,resource_type}]}]}`.
`progress.options[]` mirrors `criteria[]` one-to-one by `name`, adding live `current`/`required`
counters and per-item/-option `met` flags. `met_option` names the option that was satisfied
(null on both active rows here; a completed row has no `progress` at all, so `met_option` is
never observed populated on this account).

**Rewards** live in **`rewards`**: `{xp:Int, civilisation_points:Int, completion_achievement:String,
resources:{<type>:<qty>}}` (`resources` may be `{}`). Rewards are gain-only and unrelated to
`criteria` costs.

## Q2 — The choice: real, and where is it structured?

**Yes, some events genuinely offer a choice — but it is a minority, and it is structured in
the `criteria` payload, not in the fulfilment call.**

- **Structured, not implicit-in-rules.** The alternative approaches are explicitly enumerated
  as multiple entries in `criteria[]` (and mirrored in `progress.options[]`). The game rules
  layer only decides *which* enumerated option you end up satisfying.
- **Population of the choice.** Of 16 events on this account, **11 have a single `criteria`
  option** (usually `name:"default"` — no choice), **4 have 2 options, 1 has 3 options**
  (live `status=all` probe). So ~⅓ of events offer a real choice; the rest are a single
  prescribed recipe.
- **How the option is selected — implicit in game rules, NOT in the payload you send.** The
  resolve endpoint takes **no request body** (openapi: POST
  `/v1/locations/{location_code}/events/{designation}`, `requestBody: NONE`). You do not name
  the option. Instead you *stage* the devices/resources of one option at the event's location;
  the server tracks per-option progress and, when an option's requirements are met, sets
  `progress.met = true` and stamps `progress.met_option`. Fulfilment then commits that met
  option. So: **choice is authored structurally in `criteria`; selection is expressed
  implicitly by what you physically satisfy on-site, never as a parameter.** (openapi POST
  shape + `location-events-feature.md`: "Complete Event … does an **empty POST**".)

**Tradeoff axes** (from the 5 multi-option live events):
- **Device type** — e.g. `solar_storm_warning` (CUHECHIA-4-EVT-002): Defence Grid vs Shield
  Generator vs Radiation Shroud.
- **Device quantity** — 1× vs 2× vs 3× of a type (Radiation Shroud needs 2×; Atmo Processor 3×).
- **Device count ↔ resource cost swap** — `refugee_evacuation` (TENEGSHE-3-EVT-003):
  *Transport Fleet* 2× transport_drone + 200 volatiles **vs** *Heavy Lift* 1× cargo_lifter +
  100 volatiles (fewer, bigger devices for less resource).
- **Resource type & amount** — `geothermal_collapse` (TENEGSHE-3-EVT-004): 100 conductive
  vs 300 volatiles.
- **Simple vs composite build** — `orbital_habitat_request` (MENKENTAN-3-EVT-002):
  1× autofactory + 500 structural **vs** 2× hab_module + 1× power_cell_array + 300 structural.

Axes the payload does **not** expose: there is no delivery-vs-on-site-command distinction, no
per-option time field, no explicit cost field. Every option is the same *shape* of action
("have these devices + these resources present at the location"); time and printing/travel
cost are implicit (which devices you already own or must print, how far the location is).

## Q3 — What action fulfils an event? What confirms completion?

**Fulfilment = deliver/stage devices and resources on-site, then commit with an empty POST.**
No per-device command is issued to the event itself.

- Preconditions (openapi POST description, verbatim intent): "Requires the account to have
  **discovered the event (via scan)** and to have a **replicant at the event's location**.
  Resolver replicant is **auto-picked: most recently arrived (LIFO)** at the location." So you
  do not choose the resolver either.
- Endpoint: **`POST /v1/locations/{location_code}/events/{designation}`**, **no request body**
  (openapi). The app's `LocationEventsClient.complete(location, designation)` posts empty and
  re-reads the list (`location-events-feature.md`).
- Getting there: stage the required devices at the location (they must be *present* — note
  `location-scope-cannot-see-stowed.md`: stowing clears location, so staged devices must be
  deployed/in-transit to count) and deposit the required resources (the app cross-references
  open events after a `depositResources`/unload and refreshes — `location-events-feature.md`).
- Consumption: satisfying + committing **consumes** the devices/resources of the met option.
  The docs `event.completed` payload carries `"consumed":{devices:[...],resources:{...}}`
  (docs/api/events/catalogue). **Drift/trap:** `accounts/events` **never returns `consumed`**
  (verified across all 13 completed rows here; `experience-and-completion-events.md`) — the
  stream `event.completed` payload is its only source.

**What confirms completion:**
- On the entity: `status` flips `active → completed` and **`completed_at`** is stamped (present
  on all 13 completed rows; the `progress` block disappears). There is no boolean `completed`
  field — the ticket's "`event.completed`" refers to the *stream event name*, not an entity
  field.
- On the wire: an **`event.completed`** SSE event fires. **It is display-only** — a completed
  quest's `rewards.xp` is ALSO delivered as its own `experience.gained` with
  `source:"location_event"` (verified TENEGSHE-3-EVT-003: 1800 XP in both), so crediting
  `event.completed`'s rewards would double every award; likewise `rewards.resources`/`consumed`
  are display-only (`experience-and-completion-events.md`). XP is thus double-*delivered* across
  the two events but must be single-*credited*.
- App-side intermediate state: when objectives are met while still open the app derives a
  **"Ready"** status (denormalised `objectivesMet` from `progress.met`) — not a server status
  string; the server status stays `active` until the POST commits (`location-events-feature.md`).

## Q4 — Population / frequency: rare interrupt or constant?

**Rare, bursty interrupt — not a constant.** On this (the operator's whole) account:

- **16 events total, ever**, discovered `2026-06-30 → 2026-07-31` (~31 days) → **~0.5/day on
  average**, but clustered: 7 of 16 discovered in the final 2 days of July (discovery = a
  scan side-effect, so events surface in scanning bursts, not on a steady drip).
- **Status mix:** 13 completed, 2 active, 1 **expired** — events do lapse if unfulfilled
  (consistent with docs/concepts/story: "Location events will finish … when seasons end").
- **Variety:** 13 distinct `event_type`s, 5 `category`s (`resource_trade` ×9 dominates, then
  `community`, `cooperation`, `orbital_infrastructure`, `defensive`), **tiers 1–3** (tier 1 ×8,
  tier 2 ×6, tier 3 ×2).
- **Reward scaling by tier** (live): tier 1 ≈ 400–600 XP + 1 cp (+ a resource dab); tier 2 ≈
  1600–3000 XP + 2–4 cp; tier 3 = 15000–20000 XP + 10 cp. Tier-3 events are rare and lucrative.

**Implication for the brain:** an operator HITL decision on an event is a rare interrupt
(order of one every day or two, arriving in clusters), and only ~⅓ of events present an actual
choice to surface — so the "few clicks" seam is an occasional interrupt, not a constant one.
The single-option majority need no choice UI at all (just a stage-and-commit); the
multi-option minority is where "surface the approaches + tradeoffs, operator picks" earns its
keep.

---

## openapi drift flags (spec vs live)

- **`criteria` / `rewards` / `progress` are opaque in the spec.** `LocationEventSchema` types
  them as bare `array`/`object` with no item schema — the entire nested option/criteria/progress
  structure documented above is **untyped in openapi** and known only from the live payload.
  Any typed client model must be authored from the probe, not generated.
- **`location_name` is dead.** Spec declares it `string`; live returns `null` on all 16 rows.
- **`GET /v1/locations/{location_code}/events` has no `200`** (responses `[422, default]`) — the
  per-location variant is undecodable via the generated client without a spec patch; use the
  account-wide `GET /v1/accounts/events` (which has a proper `200` →
  `LocationEventListResponseSchema`) instead (`location-events-feature.md`, confirmed in spec).
- **Resolve POST now declares a `200`** → `LocationEventResolutionResponseSchema`
  `{designation, event_status, rewards, status, title}`. Note the memory note
  `undocumented-success-response-throws.md` / `location-events-feature.md` describe the POST as
  *only* having a `default` response (so success and error both landed in `.default`); the
  **current** `openapi.json` shows both `200` and `default` — the spec appears to have been
  updated since that note. Re-verify the app's success/error split against the live 2xx before
  relying on either.
- **`next_cursor`** typed `integer` in the list schema; live returns `null` when exhausted
  (nullable in practice).
- **`consumed` never in `accounts/events`** — present only in the `event.completed` stream
  payload (docs) / never in the REST list (`experience-and-completion-events.md`).

## Unverifiable without a mutation (not attempted)

- The exact live 2xx body of the resolve POST, and whether the app's 2xx/error split matches
  the now-documented `200` schema — would require POSTing to a real event (a live mutation).
  Left unverified per the GET-only safety rule.
- Whether committing auto-selects `met_option` when *multiple* options are simultaneously met —
  no such state exists on the account to observe read-only, and forcing it needs staging +
  a mutation.
