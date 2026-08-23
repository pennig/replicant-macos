# Fetch Run — design

**Date:** 2026-08-23
**Status:** approved, unimplemented

## Goal

A user-launched directive that moves one device from where it stands to a
location the user names, using a surge plate as the hull.

The run flies the nearest free `fetch`-tagged surge plate to the device, attaches
the device, flies to the destination, detaches, and parks the plate at a theatre.
When the device is modular it is compacted at the start of the run, so the
compaction and the plate's inbound flight overlap rather than run end to end.
The device is left compacted at the destination — no unfurl.

## Decisions

Settled with Matt on 2026-08-23; each closed an alternative that would have
produced materially different work.

| Question | Decision |
|---|---|
| Launcher inputs | The device (its own row supplies the pickup) and the destination. Not a pickup location, not a device *type*. |
| Autonomy | User-launched only. No `BrainGoal`, no ceiling, no autonomous launch. |
| Conflicts | The picker refuses a device `Ownership` already reserves; a conflict discovered in flight stalls into `needsAttention`. Never waits it out. |
| Plate's park | The theatre `TheatreResolver` resolves from the *destination* system — same mesh component preferred, nearest as fallback, operational only. |
| Payload lease | A new `Directive.payloadCode` column, not an overload of `controllerCode` or `freighterCodes`. |

## Non-goals

- **Carry mode is left alone.** A plate in `taxi` mode lets any same-owner device
  ride it, so it can arrive at the destination carrying strays. Issuing
  `configure` to force `manual` would overwrite a setting the operator may have
  chosen. Revisit only if it bites.
- **No unfurl at the destination.** Explicitly asked for.
- **One device per run.** `payloadCode` is singular. A multi-device fetch is a
  different design (it needs `attachCapacity` accounting and a load order).
- **No Brain integration.** The Brain still sees the row through `Ownership`, so
  it will not double-lease the plate or the payload, but it never launches one.

## Domain model changes

### `DirectiveKind.fetchRun`

New case in `app/Modules/GameModels/Sources/Directive.swift`, title `"Fetch Run"`.
Three switches over the enum are exhaustive and will fail to compile until the
case is handled — that is the intended safety net:

- `DirectiveKind.title` (`Directive.swift`)
- `DirectiveLaunch.fleetGoal(of:)` — answers `nil`; this kind reserves by device
  columns alone and writes no `fleetTag`
- `DirectiveTargetsSection.section(for:devices:)` (`DirectivesFeature`) — gets its
  own branch, below

`MissionRegistry.machines` gains `FetchRun()`.

### `Directive.payloadCode`

```swift
/// The device this run is fetching. A lease from launch: nothing drags it in
/// before it is attached, so without this column the brain could re-task the
/// payload out from under a plate already flying to collect it. Cleared at
/// detach, so the device is free the moment it is standing at its destination.
public var payloadCode: String?
```

Migration appended to the **end** of `GameDatabase.manifest` (append-only; an
edit to a shipped migration silently never runs):

```swift
static let addPayloadCode = SchemaMigration("Add 'payloadCode' to 'directives'") { db in
    try #sql(#"ALTER TABLE "directives" ADD COLUMN "payloadCode" TEXT"#).execute(db)
}
```

`GoldenSchemaTests` needs a regen with `RC_REGENERATE_SCHEMA_FIXTURE=1`.
`SchemaManifestTests` freezes the identifier list and needs the new entry.

**The silent-inertness trap:** `DirectiveExecutor.commit` names its columns
explicitly. `payloadCode` must be added to that `update { }` block or every write
of it is discarded with no error anywhere. This is the exact failure recorded in
`salvage-bot-roster-branch.md`.

### `Ownership.Via.payload`

New case on the `Via` enum, and a new seed in `Ownership.held(by:fleet:drags:)`:

```swift
if let payload = directive.payloadCode { claim(payload, .payload) }
```

Seeded, never dragged — like `.freighterLease`, and for the same reason: before
attach there is no edge from the plate to reach it by.

### `MissionAction.releasePayload(nextStep:)`

```swift
/// Clear `Directive.payloadCode`, then move to `nextStep`. The payload's lease
/// ends where the run's obligation to it does — at detach, not at run end.
case releasePayload(nextStep: String)
```

Handled in `DirectiveExecutor` alongside `.assignController` / `.enrolBots`,
which already write single columns and advance a step in one transaction.

Without this the payload stays leased through the plate's homeward flight — an
hour or more during which a device standing idle at its destination is invisible
to the Brain.

### `ReturnHome.Destination.nearestTo(system:)`

The existing `.theatreDepot` case reads `world.theatreDepot(for: directive)` — the
row's *launch* stamp. The plate parks relative to the *destination*, which is a
different place, so the enum gains:

