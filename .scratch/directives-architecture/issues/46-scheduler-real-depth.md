# 46 — The scheduler queues behind a busy bench

Type: task
Status: resolved
Blocked by: 45
Labels: directives-architecture, stage-3

**What Phase B was for.** `choose` stops requiring an idle bench. A depot whose demand exceeds its bench count queues rather than waits.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 14.

**The preference order:** a free bench beats a shallow queue, a shallow queue beats a deep one, and the lowest device code breaks every tie. `Bench.owners` becomes a real list, filled from `queuedOperations` and ordered oldest first.

**`queueSize` as the capacity ceiling is a real reading but an unproven one at the boundary.** `Printing.swift:141-143` documents it as capacity and `PrintingSnapshotTests.swift:117-124` pins an idle bench advertising ten. What is **not** evidenced anywhere is whether a `quantity: 3` job occupies one queue slot or three, and `MineFleetPrint` routinely orders multi-unit jobs (`MineFleetPrint.swift:114-118`). This ticket assumes one slot per job — a deliberate under-count that risks a rejected enqueue rather than a lost one. Open Question 4 asks the operator for one live observation to settle it.

**Revisit `onOrder`'s blind spot, and decide it rather than reason about it.** Ticket 34 recorded that `onOrder` misses a job whose op row was lost, and that Phase A made this unreachable by never dispatching onto an occupied bench. This ticket makes it reachable again. Either ticket 42's supersede scoping is complete and a print op is never superseded — **assert that with a test** — or `onOrder` must widen to `queuedOperations` and take the per-type maximum against the printer's own queue.

---

- [x] **Step 1:** Write five failing cases: shallowest queue wins; equal depth breaks by code; a free bench still beats a shallow queue; a bench at capacity takes nothing; two runs on one bench are both owners, oldest first.
- [x] **Step 2:** Confirm the first four return nil and the fifth returns one owner.
- [x] **Step 3:** Widen `choose` to a `min` over depth with the code tie-break, filtered by `queueDepth < device.queueSize`. Take owners and the active job from `queuedOperations`.
- [x] **Step 4:** Settle the `onOrder` question above and write the test that proves whichever answer you take.
- [x] **Step 5:** Eight targets green.
- [x] **Step 6:** **Mutation probe.** Invert the `min` comparator and confirm two cases redden. Change the capacity filter to `<=` and confirm one reddens. Revert both.
- [x] **Step 7:** Record the borrow count; `check-comments.sh`; commit.

**Done when:** three benches each holding a job take a fourth job on the shallowest of them, with a test.

**Checkpoint F follows this ticket.**

---

## Step 4 decision, recorded

`CommandClient.swift:247` scopes its supersede loop to `if kind != .print`, and a
repo-wide grep finds no other `.superseded` write site — a print op is never
superseded. That branch of the question is settled and closed.

