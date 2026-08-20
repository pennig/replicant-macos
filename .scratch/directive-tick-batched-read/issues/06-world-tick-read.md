# 06 — `WorldTick.read`, one transaction for the whole tick

Status: ready-for-agent
Blocked by: 05

One `database.read` produces the running directives, the core, and every
slice. Nothing else opens a transaction.

The read-counting test is the point of this ticket: it makes the 22× read
impossible to reintroduce without a red test.

Full steps and the exact signatures: `../plan.md` → **Task 6**.

**Done when:** `WorldTickReads.opensExactlyOneReadTransaction` passes with five
running directives and a read count of 1; `composesASnapshotPerRunningDirective`
passes; the DirectiveEngine suite passes untouched.