```swift
case nearestTo(system: String)
```

resolving through `ctx.world.theatreResolver.owningTheatre(ofSystem:)?.depot`.
That method already prefers a theatre on the same mesh component and falls back
to nearest, operational only — the house rule, unchanged.

### Two attention reasons

```swift
/// No unleased surge plate carrying the `fetch` tag has a free attach slot, so
/// the run has no hull. A configuration problem: tag a plate, or free one.
case noFetchPlateAvailable
/// Another directive holds the device this run was launched to fetch. The run
/// will not take it back — whichever run holds it should finish or be cancelled.
case fetchPayloadLeased
```

Both need a `displayName` and a `guidance` string in `DirectiveAttentionReason`.
Everything else reuses the existing set: `unreachableDevice` for a row that has
left the fleet, `commandRejected` for a refused command, `commandFailed` for a
transport failure, `vesselPositionUnconfirmed` for a plate whose arrival never
lands on its row.

## The row a launch writes

| Field | Value |
|---|---|
| `kind` | `.fetchRun` |
| `deviceCode` | the surge plate — the run's hull, and its lease through `Ownership`'s `deviceCode` seed |
| `payloadCode` | the device being fetched |
| `targets` | `[pickup, destination]` — both exact locations, pinned at launch so neither can drift when the payload's row loses its `location` on attach |
| `originDesignation` | the plate's system at launch |
| `theatreDepot` | the theatre owning the *pickup* system |
| `fleetTag` | nil |
| `returnToOrigin` | false — the plate parks by the destination, not where it started |

`theatreDepot` is for list grouping only. This kind writes no `fleetTag`, so
`Ownership.leaseDepots` never reads it and the stamp reserves nothing. It is
deliberately *not* the answer to where the plate parks; `homing` resolves that
fresh from the destination, because an hour of flight is long enough for a
theatre to stop being operational.

`targetIndex` never advances. A fetch run has one job, not a queue —
`restockRun` already behaves this way.

## The machine

`FetchRun: MissionStepMachine` in `app/Modules/DirectiveEngine/Sources/FetchRun.swift`.
Pure: every clock read comes off `world.now`, one `MissionAction` per evaluation,
no I/O.

`plan(_:)` returns `.idle` — a fetch run has no roam and must never `.exhausted`
itself through the queue-extension path.

### Steps

```
preflight → staging → attaching → confirmingAttach
          → delivering → detaching → confirmingDetach → homing → done
```

**`preflight`** — prove the run can proceed, then hand off. Reads:

- the plate row (`directive.deviceCode`) and the payload row
  (`directive.payloadCode`); either missing → `.refreshDevices([both], thenStall: .unreachableDevice)`
- either row older than `stagingFreshness` (5 min) → the same refresh, no stall
- the plate still `device_type == "surge_plate"`, still carrying the `fetch` tag,
  `attachCapacity > 0` with a free slot → else `.stall(.noFetchPlateAvailable)`
- `Ownership.resolve(directives: world.peers, devices: world.devices, theatres: world.theatres)`
  — `holders(of: payloadCode)` must contain no directive id but this run's.
  Another holder → `.stall(.fetchPayloadLeased, detail: thatDirectiveID)`

`world.peers` is every in-force directive read in the same transaction as the
devices, so this stays a pure function of the snapshot. No `WorldSnapshot` change
is needed and none should be made.

The plate is **not re-picked** here. It was picked at launch and `deviceCode` *is*
the lease; moving it mid-run would mean the run briefly leased nothing. A plate
that fails validation stalls and the operator relaunches.

Payload already at `targets[1]` → `.done`. The launcher disables Launch for this
case, but a device can be moved by hand between the two.

**`staging`** — the concurrency ladder, and the only novel part of this design.

The engine takes one action per evaluation, so overlap is expressed as a priority
ladder rather than a sequence — the same shape `ReturnHome` uses to fly several
hulls at once:

1. Payload is modular (`world.modularDeviceTypes.contains(payload.deviceType)`),
   not yet compacted, and has no open operation
   → `.dispatch(kind: .compact, deviceCode: payload, params: CommandParams(), nextStep: staging)`
2. Plate is not at `targets[0]` and has no open operation
   → `TravelTo(deviceCode: plate, destination: targets[0], arrivalTest: .exactLocation, confirmStep: staging).next(ctx)`
3. Either device still has an open operation → `.wait`
4. Both settled → `.advanceStep(attaching)`

"Both settled" is the whole gate and must be spelled out, because the obvious
reading is wrong: the plate standing at the pickup is not enough. Advance only
when the plate is at `targets[0]` with no open operation **and** the payload has
no open operation and is compacted if it is modular. Without the payload half, a
device that happens to be mid-travel of its own falls through rung 1, past rung
2, and into an attach the server will refuse.

