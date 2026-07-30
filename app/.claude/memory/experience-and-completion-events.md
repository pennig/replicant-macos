---
name: experience-and-completion-events
description: "experience.gained + event.completed ingestion: the double-delivery of quest XP, the stream-only credit rule, the droppable .account reconcile, and the consumed block accounts/events never returns"
metadata:
  type: project
---

SHIPPED 2026-07-30. Both events crossed the ingestion choke point unhandled
(`experience.gained` 250 rows in the local ledger, `event.completed` 4).

**The overlap that governs the whole design.** A quest completion's
`rewards.xp` is ALSO delivered as its own `experience.gained` with `source:
"location_event"` — verified on TENEGSHE-3-EVT-003, 1800 XP in both. So
`event.completed`'s rewards are display material only; crediting them would
double every quest award. Nothing outside `LocationEvent` tracks resource
stock either, so `rewards.resources` and `consumed` are likewise display-only.

**`experience.gained`** (`{amount, source}`, envelope carries
`replicant_code`) → `AccountIngestion` in AccountManager, which owns both
things that move: the `@Shared(.account)` total (sidebar footer) and the
`Replicant` row (active-replicant header). Sources seen: `scan`, `print`,
`achievement`, `scan_system_completion_bonus`, `location_event`. An
achievement award carries NO replicant code — total only.

- **Live stream events only.** Catch-up replays a window the launch
  `accounts/me` read already counted, so crediting it doubles the gap. Same
  rule, same reason as the roster writes in `LocationsIngestion`.
- Credits locally for immediacy, then `invalidate(.account)` for the
  authoritative reconcile — 15s debounce, because XP arrives in clusters (a
  survey run pays out per body).
- The reconcile is **droppable**: it checks `gameClient.budget(.reads)` and
  returns `false` below `AccountIngestion.readsFloor` (20, above
  `PollCoordinator`'s 12). Returning `false` leaves the domain stale, so a
  starved reconcile is deferred to the next nudge, not lost. This is why
  `AccountManager.refreshAccount` returns `Bool` — it used to swallow failures,
  which would have stamped the domain fresh for a full TTL on a failed read.

**`event.completed`** → `LocationEventsIngestion.completedRoute`, matched by
exact name (so the Event Log stops calling it unhandled — the family route's
`.all` matcher never counted as feature-specific). Applies to the one named row
via `LocationEvent.completing(payload:now:completedAt:)` instead of the full
`accounts/events` walk the `.all` route used to trigger. A row we never held
falls back to that walk: the payload has no `title`/`description`, so a
fabricated row renders blank.

**The trap: `accounts/events` NEVER returns `consumed`.** Verified against all
6 completed rows in the live DB — every one has `rewards`, none has `consumed`.
The stream payload is its only source, and `merging(event:now:)` replaces
`detail` wholesale, so the naive version made the Consumed card appear at
completion and vanish at the next refresh. `merging` now carries a captured
`consumed` across when the incoming entry has none (an incoming block still
wins). `consumed.devices` is the app's ONLY record of which devices a quest
ate — they're deleted by the time the event arrives.

Design record: `docs/superpowers/specs/2026-07-30-experience-and-completion-events-design.md`.
See [[location-events-feature]], [[event-stream-migration]], [[account-feature]],
[[staging-freshness-vs-read-budget]].
