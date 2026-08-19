# 33 — `Bench`, `PrintOrder`, and `PrintScheduler.benches`

Type: task
Status: resolved
Blocked by: nothing
Labels: directives-architecture, stage-3

The three values every print site will speak in, and the query that finds a depot's benches. Pure, table-tested, called by nothing yet.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 1.

**The depth formula is the point.** `queueDepth` is `queuedJobCount + (printingSnapshot != nil ? 1 : 0)`. The active job lives in a separate `detail["printing"]` block and is never a `print_queue` entry (`Printing.swift:136-138` against `:144`), and `Device.queueSize` is the bench's CAPACITY, not its load (`Printing.swift:141-143`, pinned by `PrintingSnapshotTests.swift:117-124`). Either mistake is a silent off-by-one in every downstream decision.

**`owners` cannot come from the queue.** A `print_queue` entry carries `device_type`, `tags`, `controller` and an index, and no id (`Printing.swift:147-152`). Owners come from `operations.directiveID`, so the array holds at most one element until ticket 42 relaxes the index. The type is `[String]` from the start so ticket 46 fills it without a signature change.

**It lives at `Sources/PrintScheduler.swift`, not under `Sources/Steps/`.** Everything in `Steps/` answers `next(_ ctx: StepContext) -> StepResult`; this answers questions about the world and returns no `StepResult`.

---

- [x] **Step 1:** Write `Tests/PrintSchedulerTests.swift`, copying the fixture idiom from `Tests/Steps/PrintJobTests.swift:16-79`. Six cases: capability filtering, code order, the depth formula, capacity-is-not-depth, owners-from-ops, and an empty depot.
- [x] **Step 2:** Confirm it fails to compile.
- [x] **Step 3:** Write `Sources/PrintScheduler.swift` — `Bench`, `RailPolicy`, `PrintOrder`, `benches(at:in:)`.
- [x] **Step 4:** `swift test --filter PrintSchedulerBenchTests` through the event stream. Expect 6 cases, 0 issues, a `runEnded`.
- [x] **Step 5:** **Mutation probe.** Change `depth` to `queuedJobCount`, confirm two cases redden, revert. Change it to `queueSize`, confirm one reddens, revert. A green suite under either mutation means the tests were written relative to the implementation.
- [x] **Step 6:** `check-comments.sh`; commit.

**Done when:** the depth formula has a test that fails if either half of it is dropped.

## Comments

**Built and reviewed 2026-08-19**, subagent-driven, on worktree branch
`worktree-directives-stage-3` off local `main` at `b7228f1`. **Not merged** — a merge is
Matt's call.

| Commit | What |
|---|---|
| `8a37d3b` | `feat(directives): PrintScheduler.benches — a depot's benches and their depth` |
| `b42fc7e` | `fix(directives): trim PrintScheduler doc comments to the 3-line budget` |

Two files, 218 insertions, nothing else touched: `DirectiveEngine/Sources/PrintScheduler.swift`
(74 lines) and `DirectiveEngine/Tests/PrintSchedulerTests.swift` (144). No `Package.swift`
edit — the target is path-based. No schema change.

**RED was a real red.** `swift build --build-tests` with only the test file present failed
with `cannot find 'PrintScheduler' in scope`, which is the correct red when no symbol exists
yet.

**GREEN.** `PrintSchedulerBenchTests` through the event stream: 6 tests, 0 issues, one
`runEnded`. Full `DirectiveEngineTests` target: 1607/1607, 0 warnings.

**The mutation probe — the point of this ticket — passed on both halves.**

| Mutation of `depth(of:)` | Test that reddened | How |
|---|---|---|
| → `device.queuedJobCount` | `depthCountsActiveAndQueued` | B1 3→2 and B3 1→0 against a literal dictionary |
| → `device.queueSize` | `capacityIsNotDepth` | idle bench advertising capacity 10 reads depth 10, not 0 |

Two different tests defend the two halves, and both assert literals rather than values
derived from the implementation. Reverted clean after each probe; suite green again before
commit. **Done-when is met:** the depth formula fails if either half is dropped.

**Review.** Task review (spec + quality) returned spec ✅ with one Important finding; scoped
re-review after the fix returned all findings addressed, no new breakage.

**The one finding, and a controller ruling that was reversed.** Three `///` blocks came
verbatim from the plan at 4 lines each — a summary line, a blank `///`, then a two-line
sentence — against `app/CLAUDE.md:41-49`'s hard 3-line declaration-doc budget. I first ruled
they could stand, on the grounds that `DirectiveEngine/Sources` already carries 195
over-budget blocks across 28 files. **That ruling was wrong and the reviewer overturned it.**
`app/CLAUDE.md` says in terms that "Blank `///` lines count", so the policy had already
considered this exact shape; and the 195 are pre-policy. The test that decides it: all nine
files Stage 2 added on 2026-08-17/18 (`Steps/BotPhase.swift`, `ConfirmRow.swift`,
`PrintJob.swift`, `PrintRail.swift`, `ReturnHome.swift`, `StepContext.swift`,
`StepResult.swift`, `StowOrAttach.swift`, `TravelTo.swift`) carry **zero** over-budget blocks.
Post-policy code obeys the rule. Fixed in `b42fc7e` by dropping the three blank separators —
three deleted lines, no sentence lost, matching `Steps/PrintJob.swift:15-17`'s continuous
style. `check-comments.sh` exits 0 but never counted lines; it is regex-only for dated history
and device codes, so it is no defence here.

**Two controller decisions the next executor should not unwind.**

1. The test helper `op(on:owner:status:deviceType:quantity:)` carries `deviceType` and
   `quantity` parameters that none of ticket 33's six cases pass. **Ticket 34 passes them** —
   the plan hands both tasks the same private fixture. Do not trim the signature.
2. The plan's Task 1 code block outranks this ticket's prose enumeration of the six cases.
   Both say six; the plan folds capability and code order into
   `benchesAreCapableDevicesInCodeOrder` and adds `activeJobIsTheLiveOp`.

**Two imports dropped from the plan's blocks**, both genuinely unused: `Foundation` and
`Utils` from the source, `GameServices` and `UniverseModels` from the tests.

**Carried to ticket 34.** `PrintOrder` and `RailPolicy` are declared here and consumed by
nothing until ticket 34 lands. Nothing in the compiler will complain if ticket 34 fails to
plumb them in — that has to be checked by eye.
