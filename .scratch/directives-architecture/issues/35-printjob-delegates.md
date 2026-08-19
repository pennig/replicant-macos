# 35 — `PrintJob` delegates to the scheduler; a busy depot waits

Type: task
Status: open
Blocked by: 34
Labels: directives-architecture, stage-3

`PrintJob.bench` stops selecting and starts asking. The three sites already on `PrintJob` follow, and the "no bench at all" case separates from the "no free bench" case.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 3. **Carries C11.**

**`PrintJob` keeps everything except the selector.** The depot anchor, `PrintJob.deadline` (1800), `stillPrinting` and `fleetEvidenceIsStale` are the step frame and are correct. The pinned-device preference at `PrintJob.swift:38-39` goes with the selector: a busy pin must not beat a free bench, and ticket 38's fan-out depends on that.

**The restructure this forces.** `MineFleetPrint.swift:42-46` and `RestockRun.swift:62-66` resolve the bench in `nextAction`'s opening guard and stall when there is none. Those two cases must split — no print-capable device at the depot is `.stall(.unreachableDevice)`; benches that all happen to be busy is `.wait`. The step functions take the depot designation from here on, not a `Device`.

---

- [x] **Step 1:** Write the failing pair in `MineFleetPrintTests` — all-busy waits, no-bench stalls — and the same pair in `RestockRunTests` and `EventCourierPrintTests`.
- [x] **Step 2:** Confirm the all-busy case fails with `.stall(.unreachableDevice)`. The no-bench case passes already; it is here so a later refactor cannot collapse the two.
- [x] **Step 3:** Replace `PrintJob.bench(_:)` with `bench(_:for:)` and `hasBench(_:)`. Delete the old body including the pin preference.
- [x] **Step 4:** Restructure the three `nextAction`s and thread the depot through the step functions.
- [x] **Step 5:** All six targets green. **No existing assertion may be edited** except the ones this ticket's own tests replace — if a mission suite reddens on a case the plan does not name, stop and report it.
- [x] **Step 6:** Record the borrow count; `check-comments.sh`; commit.

**Done when:** a depot whose every bench is busy waits, and a depot with no printer still stalls, each with a test.

## Comments

Borrow count (`grep -c "SalvageRun\.\|RelayRun\.\|RestockRun\.\|MineFleetPrint\.\|HaulRun\.\|EventRun\.\|SurveyRun\.\|MineRun\." *.swift | grep -v ":0$"` in `DirectiveEngine/Sources`), measured after this task's commit: **71** (Brain.swift 31, RelayRun.swift 11, RestockRun.swift 7, EventCourierPrint.swift 5, MineRun.swift 4, BrainReport.swift 3, SalvageRun.swift 2, one each in DirectiveEngine.swift, DirectiveExecutor.swift, EventRun.swift, HaulRun.swift, MineFleetPrint.swift, MineRecipe.swift, SurveyRun.swift, WorldSnapshot.swift). Immediately before this task (same branch, after tasks 1-2) it was 69; the plan's `3ae52be` baseline is 70. The +2 here is both `RestockRun.swift` and `EventCourierPrint.swift` each gaining one line: building a `PrintOrder` now names `RelayRun.relayDeviceType` / `EventRun.courierDeviceType` a second time in the same function (once for the order, once for the dispatch `CommandParams`) — not a new cross-file borrow, the same constant was already referenced on another line. Stage 3 sets no borrow target; recorded as measured.
