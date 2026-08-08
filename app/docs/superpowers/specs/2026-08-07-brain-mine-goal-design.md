# The brain's mine goal — design

The brain's fifth acting capability, after `survey`, `tendMesh`, `salvage` and the
general haul. It is the first one that **builds** rather than dispatches: a mine is
nine devices printed at the hub, ferried to a belt by a surge carrier, and left
there permanently.

Sits on `app/.claude/memory/brain-goal-decision-policy.md` (03),
`brain-resource-hub-model.md` (06), `brain-executor-seam.md` (04),
`brain-robustness-bar.md` (02), `brain-tendmesh-worthiness.md` (10), and the shipped
`salvage-run-design.md` / `haul-run-design.md`.

## Problem

`mine` is the one production goal with nothing to launch. `salvage` had a shipped
Salvage Run; `tendMesh` had a Relay Run. Belt mining has no executor and, more to the
point, no fleet — the devices do not exist yet and there is no path that makes them.

The wayfinder map routed "print and stage a new subfleet" to `growFleet`-future
precisely because it did not want to answer *who decides to spend 3,455 units on a
permanent installation*. This design answers it by splitting the decision in two: the
**operator authorises the spend** by invoking a print run, and the **brain chooses the
destination**. Neither half needs the other's judgement, and the expensive,
irreversible half stays human.

## The board as it stands (2026-08-07, live)

Probed GET-only against the live account, plus the local synced `systemDetails`.

**Two autofactories now**, both at `AINALRAM-BELT-1` — `43C9B54A` (printing) and
`3C39631F` (idle). The single-hub predicate of ticket 06 survives, since they share a
location; print throughput doubles to two 10-slot queues.

**Hub stock and what binds it.** Against the 370-unit `ftl_relay` bill, the hub holds
41 more relays of conductive, 91 of silicates, 112 of rares, 375 of structural, 480 of
volatiles, 608 of carbon. **Conductive is the binding type by a wide margin**, and
`tendMesh` has already planted 116 relays.

| type | at the hub | more relays |
| --- | --- | --- |
| conductive | 4,956 | **41** |
| silicates | 9,181 | 91 |
| rares | 4,487 | 112 |
| structural | 30,003 | 375 |
| volatiles | 4,807 | 480 |
| carbon | 12,169 | 608 |

**73 charted belts** — 30 dense, 25 moderate, 18 sparse; 65 already meshed. Per-type
availability at moderate-or-better, which is what the siting key ranks on:

| type | ≥ moderate | rich | high |
| --- | --- | --- | --- |
| silicates | 41 | 5 | 12 |
| structural | 40 | 5 | 16 |
| carbon | 38 | 7 | 4 |
| volatiles | 31 | 4 | 16 |
| conductive | 24 | 0 | 9 |
| **rares** | **5** | **0** | **0** |

Rares is the scarcest thing in the charted galaxy: five belts of seventy-three reach
moderate, none reach higher, and thirty-eight are outright `scarce`. Conductive is
second-scarcest and is also the hub's live bottleneck. Volatiles, by contrast, is the
third *most* available type in the ground and the type the hub has most slack in —
which is why the siting key rewards rares and conductive and ignores volatiles.

**A live `ferry` proves the haul shape.** `7D1569BF` (`ami_transport_controller`) is
coordinating `{collect: BLA-1-1, deliver: AINALRAM-BELT-1}` from `ATIANFU-1-L4` — a
location that is **neither endpoint**. Its `cargo_freighter` `E992E400` is surging home
with 408 conductive and 92 rares, full at 500/500. The controller commands from
anywhere on the mesh; the freighter moves itself.

**Hand-placed equipment is out of scope.** `ATIANFU-BELT-1` carries an operator-built
survey half (`E45C43AB` on `belt_search` at `belt_capacity:5+0/5`, two drones tracking,
four idle haulers). The brain does not see, adopt, complete or clear it. The operator
will relocate those devices.

