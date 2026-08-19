# 34 — `PrintScheduler.choose` and `PrintScheduler.onOrder`

Type: task
Status: resolved
Blocked by: 33
Labels: directives-architecture, stage-3

The chooser and the netting query. `choose` names the bench that takes a job; `onOrder` says what the owner already has coming, so a mission can decide again next tick without ordering twice.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 2.

**`choose` returns nil when no bench is free, and that is a behaviour change (C11).** `PrintJob.bench` currently ends `?? able.min { ... }` (`PrintJob.swift:46`), returning a busy bench when all are busy. The caller's guard is owner-scoped, so a co-tenant's op there is invisible, the mission dispatches, and `CommandClient.swift:247-262` marks the co-tenant's op `.superseded` — that run then loses track of a print still running. Under ticket 38's fan-out this goes from rare to routine.

**`onOrder` counts ops only, deliberately.** A queue entry cannot be attributed to a directive. Tag matching would cover three sites and miss the two that print untagged (`RestockRun.swift:127`). The gap is Open Question 2 in the plan, not a half-built feature here.

This ticket adds `Operation.printedDeviceType` and `printedQuantity` to `GameModels`, following the existing `travelSnapshot` extension pattern (`Device.swift:722-730`). If `JSONValue` has no `intValue`, add one in `Utils` with its own test rather than reaching through `doubleValue` at every call site.

---

- [x] **Step 1:** Write the `choose` suite (5 cases) and the `onOrder` suite (5 cases), including the two that pin what must NOT count: a co-tenant's op, and an op that names no device type.
- [x] **Step 2:** Confirm both fail to compile.
- [x] **Step 3:** Implement both, plus the two `Operation` accessors.
- [x] **Step 4:** Run `DirectiveEngineTests` and `GameModelsTests` whole. Baseline at `3ae52be` is 1782/1782/0 over 226 suites.
- [x] **Step 5:** **Mutation probe.** Drop `choose`'s `activeJob == nil` conjunct and confirm the all-busy case reddens. Reverse the sort in `benches` and confirm two cases redden. Revert both.
- [x] **Step 6:** `check-comments.sh`; commit.

**Done when:** an op with `detail: {}` — the shape `Reconciler` inserts for an adopted op (`Reconciler.swift:135,190`) — is provably not counted as a zero.

## Comments

**Built and reviewed 2026-08-19**, subagent-driven, on worktree branch
`worktree-directives-stage-3` off local `main` at `b7228f1`. **Not merged** — merging is Matt's
call. Every claim below was checked against the source or the event stream, not taken from a
subagent's summary.

| Commit | What |
|---|---|
| `06507f5` | `feat(directives): PrintScheduler.choose and onOrder` |
| `db1e610` | `test(directives): pin PrintScheduler.choose's activeJob guard` |
| `a358fdf` | `test(directives): pin onOrder's kind filter, drop a stale doc comment` |

`choose(_:at:in:)` and `onOrder(for:at:in:)` land, plus `Operation.printedDeviceType`/
`printedQuantity` and `Utils.JSONValue.intValue` with a new `UtilsTests` target — all four
mandated by the brief's Step 3, not scope drift.

**Two guards shipped with no defender, and both were found only by mutation probing.**

1. The brief predicted that dropping `choose`'s `$0.activeJob == nil` conjunct would redden
   `allBusyYieldsNil`. It does not: that fixture gives both benches a `printing:` block, so
   `queueDepth == 1` and the `queueDepth == 0` conjunct alone excludes them. Closed by
   `opRowBeatsSnapshot`, which puts an open op on a bench whose device snapshot is still empty —
   the reachable state C11 is about, since `openOperation(for:)` reads the ops table while
   `queueDepth` reads the device `detail` blob.
2. `onOrder`'s `kind == .print` conjunct was equally undefended: the shared `op(...)` fixture
   hardcoded the kind with no parameter to vary it. Closed by `nonPrintKindDoesNotCount`.

**Done when:** both conjuncts of `choose` and all four filters of `onOrder` now have a test that
reddens when that filter alone is deleted.
