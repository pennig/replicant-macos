# 33 — `Bench`, `PrintOrder`, and `PrintScheduler.benches`

Type: task
Status: open
Blocked by: nothing
Labels: directives-architecture, stage-3

The three values every print site will speak in, and the query that finds a depot's benches. Pure, table-tested, called by nothing yet.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 1.

**The depth formula is the point.** `queueDepth` is `queuedJobCount + (printingSnapshot != nil ? 1 : 0)`. The active job lives in a separate `detail["printing"]` block and is never a `print_queue` entry (`Printing.swift:136-138` against `:144`), and `Device.queueSize` is the bench's CAPACITY, not its load (`Printing.swift:141-143`, pinned by `PrintingSnapshotTests.swift:117-124`). Either mistake is a silent off-by-one in every downstream decision.

**`owners` cannot come from the queue.** A `print_queue` entry carries `device_type`, `tags`, `controller` and an index, and no id (`Printing.swift:147-152`). Owners come from `operations.directiveID`, so the array holds at most one element until ticket 42 relaxes the index. The type is `[String]` from the start so ticket 46 fills it without a signature change.

**It lives at `Sources/PrintScheduler.swift`, not under `Sources/Steps/`.** Everything in `Steps/` answers `next(_ ctx: StepContext) -> StepResult`; this answers questions about the world and returns no `StepResult`.

---

- [ ] **Step 1:** Write `Tests/PrintSchedulerTests.swift`, copying the fixture idiom from `Tests/Steps/PrintJobTests.swift:16-79`. Six cases: capability filtering, code order, the depth formula, capacity-is-not-depth, owners-from-ops, and an empty depot.
- [ ] **Step 2:** Confirm it fails to compile.
- [ ] **Step 3:** Write `Sources/PrintScheduler.swift` — `Bench`, `RailPolicy`, `PrintOrder`, `benches(at:in:)`.
- [ ] **Step 4:** `swift test --filter PrintSchedulerBenchTests` through the event stream. Expect 6 cases, 0 issues, a `runEnded`.
- [ ] **Step 5:** **Mutation probe.** Change `depth` to `queuedJobCount`, confirm two cases redden, revert. Change it to `queueSize`, confirm one reddens, revert. A green suite under either mutation means the tests were written relative to the implementation.
- [ ] **Step 6:** `check-comments.sh`; commit.

**Done when:** the depth formula has a test that fails if either half of it is dropped.
