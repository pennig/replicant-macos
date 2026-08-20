# 02 — Narrow `dispatchedOperations` to the kinds anyone reads

Status: ready-for-agent
Blocked by: 01

Every consumer outside the audit pass filters on `kind == print` or
`kind == travel`. Fetch only those, unioned with the few ops the audit
worklist still needs closed — any kind, or `recordCompletedOps` silently
stops writing `.opCompleted` for `launch`, `recall` and `deploy`.

`dispatchedOperations` stays one field of one type. The union is why.

Full steps, code and mutation checks: `../plan.md` → **Task 2**.

**Done when:** `DispatchedOperationsNarrowing` passes all four cases —
including a print of `.superseded` status surviving and a terminal `launch`
coming back only while its dispatch is unmatched; the DirectiveEngine suite
passes untouched; the property's doc comment names all its consumers rather
than only the audit pass.
