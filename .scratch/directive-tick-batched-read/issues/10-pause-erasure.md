# 10 — A pause landing mid-evaluation is erased, not deferred

Status: ready-for-human
Blocked by: —

`DirectiveExecutor.commit` (`DirectiveExecutor.swift:489`) does
`Directive.upsert { directive }`, writing the whole row including `status`. An
evaluation already in flight therefore writes `.running` back over a pause the
operator just applied. The pause is not delayed — it is destroyed, and must be
applied a second time to stick.

**This predates the batched-tick branch** and that branch does not cause it. The
same upsert was already there. What the branch changes is the window: from
`[own read → commit]` to `[tick read → queue wait → commit]`. Measured as
essentially unchanged in steady state — `WorldTick.read` queries `Directive`
first, so the window grows only by the remainder of the tick read — and widened
by up to one tick only when an executor overruns.

**Why it needs its own ticket rather than a deferred line.** The spec for that
branch approved a pause being *honoured on the next tick, up to 5s later*. It did
not approve a pause being lost. Reading the approval as covering this would be
wrong, so the gap is recorded here with a named fix instead.

**Named fix, either shape:**
- a status-guarded write — `UPDATE … WHERE status = 'running'` — so a paused row
  refuses the update, or
- column-scoped writes instead of a whole-row upsert, so `status` is never among
  the columns an evaluation writes.

**There is already a red-to-green target.** `WorldTickTests` carries a test
pinning the erasure as a defect (added by the final fix wave, named to document
rather than bless it). A correct fix turns it red; update it in the same commit
to assert the pause survives.

**Done when:** a pause applied while an evaluation is in flight survives that
evaluation's commit, and the erasure test is inverted to assert survival.
