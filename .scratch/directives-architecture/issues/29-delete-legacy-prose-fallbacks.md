# 29 — Delete the legacy prose fallbacks

Type: task
Status: open
Blocked by: 27
Labels: directives-architecture, stage-2

Ticket 15 left two prose parsers behind for rows written before the typed columns existed, each already marked `// Legacy row written before the columns existed; Stage 2 deletes this` — `MissionLogBudget.swift:48` and `:84`.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 10.

Both are pinned by tests whose own doc comments say "Stage 2 deletes both": `MissionLogBudgetTests.swift:75-81` and `:133-144`.

**The fail-closed leg must survive.** `lastDispatch` returns `.nothingSent` on unparseable prose, and two tests pin that — `MissionLogBudgetTests.swift:85-91` `anUnparseableLegacyRowNamesNoOrder` and `MineRunTests.swift:1223` `unnamedDispatchReturnsToArming` (fixture at `MineRunTests.swift:217-221`). Deleting the parse is only safe because the removed branch returns `.nothingSent` too. An untyped row now reads as "nothing sent", which is the same answer.

---

- [ ] **Step 1:** Collapse `MissionLogBudget.swift:45-52` to a single `guard entry.commandKind == kind.rawValue else { continue }`.
- [ ] **Step 2:** Collapse `:81-89` to a `guard let` over both columns returning `.nothingSent`.
- [ ] **Step 3:** Delete the two tests that pin the parse. **Keep** `anUnparseableLegacyRowNamesNoOrder` and the `legacyDispatch` fixture — it now exercises the untyped-row path, still a real case.
- [ ] **Step 4:** Add one test pinning the new rule: an untyped row counts for nothing under both walkers.
- [ ] **Step 5:** `swift test --filter "MissionLogBudgetTests|MineRunTests"`; `check-comments.sh`; commit.

**Done when:** `MissionLogBudget` reads columns only, the two fail-closed tests are still green, and **Checkpoint D** is scheduled.
