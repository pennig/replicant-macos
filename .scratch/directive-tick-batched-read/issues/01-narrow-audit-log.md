# 01 — Narrow `auditLog` to unmatched dispatches

Status: ready-for-agent
Blocked by: —

Push the dispatch/completion matching into SQL. `auditLog` fetches 7,954 rows
per directive per tick so `recordCompletedOps` can act on 4 of them.

Full steps, code and mutation checks: `../plan.md` → **Task 1**.
Read `../spec.md` first; the plan argues from it.

**Done when:** `AuditLogNarrowing` passes with all four exclusions pinned, each
proved by deleting its filter and watching the test go red; the whole
DirectiveEngine suite passes with no pre-existing assertion edited; the
`alreadyLogged` set is gone from `DirectiveExecutor.recordCompletedOps`.
