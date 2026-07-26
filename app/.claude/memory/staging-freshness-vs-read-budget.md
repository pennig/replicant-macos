---
name: staging-freshness-vs-read-budget
description: "A mission's WorldSnapshot is local SQLite only, so a deferred .low confirm-read made preflight read stale silence as 'not staged' — fixed by folding stow state out of device.stowed/device.deployed and by the .refreshDevices action"
metadata:
  node_type: memory
  type: reference
---

**The failure (live, 2026-07-26 15:46).** A Survey Run stalled
`noSurveyControllerAboard` on its SECOND target, on a vessel that was correctly
staged. Retry re-stalled twice. A manual refresh on the Devices screen fixed the
third Retry and the run continued.

**Root cause — three independent things composing.**

1. `WorldSnapshot.read` is a pure read of local SQLite. A mission has no way to
   demand fresh device state; `MissionAction` had `.refreshSystem` for star
   systems and no device equivalent.
2. Device rows are kept current by SSE events → `StalenessTracker.markStale` →
   a drain loop spending marks as **`.low`** reads. `PollCoordinator` *drops*
   `.low` reads when the reads budget sits at/below its floor (12). A controller
   that is not visible and holds no local `Operation` — exactly a survey
   controller, which drives its drones server-side — lands in the drain's slow
   third tier: one aged mark per pass, 60s backoff. The log showed
   `refresh B2CBDEC6 [low]: deferred (reads budget 11 ≤ floor 12)` at 15:43,
   15:44, 15:45, then the stall at 15:46.
3. Preflight's staging checks are NEGATIVE findings, and it read "no controller
   in these rows" as "no controller aboard" — absence of evidence as evidence of
   absence, over rows the app itself had flagged stale.

**Why Retry was structurally useless.** `DirectiveResolutionClient.retry` only
sets `status = .running` and re-stamps `stepStartedAt`. It triggers no read. So
Retry re-runs a *pure function over an identical stale snapshot* — a guaranteed
no-op. The manual fix worked because `DevicesFeature.refreshButtonTapped` calls
`devicesClient.fetchAll()`, a full fleet walk that bypasses `PollCoordinator`
and its budget floor entirely.

**Both halves of the fix.**

- **Fold stow state out of the event (free).** `device.stowed` carries
  `stowed_in_device_code` and `device.deployed` carries
  `deployed_from_device_code` (docs event catalogue, checked 2026-07-26 — there
  is no `device.recalled`; an AMI recall reports `ami.withdrawn` and the
  per-device `device.stowed` events are what land). `Reconciler.applyEventFields`
  now takes a `StowChange?` and settles the column under the same event-time
  guard as `location`, so staging state repairs at zero read cost and immune to
  budget pressure. Mapping lives in `GameSync.stowChange(for:)` — deliberately
  narrow: only those two events speak, and `nil` means "no opinion, leave the
  column alone". Reading a non-stow event's silence as "not stowed" would
  unstage a staged vessel on every unrelated event.
- **`MissionAction.refreshDevices(deviceCodes:thenStall:)` (the safety net).**
  A mission says "read this before I believe it"; `DirectiveEngineCore.resolveRefresh`
  spends `.high` reads (which bypass TTL *and* the budget floor), expands each
  carrier into the devices it reports stowed aboard — containment is two-ended
  and the staging checks read the CHILD's stow column — re-reads the world, and
  asks the machine once more. A second `.refreshDevices` collapses to
  `.stall(thenStall)`, so it is exactly one refresh round per evaluation, never
  a loop.

**The general lesson worth carrying:** anywhere the engine turns a *negative*
local-row finding into a stall, it must be able to tell "genuinely absent" from
"we haven't been allowed to look". `SurveyRun.configure`/`launch` still stall
`noSurveyControllerAboard` directly when a *claimed* controller vanishes — that
is a different situation (the code is known and the row is simply gone), left
as-is deliberately.

See [[controlled-devices-detail-only]] (the other half of why staging looked
unstaged) and [[directives-feature]].
