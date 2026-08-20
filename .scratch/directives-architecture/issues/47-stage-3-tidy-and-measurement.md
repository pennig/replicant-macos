# 47 — The governor, the doc comments, and the measurement

Type: task
Status: resolved
Blocked by: 46
Labels: directives-architecture, stage-3

The tidy-up, and the ticket that records what Stage 3 actually achieved.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 15.

**The governor question, and the answer this ticket expects.** `CommandGovernor` de-dups on `(directiveID, step, entityCode, kind, paramsDigest, startedAt >= owner.since, status != .failed)` (`:86-101`), so two identical prints from one run in one step on one bench are refused as `.deferred(.duplicate)`. On the evidence in this plan **no mission needs that**: `MineFleetPrint` orders `quantity: n` in one job rather than n jobs (`MineFleetPrint.swift:114-118`), and `RestockRun` orders one relay at a time against a demand `onOrder` decrements. Write the test that pins the guard as intended behaviour. Only if a mission genuinely needs two identical jobs does the digest gain a discriminator — and that is a change with its own test, not a one-line relax. Changing a de-dup guard to permit something nothing asks for is how duplicate spends get built.

**The doc comments the relax made false.** Each states or relies on "one open op per device": `Operation.swift:11-16`, `:104-106`, `:260-261`; `WorldSnapshot.swift:26-29`, `:182`; `OperationRetention.swift:42-43`; `CommandClient.swift:208-210`, `:248-249`; `Reconciler.swift:179-180`. Also `docs/superpowers/specs/2026-07-27-orrery-travel-indicators-design.md:87` — that one is a shipped design doc and a record of what was decided then, so add a line saying the invariant changed and where rather than rewriting it.

**Orphans to check, then delete:** `RelayRun.hubFreshness`, `PrintRail.hubFreshness` (if `RelayRun` was its only reader), `EventRun.printsInFlight` (deleted in ticket 36 — confirm nothing calls it), `RestockRun.pollInterval` if it is still there. An empty `findReferences` is a cold index, not proof. Delete, build, and let the compiler answer.

**Count `PrintJob.bench(_:for:)`'s callers.** Tickets 36, 37 and 38 all call `PrintScheduler.choose` directly, which may leave `EventCourierPrint` as its only caller — a one-caller wrapper over a one-line call is a redirect, not a seam. If that is what you find, delete it and let `EventCourierPrint` call the scheduler like everything else. `PrintJob.hasBench(_:)` stays regardless: three sites need "does this depot have any printer at all" as a question distinct from "can one take this job".

---

- [x] **Step 1:** Write and settle the governor test; record the decision.
- [x] **Step 2:** Correct the doc comments listed above.
- [x] **Step 3:** Delete the orphans, confirming each with LSP and then a build.
- [x] **Step 4:** Work the punch list. Close line 249 (two print sites outside `PrintJob` — tickets 36 and 37) and line 255 (`RestockRun` chooser-scoped duplicate spend — ticket 38). Re-read line 13 (`MineFleetPrint.stocking` deadline) — ticket 38 deleted that guard, so either the question is moot and you say why, or it stays open with a fresh reason. Re-read line 246 (travel sites on the unowned guard) — ticket 44 changed what that guard sees, so restate it against the new meaning rather than closing it.
- [x] **Step 5:** Record the measurement in `## Comments`: the borrow count at each of the five checkpoints against the 70 measured at `3ae52be`; **the print policy count, five-ways-split before and one after**, enumerating each of the five rows with its single answer and the ticket that produced it; the observed concurrent-print counts from Checkpoints E and F; and every case where a mutation probe failed to redden, with what was done about it.
- [x] **Step 6:** From-scratch `swift build --build-tests`, then all eight targets.
- [x] **Step 7:** Commit.

**Done when:** the five-way policy split is enumerated as one answer each, and every doc comment asserting one-open-op-per-device is gone.

## Comments

**Step 1 — the governor test, and the decision.** Added `twoIdenticalPrintsInOneStepAreDeduplicated` to `CommandDedupTests.swift`: one `CommandOwner` (`D-7`/`stocking`/`since T-60`), two `enqueue_print` dispatches on bench `B1` with identical `CommandParams` (same `deviceType`, `quantity`, `printTags`). **The test passed against unmodified `CommandGovernor.swift` — this is the finding, not a gap to close.** `CommandGovernor.swift` was left untouched. Decision, per the ticket's own reasoning: no mission in this plan ever wants two identical prints in one step on one bench — `MineFleetPrint` orders `quantity: n` in one job (`MineFleetPrint.swift:114-118`), and `RestockRun` orders one relay at a time against a demand `onOrder` decrements. The guard is correct as shipped and the new test pins it as intended behaviour rather than an oversight.