## Design

### Two directives, and only one of them is yours to create

**`mineFleetPrint`** — operator-invoked, hub-owned, terminating. It prints a complete
mine and stops. This is the only directive in the system a human creates by hand, and
creating it *is* the authorisation to spend.

**`mineRun`** — brain-owned, carrier-leased, terminating. It derives when an
unassigned `auto:mine` fleet stands at the hub and at least one candidate belt has no
mine. It sites, ferries, installs, and retires.

The handoff between them is a set of device rows, not a message: nine tagged devices
standing idle at the hub with no controller. The brain re-derives that condition every
tick and remembers nothing, which is clause 2 of the robustness bar.

### The eleven-device recipe that delivers nine

Both figures below are totals for the quantity, not per unit.

| device | qty | units | print |
| --- | --- | --- | --- |
| `ami_mining_controller` | 1 | 335 | 1,800s |
| `mining_drone` | 3 | 600 | 1,800s |
| `ami_survey_controller` | 1 | 230 | 1,500s |
| `survey_drone` | 2 | 240 | 600s |
| `service_bot` | 2 | 470 | 1,334s |
| `ami_transport_controller` | 1 | 335 | 1,800s |
| `cargo_freighter` | 1 | 1,245 | 1,200s |
| **total** | **11** | **3,455** | **10,034s** |

The print column assumes `quantity` multiplies `print_time` linearly. That is an
inference from the blueprint field, not a measurement, and it affects only the estimate
below — never a gate.

Per type: carbon 255, silicates 315, structural 1,820, rares 105, conductive 825,
volatiles 135. **Conductive caps the hub at about six mines**, matching its role as the
binding type everywhere else.

`surge_carrier` (1,140 units, 4,800s, `attach_capacity: 9`) is printed **once** if no
idle one exists, and is a shared reusable asset — never part of an installation.

Only nine of the eleven ride the carrier. `cargo_freighter` is the only transport
device with a `surge` drive, so it flies itself; `transport_hauler` and
`transport_drone` are `cruise`-only and cannot leave a system without taxi plates
staged at both endpoints. And the transport controller never travels at all — the live
`ferry` above commands its route from a third location. **Nine is the carrier's
capacity and nine is what needs carrying**, which is why the recipe fits.

A freighter is also the cheaper way to move 500 units: seven `transport_hauler`s cost
1,680 against the freighter's 1,245, arrive in seven bodies instead of one, and drag in
a taxi-plate dependency at both ends of every route.

### `mineFleetPrint`

Hub-owned, the way `restockRun` is owned by the hub device rather than a carrier — a
print needs no vessel.

| step | what it does |
| --- | --- |
| `preflight` | Resolve the hub via the shipped `RelayRun.hubLocation` predicate. Read per-type stock `.high` and veto on `printStockShort` if the 3,455-unit bill does not clear the reserve floor `R`. |
| `enqueuing` | Seven `enqueue_print` jobs across the two queues, using `quantity` for the multiples. Every job carries `tags: ["auto:mine"]`; an eighth job adds a `surge_carrier` tagged `auto:carrier` when none is idle. |
| `collecting` | Settle on `print_complete` events, each carrying `new_device_code`. Products auto-deploy idle at the printer's location. |

It does **not** pass `controller:` at enqueue time. Auto-adoption would bind the drones
to controllers that are themselves still printing and are nowhere near the belt.

Short stock parks a job in `waiting_for` rather than failing it, so the run idles
against the hub buffer and completes when salvage and the existing ferries refill it.
That is the same decoupling the Relay Run already relies on.

### `mineRun`

Carrier-leased. The carrier's `deviceCode` is the only lease, exactly as ticket 05
settled for the Relay Run; the nine attached devices are held transitively.

