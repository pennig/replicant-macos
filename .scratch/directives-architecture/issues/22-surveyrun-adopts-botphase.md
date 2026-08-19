# 22 — `SurveyRun` adopts `BotPhase`

Type: task
Status: resolved
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

---

## Comments

**Resolved by `f8f0e4b`, fixed by `f597033`.** `SurveyRun.swift` 792 → 631 lines; the eight bodies at `:598-791` and `recallArrival` are gone, and the seven bot `Step` cases are now a mapping onto `BotPhase` in the inline form, with `ctx` built once at the top of `nextAction`.

**The plan's deletion list was wrong in three places, and each would have broken the build.** `recover` reads `recallProbeDelay` (`:450`), `recallProbeInterval` (`:464`) and `recallArrival` (`:458`), all of which sit outside the deleted block. The first two are KEPT — `recover` is drone recovery, which `BotPhase` does not own, the same reason the plan already gave for keeping `recallDeadline`. `recallArrival` is deleted and `recover` repointed to `BotPhase.recallArrival`, which Task 2 left `static` and internal for exactly this. Keeping the two probe constants also saved eight `SurveyRunTests` references from needing edits.

Four test references to deleted constants were repointed (`SurveyRunBotArmTests:174`, `SurveyRunRepairTests:109, :362, :383`) — pure symbol swaps to identical values, four changed lines in total, no assertion edited.

**A silent behaviour change shipped and was caught by the task review, not by the suite.** The original `deployBots` had two `.finished`-shaped exits with DIFFERENT destinations: an empty hold went to `.configuring`, and exhausting the dispatch-round budget went to `.armingBots` — "arm whatever did deploy". `BotPhase.deploy` collapsed both into `.finished`, and the mapping sent both to `.configuring`, so a fleet with one bot deployed and a later bot failing would skip arming and repair entirely. **The existing test could not see it**: `theDeployLoopGivesUpAndSurveysUnrepaired` uses a one-bot fixture, where `armingBots`' own empty guard also lands on `.configuring`, making the old two-hop path and the new direct path indistinguishable. A fully green 1707/1707/0 suite held over a real divergence.

The fix gives `BotPhase` an injected `unrepairedStep`, and `deploy`'s give-up returns `.action(.advanceStep(nextStep: unrepairedStep))` — not a fifth `StepResult` case, which would have forced an arm into every exhaustive switch across the twelve later tasks. Two tests were added with two-bot fixtures, one at the `BotPhase` level and one through `SurveyRun.nextAction`. The Task 2 test that had pinned the buggy `.finished` was corrected, not weakened: same fixture, stronger assertion.

A controller audit of all seven original bodies in BOTH missions found this is the only phase in either that collapses two destinations into one signal.

Canonical count 1709/1709, 0 issues, `runEnded` present. `check-comments.sh` exit 0.

Deferred minors: `.repairing`'s `case .finished, .more:` arm is half dead (`awaitRepair` never returns `.more`); the already-deployed bot in the two new fixtures is narratively motivating but not mechanically load-bearing for which branch `deploy` takes.
