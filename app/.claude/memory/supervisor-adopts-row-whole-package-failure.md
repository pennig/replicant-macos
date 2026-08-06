---
name: supervisor-adopts-row-whole-package-failure
description: "theSupervisorAdoptsTheRowTheBrainLaunched fails only in the whole-package umbrella test run, not per-product — pre-existing, not yours"
metadata:
  node_type: memory
  type: project
---

`DirectiveEngineTests.BrainGrowLifecycleE2ETests/theSupervisorAdoptsTheRowTheBrainLaunched()`
fails **only** when the whole package runs as one process
(`swift test --build-system native`, the umbrella `ModulesPackageTests`
product). It passes in isolation and passes in a full
`--test-product DirectiveEngineTests` run (668 tests, green).

The three expectations that go red are the restock half:
`core.executorCount == 2`, `restock.count == 1`, and
`restock.first?.deviceCode == "HUB1"` — the second brain tick does not write
its `restockRun` row. The grow half of the test passes.

**Why:** verified pre-existing on 2026-08-05 at `a2f200a` with an unrelated
change stashed — the clean tree fails the same test the same way (2,085
tests, 1 failure). It reproduced on two consecutive umbrella runs, so it is
deterministic under whole-package parallelism rather than a random flake.
The likely mechanism is contention: the test drives `core.start()`, a
`TestClock`, and `executorCount` on a shared actor while ~2,000 other tests
run in the same process.

**How to apply:** do not spend time attributing this to your own change.
Confirm by running `--test-product DirectiveEngineTests` — if that is green,
your work is clean. If you need a whole-package signal, run per-product into
separate event-stream files and concatenate (see
[[swift-test-event-stream-output]]) rather than using `--build-system
native`, which both rebuilds from scratch and creates the contention.

Root-causing it is unfinished work. See [[brain-tendmesh-build]] and
[[relay-return-and-restock]] for what the restock row is supposed to do.