But the blind spot `onOrder` actually had was a different one, opened by Task 12:
`openOperations` narrowed to the ACTIVE op only, while `onOrder` still read it.
Once a bench can carry more than one live op (this ticket), any of the owner's
own jobs still `enqueued` behind the active one went uncounted — not because its
row was lost, but because `onOrder` was reading the wrong collection. Fixed by
widening `onOrder` (and `benches`' owner/active-job derivation) onto
`queuedOperations`, proven by `PrintSchedulerTests.ownEnqueuedJobBehindTheActiveOneCounts`.

`queuedOperations` is left empty by most of the codebase's pre-existing test
fixtures (`benches`/`onOrder` fall back to a one-op reading off `openOperations`
so those fixtures keep behaving as before); production always populates it, so
the widened read is live everywhere that matters.


---

## Comments

| Commit | Message |
|---|---|
| `ba124b1` | `feat(directives): the scheduler queues behind a busy bench` |
| `a7f56b9` | `fix(directives): read unreported queue size conservatively, retire 21 stale busy-bench assertions` |

**`queueSize <= 0` reads as ONE slot (the platen only), never as unbounded.**
Settled against the live database: 8 of 13 print-capable production devices
report `queueSize: 0` — vessels and fabricators, not real depot autofactories,
which report `10`. Reading zero as unbounded would let the scheduler pile
queued work onto a vessel, reintroducing the over-print failure this stage
exists to prevent. Pinned by two single-bench tests
(`unreportedQueueSizeStillAdmitsIdle`, `unreportedQueueSizeCapsAtOne`) and two
mutation probes.

**The 21 pre-existing tests asserting the old "any occupied bench excludes"
semantic were classified one at a time, not made green in bulk** — 11
genuinely asserted the removed semantic and are rewritten with the fixture's
`queueSize` made realistic and the assertion updated to the new dispatch/refresh
value; 6 were already correct for an unrelated reason (single-slot deadline
tests, or demand already netted to zero by `onOrder`) and needed no change;
4 are still-valid multi-bench at-capacity scenarios reframed with an explicit
`queueSize: 1` rather than an accident of the unset default
(`RestockRunTests.allBusyWaits`, `EventCourierPrintTests.allBusyWaits`,
`MineFleetPrintTests.allBusyWaits`, `MineFleetPrintSubstituteTests.allHubsQueuedYieldsNoBench`).
One, `RelayRunAcquireSchedulerTests.acquireDoesNotOrderTwice`, had a real
fixture gap — `PrintJob.stillPrinting` checks `ctx.ownedOperation(for:
ctx.directive.deviceCode)`, the CARRIER's code, while the fixture populated
the op on the BENCH's code, so the owner-scoped guard the test's own doc
claimed to pin was never reached. Fixed the fixture (`dispatched:` now
populated), not the assertion. Full per-test table:
`.superpowers/sdd/plan-stage-3/task-14-report.md`.

**The classification table was audited twice.** The first pass had two
misattributions — one row's rewrite was double-listed as also "unchanged,"
and one at-capacity reframe was missing from every category — both caught in
review and corrected by re-checking every row against `git diff` directly
rather than from memory.

**Built and reviewed 2026-08-19**, subagent-driven, on branch `worktree-directives-stage-3`,
which was merged with `main` at `8902fc1` before Phase B began. **Phase B is not itself merged** —
that is Matt's call. Every claim below was checked against source or the event stream rather than
taken from a subagent's summary.

| Commit | What |
|---|---|
| `ba124b1` | `feat(directives): the scheduler queues behind a busy bench` |
| `a7f56b9` | `fix: conservative queueSize reading; retire 21 stale busy-bench assertions` |
| `743e8ed` | `docs: fix 4 over-budget doc comments, correct the classification table` |

**What Phase B was for.** `PrintScheduler.choose` may now return an occupied bench, ranked by real
depth against capacity, so a depot whose demand exceeds its bench count queues rather than waits.
`Bench.owners` may hold several. Depth stays `queuedJobCount + (printingSnapshot != nil ? 1 : 0)`
and is **not** multiplied by quantity — see below. This ticket was built before 45, out of the
plan's order, because it is what returned the branch to green.

**Open Question 4 is answered, and the plan's assumption was wrong.** It asked whether a
`quantity: N` job takes one queue slot or N, assumed one, and worried depth under-counts. Live
bench `89130889` carried exactly one open op — `service_bot`, `quantity: 2` — with one unit on the
platen and **one entry in `print_queue`** bearing the same type and tags. **A job of N occupies N
slots, one at a time.** So `print_queue` entries are UNITS, `queuedJobCount + active` is already a
true slot count, and `Device.queueSize` is a ceiling in those same units. Multiplying by quantity
would double-count.

**`queueSize <= 0` does not mean uncapped, settled by live data over argument.** The first commit
read a non-positive `queueSize` as unbounded. Of 13 print-capable devices in production, **eight
report 0** — four heaven vessels, a racing vessel, three structural fabricators — against five
reporting 10, which are the real depot autofactories. Uncapped would let the scheduler pile
unbounded work onto a heaven vessel, which is this stage's own failure mode one layer down. A
non-positive `queueSize` now caps the bench at one slot, the platen.

**21 pre-existing tests asserted the semantic this ticket removes, and they were resolved here
rather than deferred** — the precedent being ticket 35, which rewrote 8 when it changed the same
semantic in the other direction, and ticket 38, which rewrote 18. The instruction was not "make
them green" but to decide, per test, between a removed semantic and a genuine regression. The
result: **11 rewritten**, **6 already correct**, **4 reframed as explicit at-capacity cases**, and
**one — `acquireDoesNotOrderTwice` — where a real fixture bug was found and fixed instead**:
`PrintJob.stillPrinting` checks the **carrier's** device code while the fixture populated the
**bench's**, so the owner-scoped guard was never reached.

The classification table needed a correction of its own: its arithmetic summed to 21 only because
two errors cancelled — one test double-counted, one omitted. Corrected to 11 + 6 + 4, with every
remaining row re-verified against the diff.
