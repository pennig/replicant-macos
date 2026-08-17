# 22 — `SurveyRun` adopts `BotPhase`

Type: task
Status: open
Blocked by: 21
Labels: directives-architecture, stage-2

Delete `SurveyRun.swift:598-791` and `:488-490`; the eight `Step` cases stay and become a mapping. The timeline must read identically afterwards.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 3.

**Keep `recallDeadline` (`SurveyRun.swift:86`).** `recover` (`:453`) reads it for drone recovery, which `BotPhase` does not own — tuning one currently moves the other, and that is worth a trailing comment.

**Do not unify the empty-hold destination.** Survey goes to `.configuring` and Salvage to `.armingBots`; `.finished` lets each keep its own answer. See Open Question 1 in the plan — it needs Matt, not a refactor.

---

- [ ] **Step 1:** Baseline `SurveyRunRepairTests|SurveyRunTests|SurveyRunBotArmTests` through the event stream; record the passing count here.
- [ ] **Step 2:** Delete the eight bodies plus `recallArrival` and the seven bot constants; add the `botPhase(_:_:)` helper and the seven `switch` cases.
- [ ] **Step 3:** `grep` for `botProbeInterval|botConfirmDeadline|botDispatchRounds|SurveyRun.probe` — expect hits only in `SalvageRun.swift`, which ticket 23 takes.
- [ ] **Step 4:** Re-run the three suites. Same passing count, **no assertion edited**. A test that needs editing is a finding, not a fix — stop and record it.
- [ ] **Step 5:** `check-comments.sh`, commit.

**Done when:** `SurveyRun.swift` is ~150 lines shorter, the three suites are green unedited, and the recorded before/after counts match.
