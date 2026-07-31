# Research 07 — Printing & Autofactory mechanics + material costs

Ground facts for the print/deliver/hub tickets (05, 06) and the auto-print build.
GET-only live probes; no mutations issued.

**Sources** (trust order): docs site `https://replicant.space/docs/` › `openapi.json`
(`app/Modules/API/Sources/openapi.json`, known to drift) › live GET probes (ground truth
for shapes) › linked memory (`app/.claude/memory/`).

**Probed live 2026-07-31** on the one live account. Two print-capable devices found:
`43C9B54A` (autofactory, at `AINALRAM-BELT-1`) and `965AC2C3` (heaven_vessel, at `PIPIROMA-3`).

---

## TL;DR

- **Two print surfaces.** (a) The **device-command path** `POST devices/{code}` with
  `enqueue_print`, on any device carrying the **`print` feature**; (b) the **replicant
  "internal printer"** `POST /v1/replicants/{code}/print`. The `print` *feature* is the gate.
- **Only four device types carry `print`:** `autofactory`, `cargo_vessel`, `heaven_vessel`,
  `racing_vessel` (openapi blueprints + live). Vessels have `queue_size: 0` (single-job,
  "printer busy"); the **autofactory** has `queue_size: 10` (a real managed queue).
- **Material = the six-type blueprint bill**, consumed **from the printer's current LOCATION
  stockpile** (not device cargo). Insufficient stock → the job waits (`waiting_for`).
- **Lifecycle:** `enqueue_print` → device shows `printing`/`print_queue`/`waiting_for` →
  `print_complete` event (carries `new_device_code`) → device **auto-deployed at the printer's
  location** (optionally auto-adopted to a `controller`, optionally runs an `oncomplete` verb).

---

## Q1 — What gates `print`? Request/response shapes.

### The gate: the `print` device feature

`print` is a device **feature**, not a per-device flag. Live `GET blueprints` shows exactly four
device types with it in their `features` array (probe `scratchpad/blueprints.json`, and
`openapi.json` blueprint list):

| device_type | queue_size | print_time (s) | features |
|---|---|---|---|
| `autofactory` | **10** | 2400 | cruise, **print**, modular |
| `heaven_vessel` | 0 | 28800 | surge, cruise, system_scan, mine, cradle, **print**, census |
| `racing_vessel` | 0 | 28800 | surge, cruise, system_scan, mine, cradle, **print**, census |
| `cargo_vessel` | 0 | 28800 | surge, cruise, system_scan, mine, cradle, **print**, census, attach, transport |

