# 44 — `openOperations` means the active op

Type: task
Status: open
Blocked by: 43
Labels: directives-architecture, stage-3

The last place N ops silently become one. `WorldSnapshot.openOperations` narrows to `.active`; queued ops are read from `queuedOperations`.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 12. **Carries C9.**

**The collapse.** `WorldSnapshot.swift:353` builds `openOperations` with `uniquingKeysWith: { _, last in last }` keyed on `entityCode` — since ticket 42 landed, that drops N−1 ops in unspecified row order, and its doc comment ("**The single OPEN operation per device**", `:26-29`) has been false ever since.

**Leave the read at `:237-239` fetching `openCases`.** `queuedOperations` needs them, and one query serving both is the point.

**The rule for every consumer: a print site asks `queuedOperations`; everything else keeps `openOperations`.** A site that gets this wrong fails silently — it simply stops seeing its own job. Walk every one and classify it in `## Comments`; do not change one without saying which class it is in:

| Site | Expected class |
|---|---|
| `Steps/PrintJob.swift:56-58` (`stillPrinting`) | widens to `queuedOperations` — a run's queued print is still its print |
| `Steps/TravelTo.swift:56` | unchanged; travel is `.active` or nothing |
| `EventRun.swift:443,533,703,738,801` | unchanged; non-print activities |
| `MineRun.swift:378`, `RepairFleet.swift:85,104`, `RelayRun.swift:242` | unchanged |
| `MineFleetPrint.swift:86`, `RestockRun.swift:95,159`, `EventCourierPrint.swift:83` | ticket 38 deleted or replaced most of these; confirm what remains reads `queuedOperations` |
| `PrintScheduler.benches` | ticket 46 |

---

- [ ] **Step 1:** Replace `WorldSnapshotTests.swift:161-180` ("the one open op per device") with the two cases that hold now — the active op is keyed per device, and a bench with only queued jobs has no active op. Route them through the real read path, not a hand-built snapshot; the read path is what changes.
- [ ] **Step 2:** Confirm the queued-only case fails.
- [ ] **Step 3:** Key `openOperations` on `.active`. Correct the doc comments at `:26-29` and `:182`.
- [ ] **Step 4:** Walk the consumer table above, one at a time.
- [ ] **Step 5:** Eight targets green.
- [ ] **Step 6:** Record the borrow count; `check-comments.sh`; commit.

**Done when:** a bench with a queued print and nothing on the platen returns nil from `openOperation(for:)` and one element from `queuedOperations`, with a test.
