# 34 — `PrintScheduler.choose` and `PrintScheduler.onOrder`

Type: task
Status: open
Blocked by: 33
Labels: directives-architecture, stage-3

The chooser and the netting query. `choose` names the bench that takes a job; `onOrder` says what the owner already has coming, so a mission can decide again next tick without ordering twice.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 2.

**`choose` returns nil when no bench is free, and that is a behaviour change (C11).** `PrintJob.bench` currently ends `?? able.min { ... }` (`PrintJob.swift:46`), returning a busy bench when all are busy. The caller's guard is owner-scoped, so a co-tenant's op there is invisible, the mission dispatches, and `CommandClient.swift:247-262` marks the co-tenant's op `.superseded` — that run then loses track of a print still running. Under ticket 38's fan-out this goes from rare to routine.

**`onOrder` counts ops only, deliberately.** A queue entry cannot be attributed to a directive. Tag matching would cover three sites and miss the two that print untagged (`RestockRun.swift:127`). The gap is Open Question 2 in the plan, not a half-built feature here.

This ticket adds `Operation.printedDeviceType` and `printedQuantity` to `GameModels`, following the existing `travelSnapshot` extension pattern (`Device.swift:722-730`). If `JSONValue` has no `intValue`, add one in `Utils` with its own test rather than reaching through `doubleValue` at every call site.

---

- [ ] **Step 1:** Write the `choose` suite (5 cases) and the `onOrder` suite (5 cases), including the two that pin what must NOT count: a co-tenant's op, and an op that names no device type.
- [ ] **Step 2:** Confirm both fail to compile.
- [ ] **Step 3:** Implement both, plus the two `Operation` accessors.
- [ ] **Step 4:** Run `DirectiveEngineTests` and `GameModelsTests` whole. Baseline at `3ae52be` is 1782/1782/0 over 226 suites.
- [ ] **Step 5:** **Mutation probe.** Drop `choose`'s `activeJob == nil` conjunct and confirm the all-busy case reddens. Reverse the sort in `benches` and confirm two cases redden. Revert both.
- [ ] **Step 6:** `check-comments.sh`; commit.

**Done when:** an op with `detail: {}` — the shape `Reconciler` inserts for an adopted op (`Reconciler.swift:135,190`) — is provably not counted as a zero.
