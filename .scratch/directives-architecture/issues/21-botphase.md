# 21 — `BotPhase`: the service-bot lifecycle, once

Type: task
Status: open
Blocked by: 20
Labels: directives-architecture, stage-2

The sub-machine that replaces `SurveyRun.swift:598-791` (194 lines) and `SalvageRun.swift:669-873` (203 lines). Not yet wired into either mission — tickets 22 and 23 do that.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 2 carries the code.

The two blocks differ in exactly five things, measured: three next-step destinations (which `.finished`/`.more` remove from the sub-machine entirely), one constant NAME (`recallDeadline` vs `botRecallDeadline`, both `20 * 60`), and log prose (the `runNoun` parameter). `probe` is byte-identical in both (md5 `d630420ab179204a442cae451e3f796c`).

Four premises worth not re-deriving: both missions deploy **once per system**, not per body; their gates are semantically identical; their stall reasons are identical; and their handling of a recalled bot's nil location is identical.

---

- [ ] **Step 1:** Write `Tests/Steps/BotPhaseTests.swift` using the existing `Tests/RepairTestSupport.swift` fixtures. Cover: deploy orders the first bot aboard; an empty hold `.finished` rather than naming a step; the round budget; **deadline before read** in `awaitRepair`; idle bots finish; a bot in transit still counts as out.
- [ ] **Step 2:** Confirm the build fails on `cannot find 'BotPhase' in scope`.
- [ ] **Step 3:** Write `Sources/Steps/BotPhase.swift` with the seven phases and the six constants. Copy `recallArrival` from `SurveyRun.swift:488-490` rather than re-deriving it.
- [ ] **Step 4:** `swift test --filter BotPhaseTests`.
- [ ] **Step 5:** `check-comments.sh`, commit.

**Done when:** six tests green and no mission file has changed yet.