**Step 3 — orphans, checked and NOT deleted.** None of the four qualified:
- `RelayRun.hubFreshness` — live production reader (`BrainReport.swift:113`) plus test readers across five files. Task 5 did not leave it unreferenced.
- `PrintRail.hubFreshness` — `RelayRun.hubFreshness` is defined AS `PrintRail.hubFreshness`, and `PrintRail` itself reads it twice internally (`Steps/PrintRail.swift:45,60`). Not RelayRun's-only.
- `EventRun.printsInFlight` — already gone; the only hit in the tree is a historical mention inside a test doc comment (`EventRunPrintTests.swift:102`), not a live symbol.
- `RestockRun.pollInterval` — already gone; zero matches anywhere.

Also checked, though not in the brief's Step 3 list (the ticket body raises it): **`PrintJob.bench(_:for:)` has two callers, not one** — `RelayRun.swift:351` and `EventCourierPrint.swift:87`. The one-caller-wrapper scenario the ticket speculated about did not materialize (`RelayRun` still goes through `PrintJob.bench`, not `PrintScheduler.choose` directly), so nothing to delete there either.

**Step 4 — punch list.** Closed lines 249 and 13 (both DONE); restated line 246 against the new `openOperations` meaning (still open, narrower); added one new deferral (the depot-anchor 2-way split) surfaced by the print-policy audit below. `Device.canPrint` vs `Device.isPrintHub` was ALSO going to be a new deferral until a full read of the file found it already recorded, dated 2026-08-19 — not duplicated. Full text in `punch-list.md`.

**The six deferred items**, one at a time:

1. `WorldSnapshotTests.swift` (`queuedOpsAreOldestFirst`) — the doc named "Task 11's completion picker" and "Task 14's queue-depth read", plan-document task numbers with no code symbol behind them. Restated as the invariant itself: a bench's live ops come back oldest first, which a "pick the oldest matching op" completion rule and a "position = index" queue-depth read both depend on.
2. `DatabaseEraseResetTests.swift:43` — "21 migrations" is now 50 and would drift again. Reworded to name `GameDatabase.manifest` instead of a literal count, so the comment can't go stale a second time.
3. `Reconciler.selectCompletableOp` — restored three distinct `logger.notice` lines for three distinct declines (kind mismatch, stale event, and — newly — a type mismatch that no longer declines but silently fell back to the oldest candidate with no log at all). The kind and stale-event guards now check emptiness right after their own filter instead of after both filters combined, so each gets its own message; the type-mismatch case gets an informational notice on the fallback path, selecting behaviour unchanged. This is exactly the log shape the 2026-08-19 stall triage needed to distinguish its three causes.
4. Ticket 44's `## Comments` — corrected the `PrintJob.stillPrinting` row. It DOES reach `world.openOperations`, transitively, via `ctx.ownedOperation(for:)` → `world.openOperation(for:owner:)`; the reason the conclusion (unaffected) still holds is that `mine` — built on the status-unfiltered `dispatchedOperations` — short-circuits `||` first whenever the narrowing to `.active`-only would otherwise hide something.
5. Test-count convention — added a bullet to `plan-stage-3.md`'s Global Constraints: `1671 tests in 221 suites` and `1892` are the same `DirectiveEngineTests` run counted two ways (console test-function count vs. one `testStarted` per `@Suite` as well as per test in the event stream; `1671 + 221 = 1892`). Verified against this ticket's own `CommandDedupTests` run: 6 test functions + 1 suite = 7 `testStarted` events, matching exactly. Quote the console figure and the suite count separately; never sum them.
6. `DeviceDetailView.swift:31` — the `@FetchAll(Operation.order { $0.startedAt.desc() })` was genuinely vestigial: `operations` is consumed only through `DeviceOperations.card`/`queuedBehind`, both of which fully re-filter (`entityCode`, `status.isOpen`) and re-sort (ascending) per device. Removed the dead `.order`, replaced with `Operation.all` and a one-line comment saying why.

**Step 5 — the measurement.**

