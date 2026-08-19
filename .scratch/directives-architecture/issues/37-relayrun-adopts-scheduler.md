# 37 — `RelayRun.acquire` adopts the scheduler

Type: task
Status: resolved
Blocked by: 36
Labels: directives-architecture, stage-3

The second hand-rolled site, and the largest behaviour change in Stage 3.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 5. **Carries C5, C6 and C7.**

**The dispatch is in `acquire`, not `printing`.** Stage 2's hand-off note said `RelayRun.swift:359`; that is the poll step and it dispatches nothing. The `enqueue_print` is at `RelayRun.swift:348`, inside `acquire` (`:305-353`). A ticket that migrated `printing` would change nothing and report success.

**Four things change at once, because `RelayRun` differs from the other four on four axes:**

- **C5** — `hub(near:in:)` anchors on `carrier.location` (`:150`), a device location, which `PrintJob.swift:20-21` warns against: a hub that unfurls elsewhere must not drag the run with it. It becomes the theatre depot.
- **C6** — `hub` prefers "anything but our own carrier", then lowest code. Never a free bench, and a carrier hull is a legal pick.
- **C7** — `acquire` has no open-op guard at all, alone among the five sites.
- The per-device freshness gate (`hub.updatedAt > hubFreshness`, `:328`) becomes the depot-wide `PrintJob.fleetEvidenceIsStale` the other sites use, placed last before the spend.

**What does NOT change:** `RelayRun` stays the one site that stalls on a short rail. It passes `onRailShort: .stall(.printStockShort)`. See Open Question 1.

**The C7 guard has a trap in it.** `world.openOperation(for: directive.deviceCode, owner:)` asks about the carrier, not the bench — and the bench is recomputed every tick, so "is my print open?" cannot be asked of a device the chooser may have moved on from. That is punch-list line 255 in a different mission. Use `PrintJob.stillPrinting`, and read it first (`Steps/PrintJob.swift:52-60`) to confirm it answers "does this owner have a print open anywhere" rather than "is this device busy". If it answers the latter, widen it here and say so.

---

- [x] **Step 1:** Write the three failing tests — depot anchor, free-bench-and-no-hulls, and no-double-order.
- [x] **Step 2:** Confirm all three fail.
- [x] **Step 3:** Rewrite `acquire`'s tail. Keep the rail stall.
- [x] **Step 4:** Delete `hub(near:in:)` (`:149-157`). Confirm with LSP, then with a build — an empty `findReferences` is a cold index, not proof.
- [x] **Step 5:** All six targets green. `RelayRunTests` is the largest suite in the module; read failures individually.
- [x] **Step 6:** Record the borrow count; `check-comments.sh`; commit.

**Done when:** a carrier standing away from its theatre depot still prints at the depot, with a test.

## Comments

**C7's brief-literal test is vacuous alone.** `acquireDoesNotOrderTwice` (a single busy bench, our own print) still passes with the `stillPrinting` guard deleted, because `PrintScheduler.choose`'s busy-bench skip (C6) already produces `.wait` for a lone busy bench regardless of ownership. Added `acquireDoesNotDoubleOrderAtAFreeBench` (a busy bench holding our print PLUS a free bench) to isolate C7 — deleting `stillPrinting` alone reddens only that test, confirmed by mutation. `acquireDoesNotOrderTwice` stays, still real (it reddens against the pre-change `hub(near:)`, which had no busy check at all) but its coverage is of C6, not C7 specifically.

**Three pre-existing tests needed rewriting**, all a direct consequence of moving the per-device hub-freshness gate to the depot-wide `PrintJob.fleetEvidenceIsStale` placed last, before the dispatch, per the brief: `RelayRunTests.refreshesAStaleHubRowBeforePrinting` (now `refreshesStaleFleetEvidenceBeforePrinting`), `DirectiveEngineTests.RelayRunEngineTests.aStaleHubRowThenAStaleCensusReachesTheReserveRail`, and `BrainDegradationTests.theReserveRailVetoesThePrintAndTheBrainIdlesInsteadOfThrashing`. The last one is a genuine, favourable behaviour change beyond C5/C6/C7: a persistently short-stock world no longer re-reads the hub device row on every spaced retry, since the fleet-evidence gate sits after the stock veto and is never reached while stock stays short — reads dropped from 3 to 1 over the fifty-virtual-minute run, with the census-read count unaffected.

Borrow count (`grep -c "SalvageRun\.\|RelayRun\.\|RestockRun\.\|MineFleetPrint\.\|HaulRun\.\|EventRun\.\|SurveyRun\.\|MineRun\." *.swift | grep -v ":0$"` in `DirectiveEngine/Sources`), measured after this task's commit: **71** (Brain.swift 31, RelayRun.swift 11, RestockRun.swift 7, EventCourierPrint.swift 5, MineRun.swift 4, BrainReport.swift 3, SalvageRun.swift 2, one each in DirectiveEngine.swift, DirectiveExecutor.swift, EventRun.swift, HaulRun.swift, MineFleetPrint.swift, MineRecipe.swift, SurveyRun.swift, WorldSnapshot.swift) — unchanged from the 71 recorded after ticket 35 (task 4). `hub(near:in:)`'s deletion removed a borrow-free helper, so it does not move this number.

**Built and reviewed 2026-08-19**, subagent-driven, on worktree branch
`worktree-directives-stage-3` off local `main` at `b7228f1`. **Not merged** — merging is Matt's
call. Every claim below was checked against the source or the event stream, not taken from a
subagent's summary.

| Commit | What |
|---|---|
| `1ed99fe` | `refactor(directives): RelayRun.acquire prints through PrintScheduler (C5, C6, C7)` |
| `bea0196` | `fix(directives): RelayRun review round 1 — real C7 fixture, PrintJob idiom, C13` |

C5, C6 and C7 land and `hub(near:in:)` is deleted — it had exactly one caller, inside the
`acquire` this ticket rewrote. `onRailShort: .stall(.printStockShort)` is preserved: RelayRun
remains the only site that stalls on a short rail.

**C7 took three attempts to pin, and the first two both passed for the wrong reason.** The
brief's `acquireDoesNotOrderTwice` was vacuous — a single busy bench is skipped by C6 regardless
of ownership. The first replacement passed only because it set the carrier's code equal to the
busy bench's, exploiting `stillPrinting`'s device-scoped disjunct; that cannot happen in
production, because a RelayRun's `directive.deviceCode` is always the carrier and
`PrintScheduler.benches` excludes carrier hulls. The third version gives the carrier a code
distinct from every bench and attributes the print through `dispatchedOperations`, so the
owner-scoped `mine` disjunct is what does the work. Deleting `mine` alone reddens it and nothing
else.

**C13 was found here and named.** The mandated reorder puts the fleet-evidence gate after the
reserve rail, so the hub row stops being re-read whenever the rail already vetoes — a hub-row
read count of 3 dropping to 1 across a 600-tick regression. No incorrect dispatch results.

`RelayRun` also stopped speaking a sixth idiom: it now gates and picks through
`PrintJob(depot:).hasBench(ctx)` and `.bench(ctx, for:)` like the other four sites.
`grep -n "PrintScheduler" Sources/RelayRun.swift` is empty.