| step | what it does |
| --- | --- |
| `preflight` | Claim the carrier, confirm all nine fleet members are at the hub and `in_control_range`. |
| `siting` | Rank candidate belts, write the winner to the row's target. |
| `attaching` | Nine `attach` commands, one per device — the API takes no batch form. |
| `travel` | Carrier `travel` to the belt designation. |
| `detaching` | One `detach` releases all nine. |
| `adopting` | Three mining drones to the mining controller; two survey drones to the survey controller. Service bots are **not** adopted — they carry the `ami` feature and take their own directive, which is how the `auto:salvage` bots already run. |
| `activating` | `gather_evenly` on the mining controller, `belt_search` on the survey controller, `service` on each bot, and `ferry {collect: <belt>, deliver: <hub>}` on the transport controller with the freighter adopted to it. |
| `confirming` | Re-read: both controllers report `ami_directive_status: active`, drones report `mining (…)` and `tracking`. |
| `releasing` | Drop the carrier lease. |

**Adoption happens after detach, never before.** Whether an AMI-adopted device survives
being attached and ferried is unverified and would need a mutation to find out. Ordering
the steps this way means the question never has to be answered.

`gather_evenly` is the chosen mining directive. `gather_resources` is disqualified
outright — it **deactivates the controller once its targets are met**, which is fatal
to a permanent installation. `deplete_smallest` chases whatever is scarcest *at the
site*, which is not the same as scarcest *to the hub* and would dig backwards at a
rares-bearing belt. `maintain_ratios` could aim deliberately at rares and conductive but
needs ratio literals nobody has measured; `gather_evenly` produces the yield numbers
that would calibrate them.

### The siting key

Hard filters, so they never appear as rank terms:

- the belt's system is meshed — production derives only for meshed systems (ticket 10),
  and an off-mesh mine is uncommandable
- no live mine installation on that belt
- `BeltClass.classify` returns non-nil — an unreadable belt yields no target rather
  than defaulting to `.sparse`

Then lexicographic:

1. **`BeltClass`** descending (`rich` ▸ `moderate` ▸ `sparse`), reusing the shipped
   enum in `MeshValue.swift`
2. **scarce-type bonus** descending — `rares ≥ moderate` scores 2, `conductive ≥
   moderate` scores 1, summed. Rares outweighs conductive because five belts of
   seventy-three carry it against twenty-four.
3. **distance from the hub** ascending
4. **designation** ascending, for a stable result

Class above distance is what makes a far rich belt beat a near sparse one. On today's
board the winner is `AMEDIOHA-BELT-1` — dense, `rares: moderate`, meshed, 16.4 ly, and
the only dense meshed belt in the charted galaxy with rares above `low`.

`ACHERNUR-BELT-1` is better still (dense, `rares: moderate`, `conductive: high`) and is
**unmeshed** at 17.6 ly. It is a `tendMesh` grow target before it is a mine target,
which is the enabling chain working as designed.

### The `mine` goal itself

No third directive. Once installed, a mine is kept alive by per-tick liveness checks in
the brain, in the idiom the salvage build established:

- each installed mine's mining and survey controllers still read
  `ami_directive_status: active`, re-issued through the sanctioned retry seam if lapsed
- `ensureOne(.haulRun, matching: { $0.target == belt })` keeps that mine's ferry
  standing. The `matching` predicate went into `ensureOne` during the salvage build for
  exactly this — one general drainer alongside per-site siblings.

The ferry is the shipped `HaulRun`, whose `requiredDirective` is already
`HaulTargetPlanner.ferry`. It needs a source parameter beside its existing derived
sink; nothing else about it changes.

Sites deplete but **regenerate**, and `belt_search` reseeds a mine as they drain —
"it takes longer each time, and has diminishing returns." A mine is therefore genuinely
permanent, which is the bet `brain-resource-hub-model.md` made.

### The why-view

Two more rows through the existing `BrainGoalStatus`: one for the mine fleet awaiting
siting, one per installed mine. The idle reasons a reader needs distinguished are
"no fleet printed" (nothing for the brain to do), "every candidate belt taken", and
"no meshed candidate belt" — all idle-calm, none escalated.

