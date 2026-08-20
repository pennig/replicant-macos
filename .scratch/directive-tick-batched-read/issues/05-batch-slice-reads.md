# 05 — Batch the slice reads

Status: ready-for-agent
Blocked by: 04

`DirectiveSlice.readAll` answers for every running directive at once, taking
the scoped queries from 22 round trips to 3. `read` is reimplemented as
`readAll` with one element, so there is exactly one implementation and the
equivalence test cannot drift.

The one genuinely open decision is how to do the per-directive `logWindow`
truncation — a window function or a Swift-side group-and-take. The plan names
the constraint and the test that catches it wrong; pick whichever matches
what the codebase already does elsewhere.

Full steps: `../plan.md` → **Task 5**.

**Done when:** `DirectiveSliceBatching` passes both cases, including the empty
directive list emitting no `IN ()`; `WorldSnapshotTests`'s log-window cases
pass untouched — they are what catch a per-directive `LIMIT` done wrong.
