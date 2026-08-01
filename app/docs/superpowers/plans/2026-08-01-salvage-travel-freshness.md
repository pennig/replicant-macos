# Salvage Run: prove the vessel row post-dates the arrival before re-dispatching travel

**Incident (2026-08-01, live).** Salvage Run `BCC18F1C` stalled
`commandRejected: "Already at destination"` in `positioning` at 01:37:34, 139 ms after the
`travel.arrived` event for vessel `C7836770` at ALZEPHINA-7-4.

## Root cause

`GameSync.deviceRoute` settles two facts from one `travel.arrived` event in **two separate
transactions with awaits between them**:

1. `Reconciler.applyOperationEvent` → closes the vessel's open travel op (`GameSync.swift:314`)
2. `Reconciler.applyEventFields` → writes `device.location` (`GameSync.swift:354`)

All four of `SalvageRun`'s travel dispatch sites read exactly those two facts and guard only on
the first:

```swift
if vessel.location == destination { /* advance */ }
if world.openOperation(for: vessel.deviceCode) != nil { return .wait }
return .dispatch(kind: .travel, ... destination: destination, nextStep: <same step>)
```

The `openOperation` guard is the only thing holding the step while travelling. The instant write
#1 lands, that guard opens; if the 5 s tick falls before write #2 commits, `vessel.location`
still names the origin, the equality fails, and the step re-commands travel to where the vessel
already physically is. The server rejects with "Already at destination" and
`DirectiveExecutor` stalls `.commandRejected`.

Intermittent, not constant: the three earlier `positioning` cycles that night had the tick land
2.2–4.7 s after arrival (outside the window) and advanced cleanly.

Second, independent trigger for the same stale row: `Reconciler.swift:256`'s
`guard eventTime >= device.updatedAt` — live `createdAt` has only **second** granularity, so a
device read stamping `updatedAt` later within the same second silently drops the location write
entirely.

`HaulRun.swift:542` already carries the `updatedAt >= stepStartedAt` gate from the 2026-07-31
review ([[confirm-steps-need-fresh-evidence]]). `SalvageRun` never got it.

## The four sites

| # | func | destination | nextStep |
|---|------|-------------|----------|
| 1 | `travel` (:366) | `target` (system) | `.travelling` |
| 2 | `emplace` (:431) | `point` (Lagrange) | `.emplacing` |
| 3 | `position` (:718) | `body` | `.positioning` |
| 4 | `restock` (:1064) | `baseDesignation` | `.restocking` |

## Watermark: NOT `stepStartedAt`

HaulRun's `updatedAt >= stepStartedAt` is wrong here. These are *dispatch* steps, not polling
steps: on first entry `stepStartedAt` is the step-entry time and the vessel row is legitimately
older, so that gate would delay every first travel by a deadline. The deadline would also
already be blown on arrival, because a same-step `.travel` dispatch re-stamps `stepStartedAt`
and travel takes minutes.

The correct watermark is **the completion of the last travel this directive dispatched for the
vessel**. `WorldSnapshot.dispatchedOperations` carries closed ops scoped to this directive's own
`.commandDispatched` entries — exactly what is needed, no new column, no migration.

Verified against the incident: op `1F616245` closed `lastConfirmedAt = 01:37:33.000`, vessel
`updatedAt ≈ 01:35:30` → `01:35:30 >= 01:37:33` is false → correctly detected as stale.
On first entry to `positioning` at 01:35:25 the last completed travel was `303BFBAB`
(`01:23:16`) and the vessel row was stamped by that same arrival → gate passes, first dispatch
proceeds immediately.

Gate the **dispatch path only**. A stale row that happens to equal the destination is the benign
direction (it advances to work the body it is already at); the hazard is exclusively
stale-says-elsewhere → re-command.

## Ordering (mandated by [[confirm-steps-need-fresh-evidence]] half two)

Deadline first, then staleness, then the throttled read — and the deadline measures from the
**arrival**, never from `stepStartedAt`:

```swift
guard vessel.updatedAt >= completion else {
    if world.now.timeIntervalSince(completion) >= Self.arrivalConfirmDeadline {
        return .refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: .vesselPositionUnconfirmed)
    }
    if world.now.timeIntervalSince(vessel.updatedAt) > Self.arrivalReadInterval {
        return .refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: nil)
    }
    return .wait
}
```

`thenStall: nil` is what keeps the mid-flight read bounded — `DirectiveEngine.reAsk` collapses a
repeat refresh to `.wait`.

## Tasks

### Task 1 — new stall reason
`GameModels/Sources/Directive.swift`: add `case vesselPositionUnconfirmed` to
`DirectiveAttentionReason` plus its `displayName` ("Vessel position unconfirmed") and `guidance`
("The vessel finished travelling but its position never refreshed. Retry to re-read it, or
cancel the run."). The two switches in that file are the only exhaustive ones;
`DirectiveVocabularyTests`/`DirectiveSchemaTests` iterate `allCases` and will cover it. String
column — no migration.

### Task 2 — the gate
`DirectiveEngine/Sources/SalvageRun.swift`:
- `static let arrivalConfirmDeadline: TimeInterval = 5 * 60`
- `static let arrivalReadInterval: TimeInterval = 30`
- `static func lastTravelCompletion(for:_ world:) -> Date?` — the max `lastConfirmedAt` over
  `world.dispatchedOperations` values that are `kind == .travel`, terminal, and
  `entityCode == vessel.deviceCode`.
- `private func travelPositionUnconfirmed(_ vessel:_ world:) -> MissionAction?` — nil when the
  row is trustworthy (or no travel has ever completed), otherwise the action above.
- Call it in all four sites, immediately AFTER the `openOperation` guard and immediately BEFORE
  the `.dispatch`. Do not move the location-equality checks.

### Task 3 — tests
`DirectiveEngine/Tests/SalvageRunTests.swift`:
- Per site (×4): a vessel whose `location` is the ORIGIN and whose `updatedAt` predates a
  completed travel op → expect `.wait`, NOT `.dispatch`. Fixture the *prior* state, per the
  memory's "fixture the prior state, not just the empty one" rule.
- Fresh row (`updatedAt` after completion) at the origin → still dispatches (no regression).
- First entry, no completed travel op at all → dispatches immediately.
- Past `arrivalConfirmDeadline` → `.refreshDevices(thenStall: .vesselPositionUnconfirmed)`.
- Between `arrivalReadInterval` and the deadline → `.refreshDevices(thenStall: nil)`.
- **End-to-end through `evaluateOnce`** (`DirectiveEngineTests`), replaying the incident: op
  closed, device row stale → assert no travel command is dispatched and the run does not stall.
  A unit test of `position` alone passed throughout the incident; only the end-to-end shape is a
  real regression guard.

### Task 4 — review
Whole-diff review against this plan, the two memory notes, and the four-site table. Confirm no
site kept an unguarded dispatch and no first-dispatch path regressed.