Tick one starts the compaction; tick two launches the plate while the compaction
op is still open; every tick after is a wait. That is the concurrency the ask
called for, with no new engine mechanism.

The compacted test is `payload.statusBase == "compacted"`, not `status` — a
status can carry a suffix, and every other status check in `Device` goes through
`statusBase` (`Device.swift:282`). `OperationKind.compact` is already in
`CommandClient.deadlineCommands` (`CommandClient+Lifecycle.swift:46`), and
`Device` already parses the `compact` block's `completes_at` into a tracked
deadline op, so the engine completes it without help.

A non-modular payload skips rung 1 entirely and the run is a plain flight.

**`attaching`** —

```swift
StowOrAttach(
    carrierCode: plate, deviceCodes: [payload], verb: .attach,
    confirmField: .attachedTo, confirmStep: confirmingAttach, sendsWholeList: false
)
```

`.finished` → `.advanceStep(delivering)`. `.noSubject` → `.stall(.unreachableDevice)`.

**`confirmingAttach`** — `ConfirmRow(deadline: 5 * 60, onExpiry: .readThenStall(.commandRejected))`
over the payload row. `payload.attachedToDeviceCode == plate` → `.advanceStep(delivering)`.
Every path that stays in this step returns `.wait`, the one action that does not
re-stamp `stepStartedAt` — anything else makes the deadline unreachable.

**`delivering`** — `TravelTo(plate → targets[1], .exactLocation, confirmStep: nil)`.
The same-step loop, guarded by the tracked travel op. `.finished` → `.advanceStep(detaching)`.

**`detaching`** — `StowOrAttach(..., verb: .detach, confirmField: .loose, confirmStep: confirmingDetach)`.

**`confirmingDetach`** — the same `ConfirmRow` ladder. Success is
`payload.attachedToDeviceCode == nil` **and** `payload.location == targets[1]` —
both, because a detach that lands while the plate is somewhere unexpected has
put the device in the wrong place. Success → `.releasePayload(nextStep: homing)`.

**`homing`** — `ReturnHome(deviceCodes: [plate], destination: .nearestTo(system: SiteAssay.system(of: targets[1])))`.
`.finished` → `.done`. `.noSubject` — no operational theatre resolves — →
`.done` as well: the plate is loose and idle at the destination, which is a fine
place to leave it, and stalling a run whose actual job is complete would be
noise. Log a notice.

## Launcher

`NewFetchRunFeature` + `NewFetchRunSheet` in `app/Modules/DirectivesFeature/Sources/`,
modeled on `NewHaulRunFeature`/`NewHaulRunSheet`.

State, all derived from `@FetchAll` rows so the picker and the engine share one
definition of eligible:

- `payloadCode: String?` — the device to fetch
- `destination: String?` — an exact location
- eligible payloads: devices with a non-nil `location`, absent from
  `Ownership.resolve(directives:devices:theatres:).reserved`, and not the plate
  itself. A stowed device has no `location` and cannot be fetched — that is the
  filter's whole job, not an accident.
- `plate: Device?` — the resolved plate, **shown in the sheet** so the user sees
  which hull will fly before committing
- `canLaunch` — a payload, a destination that differs from the payload's current
  location, and a resolved plate

### Plate resolution

One static function, shared by the launcher and by `preflight`'s validation, so
there is one definition:

```swift
FetchRun.plate(for pickup: String, in devices: [Device], reserved: Set<String>) -> Device?
```

Predicate: `deviceType == "surge_plate"`, `tags.contains("fetch")`,
`!reserved.contains(deviceCode)`, `attachCapacity > attachedDeviceCodes.count`,
`location != nil`. Ranked by `Position.distance` from the pickup's system, ties
broken by `deviceCode` so the answer cannot flicker with dictionary order.

The plate's system may be absent from `starPositions`; such a plate sorts last
rather than being excluded — it is still a usable hull.

`fetch` is a **plain tag string**, not a `FleetTag`. `FleetTag` parses
`auto:<goal>` forms and would not match; the ask named a bare tag.

### Wiring

`DirectivesFeature` gains a `@Presents var newFetchRun: NewFetchRunFeature.State?`,
an action case, an `.ifLet` scope, and a Menu entry in `DirectivesListView`
beside the existing New Salvage Run / New Haul Run items.

`DirectiveTargetsSection.section(for:devices:)` gains a `.fetchRun` branch
rendering the two stops as pickup → destination rather than a survey queue.