*Borrow count.* Recomputed at all five checkpoint commits named by the plan (tasks 3, 5, 6, 12, 14 → tickets 35, 37, 38, 44, 46), using the plan's exact instrument against each commit's tree, since three of the five ticket files never actually recorded the number their own Step said to record (35 did; 37 did; 38's, 44's and 46's checkbox was ticked — or in 44's/46's case not even ticked — with no figure written down). All five checkpoints: **71**. Current worktree HEAD (after this ticket's edits, which touch no `DirectiveEngine/Sources` production file): **71**. So: `3ae52be` baseline 70 → this branch's start 69 → after Phase A 71 → unchanged at 71 through every Phase B checkpoint → **71 final**. Stage 3 set no borrow target and the number never moved after Phase A landed.

*Print policy count — five sites, five original policies, verified against CURRENT source rather than assumed from the plan's framing:*

| Policy | Before (5 sites) | After | Unified by |
|---|---|---|---|
| **Rail short** | `.wait` at 4 sites, `.stall(.printStockShort)` at `RelayRun` | **One mechanism, one deliberate exception.** `PrintOrder.onRailShort: RailPolicy` defaults to `.wait`; only `RelayRun.swift:349` passes `.stall(.printStockShort)` explicitly. Not full behavioural agreement — Open Question 1 leaves that as policy, not a bug — but the five sites no longer hand-roll five independent branches; there is one typed knob and one named exception. | Task 2 (`PrintOrder`/`PrintScheduler`, ticket 34) |
| **Depot anchor** | `PrintJob.depot` (stamped theatre ?? pinned device location) vs. `world.theatreDepot(for:)` (stamped theatre only, and only if still `.operational`) vs. `RelayRun.hub`'s `carrier.location` | **Not fully unified — a real, verified finding, not the plan's stated target.** `RelayRun` (ticket 37) moved off the dangerous `carrier.location` device-anchor onto `PrintJob.depot`, so `RestockRun`, `MineFleetPrint` and `RelayRun` (3 of 5) now agree. **`EventRun` and `EventCourierPrint` (2 of 5) still call `world.theatreDepot(for:)`**, which is stricter in two ways `PrintJob.depot` is not: no device-location fallback, and it invalidates a theatre that has gone off `.operational`. `EventCourierPrint`'s use of `world.theatreDepot` predates this entire plan — the plan's own baseline table states all of sites 1-3 use `PrintJob.depot`, which was already wrong about site 3 at `3ae52be`. No Stage 3 ticket targeted EventRun's or EventCourierPrint's depot anchor. Added to the punch list under "Found by ticket 47's print-policy audit". | RelayRun by ticket 37 (Task 5); EventRun/EventCourierPrint untouched |
| **Bench capability** | `PrintJob.bench`'s `acceptsPrintJobs && !isCarrierHull` vs. `EventRun`'s `deviceType == "autofactory"` vs. `RelayRun.hub`'s `acceptsPrintJobs` with carrier hulls allowed vs. `PrintQueueFeature`'s UI-side `Device.canPrint` (`features.contains("print")`) | **One predicate for all five dispatch sites**: `PrintScheduler.benches` (`acceptsPrintJobs && location == depot && !isCarrierHull`), reached by every site via `PrintJob.bench`/`hasBench` or `PrintScheduler.choose` directly. The UI-side `Device.canPrint` is a separate, still-standing fourth predicate — real, but it was never one of the five dispatch sites; it was already on the punch list, dated 2026-08-19, before this ticket started. | EventRun by ticket 36 (C3); RelayRun's carrier-hull leak by ticket 37 (C6) |
| **Bench busy** | Owner-scoped `openOperation(for:owner:)` at sites 1-3, owner-unscoped at `EventRun`, no guard at all in `RelayRun.acquire` | **One rule for all five**: bench admission moved from "busy = excluded" to "queue depth < capacity", inside `PrintScheduler.choose`, with no per-site guard left to disagree. | The any-owner busy-exclusion unified once all five routed through `choose` (tickets 35-37); replaced with real depth admission by ticket 46 (Task 14) |
| **Fleet freshness before spending** | Depot-wide `PrintJob.fleetEvidenceIsStale` at sites 2-4, per-device `hub.updatedAt > hubFreshness` at `RelayRun`, none at `RestockRun` | **One check, all five sites**: `PrintJob.fleetEvidenceIsStale(directive, at:in:)`, confirmed present in `RestockRun.swift:115`, `EventCourierPrint.swift:93`, `MineFleetPrint.swift:109`, `EventRun.swift:374`, `RelayRun.swift:355`. | RestockRun by ticket 39 (Task 7, C8); EventRun/RelayRun by tickets 36/37 |

