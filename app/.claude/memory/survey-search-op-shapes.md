---
name: survey-search-op-shapes
description: "Survey-drone search command shapes — scan activity block (eta_seconds, no completes_at) and scan_complete relay event."
metadata: 
  node_type: memory
  type: reference
  originSessionId: 13a9a992-3a74-44ab-9655-ceb32806f1e5
---

Survey-drone `search` command (belt-only, "scour rocks until a mining cluster is found") — verified live against device `2586E328`:

- **While running:** device status `searching`; carries a `scan` activity block (spec `ScanInfoSchema`) with `target`, `started_at`, `progress_percent`, **`eta_seconds`** — and **no `completes_at`**. The deadline is `updatedAt + eta_seconds` (eta is *remaining* time, so anchor on fetch time, not `started_at`).
- **Completion:** fires a relay event `event_type: "scan_complete"` (`device_code` set, `payload: null`, info in title/body). After completion the drone enters a **tracking** state — it does *not* settle to idle ("mining can proceed while tracking is active"), so the event, not a settled status, is the completion signal.

Wired in the app as `OperationKind.search` (deadline op): `Device.derivedActivity`/`activityDeadline` read the `scan` block, `CommandClient.deadlineCommands` tracks `search` (completesAt back-filled from the post-command read since the dispatch response withholds it), and `Reconciler.completionEventTypes` includes `scan_complete`.

Distinct from the heaven_vessel `system_scan` (synchronous → `OperationKind.scan`, no tracked op) — see [[device-command-shapes]]. Still unhandled (out of scope when this was built): the `prospect` activity block (has its own `completes_at`) and the survey-drone `scan` command (`scanning` status).
