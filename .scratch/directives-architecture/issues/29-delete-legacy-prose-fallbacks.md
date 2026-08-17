# 29 — Delete the legacy prose fallbacks

Type: task
Status: open
Blocked by: 27
Labels: directives-architecture, stage-2

Ticket 15 left **three** prose parsers behind for rows written before the typed columns existed, each already marked `// Legacy row written before the columns existed; Stage 2 deletes this` — `MissionLogBudget.swift:48` and `:84`, and **`DirectivesFeature/Sources/DirectiveStallDetail.swift:26`**.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 10.

The third is easy to miss: every other Stage 2 ticket stays inside `DirectiveEngine`, and this one crosses into `DirectivesFeature`. Ticket 17 names it explicitly ("`lastDispatch` prose split, `DirectiveStallDetail` prefix parse").

**`DirectiveStallDetail`'s prefix MATCH at `:24` stays.** `DirectiveLogEntry` has no typed reason column, so the summary prefix is how an entry is matched to the row's current reason — an entry recording an earlier stall must never speak under a different one. Only the detail-from-prose at `:27` goes.

The engine's two are pinned by tests whose own doc comments say "Stage 2 deletes both": `MissionLogBudgetTests.swift:75-81` and `:133-144`. The feature's is pinned by `DirectiveStallDetailTests.swift:39-43`, whose fixture passes no `detail:` and expects the value recovered from the summary.

**The fail-closed leg must survive.** `lastDispatch` returns `.nothingSent` on unparseable prose, and two tests pin that — `MissionLogBudgetTests.swift:85-91` `anUnparseableLegacyRowNamesNoOrder` and `MineRunTests.swift:1223` `unnamedDispatchReturnsToArming` (fixture at `MineRunTests.swift:217-221`). Deleting the parse is only safe because the removed branch returns `.nothingSent` too. An untyped row now reads as "nothing sent", which is the same answer.

---

- [ ] **Step 1:** Collapse `MissionLogBudget.swift:45-52` to a single `guard entry.commandKind == kind.rawValue else { continue }`.
- [ ] **Step 2:** Collapse `:81-89` to a `guard let` over both columns returning `.nothingSent`.
- [ ] **Step 3:** Delete the two tests that pin the parse. **Keep** `anUnparseableLegacyRowNamesNoOrder` and the `legacyDispatch` fixture — it now exercises the untyped-row path, still a real case.
- [ ] **Step 4:** Add one test pinning the new rule: an untyped row counts for nothing under both walkers.
- [ ] **Step 5:** Collapse `DirectiveStallDetail.swift:25-28` to a `guard let` over the `detail` column. Retire `DirectiveStallDetailTests.swift:39-43` and replace it with one asserting a detail-less legacy row names nothing. **Keep `:29-34`** — it pins that the column wins over a disagreeing summary, which is the whole point.
- [ ] **Step 6:** `swift test --filter "MissionLogBudgetTests|MineRunTests|DirectiveStallDetailTests"`, then the full `DirectiveEngineTests` and `DirectivesFeatureTests`; `check-comments.sh` on both touched sources; commit.

**Done when:** all three parsers are gone, the two fail-closed tests are still green, the column-wins test is still green, and **Checkpoint D** is scheduled.

This is the only Stage 2 ticket that touches `DirectivesFeature`.
