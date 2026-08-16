# 18 — Write the Stage 3 (print scheduler, goal A) plan

Type: task
Status: open
Blocked by: 17
Labels: directives-architecture, stage-3, planning

The design is in `spec.md` §Stage 3. This ticket produces the plan and its tickets; no production code. Goal A — printing scales with the number of autofactories — is delivered by the build this plan describes.

**Output:** `.scratch/directives-architecture/plan-stage-3.md` + tickets numbered after Stage 2's, `Labels: directives-architecture, stage-3`.

---

- [ ] **Step 1: Pin the facts the plan needs**

Read and record in `## Comments`: how the printer's `print_queue` snapshot reaches the `Device` row today (`Reconciler.swift` `printing` block promotion, `Device.printQueue` or equivalent field); which readers depend on `operation_one_open_per_device` (`Reconciler.completeOpenOperation` `fetchOne`, `WorldSnapshot.openOperations` uniquing, `DeadlineScheduler` active-only queries, `SidebarFeature` progress, `PrintQueueFeature`); the five enqueue sites as they stand after Stage 2 (`PrintJob` callers).

- [ ] **Step 2: Invoke `superpowers:writing-plans`** against spec §Stage 3 with these constraints:

- `PrintScheduler` is a pure value in `DirectiveEngine` (`benches(at:in:)`, `choose(job:at:in:)`), tested as a table; `PrintJob` (Stage 2) calls `choose`.
- Index decision (D7): a migration replacing `operation_one_open_per_device` with `WHERE "status" = 'active'` plus a NEW partial unique index for non-print enqueued kinds if any exist (audit `completion(for:)` — only `.print` is `.enqueued`; if so, no second index). `completeOpenOperation` for `print.completed` selects the live print op by `detail.params.device_type` == the event's device type, oldest first; `WorldSnapshot` gains `queuedOperations: [String: [Operation]]` and `openOperations` becomes "the active op per device"; every reader listed in Step 1 is a task.
- Demand: `RestockRun` and `MineFleetPrint` compute demand per theatre and dispatch one job per free bench per tick (the `EventRun.printing` shape); `RestockRun.idleCap` = `min(10, 3 × benches)` (state the formula; the operator can retune); the reserve rail is checked per job.
- `PrintQueueFeature` joins `operations.directiveID` → shows the owning run's title beside each queued job; the detail pane's Print Queue readout gains the same.
- Acceptance: with three autofactories at one depot and a mine-fleet shortfall of ≥ 3 types, three prints are in flight simultaneously within two ticks; with one autofactory behaviour equals today's; a co-tenant's job never blocks or extends another run's deadline (test through the real engine).

- [ ] **Step 3: Self-review; stop for operator review.**
