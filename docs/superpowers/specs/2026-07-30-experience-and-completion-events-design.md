# Handling `experience.gained` and `event.completed`

**Date:** 2026-07-30
**Status:** approved, ready to implement

Two events cross the SSE ingestion choke point today with no feature-specific
route. Both are visible in the live `eventLogs` ledger as `isHandled = 0`:
`experience.gained` (250 rows) and `event.completed` (4 rows).

## Observed payloads

Read from the live database, not from `openapi.json`.

`experience.gained` — envelope carries `replicant_code`, `star`, `location`:

```json
{ "amount": 1800, "source": "location_event" }
```

Sources observed: `scan`, `print`, `achievement`,
`scan_system_completion_bonus`, `location_event`.

`event.completed` — envelope carries `replicant_code` only; the location lives
in the payload:

```json
{
  "designation": "TENEGSHE-3-EVT-003",
  "event_type": "refugee_evacuation",
  "location": "TENEGSHE-3",
  "tier": 2,
  "rewards": {
    "civilisation_points": 3,
    "resources": { "carbon": 200, "rares": 300 },
    "xp": 1800
  },
  "consumed": {
    "resources": { "volatiles": 200 },
    "devices": [
      { "device_code": "60C33A33", "device_type": "transport_drone" },
      { "device_code": "41A1B62E", "device_type": "transport_drone" }
    ]
  }
}
```

The two events overlap by design: that completion's `rewards.xp` of 1800 is
also delivered as its own `experience.gained` with `source: "location_event"`.
Crediting both would double the award. **`event.completed` must never credit
XP.** Its `rewards` block is display material for the completed quest, nothing
more — and no resource stock is modelled outside the location-events feature
either, so `consumed` and `rewards.resources` are likewise display-only.

## Part 1 — `experience.gained`

### Where it lands

The account footer (`RCAccountFooter`) reads `@Shared(.account)
.experiencePointsTotal`; the active-replicant header reads the `Replicant`
row's `experiencePoints`. `GET /accounts/me` refreshes both, but only runs at
launch and on the signed-in window's appear — so XP never moves during a
session. Both values are owned by `AccountManager`, so its module is where the
ingestion policy belongs, mirroring `LocationEventsIngestion` and
`MessagesIngestion`.

### The route

New `AccountIngestion.swift` in `AccountManager`, exposing
`eventRoute` (`id: "account.experience"`, `match: .event("experience.gained")`)
and `domainRegistration`.

`apply` does three things, in order:

1. **Gate on provenance.** `guard event.provenance == .stream`. Catch-up replay
   covers a window already folded into the launch `/accounts/me` read, so
   applying a replayed delta would double-count. The stream events are
   authoritative enough to trust on their own.
2. **Credit locally, immediately.** `$account.withLock { $0
   .experiencePointsTotal += amount }`, and an in-place SQL increment of the
   replicant row keyed on the envelope's `replicant_code`. An envelope with no
   replicant code (achievement XP) credits the account total only. A zero or
   absent `amount` is a no-op.
3. **Queue the reconcile.** `domainFreshness.invalidate(.account)`.

No `gapRepair`: the launch `refreshAccount()` already is this channel's tier-2
catch-up.

### The `.account` freshness domain

A new `FreshnessDomain.account` case, registered in `ReplicantApp` alongside
the other three.

- `debounce: .seconds(15)` — XP arrives in clusters (a survey run fires many in
  a burst), and one authoritative read after the cluster observes the same
  state as fifteen would.
- `ttl: 60`.
- `refresh` reads the rate-limit budget before spending anything:
  `guard await gameClient.budget(.reads).remaining > 20 else { return false }`.
  The floor sits above `PollCoordinator`'s 12 because a device confirm-read
  outranks a cosmetic XP total. Returning `false` leaves the domain marked
  stale, so a budget-starved reconcile is *dropped, not lost* — the next nudge
  retries it.

`AccountManager.refreshAccount` currently returns `Void` and swallows its
errors, which would stamp the domain fresh for a full TTL on a failed read —
exactly what `DomainRegistration.refresh`'s contract warns against. It changes
to `-> Bool`.

`AccountManager` gains a `GameServices` dependency for `EventRoute` and
`DomainRegistration`. No cycle: `GameServices` does not reference
`AccountManager`.

### Drift

The optimistic credit can drift from the server between reconciles — a stream
event missed while the connection was down is never replayed as `.stream`. It
self-heals: any `/accounts/me` read (the next XP nudge, the window appearing,
the next launch) overwrites both numbers with authoritative values.

## Part 2 — `event.completed`

Today this event is swallowed by the `locationEvents` route, whose matcher is
`.all`; it invalidates the `.locationEvents` domain, which walks every page of
`accounts/events`. A full walk to learn one row flipped to `completed` is
wasteful, and the `.all` matcher is also why the event reads as unhandled in
the Event Log.

New route `id: "locationEvents.completed"`, `match:
.event("event.completed")`. A non-catch-all matcher, so `isHandled` flips true
and `matchedRoutes` names it. The existing `.all` route gains `guard event
.event != "event.completed"`, so `event.discovered` and `scan.completed` keep
triggering the authoritative walk — only completion stops doing so.

`apply` fetches the row by `designation` and folds the payload in via a new
`LocationEvent.completing(payload:now:)` helper, declared beside
`merging(event:now:)`:

- `status = "completed"`, `objectivesMet = true`, `updatedAt = now`
- `completedAt` from the envelope's `created_at`, falling back to `now`
- fills `location`, `eventType`, `tier` when the row is blank
- folds the payload's `rewards` and `consumed` into the `detail` blob

**Missing row** — discovery missed, or the quest completed from another client:
fall back to `domainFreshness.invalidate(.locationEvents)`. The payload has no
`title` or `description`, so a fabricated row would render blank.

## Part 3 — completed-quest UI

`LocationEventDetail` gains, decoded from `detail.consumed`:

```swift
public struct ConsumedDevice: Equatable, Sendable, Identifiable {
    public let deviceCode: String
    public let deviceType: String
    public var id: String { deviceCode }
}

public let consumedResources: [RewardResource]
public let consumedDevices: [ConsumedDevice]
```

Both empty when the blob carries no `consumed`, so an active event renders
exactly as it does today.

In `LocationEventDetailView`, the rewards card retitles to "Rewards Granted"
once the event is completed, and a Consumed card appears below it when
anything was consumed: resource rows first, then one row per device with its
code in `.rcMono`. That device list exists nowhere else in the app — the
devices are gone by the time the quest closes.

## Tests

- `AccountIngestion`: a `.stream` event credits both the account total and the
  named replicant; a `.catchUp` event credits neither; an envelope with no
  `replicant_code` credits the account only; a zero/absent amount is a no-op.
- `.account` registration: `refresh` returns `false` without reading when the
  budget is at the floor, and returns the refresh's own success otherwise.
- `LocationEventsIngestion`: `event.completed` updates the row and does *not*
  invalidate `.locationEvents`; a missing row does invalidate it; other
  `event.*` names still invalidate.
- `LocationEvent.completing` merge, and `LocationEventDetail`'s `consumed`
  decode (including the absent-block case).
