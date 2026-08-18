# 29 — Delete the legacy prose fallbacks

Type: task
Status: resolved
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

---

## Comments

**Resolved by `73ab16a`** (ticket 24), **`47fd5b9`** (25), **`596cdc6`** (26), **`4728651`+`b5aadaf`** (27), **`ba20dc1`+`0c00ce1`+`8621a27`+`7582c5e`+`5189b8d`** (28), **`d1a7272`** (29).

Full detail lives in each ticket's own comment; this note records what the six have in common.

### Four plan defects that would have broken the build or the behaviour

1. **Ticket 24's deletion could not be done as written.** Removing `SalvageRun.travelPositionUnconfirmed` and `lastTravelCompletion` breaks **13 production call sites and 11 test references at once**, and the plan's own answer was "land it with ticket 25 in one commit, or leave the branch red". Neither was necessary: ticket 24 left one-line forwarders and constant aliases, so the body existed once in `TravelTo` from the first commit while every caller kept compiling. Ticket 26 deleted the forwarders once the last caller moved.
2. **The plan named test readers it did not know about.** Six test sites read `SalvageRun.lastTravelCompletion`, five more read the two constants. None appear in ticket 24's text.
3. **Ticket 26's test helper does not exist.** The plan says to reuse `operationalTheatre(depot:)` and forbids adding a second. The real helper is `singleOperationalTheatre(depot:)` at `BrainTestSupport.swift:373`, returning a tuple — the plan's `[operationalTheatre(depot: depot)]` does not compile.
4. **Three of ticket 27's own test fixtures asserted outcomes their inputs cannot produce.** Each paired `ctx(60)` with a device `updatedAt` of `now - 60` or `now - 5`, which under `.stepStart` freshness makes the row FRESH, so `verdict` answers `.judge` — not the throttled read or wait asserted. Only the setup was changed; no `#expect` was touched.

### Two sites that did not fit, and were left alone rather than forced

- **`RelayRun.confirmSource`** attaches `thenStall: .unreachableDevice` to its *ordinary* staleness read. `ConfirmRow`'s throttle read is hardcoded `thenStall: nil`, and only `.readThenStall` at deadline expiry carries a reason — which a `deadline: .infinity` site can never reach. Reverted and punch-listed. Eight of nine planned migrations landed in ticket 28, not nine.
- **`RelayRun.carrierRetainsAuthority`**'s watermark is two-sided; `ConfirmRow` has no two-sided case and one site does not justify a fifth.

### One brief instruction that was wrong, and correctly disobeyed

Ticket 28's table gives `SurveyRun.awaitCompletion` `watermark: .skewed(eventTimeSkewTolerance)`. That is the *success test's* condition, not the ladder's. Used as the watermark it compares against a fixed `stepStartedAt - tolerance` that never moves once crossed, so every row reads fresh forever, `verdict` answers `.judge` forever, and an hours-long poll silently stops buying reads. `.age(backstopInterval)` reproduces the original gate — which was always a pure age test — exactly.

### Counts

`DirectiveEngineTests` 1709 → **1736**; `DirectivesFeatureTests` **297**, unchanged. Every task reported four measures from the canonical command, and each landing was predicted before the run and hit exactly.

**A note for whoever runs tickets 30-32: `check-comments.sh` does not count lines.** It is eleven regexes for dates, history and device codes. Ticket 28 failed its review on four over-budget inline comments after correctly reporting `exit 0`. Hand-count the ≤2-line inline and ≤3-line `///` budgets.

**Checkpoint D is now due — operator action.** The timeline should show no `Dispatched …` prose being re-parsed, and `MissionLogBudget` reading columns only.
