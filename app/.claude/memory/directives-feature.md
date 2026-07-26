---
name: directives-feature
description: "Directives v2: Stages 1-3 SHIPPED 2026-07-25 (unified surface, then CommandGovernor + the DirectiveEngine module + the directive.* route). Engine loop is live but registers NO mission machines until Stage 4 (Survey Run). Spec in docs/superpowers/specs/2026-07-24-directives-design.md."
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

Verified API facts backing the step sequences live in §3 of the spec (stow co-location, `deploy`
doesn't activate, `launch` auto-deploys adopted stowed devices, `directive.completed` payload).

See [[architecture-review-v3]] for the V3.9 readiness analysis this design answers, and
[[device-command-taxonomy]] for the AMI directive vocabulary.
