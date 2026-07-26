---
name: directives-feature
description: "Directives v2: Stages 1-4 + stall resolution + the §7 step timeline SHIPPED. Unified surface; CommandGovernor + DirectiveEngine; Survey Run + launcher; Retry/Skip/Cancel/Pause/Resume; live timeline serving both row kinds. Survey Run NEVER stows or adopts. Remaining: Stage 5 Relay Run, and .opCompleted entries are still unwritten."
metadata:
  type: project
---

The automations feature is named **Directives**. Approved spec:
`docs/superpowers/specs/2026-07-24-directives-design.md` (v2) — read it before any implementation
work. The 2026-07-21 v1 spec is **superseded** (header points here); its vision + engine architecture
carry over. Not yet implemented as of 2026-07-24.

Non-obvious decisions (the why, beyond the spec text):

- **The naming collision is resolved by unification, not avoidance.** The backend's `set_directive`
  AMI standing-behaviour is also called a directive. Rather than pick a free word, one surface shows
  both — *built-in* (AMI, server-run) and *custom* (multi-step, app-run). It's earned, not cosmetic:
  Survey Run's step 4 literally issues `set_directive`, so a custom mission composes a built-in one.
- **Built-in rows are derived from `Device` rows, never mirrored into a table.** The server owns AMI
  directive state; mirroring would create drift and turn every device refresh into a reconcile-diff.
  Derived rows are structurally incapable of lying. `DirectiveLogEntry` carries an optional
  `directiveID` *and* an optional `deviceCode` so one table gives both kinds a timeline.