`DirectiveRow.subtitle` needs two changes, and the compiler only forces one of
them. Its `switch directive.kind` sits inside a `roamCentre != nil` guard, so a
fetch run never reaches it — but the switch is exhaustive and the case must be
added returning nil. The change that matters is the one after the guard: the
fallback renders `"\(progress.completed)/\(progress.total)"`, which for a fetch
run reads `"0/2"` against a `targets` array that is a pickup and a destination,
not a queue. An early `.fetchRun` return is needed there.

## Failure modes and what surfaces

| Situation | Result |
|---|---|
| No tagged, unleased plate at launch | Launch disabled, sheet says why |
| Plate untagged or taken between launch and preflight | `.noFetchPlateAvailable` |
| Payload leased by another directive | `.fetchPayloadLeased`, detail names the holder |
| Either row gone from the fleet | `.unreachableDevice` |
| Compact refused (non-modular after all, or busy) | `.commandRejected` via the dispatch ladder |
| Attach or detach never confirms in 5 min | `.commandRejected` |
| Plate arrives but its row never refreshes | `.vesselPositionUnconfirmed`, via `TravelTo.positionUnconfirmed` |
| No operational theatre near the destination | `.done`, plate left at the destination, notice logged |

## Testing

`FetchRunTests.swift` in `app/Modules/DirectiveEngine/Tests/`, pure-function tests
over hand-built `WorldSnapshot` fixtures — the established shape for this module.

Two standing traps in this repo apply directly:

- **Pin constants absolutely.** Fixtures written *relative* to the constant under
  test leave that constant's value undefended
  (`relative-fixtures-hide-constant-drift.md`). Every deadline and freshness
  window gets an explicitly pinned root, and each pin is proved by mutating the
  constant and watching the test go red.
- **Read results from the event stream.** `swift test --event-stream-output-path`
  with `--test-product` pinned, per the `swift-test-event-stream` skill; a green
  50-test run can otherwise stand in for the whole suite.

Cases that must exist, each proved by mutation:

1. A modular payload dispatches `compact` on the first `staging` evaluation.
2. The *second* `staging` evaluation dispatches the plate's travel while the
   compact op is still open — the concurrency claim, and the one this design
   turns on.
3. A non-modular payload never dispatches `compact`.
4. A payload already `compacted` never re-dispatches it.
5. `staging` returns `.wait`, not a second dispatch, while both ops are open.
6. Plate selection picks the nearest of several eligible plates, and the
   lowest-coded of two equidistant ones.
7. A reserved plate is not selected; a plate without the `fetch` tag is not
   selected; a full plate is not selected.
8. `preflight` stalls `.fetchPayloadLeased` when a peer directive holds the payload.
9. `confirmingDetach` does **not** succeed on a detached payload standing
   somewhere other than the destination.
10. `.releasePayload` clears the column, and `Ownership` stops reserving the
    payload once it is cleared.
11. `homing` resolves the theatre from the destination, not from `theatreDepot`.
12. A run whose payload already stands at the destination completes at `preflight`.

`OwnershipTests` gains a case for the `.payload` seed. `SchemaManifestTests` and
`GoldenSchemaTests` cover the migration.

## Files touched

**New**

- `app/Modules/DirectiveEngine/Sources/FetchRun.swift`
- `app/Modules/DirectiveEngine/Tests/FetchRunTests.swift`
- `app/Modules/DirectivesFeature/Sources/NewFetchRunFeature.swift`
- `app/Modules/DirectivesFeature/Sources/NewFetchRunSheet.swift`

**Changed**

- `GameModels/Sources/Directive.swift` — kind case, `payloadCode`, migration,
  two attention reasons with display names and guidance
- `GameDatabase/Sources/GameDatabase.swift` — manifest entry
- `DirectiveEngine/Sources/MissionRegistry.swift` — register `FetchRun()`
- `DirectiveEngine/Sources/DirectiveLaunch.swift` — `Launch.payloadCode`,
  `fleetGoal` case
- `DirectiveEngine/Sources/Ownership.swift` — `.payload` via and seed
- `DirectiveEngine/Sources/MissionStepMachine.swift` — `.releasePayload`
- `DirectiveEngine/Sources/DirectiveExecutor.swift` — handle `.releasePayload`,
  **and add `payloadCode` to `commit`'s column list**
- `DirectiveEngine/Sources/Steps/ReturnHome.swift` — `.nearestTo(system:)`
- `DirectivesFeature/Sources/DirectivesFeature.swift` — presentation slot, action, scope
- `DirectivesFeature/Sources/DirectivesListView.swift` — Menu entry
- `DirectivesFeature/Sources/DirectiveTargetsSection.swift` — `.fetchRun` branch
- `DirectivesFeature/Sources/DirectiveRow.swift` — an early `.fetchRun` return in
  `subtitle`, plus the compile-forced case in its roam switch
- `GameDatabase/Tests/SchemaManifestTests.swift`, `GoldenSchemaTests` fixture
