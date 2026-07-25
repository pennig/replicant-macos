---
name: directives-feature
description: "Directives v2 design approved 2026-07-24: ONE surface unifying built-in AMI directives with custom Survey/Relay Run missions; DirectiveEngine + CommandGovernor; spec in docs/superpowers/specs/2026-07-24-directives-design.md."
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

Verified API facts backing the step sequences live in §3 of the spec (stow co-location, `deploy`
doesn't activate, `launch` auto-deploys adopted stowed devices, `directive.completed` payload).

See [[architecture-review-v3]] for the V3.9 readiness analysis this design answers, and
[[device-command-taxonomy]] for the AMI directive vocabulary.