`queue_size` is the discriminator: **vessels = single-job** ("Your vessel can't do anything else
while printing" — docs `/docs/concepts/blueprints/`; "sensitive bit of equipment … cannot operate
concurrently" — docs `/docs/autofactories/`); **autofactory = managed 10-slot queue**.

The replicant-internal endpoint is additionally gated on **knowing the blueprint**: "requires
something you know how to print" from `GET /v1/blueprints` (docs `/docs/api/replicants/print/`).
Blueprints unlock via achievements and via **decommissioning devices at an autofactory** (docs
`/docs/concepts/blueprints/`, `/docs/autofactories/`).

### Path A — device command `enqueue_print` (used by autofactory AND vessels)

`POST devices/{code}` with `app_schemas_device_commands_EnqueuePrintSchema`
(`openapi.json` L4238):

```
{ "command": "enqueue_print",
  "device_type": "<blueprint>",   // required
  "quantity":   <1..50>,          // default 1
  "oncomplete": { ... }|null,     // command to run on each finished device
  "controller": "<CODE>"|null,    // auto-adopt the new device to this AMI controller
  "tags":       ["..."]|null }    // tags applied to the new device
```

Companion commands (live `available_commands` on both the autofactory and the heaven_vessel):
`dequeue_print` (`{command, index}` — remove a queued job by index, `openapi.json` L4282),
`clear_queue`, `deactivate` (cancels the active job).

**Enqueued class** (memory `device-command-shapes.md`): the POST response is one
`DeviceCommandResponseSchema` optional bag; `print` is classified *enqueued* and completes via a
`print_complete` event carrying `new_device_code` — **not** a synchronous return of the device.

### Path B — replicant internal printer

`POST /v1/replicants/{replicant_code}/print` (openapi `/v1/replicants/{replicant_code}/print`,
tag `printing` = "Internal printer"). Request `app_schemas_printing_PrintRequestSchema` (L2950):

```
{ "device_type": "<blueprint>",   // the blueprint to print
  "command":     "<string>",      // docs: "clear_queue" | "cancel"
  "notify":      { "device": "CODE" }|null }
```

openapi response `app_schemas_printing_PrintResponseSchema` (200, L2969):
`{ status, device_type, started_at, completes_at, print_time_seconds, resources_refunded }`.

### The enqueued-op shape ([[device-command-shapes]])

For the automation, `print` is the **enqueued** completion class: dispatch does not carry a
deadline back; the tracked Operation is settled by the `print_complete` relay event whose
`new_device_code` names the produced device (memory `device-command-shapes.md`;
`architecture-review-v3.md` records "S9 `new_device_code` CONFIRMED from the local ledger").

---

## Q2 — Material cost. What/how much, where must it be, the six-type relay bill.

### The six resource types

`carbon, silicates, structural, rares, conductive, volatiles` (docs `/docs/concepts/resources/`,
`/docs/concepts/blueprints/`; every blueprint `resources` map uses exactly these keys). Docs gloss:
structural=frames/chassis, conductive=wiring/PCBs, silicates=insulation/ceramics,
carbon=composites/heat-pipes, volatiles=coolants/consumables, rares=chips/sensors/batteries.

### Cost = the blueprint's `resources` map

Each blueprint declares an exact per-type quantity (`BlueprintSchema.resources`,
`additionalProperties: integer`, `openapi.json` L2993). Live values (from `GET blueprints`) — a
representative sample of the 39 blueprints (full data in `scratchpad/blueprints.json`):

| device_type | carbon | silicates | structural | rares | conductive | volatiles | total |
|---|---|---|---|---|---|---|---|
| **ftl_relay** | 20 | 100 | 80 | 40 | 120 | 10 | **370** |
| survey_drone | 10 | 15 | 60 | 5 | 30 | — | 120 |
| mining_drone | 25 | 25 | 100 | — | 50 | — | 200 |
| ami_survey_controller | 20 | 30 | 100 | 15 | 60 | 5 | 230 |
| ami_mining_controller | 35 | 40 | 150 | 20 | 80 | 10 | 335 |
| **autofactory** | 150 | 200 | 800 | 80 | 400 | 50 | 1680 |
| heaven_vessel | 400 | 500 | 2000 | 300 | 1000 | 200 | 4400 |
| system_hub | 600 | 800 | 3000 | 500 | 1500 | 400 | 6800 |

`quantity` multiplies the bill (device-command path only, max 50).

### Where the material must be: the printer's LOCATION stockpile

"Resources are taken from the current location" where the replicant/printer sits (docs
`/docs/api/replicants/print/`). Material is **location-bound**: it comes from the location
inventory/stockpile, **not** from device cargo. If stock is short, "the factory waits for
delivery before beginning" (docs `/docs/concepts/blueprints/`, `/docs/autofactories/`) — surfaced
on the device as **`waiting_for`**: `{resource: {need, have}}` (openapi device schema L2086,
"Resources still needed for a queued print"). This is exactly why the salvage design notes a
printer at a belt can print a relay *in situ* from freshly-mined stock (see below).

### The "six-type relay bill" ([[salvage-run-design]])

= the **`ftl_relay` blueprint**: `{carbon:20, silicates:100, structural:80, rares:40,
conductive:120, volatiles:10}` = **370 units** across all six types. This matches
`salvage-run-design.md`'s "a single ~378-unit site rarely covers a relay's six-type bill, but a
whole 1,000–3,500-unit system usually does" — the six-type spread is why one small single-resource
salvage site can't cover it. (`awaitingRelayRestock`, the last human-gated stall in the Salvage
Run, is the first place engine-side printing pays off — `salvage-run-design.md` §"deliberately not
built".)

---

## Q3 — Autofactory: what it is, supply, vs plain print, endpoints.

### What it is

A device (`device_type: "autofactory"`, features `cruise, print, modular`, `queue_size: 10`) —
"a sprawling industrial complex that manufactures complex equipment from a local stockpile … A
replicant can manage the print queue remotely, assigning new blueprints while the factory indexes
the local stockpile and folds completed equipment into launch racks to be automatically deployed
into use" (live blueprint `description`; docs `/docs/autofactories/`). Costs 1680 units to print;
`modular` (deploys in place, uses `compact`/`unfurl` for transport, not `stow`).

### How it differs from a plain (vessel) print — four things (docs `/docs/autofactories/`)

1. **Managed queue** — up to 10 jobs run sequentially (`queue_size: 10`); a vessel printer is
   single-job and "can't do anything else while printing".
2. **Device scrapping/recycling** — `decommission` old devices at the factory recovers ~60% of
   their resource cost (docs `/docs/concepts/resources/`, `/docs/concepts/blueprints/`).
3. **Blueprint discovery** — decommissioning a new device type there reveals/unlocks its blueprint.
4. **Automatic post-print commands** — `oncomplete` runs a verb (docs: currently `travel` or
   `start_mining`) on each finished device, and `controller` auto-adopts it to an AMI controller.

### How it is supplied

From the **location inventory** at the factory's site; kept full via transport routes / AMI
transport controllers (docs `/docs/autofactories/`, mining/salvage output lands in the location
stockpile). The live factory sits at `AINALRAM-BELT-1` — the Salvage Run's home belt — so mined
salvage feeds it directly.

### Endpoints exposing its state/queue

- **State/queue:** `GET devices/{code}` — returns `queue_size`, `print_queue` (array of queued
  jobs), and while active `printing` (`{device_type, started_at, completes_at, progress_percent,
  eta_seconds, tags}`, openapi L1924) and `waiting_for`. Live idle autofactory `43C9B54A`
  returned `queue_size: 10`, `print_queue: []`, `available_commands: [change_owner, clear_queue,
  compact, deactivate, decommission, dequeue_print, enqueue_print, recall, travel, unfurl]`,
  `in_control_range: true` — `printing`/`waiting_for` omitted when idle.
- **Queue control:** `POST devices/{code}` with `enqueue_print` / `dequeue_print` /
  `clear_queue` / `deactivate` (see Q1 Path A).
- There is **no `/blueprints`-style autofactory endpoint**; its state is entirely on the device
  record. Blueprints to feed it: `GET /v1/blueprints`.

---

## Q4 — Print lifecycle & where the device lands.

1. **Enqueue** — `enqueue_print` (device) or `POST replicants/{code}/print` (internal). If the
   location stockpile can't cover the bill, the job sits in `waiting_for` until resources arrive
   (docs; openapi `waiting_for`).
2. **In progress** — device carries `printing` (`started_at`/`completes_at`/`progress_percent`/
   `eta_seconds`) and the job stays in `print_queue`; a vessel is `queue_size: 0` and blocked from
   other work, an autofactory keeps up to 10 jobs queued (openapi device schema; docs).
3. **Complete** — emits a **`print_complete`** relay event carrying **`new_device_code`**
   (memory `device-command-shapes.md`; confirmed from the local ledger per
   `architecture-review-v3.md`). This is the automation's completion signal (enqueued class).
4. **Where it appears** — the finished device is **deployed at the printer's location**
   ("folds completed equipment into launch racks to be automatically deployed into use" —
   autofactory description/docs). Not stockpiled, not left stowed. Refinements at enqueue time:
   `controller` → the new device is **auto-adopted** to that AMI controller; `oncomplete` → it
   immediately runs `travel`/`start_mining`; `tags` → applied to the new device. So an auto-print
   pipeline can print → adopt → dispatch with no follow-up command.

---

## OpenAPI ↔ live/docs drift flags

1. **`autofactory` is invisible in openapi as a concept.** The literal string never appears in
   `openapi.json` (no schema/enum/param names it). It exists only as a **blueprint `device_type`
   value** and as docs. Treat it as "a device with the `print` feature and `queue_size: 10`",
   not a modelled type. *(openapi vs live/docs.)*
2. **Replicant-print response is under-specified in openapi.** openapi documents only a single
   **200** `PrintResponseSchema`. Docs `/docs/api/replicants/print/` describe **202 `enqueued`**
   on start, **200 `queue_cleared`** for `command=clear_queue`, and **200 `af_print_cancelled`**
   (+ refund) for `command=cancel`. The command-variant responses and the 202 are undocumented in
   openapi. **Unverifiable without a mutation** (would need a real POST). *(openapi vs docs.)*
3. **`command` values.** openapi `PrintRequestSchema.command` is a bare `string`; docs pin it to
   `clear_queue` | `cancel`. *(openapi under-specified vs docs.)*
4. **`quantity` is device-path only.** The `quantity` (1–50) field lives on the device-command
   `EnqueuePrintSchema`, **not** on the replicant `PrintRequestSchema`. The internal printer has no
   documented multi-quantity. *(surface asymmetry — noted, not a drift bug.)*
5. **Idle devices omit optional print blocks.** Live idle autofactory/vessel returned
   `print_queue: []` + `queue_size` but no `printing`/`waiting_for` keys. Expected optional
   behaviour (coalesce), **not** a drift — flagged so decoders treat them as optional.

---

## Provenance

- Docs: `/docs/autofactories/`, `/docs/concepts/blueprints/`, `/docs/concepts/resources/`,
  `/docs/api/replicants/print/` (fetched 2026-07-31).
- openapi: `app/Modules/API/Sources/openapi.json` — schemas
  `PrintRequestSchema`/`PrintResponseSchema`/`BlueprintSchema`/`EnqueuePrintSchema`/`DequeuePrintSchema`/
  `PrintingInfoSchema`, path `/v1/replicants/{replicant_code}/print`, `/v1/blueprints`.
- Live GET probes: `GET blueprints` (→ `scratchpad/blueprints.json`), `GET devices`,
  `GET devices/43C9B54A` (autofactory), `GET devices/965AC2C3` (heaven_vessel). GET-only; no mutations.
- Memory: `device-command-shapes.md`, `salvage-run-design.md`, `salvage-resource-amounts.md`,
  `architecture-review-v3.md`.