Net: **3 of 5 policy rows are fully unified to one answer** (bench capability, bench busy, fleet freshness). **Rail short is one mechanism with one named exception**, which is the state Open Question 1 deliberately leaves it in. **Depot anchor is the one row Stage 3 did not close** — it narrowed from three answers to two, and the two-way split is now recorded on the punch list rather than left implicit.

*Concurrent-print counts, Checkpoints E and F.* **Checkpoint E — RUN, 2026-08-19**: Matt observed every printer at a multi-autofactory depot leveraged by multiple runs, and multiple concurrent prints from a single Mine Fleet Print directive — qualitatively "greater than 1"; the plan records the observation, not an exact concurrent count, and none is written down anywhere in the tree. **Checkpoint F — NOT YET RUN.** It requires an evening with the brain on at a depot whose demand exceeds its bench count, and nothing in the plan, the punch list, or any ticket's `## Comments` records that session having happened. This still needs Matt.

*Mutation probes that did not redden as expected, and what was done:*
- **Ticket 37 (RelayRun, C7).** The brief-literal `acquireDoesNotOrderTwice` stayed green with `PrintJob.stillPrinting`'s guard deleted — a single busy bench is already skipped by C6's busy-bench rule regardless of ownership, so the test wasn't exercising C7 at all. Added `acquireDoesNotDoubleOrderAtAFreeBench` (a busy bench holding OUR print, plus a second free bench) to isolate C7; deleting `stillPrinting` alone now reddens only the new test, confirmed by mutation. The original test was kept — it is real coverage of C6, just not C7.
- **Ticket 43 (`DeadlineScheduler.processDue`, Task 11).** Dropping `operationID: op.id` from the completion call stayed green on first attempt: the fixture's due op happened to already be the oldest live op, so the fallback-to-oldest path picked the right row "by accident". Rewrote `deadlineClosesItsOwnOperation` so the enqueued sibling is the OLDER op, forcing a bare oldest-first fallback to pick the wrong one; re-ran the probe and it reddened correctly.
- **Ticket 43, a second fixture** (`theRequestedTypeStillClosesOverAnOlderSibling`) had the same shape and was rewritten the same way, caught in the same pass.
- **Ticket 42 (index relax, Task 10).** `CommandClientTests`' `#expect(live.filter { $0.status == .active }.count <= 1)` could never fail — `.print` always confirms `.enqueued`, never `.active`, so no fixture op in that test is ever active. Removed; the invariant it was trying to defend is covered directly at the database level by `GameDatabaseTests.twoActiveOpsOnOneDeviceAreRejected`, and the assertion doing the real work in that same test (`live.count == 2`) was untouched.
- **Ticket 46 (Task 14).** No brief-supplied test passed vacuously against unmodified source — confirmed by running the whole brief-supplied + new test set (`--filter PrintScheduler`) against the pre-Task-14 `PrintScheduler.swift` and getting a build failure, not a pass (`Bench` had no multi-owner support yet). Recorded as a clean result, not a gap.

**No brief-supplied test in this ticket (Step 1's governor test) reddened against unmodified source** — see above; that is this ticket's own version of the same trap the plan warns about, and the correct response was leaving `CommandGovernor.swift` alone rather than finding a change to make.

**Step 6 — from-scratch build and all eight targets, via the JSON event stream.** `rm -rf app/Modules/.build`, `swift build --build-tests` (clean, `Build complete!`), `./scripts/link-index-store.sh`, then each target run individually with `--disable-xctest --event-stream-version 0`:

| Target | Tests | Suites | Issues |
|---|---|---|---|
| `DirectiveEngineTests` | 1671 | 221 | 0 |
| `GameServicesTests` | 295 | 40 | 0 |
| `GameSyncTests` | 70 | 15 | 0 |
| `GameModelsTests` | 137 | 25 | 0 |
| `DirectivesFeatureTests` | 270 | 27 | 0 |
| `PrintQueueFeatureTests` | 14 | 2 | 0 |
| `GameDatabaseTests` | 22 | 7 | 0 |
| `DevicesFeatureTests` | 159 | 15 | 0 |

Every `runEnded` present, zero crashed (started-but-unterminated) tests on `DirectiveEngineTests`, confirmed by diffing `testStarted` against `testEnded ∪ testSkipped`. Re-run in full a second time after the last content edits (Reconciler's dated-history removal, the `CommandDedupTests` doc-budget trim) — identical counts both times.

**Status: resolved.** Commit: `50c0561` — `chore(directives): Stage 3 tidy-up — doc comments, orphans, the measurement`.
