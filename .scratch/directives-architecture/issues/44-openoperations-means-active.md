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

## Comments

Consumer walk, one call site at a time (current line numbers; the ticket's predate a `main` merge):

| Site | Verdict |
|---|---|
| `Steps/PrintJob.stillPrinting` | unaffected — reads `dispatchedOperations` (`.status.isOpen`) and `ctx.ownedOperation`, never `world.openOperations` directly; already widened by an earlier ticket |
| `Steps/TravelTo.swift:56` | unchanged — travel never goes `.enqueued` (`CommandClient.completion(for:)` maps `.travel` to `.deadline` → `.active`) |
| `EventRun.swift:518,617,804,839,903` | unchanged — all non-print device-busy checks (collect/deposit/attach/arrival) |
| `MineRun.swift:378`, `RepairFleet.swift:85,104` | unchanged — travel/recall busy checks |
| `RelayRun.swift` | no `openOperation` call remains; its print logic (`printInFlight`, `printStillQueued`, `printDiagnosis`) already reads `dispatchedOperations`, not `openOperations` |
| `MineFleetPrint.swift`, `RestockRun.swift`, `EventCourierPrint.swift` | none call `openOperation(for:)`; all print decisions route through `PrintScheduler.choose`/`onOrder` |
| `PrintScheduler.benches`/`choose`/`onOrder` | all three read `world.openOperations` directly (not via the two named accessors) and are UNCHANGED in this ticket — deferred to ticket 46, per the table. `onOrder` is the same collapse-adjacent risk as `benches`: a directive's own queued (not yet active) print now nets to zero "on order", so it can over-print against the reserve rail until 46 lands |

**Confirmed regression, not hypothetical:** `BrainGrowLifecycleE2ETests` (3 tests, real end-to-end simulation through `PrintScheduler`) now fails — a bench holding a queued print reads as free, so the print/restock decoupling scenario dispatches an extra `print` instead of reusing the queued one. `DirectiveEngineTests` moved from 1881/0 to 1883/3-failing (2 new tests, one rename net zero). This is the exact risk the brief asked to be flagged, not silently fixed (fixing it means editing `PrintScheduler.swift`, out of this ticket's scope). **Not safe to leave standing** — ticket 46 should land before this branch merges, or the three failing tests should gate the merge.

Also found and fixed, not named in the brief: `WorldSnapshotTests.optimisticOpsCountAsOpen` asserted the same stale "any open status counts" meaning this ticket removes, just for `.optimistic` rather than `.enqueued`. Renamed to `optimisticOpsDoNotCountAsActive`. Verified safe in practice: `CommandClient.execute` writes the optimistic row and awaits the full POST + confirm before returning, and `DirectiveExecutor.apply`'s `.dispatch` case awaits that whole call before the next tick evaluates — so no `WorldSnapshot.read()` inside this branch's own control flow ever observes a lingering `.optimistic` op for a device this directive just dispatched to. `Reconciler.apply` additionally promotes an orphaned optimistic row to `.active` on the next device poll (crash/relaunch case).

Resolved 2026-08-19. `openOperations` narrowed to `.active`; two doc comments corrected; `readsDevicesAndOnlyOpenOperations` split into `readsDevicesAndDropsClosedOperations` + two new narrowing tests; `optimisticOpsCountAsOpen` rewritten to `optimisticOpsDoNotCountAsActive`. RED confirmed against unmodified source (event stream), then GREEN. `DirectiveEngineTests`/`GameServicesTests`/`GameSyncTests`/`DirectivesFeatureTests`/`GameModelsTests`/`DevicesFeatureTests`/`GameDatabaseTests` run through the JSON event stream; only the three `BrainGrowLifecycleE2ETests` above are new failures, both flagged and left unfixed (ticket 46's scope).
