# Logistics — haul yield tracking

**Status:** design, approved 2026-08-10. Not built.

A new sidebar feature recording what every Haul Run actually brings home: one row
per pickup, carrying the run, the source pile, the units, the per-resource-type
breakdown, and when it was collected — so yields can be graphed over time and in
aggregate.

## 1. The constraint that shapes everything

**A Haul Run's pickups are not reported to us with resource detail.**

The Haul Run works by tagging an `ami_transport_controller` and letting it ferry
server-side (see `.claude/memory/haul-run-design.md`). A device under an AMI
controller stops emitting per-device events; they are rolled into the
controller's `ami.*.digest` (`.claude/memory/ami-drones-are-event-silent.md`).

Measured on the live `eventLogs` table over 2026-07-26 → 2026-08-10:

| Signal | Count |
|---|---|
| Collections reported inside `ami.transport.digest` | 1,318 |
| Individual `transport.collected` events received | 22 |

All 22 came from `5187CFCF`, a freighter that is currently *unadopted*; its last
one was 2026-08-06. The active fleet's freighter `F7B455B6` (under controller
`8D53C9B1`) has **zero** individual event rows of any kind.

The `transport.collected` payload is exactly the shape this feature wants —
`{"resources": {"rares": 200, "structural": 200}, "total": 400, "cargo_after": 400}`
— and it is the 1.7% case. The `ami.transport.digest` that replaces it carries
only `cargo_capacity`, `cargo_carried`, `collect`, `deliver`, and a fleet phase
count. No resource breakdown.

There is no opt-out. The docs describe `events.ami_digest_interval` (1–30), which
changes digest *frequency*, not the buffering. `GET /v1/events` does not rescue
it either: `before=2026-08-09` returns zero rows, so server-side history is a
short window and there is no backfill.

**Consequence:** yields are *reconstructed*, never *reported*. Every design
decision below follows from that, and the schema is required to say so.

## 2. Signal

`report.cargo_carried` in the digest is the controller fleet's carried total, and
it moves cleanly. A real captured sequence for `8D53C9B1`:

```
15:07:30  carried=  0  nc=0 nd=0   ACHERNUR-BELT-1 -> AINALRAM-BELT-1  delivering:1
15:08:22  carried=345  nc=1 nd=0   ACHERNUR-BELT-1 -> AINALRAM-BELT-1  loading:1
15:17:33  carried=345  nc=0 nd=0   ACHERNUR-BELT-1 -> AINALRAM-BELT-1  delivering:1
15:18:33  carried=  0  nc=0 nd=1   ACHERNUR-BELT-1 -> AINALRAM-BELT-1  loading:1
```

- **`carried` rises** → a pickup. The rise is the units collected.
- **`carried` falls** → a delivery. It closes the oldest pickup for that
  controller whose delivery columns are still null. With one freighter per
  controller there is at most one such row, which is what makes the pairing
  unambiguous today.

`collect` and `deliver` name the source and destination designations directly.
Round trips run about ten minutes, and loads observed range 87–411 units.

### Per-type breakdown

On a rise, the route issues **one** explicit read of the freighter through
`@Dependency(\.deviceRefresher)` and takes `detail.cargo` — a per-resource-type
array present on every device row — as the hold's composition.

The read must be explicit: an AMI-controlled device is event-silent, so its row
never goes stale and never updates on its own.

- Hold was empty before the pickup (the common case, since `carried` returns to 0
  after each delivery): the hold **is** the pickup.
- Multi-stop load: this pickup's per-type is the hold now minus the hold recorded
  at the previous read.

Cost: ~88 reads/day at measured rates (1,318 collections over 15 days). The read
is `.high` priority — a `.low` read is deferred under budget pressure
(`PollCoordinator.budgetFloor`), and a deferred read here loses the sample
permanently rather than delaying it.

### Cross-check

The digest's `carried` delta and the sum of the per-type breakdown are two
independent measurements of one quantity. They must agree. When they do not, the
row keeps the digest total (the reliable number) and marks the breakdown, rather
than silently trusting a reconstruction.

