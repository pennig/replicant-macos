# 30 — `PrintJob` over the three depot-anchored print sites

Type: task
Status: open
Blocked by: 27
Labels: directives-architecture, stage-2

`MineFleetPrint.printer(for:in:)` and `MineFleetPrint.fleetEvidenceIsStale` move into a sub-machine that owns the bench rule, the evidence gate and the print deadline. `MineFleetPrint`, `RestockRun` and `EventCourierPrint` adopt it.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 11.

**Scope is three of the five print sites, deliberately.** `EventRun.swift:380` computes a variable deadline (`printSlack` + the longest blueprint print time) measured from `lastOrderedAt` rather than `stepStartedAt`; `RelayRun.swift:401` anchors bench selection on **`carrier.location`, not a depot**, and is the only site that stalls rather than waits on a short rail. Forcing an anchor union, a deadline union, a deadline-anchor union and a terminal-disposition union into a type Stage 3 is about to rewrite buys nothing. Ticket 18 must take all five.

**This ticket carries a real bug fix.** `EventCourierPrint.swift:113` polls `world.openOperation(for: directive.deviceCode, owner: directive.id)` — the launch-pinned host — while the dispatch at `:98` went to `printer.deviceCode`, which substitution may have moved to a different bench. On substitution the poll asks about the wrong queue. It gets its own failing test first.

---

- [ ] **Step 1:** Write `Tests/Steps/PrintJobTests.swift`, starting with the failing test for the wrong-device guard: a pinned host that refuses jobs must substitute, and `bench(_:)` must name the substitute.
- [ ] **Step 2:** Confirm it fails.
- [ ] **Step 3:** Write `Sources/Steps/PrintJob.swift`. Give it a `pollStep: String?` mirroring `TravelTo.confirmStep` — only `EventRun` self-targets, and the three migrated sites hand to a separate polling step.
- [ ] **Step 4:** Migrate the three sites, each keeping its own rail gates, its own "already have one" escape and its own polling step. **The deadline stays above the guard**, which is where all three already have it.
- [ ] **Step 5:** Delete `MineFleetPrint.swift:55-69` and `:92-101`; repoint `RestockRun:72`, `EventCourierPrint:79,88`, `EventRun:350`.
- [ ] **Step 6:** `swift test --filter DirectiveEngineTests`; `check-comments.sh`; commit.

**Done when:** the courier poll watches its own bench with a test proving it, and `MineFleetPrint.printer` has no external caller.
