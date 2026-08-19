# 30 — `PrintJob` over the three depot-anchored print sites

Type: task
Status: resolved
Blocked by: 27
Labels: directives-architecture, stage-2

`MineFleetPrint.printer(for:in:)` and `MineFleetPrint.fleetEvidenceIsStale` move into a sub-machine that owns the bench rule, the evidence gate and the print deadline. `MineFleetPrint`, `RestockRun` and `EventCourierPrint` adopt it.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 11.

**Scope is three of the five print sites, deliberately.** `EventRun.swift:380` computes a variable deadline (`printSlack` + the longest blueprint print time) measured from `lastOrderedAt` rather than `stepStartedAt`; `RelayRun.swift:401` anchors bench selection on **`carrier.location`, not a depot**, and is the only site that stalls rather than waits on a short rail. Forcing an anchor union, a deadline union, a deadline-anchor union and a terminal-disposition union into a type Stage 3 is about to rewrite buys nothing. Ticket 18 must take all five.

**This ticket carries a real bug fix.** `EventCourierPrint.swift:113` polls `world.openOperation(for: directive.deviceCode, owner: directive.id)` — the launch-pinned host — while the dispatch at `:98` went to `printer.deviceCode`, which substitution may have moved to a different bench. On substitution the poll asks about the wrong queue. It gets its own failing test first.

---

- [x] **Step 1:** Write `Tests/Steps/PrintJobTests.swift`, starting with the failing test for the wrong-device guard: a pinned host that refuses jobs must substitute, and `bench(_:)` must name the substitute.
- [x] **Step 2:** Confirm it fails.
- [x] **Step 3:** Write `Sources/Steps/PrintJob.swift`. Give it a `pollStep: String?` mirroring `TravelTo.confirmStep` — only `EventRun` self-targets, and the three migrated sites hand to a separate polling step.
- [x] **Step 4:** Migrate the three sites, each keeping its own rail gates, its own "already have one" escape and its own polling step. **The deadline stays above the guard**, which is where all three already have it.
- [x] **Step 5:** Delete `MineFleetPrint.swift:55-69` and `:92-101`; repoint `RestockRun:72`, `EventCourierPrint:79,88`, `EventRun:350`.
- [x] **Step 6:** `swift test --filter DirectiveEngineTests`; `check-comments.sh`; commit.

**Done when:** the courier poll watches its own bench with a test proving it, and `MineFleetPrint.printer` has no external caller.

## Comments

Resolved by `b993daf` (PrintJob, the three migrations, the deleted members) and `fe84043` (the review
fix round). `DirectiveEngineTests` 1756/1756/0 at `fe84043`, from 1736 — 15 new `PrintJobTests` cases
plus one suite, then 3 more cases and the courier regression test.

**The plan's fix for the wrong-device poll was unsound and was NOT implemented as written.** The plan
said to poll `job.bench(ctx)`, "the bench the job went to". It is not: the chooser prefers a bench with
no open operation and that filter is owner-blind, so at poll time it excludes the very bench holding
our own print. With two able benches at the depot it returns a different free one, the poll finds
nothing, and `printing` — recomputing the same way — dispatches a SECOND print. Irreversible duplicate
spend, strictly worse than the bug being fixed, and the plan's own two-device fixture could not detect
it. `PrintJob.stillPrinting` answers off the operations table instead (`op.kind == .print &&
op.status.isOpen`, over the already directive-scoped `dispatchedOperations`), disjoined with the old
device-scoped guard so it is a strict superset and no green test could flip.

Six other plan defects, each verified against the code before ruling: `depot` cannot be injected
(`MineFleetPrint` and `RestockRun` call the chooser BEFORE a depot exists, so the resolution moved too,
on the raw `theatreDepot` column — `world.theatreDepot(for:)` is theatre-gated and reddens ~30 tests);
`PrintJob.next` as specified was both wrong (bench → staleness → owned-op, where all three sites order
owned-op → rail → staleness) and dead, so it was not shipped, and `pollStep` went with it; the Step-1
fixture status `"compacting"` is not in `printRefusingStatuses` (`"compacted"` is), so the plan's test
fails against a CORRECT implementation; the deletion range orphaned a doc comment; the verification
grep missed a test-target compile break; and `PrintJob.deadline` would have been a fourth independent
1800, so it became the root with two aliases repointed.

**Left undone, deliberately:** `RestockRun.printing` carries an isomorphic duplicate-spend path — the
chooser recomputes at poll time, the owner-scoped guard misses, `stocking` dispatches again, and
`CommandGovernor` de-dups on `entityCode` and `owner.since`, both of which miss. Pre-existing and
outside this ticket; punch-listed. `MineFleetPrint` does not have the hole.