Precedent for mining structured intel out of a digest report:
`.claude/memory/survey-digest-scans.md`.

## 3. Scope

`haulRun` directives only — both the general `auto:haul` drainer and every
belt-pinned `auto:mine:<belt>` ferry. Other transport work (restock runs, relay
deliveries, operator-launched ferries) is out of scope.

**Attribution goes through `directives.deviceCode`, which holds the controller
code.** Verified on both live rows:

| directive | kind | fleetTag | deviceCode |
|---|---|---|---|
| `2778DB10…` | haulRun | `auto:haul` | `7D1569BF` |
| `C4A542AE…` | haulRun | `auto:mine:ACHERNUR-BELT-1` | `8D53C9B1` |

Do **not** attribute by fleet tag. Controller `8D53C9B1` carries the bare tag
`auto:mine` while its directive's `fleetTag` reads `auto:mine:ACHERNUR-BELT-1`, so
tag-matching misattributes as soon as a second belt exists.

## 4. Data model

One table, one append-only `SchemaMigration` appended to `GameDatabase.manifest`.

```
HaulYield
  id                      UUID, primary key
  directiveID             TEXT     — the haulRun this belongs to
  controllerCode          TEXT     — ami_transport_controller
  deviceCode              TEXT     — the freighter that carried it
  sourceDesignation       TEXT     — digest `report.collect`
  collectedAt             DATE
  unitsCollected          INTEGER  — digest `carried` delta, authoritative
  perType                 JSON     — [resource_type: units]
  breakdownState          TEXT     — exact | partial | unavailable
  destinationDesignation  TEXT?    — digest `report.deliver`, filled on delivery
  deliveredAt             DATE?
  unitsDelivered          INTEGER?
  followsGap              BOOL     — see below
```

**Row grain is a pickup**, written complete the moment the collection is seen.
Delivery columns are nullable and filled in when that half is observed, so no row
is ever in a half-built state and an interrupted trip is still half-recorded.

`breakdownState`:

- `exact` — hold was empty beforehand, per-type sum matches the digest delta.
- `partial` — a multi-stop load, or the sum disagrees with the digest delta.
- `unavailable` — the device read failed or was skipped. `unitsCollected` still
  holds; `perType` is empty.

`followsGap` is the honesty column. Digests arrive only while the app is running
and the server keeps no history worth backfilling, so a row written after a
reconnect marks the interval since the previous row as unobserved. Without it, a
week with the app closed graphs as a production collapse. The route's existing
`gapRepair()` hook is where the flag is set; it cannot recover the missed data,
only record that it is missing.

## 5. Components

| Unit | Home | Responsibility |
|---|---|---|
| `HaulYield` | `GameModels` | the record + its migration |
| `LogisticsIngestion` | `GameServices` | `EventRoute` on `ami.transport.digest`; the pickup/delivery state machine |
| `HaulYieldClient` | `GameServices` | writes rows; resolves the per-type read |
| `LogisticsFeature` | new SPM module | TCA feature, the screen |
| `SidebarItem.logistics` | `SidebarFeature` | "Logistics" |

Layout is sidebar + content, no third pane, as with Stars and Event Log.

Per-controller carry state (the previous `carried` value and the previous hold
composition) is read off the **last row for that controller**, not held in
memory, so it survives relaunch and needs no separate store.

## 6. Screen

Top to bottom in the content pane:

1. **KPI row** — total units hauled, trips, units/day, most-hauled type.
2. **Filter row** — time range and resource type, in one row above the charts.
3. **Composition over time** — stacked column by day, categorical by resource
   type, legend plus direct labels on the largest segments. One axis.
4. **Aggregate by resource type** and **aggregate by source pile** — horizontal
   bars, sequential single hue. Source designations render monospace.
5. **The ledger table** — the rows themselves, and the table view that relieves
   the light-mode contrast warning below.

