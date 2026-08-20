# 44 — `openOperations` means the active op

Type: task
Status: resolved
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

- [x] **Step 1:** Replace `WorldSnapshotTests.swift:161-180` ("the one open op per device") with the two cases that hold now — the active op is keyed per device, and a bench with only queued jobs has no active op. Route them through the real read path, not a hand-built snapshot; the read path is what changes.
- [x] **Step 2:** Confirm the queued-only case fails.
- [x] **Step 3:** Key `openOperations` on `.active`. Correct the doc comments at `:26-29` and `:182`.
- [x] **Step 4:** Walk the consumer table above, one at a time.
- [x] **Step 5:** Eight targets green.
- [x] **Step 6:** Record the borrow count; `check-comments.sh`; commit.

**Done when:** a bench with a queued print and nothing on the platen returns nil from `openOperation(for:)` and one element from `queuedOperations`, with a test.

## Comments

Consumer walk, one call site at a time (current line numbers; the ticket's predate a `main` merge):

| Site | Verdict |
|---|---|
| `Steps/PrintJob.stillPrinting` | unaffected — it DOES reach `world.openOperations`, transitively, via `ctx.ownedOperation` → `world.openOperation(for:owner:)`; the reason it is unaffected is that `mine` (built on the status-unfiltered `dispatchedOperations`) short-circuits `\|\|` first whenever the narrowing would hide anything |
| `Steps/TravelTo.swift:56` | unchanged — travel never goes `.enqueued` (`CommandClient.completion(for:)` maps `.travel` to `.deadline` → `.active`) |
| `EventRun.swift:518,617,804,839,903` | unchanged — all non-print device-busy checks (collect/deposit/attach/arrival) |
| `MineRun.swift:378`, `RepairFleet.swift:85,104` | unchanged — travel/recall busy checks |
| `RelayRun.swift` | no `openOperation` call remains; its print logic (`printInFlight`, `printStillQueued`, `printDiagnosis`) already reads `dispatchedOperations`, not `openOperations` |
| `MineFleetPrint.swift`, `RestockRun.swift`, `EventCourierPrint.swift` | none call `openOperation(for:)`; all print decisions route through `PrintScheduler.choose`/`onOrder` |
| `PrintScheduler.benches`/`choose`/`onOrder` | all three read `world.openOperations` directly (not via the two named accessors) and are UNCHANGED in this ticket — deferred to ticket 46, per the table. `onOrder` is the same collapse-adjacent risk as `benches`: a directive's own queued (not yet active) print now nets to zero "on order", so it can over-print against the reserve rail until 46 lands |

**Confirmed regression, not hypothetical:** `BrainGrowLifecycleE2ETests` (3 tests, real end-to-end simulation through `PrintScheduler`) now fails — a bench holding a queued print reads as free, so the print/restock decoupling scenario dispatches an extra `print` instead of reusing the queued one. `DirectiveEngineTests` moved from 1881/0 to 1883/3-failing (2 new tests, one rename net zero). This is the exact risk the brief asked to be flagged, not silently fixed (fixing it means editing `PrintScheduler.swift`, out of this ticket's scope). **Not safe to leave standing** — ticket 46 should land before this branch merges, or the three failing tests should gate the merge.

Also found and fixed, not named in the brief: `WorldSnapshotTests.optimisticOpsCountAsOpen` asserted the same stale "any open status counts" meaning this ticket removes, just for `.optimistic` rather than `.enqueued`. Renamed to `optimisticOpsDoNotCountAsActive`. Verified safe in practice: `CommandClient.execute` writes the optimistic row and awaits the full POST + confirm before returning, and `DirectiveExecutor.apply`'s `.dispatch` case awaits that whole call before the next tick evaluates — so no `WorldSnapshot.read()` inside this branch's own control flow ever observes a lingering `.optimistic` op for a device this directive just dispatched to. `Reconciler.apply` additionally promotes an orphaned optimistic row to `.active` on the next device poll (crash/relaunch case).

Resolved 2026-08-19. `openOperations` narrowed to `.active`; two doc comments corrected; `readsDevicesAndOnlyOpenOperations` split into `readsDevicesAndDropsClosedOperations` + two new narrowing tests; `optimisticOpsCountAsOpen` rewritten to `optimisticOpsDoNotCountAsActive`. RED confirmed against unmodified source (event stream), then GREEN. `DirectiveEngineTests`/`GameServicesTests`/`GameSyncTests`/`DirectivesFeatureTests`/`GameModelsTests`/`DevicesFeatureTests`/`GameDatabaseTests` run through the JSON event stream; only the three `BrainGrowLifecycleE2ETests` above are new failures, both flagged and left unfixed (ticket 46's scope).

**Built and reviewed 2026-08-19**, subagent-driven, on branch `worktree-directives-stage-3`,
which was merged with `main` at `8902fc1` before Phase B began. **Phase B is not itself merged** —
that is Matt's call. Every claim below was checked against source or the event stream rather than
taken from a subagent's summary.

| Commit | What |
|---|---|
| `8db8769` | `refactor(directives): openOperations means the active op (C9)` |

C9 lands. `WorldSnapshot.openOperations` narrows from "the newest open op per device", collapsed
with `uniquingKeysWith: { _, last in last }`, to **the active op**. Queued ops reach callers through
`queuedOperations`, added by ticket 41. Using `uniqueKeysWithValues` over a `.active`-filtered array
means a two-active violation now traps rather than silently collapsing — and ticket 42's index makes
that unreachable through normal inserts.

**The consumer walk is what made this safe, and the reviewer re-derived it by grep rather than
accepting it.** The load-bearing fact: **`.print` is the only kind that ever reaches `.enqueued`** —
`CommandClient.swift:355` is the single production assignment site, while travel maps to
`.deadline` then `.active`, and mining, attach, collect and deposit are `.continuous` or
`.immediate`. So no non-print consumer can observe the narrowing at all. Every caller of
`openOperation(for:)` and `openOperation(for:owner:)` was enumerated with nothing missing.

**This ticket deliberately left the branch red**, and that was the right call. `PrintScheduler`
reads `openOperations` directly, so a bench holding only a queued print began reading as free and
three `BrainGrowLifecycleE2ETests` double-printed. Fixing it here would have meant editing
`PrintScheduler.swift`, which the brief withholds; weakening the tests would have hidden a real
regression. **Ticket 46 closed it**, and the remaining Phase B order was swapped to 46-then-45 so
the red stood for one ticket rather than two.

An unrequested but correct extra: `optimisticOpsCountAsOpen` asserted the same stale meaning for
`.optimistic` ops. The reviewer verified the race argument by tracing `DirectiveExecutor.apply`
through `CommandGovernor.dispatch` to `CommandClient` and finding the insert, the POST and the
confirm all inside one async closure before control returns.
