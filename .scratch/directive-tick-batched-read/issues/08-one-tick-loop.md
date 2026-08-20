# 08 — Rewire the engine to one tick loop

Status: ready-for-agent
Blocked by: 07

The supervisor, brain and executor loops collapse into one. Executors stay
one-`Task`-per-directive and keep applying their own writes in their own
transactions — only the cadence and the snapshot source move.

This is the only ticket that changes control flow and the only one carrying a
behaviour delta: a directive paused mid-tick is honoured on the next tick, up
to 5s later. It is pinned by a test rather than left to inspection.

It also invalidates the `peers` doc comment at `WorldSnapshot.swift:118-140`,
which argues `RelayRun.isNextInLine` is needed because runs have "no
serialising authority above" them. The tick loop is now that authority, and
the FIFO answer becomes deterministic rather than dependent on who asked
when. Rewrite the paragraph; do not touch `RelayRun`.

Full steps: `../plan.md` → **Task 8**.

**Done when:** the WHOLE app suite passes, not just DirectiveEngine — `stop()`
ordering, `@Shared(.brainReport)` clearing and any `TestClock`-driven engine
test are what this ticket is most likely to break.