### Categorical palette (new design-system tokens)

Six resource types is a closed set (`.claude/memory/belt-value-vocabulary.md`):
`carbon`, `conductive`, `rares`, `silicates`, `structural`, `volatiles`. The
design system has no categorical ramp — one accent, seven *reserved* status
colors — so six new colorsets are added to `Colors.xcassets` as a deliberate
extension for charts. Assignment is fixed and never cycled.

| Slot | Light | Dark |
|---|---|---|
| structural | `#2a78d6` | `#3987e5` |
| conductive | `#eb6834` | `#d95926` |
| silicates | `#1baf7a` | `#199e70` |
| rares | `#4a3aa7` | `#9085e9` |
| volatiles | `#e87ba4` | `#d55181` |
| carbon | `#008300` | `#008300` |

Validated with the dataviz validator against the app's real surfaces —
`ContentBackground` `#F9F5EE` light, `#0D1018` dark:

- **Light:** lightness band, chroma floor, CVD separation (worst adjacent ΔE 9.2
  deutan, tritan 26.6) and normal-vision floor (27.6) all pass. Contrast warns
  below 3:1 for three slots, relieved by direct labels and the ledger table.
- **Dark:** all six checks pass, contrast included.

Yellow was deliberately excluded. The obvious slot-4 yellow (`#eda100`) sits on
top of the app's amber accent (`#D19317` / `#FFB23E`), so a series would read as
selected; violet replaces it, which also lifts the weakest tritan pair from
ΔE 5.8 to 26.6.

CVD separation sits in the 6–9 floor band, so **direct labels are mandatory**,
not optional polish.

## 7. Failure modes

| Case | Behaviour |
|---|---|
| Device read fails or is refused by the rate limiter | row written, `breakdownState = .unavailable`, total preserved |
| Per-type sum ≠ digest delta | `breakdownState = .partial`, digest total wins |
| Multi-stop load | per-type diffed against previous hold, `breakdownState = .partial` |
| Delivery with no open pickup | delivery discarded, logged; never invents a pickup |
| App closed / SSE disconnected | next row carries `followsGap`; data is not recoverable |
| Digest arrives after delivery already happened | hold reads empty, sum mismatches → `.unavailable` |
| Two freighters on one controller | `carried` is a fleet total and blurs; **not supported** — see below |

**Known limit.** `cargo_carried` is summed across the controller's fleet. Every
controller owns exactly one freighter today, which is what makes the delta
unambiguous. A second freighter on one controller would let a collect by A and a
delivery by B net out within a window. The digest's `devices[]` array does name
which device fired `last_event`, so the *fact* of a pickup stays attributable —
only the *amount* blurs. When a second freighter joins a controller, rows for
that controller must degrade to `breakdownState = .partial` rather than report a
number that quietly nets two devices together.

## 8. Testing

Ingestion is a pure function from (previous controller state, digest payload) to
row mutations, so the state machine tests as a table. Fixtures come from the
7,723 real digests already captured locally rather than from invented payloads.

Cases with tests: rise-then-fall round trip; multi-stop load; read failure →
`.unavailable`; delivery with no matching open pickup; reconnect setting
`followsGap`; sum mismatch → `.partial`; two-freighter degradation.

The device read is a dependency whose `testValue` is `unimplemented(...)` per the
house rule, so a test that forgets to stub it fails loudly.

## 9. Deliberately not built

- **Backfill of history before the feature ships.** The server does not retain it.
- **Per-device attribution within a multi-freighter controller.** Degrade to
  `.partial` instead.
- **Anything outside `haulRun`** — restock, relay delivery, operator ferries.
- **Mining and salvage output at the source.** `ami.mining.digest` carries
  per-type `actual`/`capacity` per belt and would answer "what is my economy
  producing", but it is a second ingestion path and a row that means something
  different.
- **A retention sweep.** ~88 rows/day is ~32k/year; bound the read if a screen
  ever needs it, following `.claude/memory/directive-log-window-and-timeline.md`.
