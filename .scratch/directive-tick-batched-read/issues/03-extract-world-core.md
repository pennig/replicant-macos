# 03 — Extract `WorldCore`

Status: ready-for-agent
Blocked by: 02

Move the 13 global fields and their fetches into their own type. Pure
refactor — no query changes, no re-ordering, no improvements. This is the
seam every later task reads once per tick instead of 22 times.

Full steps, code and the exact 13 field signatures: `../plan.md` → **Task 3**.

**Done when:** `WorldCoreEquivalence.matchesTheSnapshotItComposes` passes,
comparing all 13 fields against the snapshot they compose; the DirectiveEngine
suite passes untouched. A failure here is a transcription error in the move —
diff against git history rather than debugging forward.
