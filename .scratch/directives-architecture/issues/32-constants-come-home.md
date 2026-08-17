# 32 — The constants come home; the borrow count is measured

Type: task
Status: open
Blocked by: 26, 28, 29, 30, 31
Labels: directives-architecture, stage-2

The last Stage 2 ticket. Constants move onto the sub-machine that uses them, the print rail leaves `RelayRun`, dead declarations go, and the borrow count is measured against its target and recorded.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 13.

Two constants are dead or near-dead, both confirmed by exhaustive textual sweep during ticket 17 **after an LSP `findReferences` returned empty on a cold index and could not be trusted**:

- `RestockRun.pollInterval` (`RestockRun.swift:64`) — **zero readers in `Modules`, production or test**. Delete.
- `RelayRun.trackedKinds` (`RelayRun.swift:89`) — no production reader; read only by `RelayRunTests.swift:1535` and `:1559`. **Decide deliberately**: delete it with the two assertions, or add the production reader the tests imply exists. A constant only tests read is a claim nothing enforces.

Four missions construct a whole `RelayRun(reserveFloor:)` to reach two instance methods that have nothing to do with relays (`EventRun:171,345`, `RestockRun:120`, `MineFleetPrint:118`, `EventCourierPrint:83`) — 5 constructions, 10 calls. Extract `PrintRail` and leave `RelayRun` a caller like the rest.

Six constants have **only cross-file readers**. `stagingFreshness = 5 * 60` is declared three times with no alias linking them; leave those and add a punch-list line rather than inventing a sub-machine to hold one number.

---

- [ ] **Step 1:** Delete `RestockRun.pollInterval`; decide and act on `RelayRun.trackedKinds`.
- [ ] **Step 2:** Create `Sources/Steps/PrintRail.swift`; repoint all five construction sites.
- [ ] **Step 3:** Move `SalvageRun.activationDeadline` and `relayPollInterval` to `RelayRun` (their only reader). Retire the `printDeadline` alias chain onto `PrintJob.deadline`.
- [ ] **Step 4:** **Measure the borrow count.** Baseline at `0115c20` is 114 occurrences / 108 distinct lines, of which 52 reach into a live mission struct (`RepairFleet` 34 and `MineRecipe` 28 are intentional namespaces, excluded from the 52). Target: **the 52 falls below 15**. Record the real number here. If it does not fall below 15, say what is left and why rather than forcing it.
- [ ] **Step 5:** Append the six deferred items to `punch-list.md`, each with `file:line`.
- [ ] **Step 6:** Run **all five targets**; `check-comments.sh` over every touched path; commit.

**Done when:** the borrow count is recorded, the punch list carries the six deferrals, all five targets are green, and Stage 2 is ready for operator review.