## Non-goals

- **Deciding to print.** The brain never creates a `mineFleetPrint`. Authorising a
  3,455-unit permanent commitment stays with the operator.
- **Teardown and relocation.** The brain installs and keeps alive. It never recalls,
  relocates or decommissions a mine, and it never touches hand-placed equipment.
- **Completing a partial mine.** A belt is either a fresh candidate or filtered out.
- **Multi-hub routing and hub placement.** Still `growFleet`-future.
- **Scaling an existing mine.** Adopting more freighters to a live route is the
  documented way to raise throughput; nothing derives it yet.

## Robustness

1. **Selector, not enactor.** The brain creates and cancels the `mineRun` row and
   drives the sanctioned `retry`/`cancel` verbs. Every command still flows executor →
   `CommandGovernor` → engine.
2. **Stateless.** Siting re-derives from device rows and belt data each tick. The brain
   holds no memory of which belts it has considered or which fleets it has placed.
3. **Pure selection; the API vetoes but never chooses.** `printStockShort` and
   `in_control_range` can refuse a dispatch; neither picks a belt.
4. **Three-tier snapshot fidelity.** Belt class and richness are ranked on from the
   best-effort `WorldView`; every dispatch confirms `.high` first. A stale belt row
   costs a wasted tick of ranking, never a misdelivery.
5. **End-to-end through the real seam.** A `mineRun` test drives `evaluateOnce()`
   through the real `report()` from a printed fleet to two active controllers, with
   negative twins for an unmeshed board and an already-mined board.
6. **Idle-calm versus stall.** No printed fleet, no meshed candidate, or every candidate
   taken are all idle and surfaced without escalation. A stuck `attach`, a carrier that
   never arrives, or a directive that will not activate stall and escalate.
7. **Bounded blast radius.** The carrier is leased and released; the reserve floor `R`
   refuses a print that would drive any type below it. The don't-strand obligation is
   real here in a way it was not for salvage — nine devices attached to a carrier
   mid-route must be recoverable, so a failed `mineRun` holds its lease and escalates
   rather than cancelling and abandoning the load.
8. **Live derived why.** Both new rows render from derived state, and the siting key's
   terms are legible per-candidate rather than collapsed into a score.

## What this costs

3,455 units per mine plus 1,140 once for the carrier. Against hub stock that is six
mines before conductive binds, and each mine returns a 500-unit freighter load per
round trip against a belt that regenerates.

Serial print time is about 2h47m; split across the two autofactories, roughly 1h24m.
The carrier adds 80 minutes the first time.

## Testing

Every regression demonstrated failing before its fix, per the house rule.

- the siting key, as a verdict table over synthetic belts — class dominating distance,
  rares outranking conductive, unmeshed and already-mined filtered out, unclassifiable
  yielding no target
- `mineFleetPrint` short-stock idling rather than failing, and the recipe's per-type
  bill matching the blueprint sum
- adoption strictly after detach, demonstrated by a fixture whose adopt step is
  unreachable while any device is attached
- `gather_resources` rejected as a mining directive by construction, not by convention
- `ensureOne(.haulRun, matching:)` distinguishing a per-mine ferry from the general
  salvage drainer, with two mines live
- the clause-5 seam test with its two negative twins, mutation-checked

## Open, and deliberately so

- **`maintain_ratios` literals.** Deferred until `gather_evenly` produces real yield
  figures at a rares-bearing belt.
- **Attach behaviour under AMI adoption.** Unverified; sidestepped by step ordering
  rather than resolved.
- **One controller, many routes.** The directive config is a single `{collect,
  deliver}` pair, so one controller serves one route. Whether a controller can hold
  more is undocumented and untested.
- **`consolidate` as a mine drainer.** Documented as system-wide, so it cannot serve
  cross-system mines; not pursued.
