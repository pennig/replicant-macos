# 04 — Extract `DirectiveSlice`

Status: ready-for-agent
Blocked by: 03

The mirror of 03 for the five directive-scoped fields, plus the
`WorldSnapshot.init(core:slice:now:)` that composes the public shape back
together. Still no behaviour change.

The `baseWanted`/`baseDecoded`/`wanted`/`decoded` computation belongs to the
slice, not the core — it reads `core.devices` to find the vessel.

Full steps and the exact signatures: `../plan.md` → **Task 4**.

**Done when:** `DirectiveSliceComposition.composesTheSameSnapshotAsTheDirectRead`
passes on whole-value equality; the DirectiveEngine suite passes untouched.
