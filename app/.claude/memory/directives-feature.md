---
name: directives-feature
description: "Directives (automations v1) design approved 2026-07-21: built-in Survey Run + Relay Run missions, DirectiveEngine module, CommandGovernor; spec in docs/superpowers/specs/."
metadata:
  type: project
---

The automations feature is named **Directives** (sidebar "Missions"/"Operations" were taken).
Approved spec: `docs/superpowers/specs/2026-07-21-directives-design.md` — read it before any
implementation work. Not yet implemented as of 2026-07-21; next step is a writing-plans
implementation plan, preceded by probe-api validation of the relay stow/deploy sequence.

Non-obvious decisions (the why, beyond the spec text):

- **Solo-operator principle**: the user is the only player ever; authoring friction is the
  known kill-risk (their Satisfactory burnout), so 3-click launch + watchable timeline outrank
  flexibility. Procedures are baked in; the player only ever picks where/when/with-what.
- Missions are **pure step machines over reconciled state**; the engine waits on op *identity*,
  which is what makes V3.9 blockers 1/4 (replay, loop protection) free. Don't re-introduce
  raw-event triggers without an event-time guard.
- V3.9 groundwork blockers 3–5 ship **inside** this feature (CommandGovernor in GameServices,
  DirectiveLogEntry audit), not as a separate pre-project.
- Recorded follow-up: **device-list organization at scale** (fleet will grow to hundreds;
  flat 3-pane list won't hold) — deliberately deferred, deliberately written down.

See [[architecture-review-v3]] for the V3.9 readiness analysis this design answers.