- **Built-ins are editable in place** (Reconfigure/Clear) because in a 3-pane layout the detail pane
  *is* the device context — a read-only pane saying "edit this elsewhere" would re-introduce the very
  asymmetry the unification removes. Forces extracting `DirectiveComposer` out of DevicesFeature into
  its own small feature module (it can't go in PrintingUI/TravelUI — those are TCA-free by manifest).
- **Solo-operator principle**: the user is the only player ever; authoring friction is the known
  kill-risk (their Satisfactory burnout), so 3-click launch + watchable timeline outrank flexibility.
- Missions are **pure step machines over reconciled state**; the engine waits on op *identity*, which
  is what makes V3.9 blockers 1/4 (replay, loop protection) free. `directive.completed` is the one
  raw-event route — it only writes a `DirectiveLogEntry`, guarded *issue-time relative*
  (`eventTime >= stepStartedAt - 5s`, the `Reconciler.completeOpenOperation` shape) so a post-close
  catch-up completion still lands while replays are rejected.
- **Print-if-missing is permanently out, not deferred** — inventory is location-bound and only
  `transport` devices carry cargo, so it can't work at an arbitrary target.
- Survey completion backstop is `locations/{star}` `planets_scanned`/`_total` +
  `moons_scanned`/`_total`, *not* drone state — drones/controller may have moved on and report
  unreliably. Same read is also the skip-already-scanned precondition.
- V3.9 blockers 3–5 ship **inside** this feature (CommandGovernor in GameServices, DirectiveLogEntry
  audit). The FTL-mesh incremental-add optimization is also in scope: Relay Run turns
  `FTLMeshRefresher`'s full O(relays) rebuild from rare into per-target.
- Recorded follow-up: **device-list organization at scale** (fleet will grow to hundreds; flat 3-pane
  list won't hold) — deliberately deferred, deliberately written down.

## Stages 1–2 SHIPPED 2026-07-25

Plan: `docs/superpowers/plans/2026-07-24-directives-stage1-2-unified-surface.md`. What landed:
`DirectiveComposerFeature` (the composer extracted out of DevicesFeature so two features present it),
the `Directive`/`DirectiveLogEntry` tables, and `DirectivesFeature` — the unified list + detail with
built-in rows reconfigurable/clearable in place. Sidebar: Operations ▸ Directives. **No engine** —
the custom half of the list is empty until Stage 3.

Invariants established (don't undo these):
- **Built-in rows are derived, never persisted.** No production code writes the `Directive` table.
  `DirectiveRow.merge(devices:directives:)` recomputes on every read, so a derived row cannot drift.
- Row ids are namespaced `custom:` / `builtin:` so a device code and a directive id can't collide.
- `.reconfigureTapped` / `.clearTapped` **guard on `case .builtIn`** — for a custom row, `deviceCode`
  is the mission's *vessel*, so an unguarded handler would clear a directive on the wrong device.
- **`DirectivesFeature` does NOT issue its own confirm-read** after dispatch. `CommandClient` already
  does it for `.immediate` commands, and `PollCoordinator` TTL-limits only `.low` — so an extra
  `.high` read always hits the network and fires even on the rejected path. Matches
  `DevicesFeature.commandConfirmed`. See [[device-refresher-dependency]].
- `DirectiveConfigFlattening` is a top-level enum, not a static on the view — see
  [[swiftui-view-statics-trap-in-tests]]. It bit us mid-implementation.
- `Space.xxs = 2` was added to DesignSystem (half-step below `xs`). `UI/DESIGN_SPEC.md`'s spacing
  scale line is now stale and should be updated.

All six Stage-3 follow-ups from the whole-branch review are now CLEARED (see the Stage 3 section).

## Stage 3 SHIPPED 2026-07-25

Plan: `docs/superpowers/plans/2026-07-25-directives-stage3-engine.md`. What landed: `CommandGovernor`
+ `@Dependency(\.commandGovernor)` in GameServices; the **`DirectiveEngine` module** (non-feature
tier — `Dependencies`, no TCA) holding `WorldSnapshot`, the `MissionStepMachine`/`MissionAction`
seam, the supervisor+executor loop, and `DirectiveIngestion.eventRoute`; `Directive.controllerCode`;
and the composition-root wiring. Full suite at ship: **775 tests over 26 products, 0 failing.**

**No mission machines ship yet** — the registry is empty in production, so starting the engine is a
no-op on real data until Stage 4 registers Survey Run. That is deliberate, not an oversight: the loop
is proven end-to-end by scripted fake machines in `DirectiveEngineTests`.

Invariants established (don't undo these):
- **Evaluation is clock-driven (5s tick), not event-driven.** An evaluation is a local SQLite read
  plus a pure function, and only touches the network when the mission asks for a command. This is
  what buys replay immunity (the engine never sees an event, so its own command echo can't spook it)
  and deterministic tests under `TestClock` — with no observation plumbing to get wrong. Resisting a
  "kick the executor on table change" optimization is the point.
- **A `.deferred` dispatch writes NOTHING and is not a failure.** The governor refuses under
  actions-budget pressure or a per-device in-flight claim; the step is late, never lost, and the
  directive's status is untouched. Only a `.rejected`/`.failed` outcome stalls.
- **A directive whose kind has no registered machine is left entirely alone** — no writes at all.
  In Stage 3 that is every production row, so a bug here would corrupt data the moment the app runs.
- **Only `.running` directives are evaluated.** A stall or pause is the user's to resolve; a tick
  must never resume one behind their back.
- `DirectiveExecutor` commits the row and its log entries in **one transaction** — a mission is never
  observed half-advanced.
- **Engine stops BEFORE `gameSync`, and both before the table wipes** (the `gameSync` lifecycle
  handler is registered first, wipes are registered later and so run later).
- `CommandGovernor`'s in-flight claim is released on **every** path including rejection — a retained
  claim would wedge that device for the session. Floor is 6 of the 60/min actions bucket
  (proportional to `PollCoordinator`'s 12 of 120 reads).
- `WorldSnapshot` qualifies `GameModels.Operation` rather than aliasing it: a file-private typealias
  cannot appear in public API, and `Foundation.Operation` would otherwise win the name.

**The open two-rows design question is SETTLED: badge and lock, not hide.** A built-in row whose
controller a live mission drives shows "driven by <mission>" and refuses Reconfigure/Clear (guarded
in the reducer, not merely `.disabled` in the view) — clearing a directive a step is waiting on would
stall the mission with a confusing `surveyIncomplete`. `Directive.controllerCode` exists to make that
ownership knowable; the vessel can't stand in for it, since a Survey Run's vessel and its controller
are different devices. `.completed`/`.cancelled` release ownership; `.paused`/`.needsAttention` keep
it (the directive is still in force server-side).

**App-target link: DONE** (user, 2026-07-25). `DirectiveEngine` is in the Replicould target's
`packageProductDependencies` and Frameworks phase. It was made in the Stage 3 worktree and swept into
`ab6e977` by a broad `git add -A`, so that commit's "still needs linking" message is stale — the link
is committed. See [[pbxproj-link-is-manual]] for why this half is always manual.

Stage 4 (Survey Run) and Stage 5 (Relay Run + FTL-mesh incremental add) are now unblocked and
independent of each other. `.opCompleted` log entries are unwritten until Stage 4 gives the engine an
op to watch.

## Stage 4 SHIPPED 2026-07-26 — Survey Run

Plan: `docs/superpowers/plans/2026-07-26-directives-stage4-survey-run.md`. What landed: the
`SurveyRun` step machine (registered in `DirectiveEngine.makeLive`, so **the engine is no longer
inert**), three new mission actions (`advanceStep`, `assignController`, `refreshSystem`), a
`WorldSnapshot` that also carries the directive's log entries and the cached `StarSystem` blobs for
its targets, `LocationsClient.hydrateSystem`, `DirectiveAttentionReason.noSurveyControllerAboard`, and
a minimal **New Survey Run** sheet. Full suite at ship: **833 tests over 26 products, 0 failing.**

**The precondition contract (operator decision, 2026-07-26 — this is the load-bearing one).** A
Survey Run **never stows and never adopts**. It uses an AMI survey controller already stowed aboard
the vessel and drones that controller has already adopted and that are stowed with it. Missing either
is a stall (`noSurveyControllerAboard` / `noSurveyDroneAboard`), not a step the engine performs. The
reason: adoption is persistent state that outlives the mission, and re-parenting the player's fleet
behind their back is not the engine's call. This is why spec §4's step 1 (stow) has no counterpart in
the machine — don't "restore" it.

**§5 deviation, forced by the API.** `GET locations/{star}` is presence-gated (403 unless a replicant
is in that system — [[location-endpoint-presence-gate]]), so the "skip an already-scanned target"
precondition can only consult the **cached** `SystemDetail` blob. Live re-reads happen only after
arrival. Spec §5 reads as though one live call serves both purposes; it can't.

Invariants (don't undo these):
- **Unknown scan counts are never "fully scanned."** A wasted trip to a finished system is cheap;
  silently skipping an unscanned one loses the point of the run. `isFullyScanned(nil) == false`.
- **Completion is two-tier and issue-time relative.** The `directive.completed` log entry Stage 3's
  route writes is the fast path, guarded `occurredAt >= stepStartedAt - 5s` (so a catch-up completion
  after a close still counts and a replay doesn't) → `refreshSystem` → counts agree ⇒ `advanceTarget`,
  counts disagree ⇒ **stall `surveyIncomplete`**, never a silent advance. A 10-minute backstop poll
  covers a dropped event; its disagreement returns to *waiting*, not a stall, because nothing claimed
  completion so there is nothing to disbelieve.
- **`refreshSystem` is best-effort.** A 403/failed read still advances the step — stalling on a
  transient read would strand a mission that is fine.
- **The controller is claimed at preflight, not at creation.** The sheet writes `controllerCode: nil`;
  recording it at creation would go stale if the fleet moved first. `assignController` is what sets it
  (and therefore what badges/locks the built-in row).
- **The controller is identified by capability**, `availableDirectives.contains("survey_system")`, not
  by `device_type` — and STOWED, not merely co-located, since `launch` deploys stowed devices.
- **`set_directive` is re-issued unless the in-force config matches exactly** on planets/moons/recall.
  A leftover `moons: none` from manual use would silently survey half the system. Note Survey Run's
  config (`moons: all`) deliberately differs from the composer's manual default (`moons: none`).
- The **launcher offers only staged vessels**, computed through `SurveyRun`'s own fleet queries so the
  picker and the engine share one definition of "staged" and the sheet can't manufacture a stall.

**Not built, and the natural next slice:** the `needsAttention` resolution verbs (Retry / Skip target /
Cancel) from spec §7. A stalled run is visible in the detail pane but cannot be resolved from the UI —
today it needs a direct SQLite edit. Stage 5 (Relay Run + the FTL-mesh incremental add) is the other
open piece; the two are independent.

## Stall resolution SHIPPED 2026-07-26

Plan: `docs/superpowers/plans/2026-07-26-directive-stall-resolution.md`. Closes the gap Stage 4 left:
a stalled run was visible but inert, and clearing it meant editing SQLite by hand. What landed:
`DirectiveResolutionClient` (`@Dependency(\.directiveResolution)`) with **retry / skipTarget / cancel
/ pause / resume**, `MissionRegistry` as the single mission-registration point, per-reason
`displayName` + `guidance` on `DirectiveAttentionReason`, and a `DirectiveStallPanel` in the custom
detail pane. Full suite at ship: **848 tests over 26 products, 0 failing.**

| Verb | Effect | Allowed from |
| --- | --- | --- |
| retry | same step, `stepStartedAt` re-stamped, back to `.running` | `needsAttention` |
| skipTarget | `targetIndex += 1`, step reset to the machine's `firstStep`, `.running` | `needsAttention`, `paused` |
| cancel | `.cancelled` | `running`, `needsAttention`, `paused` |
| pause | `.paused` | `running` |
| resume | `.running`, `stepStartedAt` re-stamped | `paused` |

- **Why retry re-stamps `stepStartedAt`** (the non-obvious bit): the completion guard is issue-time
  relative, so re-stamping makes a `surveyIncomplete` stall's stale completion entry predate the step.
  The machine drops back to waiting and the backstop re-polls, instead of instantly re-stalling on the
  same evidence. Resume re-stamps for the same reason.
- **A verb applied from a status it doesn't apply to is a logged no-op**, not a crash or a corrupt
  row — the UI shouldn't offer it, but a stale click must not land.
- **`cancel` deliberately leaves the AMI directive in force** on the controller. Clearing it is a
  server command with its own failure modes; cancelling releases ownership (`.cancelled` is outside
  `DirectiveRow.owningStatuses`), so the built-in row's Clear button becomes available for the user to
  do it deliberately.
- Each verb writes the row change and its `.resolved` timeline entry **in one transaction**.
- **Deviation from spec §7:** it names `RCErrorBanner` for the verbs, but that control hard-codes a
  single Dismiss button and four other screens depend on its shape. A purpose-made
  `DirectiveStallPanel` carries the same intent without shared-control churn.
- Tests exercising the live client must set `$0.directiveResolution = .liveValue` — the `testValue` is
  `unimplemented` per the loud-defaults rule.

**Still open:** the §7 **live step timeline** fed by `DirectiveLogEntry` (the sit-back-and-watch view —
every entry it needs is already written, including these `.resolved` ones), and **Stage 5 Relay Run**
+ the FTL-mesh incremental add. Independent of each other.

## Step timeline SHIPPED 2026-07-26

Plan: `docs/superpowers/plans/2026-07-26-directive-step-timeline.md`. Closes §7's "sit-back-and-watch
view". **Read-only** — the engine and the `directive.*` route already wrote every entry it renders;
nothing about mission execution changed. Full suite at ship: **863 tests over 26 products, 0 failing.**

- **One `DirectiveTimeline` `FetchKeyRequest` serves BOTH row kinds** — a mission's timeline is
  `directiveID == id`, a built-in directive's completion history is `deviceCode == controller`. This
  is what §2's optional `directiveID`/`deviceCode` pair was for, finally realized. `request(for:)` is
  the single place that knows which id goes in which slot; **never mix them** — a controller's history
  under a mission that merely drives it would read as the mission's own work.
- Newest-first, capped at `entryLimit` (100). A run accumulates ~6 entries per target and nothing
  prunes the table; oldest-first would push the end you're watching off screen.
- **`selectionChanged(_:)` is called from BOTH selection paths** — the `selectedRowID` binding and the
  launcher's `.created` delegate, which selects programmatically. Missing the second is the easy bug;
  `BobnetFeature` carries the same helper for the same reason. Set the selection *before* building the
  request or it resolves against the previous row.
- Times render with `Text(date, style: .relative)` — ticks on its own, no timer and no formatter to
  test. The custom pane's **Now** readout (current step + elapsed) uses the same thing and is what
  covers a long quiet step.
- `DirectiveLogPresentation` (glyph + prominence per kind) is a SwiftUI-free namespace, not statics on
  the view — [[swiftui-view-statics-trap-in-tests]].
- A TCA note that cost a cycle: sending `.newDirective(.presented(.delegate(...)))` in a test without
  first presenting the sheet is an `ifLet` application-logic error, not a valid path. Send
  `.newDirectiveTapped` first.

**Still not written: `.opCompleted` entries.** The timeline shows step transitions, dispatches, stalls
and resolutions, so a long travel reads as a quiet gap until the next step starts — which the Now
readout covers. Writing them is engine work (the executor would have to notice a dispatched op
closing) and remains the one gap in the audit trail.

Verified API facts backing the step sequences live in §3 of the spec (stow co-location, `deploy`
doesn't activate, `launch` auto-deploys adopted stowed devices, `directive.completed` payload).

See [[architecture-review-v3]] for the V3.9 readiness analysis this design answers, and
[[device-command-taxonomy]] for the AMI directive vocabulary.
