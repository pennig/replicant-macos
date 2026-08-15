---
name: supervisor-adopts-row-whole-package-failure
description: "RESOLVED 2026-08-15 — the supervisor-adopts-row flake is fixed; this note's original diagnosis was wrong on both counts"
metadata:
  node_type: memory
  type: project
---

`DirectiveEngineTests.BrainGrowLifecycleE2ETests/theSupervisorAdoptsTheRowTheBrainLaunched()`
is **FIXED**. Older plan docs still tell you to expect it red and not to
attribute it to your change — that instruction is now stale. A failure of this
test is yours.

This note originally called it **deterministic under whole-package parallelism**
with root-causing unfinished. Both halves were wrong:

- Not deterministic, and not about the backend. 21 consecutive whole-package
  `--build-system native` runs on an idle machine passed; under CPU load, 5 of
  10 failed. **Load is the variable.**
- Not contention on a shared actor. The mechanism is two brain ticks OVERLAPPING
  and both reading the pre-launch world — see [[brain-tick-overlap-race]] for
  the full contract and the rule for any test that needs N completed ticks.

Fixed by driving both ticks explicitly and sequentially instead of counting
`start()`'s concurrent one, plus letting the scripted server treat a
teardown `CancellationError` as teardown rather than a scripting fault.
Verified 25 loaded whole-package runs with zero failures of this test.
