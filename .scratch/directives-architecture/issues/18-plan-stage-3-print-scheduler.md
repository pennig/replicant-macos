# 18 — Write the Stage 3 (print scheduler, goal A) plan

Type: task
Status: resolved
Blocked by: 17
Labels: directives-architecture, stage-3, planning

The design is in `spec.md` §Stage 3. This ticket produces the plan and its tickets; no production code. Goal A — printing scales with the number of autofactories — is delivered by the build this plan describes.

**Output:** `.scratch/directives-architecture/plan-stage-3.md` + tickets numbered after Stage 2's, `Labels: directives-architecture, stage-3`.

---

- [x] **Step 1: Pin the facts the plan needs**

Read and record in `## Comments`: how the printer's `print_queue` snapshot reaches the `Device` row today (`Reconciler.swift` `printing` block promotion, `Device.printQueue` or equivalent field); which readers depend on `operation_one_open_per_device` (`Reconciler.completeOpenOperation` `fetchOne`, `WorldSnapshot.openOperations` uniquing, `DeadlineScheduler` active-only queries, `SidebarFeature` progress, `PrintQueueFeature`); the five enqueue sites as they stand after Stage 2 (`PrintJob` callers).

- [x] **Step 2: Invoke `superpowers:writing-plans`** against spec §Stage 3 with these constraints:

- `PrintScheduler` is a pure value in `DirectiveEngine` (`benches(at:in:)`, `choose(job:at:in:)`), tested as a table; `PrintJob` (Stage 2) calls `choose`.
- Index decision (D7): a migration replacing `operation_one_open_per_device` with `WHERE "status" = 'active'` plus a NEW partial unique index for non-print enqueued kinds if any exist (audit `completion(for:)` — only `.print` is `.enqueued`; if so, no second index). `completeOpenOperation` for `print.completed` selects the live print op by `detail.params.device_type` == the event's device type, oldest first; `WorldSnapshot` gains `queuedOperations: [String: [Operation]]` and `openOperations` becomes "the active op per device"; every reader listed in Step 1 is a task.
- Demand: `RestockRun` and `MineFleetPrint` compute demand per theatre and dispatch one job per free bench per tick (the `EventRun.printing` shape); `RestockRun.idleCap` = `min(10, 3 × benches)` (state the formula; the operator can retune); the reserve rail is checked per job.
- `PrintQueueFeature` joins `operations.directiveID` → shows the owning run's title beside each queued job; the detail pane's Print Queue readout gains the same.
- Acceptance: with three autofactories at one depot and a mine-fleet shortfall of ≥ 3 types, three prints are in flight simultaneously within two ticks; with one autofactory behaviour equals today's; a co-tenant's job never blocks or extends another run's deadline (test through the real engine).

- [x] **Step 3: Self-review; stop for operator review.**

## Comments

Resolved 2026-08-19 against `main` at `3ae52be`. Output: `.scratch/directives-architecture/plan-stage-3.md` (15 tasks) and tickets **33-47**, indexed in `plan.md`. No production code.

**Step 1's facts were pinned by four parallel research passes. The Swift LSP tool was not available to any of them**, so every `file:line` in the plan was established by exhaustive `rg` sweeps and direct reads. That is accurate for what it claims but weaker than LSP for "is anything else calling this?", so the three tickets that delete symbols (37, 44, 47) each say to confirm with LSP and then with a build.

**Three claims in this ticket and in Stage 2's hand-off note did not survive being read against the code.** Each would have produced a task that changed nothing and reported success:

1. **`RelayRun`'s print dispatch is in `acquire` (`RelayRun.swift:348`), not `printing`.** Stage 2's hand-off pointed at `RelayRun.swift:359`, which is a pure poll step that dispatches nothing.
2. **`EventRun.printing` does not dispatch "one job per free bench per tick".** Single `first(where:)` at `:373`, single `.dispatch` at `:380`, no loop over printers. It fans out across *successive* ticks by re-entering its own step. Its own comment at `:318-319` says so.
3. **The index is not what blocks goal A.** `operation_one_open_per_device` is keyed on `entityCode`, so three benches may each hold a live op today. What blocks it is that `MineFleetPrint.printing` waits for the whole eleven-device recipe or thirty minutes before deciding again (`:124-138`). That reframing is what split the plan into two phases, and it means **Phase A delivers the acceptance criterion with no schema change at all.**

**Seven departures from this ticket's own constraints, each recorded in the plan with its evidence:**

- **"Within two ticks" is unreachable.** `MissionAction.dispatch` carries one command (`MissionStepMachine.swift:21`), `nextAction` is called once per directive per evaluation (`DirectiveEngine.swift:261`), the tick is 5 s (`:50`). N benches take N ticks. The alternative breaks the spec's own "one action per evaluation" invariant for ten seconds of latency. Restated as N ticks.
- **`Bench.owners` is a 0-or-1 array until the index relaxes**, because a `print_queue` entry carries no id (`Printing.swift:147-152`). Typed `[String]` from the start so ticket 46 fills it without a signature change.
- **`completeOpenOperation` cannot select by `detail.params.device_type`.** The field is absent on ops adopted from a device snapshot (`Reconciler.swift:135,190`), and the event's device type is discarded before the function is reached (`:439-445`). Worse, **nothing in this repository evidences whether the server puts the printer's type or the printed device's type in that field.** Ticket 43 implements oldest-first; Open Question 3 asks for one live probe.
- **The rail-short policy stays split 4-1** and becomes a `PrintOrder` parameter. Both sides are documented as deliberate (`RestockRun.swift:82-85` against `RelayRun.swift:344`).
- **`idleCap = min(10, 3 × benches)` is implemented verbatim and will usually change nothing**, because `targets.count` binds (automation-brain ticket 14 measured it at 1). Ticket 39's test manufactures the case where the cap binds and says so.
- **`PrintScheduler` lives beside `Steps/`, not inside it** — everything in `Steps/` answers `next(_:) -> StepResult` and this answers questions about the world.
- **No second partial unique index is needed.** This ticket asked for the audit; `.print` is provably the only kind that produces an `.enqueued` op (`CommandClient.swift:351-359` — `.enqueued` is unreachable through the `default:` arm).

**The finding that shapes Phase B: relaxing the index accomplishes nothing on its own.** `CommandClient.swift:247-262` proactively supersedes a device's other live ops on every confirm, and names the index as its reason. Four more sites pick an arbitrary row from an unordered `fetchOne` over `liveCases`. The plan lists all five as B1-B5 and ticket 42 carries the migration and the supersede scope in one commit, because either alone is worse than neither.

**Eleven deliberate behaviour changes (C1-C11), each with a named test.** Stage 2 was behaviour-preserving by default; Stage 3 cannot be, because unifying five print sites means four of the five policy rows change at two of them. C11 was found while designing the chooser and is a live cross-run bug: `PrintJob.bench` falls back to a busy bench (`:46`), the caller's owner-scoped guard cannot see a co-tenant's op there, and the dispatch supersedes it — the co-tenant then loses track of a print still running.

**Punch-list line 255 and automation-brain ticket 14 are both in scope and both close in Phase A** — 255 in ticket 38, ticket 14 in ticket 39. They are the same failure shape as goal A, which is why they belong here rather than anywhere else.

**Four open questions for the operator**, in the plan's own section. Two block nothing; Open Question 3 blocks ticket 43's refinement and Open Question 4 blocks ticket 46's capacity arithmetic. Both want one live observation rather than a decision.
