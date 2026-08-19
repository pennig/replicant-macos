# 41 — `WorldSnapshot` gains `queuedOperations`

Type: task
Status: open
Blocked by: 40
Labels: directives-architecture, stage-3

A pure addition, landed while the index still enforces uniqueness so that it changes nothing. Ticket 42 relaxes the index into a reader that is already in place.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 9.

**Phase B starts here, and not before Checkpoint E has been run and recorded.** If the observed concurrent-print count at Checkpoint E was 1, Phase A did not work and none of these tickets should start.

**`openOperations` keeps its current meaning until ticket 44.** This ticket only adds.

**The `id` tie-break is not decoration.** `startedAt` is a client clock stamped at dispatch, and two ops written in one transaction can share it. Without a tie-break the order is unstable across reads, and ticket 43's "oldest wins" rule inherits the instability.

Give the memberwise initialiser a `[:]` default for the new argument, or every one of the existing `WorldSnapshot(...)` constructions in tests has to change in this ticket. Say in `## Comments` that the default exists for that reason.

---

- [ ] **Step 1:** Read `WorldSnapshot`'s initialiser first. If the test-facing init is memberwise and unsorted, the sort belongs inside it and the test goes there; if the sort is at the read path (`:237-239`), the test goes against the read path. Decide, then write the failing test.
- [ ] **Step 2:** Confirm it fails to compile.
- [ ] **Step 3:** Add the property at `:29` and fill it at `:353` with `Dictionary(grouping:by:)` over open ops, sorted by `(startedAt, id)`.
- [ ] **Step 4:** All six targets green.
- [ ] **Step 5:** `check-comments.sh`; commit.

**Done when:** two ops sharing a `startedAt` come back in a stable order, with a test.
