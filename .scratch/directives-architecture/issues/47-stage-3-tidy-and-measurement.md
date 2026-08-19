# 47 — The governor, the doc comments, and the measurement

Type: task
Status: open
Blocked by: 46
Labels: directives-architecture, stage-3

The tidy-up, and the ticket that records what Stage 3 actually achieved.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 15.

**The governor question, and the answer this ticket expects.** `CommandGovernor` de-dups on `(directiveID, step, entityCode, kind, paramsDigest, startedAt >= owner.since, status != .failed)` (`:86-101`), so two identical prints from one run in one step on one bench are refused as `.deferred(.duplicate)`. On the evidence in this plan **no mission needs that**: `MineFleetPrint` orders `quantity: n` in one job rather than n jobs (`MineFleetPrint.swift:114-118`), and `RestockRun` orders one relay at a time against a demand `onOrder` decrements. Write the test that pins the guard as intended behaviour. Only if a mission genuinely needs two identical jobs does the digest gain a discriminator — and that is a change with its own test, not a one-line relax. Changing a de-dup guard to permit something nothing asks for is how duplicate spends get built.

**The doc comments the relax made false.** Each states or relies on "one open op per device": `Operation.swift:11-16`, `:104-106`, `:260-261`; `WorldSnapshot.swift:26-29`, `:182`; `OperationRetention.swift:42-43`; `CommandClient.swift:208-210`, `:248-249`; `Reconciler.swift:179-180`. Also `docs/superpowers/specs/2026-07-27-orrery-travel-indicators-design.md:87` — that one is a shipped design doc and a record of what was decided then, so add a line saying the invariant changed and where rather than rewriting it.

**Orphans to check, then delete:** `RelayRun.hubFreshness`, `PrintRail.hubFreshness` (if `RelayRun` was its only reader), `EventRun.printsInFlight` (deleted in ticket 36 — confirm nothing calls it), `RestockRun.pollInterval` if it is still there. An empty `findReferences` is a cold index, not proof. Delete, build, and let the compiler answer.

**Count `PrintJob.bench(_:for:)`'s callers.** Tickets 36, 37 and 38 all call `PrintScheduler.choose` directly, which may leave `EventCourierPrint` as its only caller — a one-caller wrapper over a one-line call is a redirect, not a seam. If that is what you find, delete it and let `EventCourierPrint` call the scheduler like everything else. `PrintJob.hasBench(_:)` stays regardless: three sites need "does this depot have any printer at all" as a question distinct from "can one take this job".

---

- [ ] **Step 1:** Write and settle the governor test; record the decision.
- [ ] **Step 2:** Correct the doc comments listed above.
- [ ] **Step 3:** Delete the orphans, confirming each with LSP and then a build.
- [ ] **Step 4:** Work the punch list. Close line 249 (two print sites outside `PrintJob` — tickets 36 and 37) and line 255 (`RestockRun` chooser-scoped duplicate spend — ticket 38). Re-read line 13 (`MineFleetPrint.stocking` deadline) — ticket 38 deleted that guard, so either the question is moot and you say why, or it stays open with a fresh reason. Re-read line 246 (travel sites on the unowned guard) — ticket 44 changed what that guard sees, so restate it against the new meaning rather than closing it.
- [ ] **Step 5:** Record the measurement in `## Comments`: the borrow count at each of the five checkpoints against the 70 measured at `3ae52be`; **the print policy count, five-ways-split before and one after**, enumerating each of the five rows with its single answer and the ticket that produced it; the observed concurrent-print counts from Checkpoints E and F; and every case where a mutation probe failed to redden, with what was done about it.
- [ ] **Step 6:** From-scratch `swift build --build-tests`, then all eight targets.
- [ ] **Step 7:** Commit.

**Done when:** the five-way policy split is enumerated as one answer each, and every doc comment asserting one-open-op-per-device is gone.
