# Directives Stage 3 — Print Scheduler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Tickets live one per file under `.scratch/directives-architecture/issues/`; steps use checkbox (`- [ ]`) syntax for tracking. Claim a ticket by setting `Status: claimed` before touching code; resolve it by setting `Status: resolved` and appending a `## Comments` note with the commit sha(s).

**Goal:** Goal A — printing scales with the number of autofactories. Today a depot with three autofactories prints at the rate of one, because `MineFleetPrint` and `RestockRun` dispatch one job and then wait up to thirty minutes for its clone before deciding again. This plan gives `DirectiveEngine` one `PrintScheduler` that every print site calls, turns the two print-only missions from serial into fan-out, and then — separately, and second — makes the substrate able to hold more than one live print per bench.

**Architecture:** Two phases with a hard line between them, because they are two different scaling axes and only one of them needs a migration.

- **Phase A — breadth, across benches.** Three autofactories should carry three jobs at once. `operation_one_open_per_device` is keyed on `entityCode`, so three ops on three devices are already legal; nothing in the schema stops this today. What stops it is that each mission holds one job at a time and blocks. Phase A adds `PrintScheduler` (`benches`, `choose`, `onOrder`), moves all five dispatch sites onto it, and replaces each mission's block-until-clone loop with a demand computation netted against what is already on order. **Phase A changes no schema and delivers the ticket's acceptance criterion.**
- **Phase B — depth, within one bench.** When demand exceeds bench count, jobs should queue. That needs the index relaxed to `WHERE "status" = 'active'`, and — the finding that matters — four other changes, without which relaxing the index accomplishes nothing at all, because `CommandClient` proactively supersedes a device's other live ops on every confirm.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26+), Composable Architecture, SQLiteData + GRDB, StructuredQueries, Swift Testing, swift-openapi-generator.

**Spec:** `.scratch/directives-architecture/spec.md` §Stage 3 — read it first, together with "Where the spec did not survive measurement" below, which records seven places this plan departs from the spec's provisional shape and why. D1 and D7 are the locked decisions in play.

**Parent plan:** `.scratch/directives-architecture/plan.md`. **Punch list:** `.scratch/directives-architecture/punch-list.md`.

**Measured against:** local `main` at `3ae52be` (Stages 0–2 landed and merged), 2026-08-19.

## Global Constraints

Every task's requirements implicitly include this section. Copied from `plan.md`, with the Stage 3 additions marked.

- **LSP setup, once per worktree, before anything else:** `cd app/Modules && swift build --build-tests`, then `./scripts/link-index-store.sh`. Without the second the index returns zero references silently. LSP root is `app/Modules/`, not the repo root. Measured on 2026-08-19: a cold build plus link takes **166 s** and reports **2346 units**.
- **Use Swift-LSP for navigation and verification**, not grep, for anything in `app/Modules/`. An empty `findReferences` on same-session code is a cold index, never proof a symbol is unused — fall back to `swift build --build-tests`. **Stage 3 addition: ticket 18's own fact-finding ran without LSP** — the tool was absent from the research agents' toolsets, so every `file:line` in the tables below was established by exhaustive `rg` sweeps and direct reads. Treat them as accurate but re-verify with LSP before deleting anything, and say which tool answered.
- **Read test results from the Swift Testing JSON event stream** via the `swift-test-event-stream` skill. Never parse console text; a grep for "fail" false-positives on test method names. **Stage 3 addition: there are SIX targets, not five.** Run `DirectiveEngineTests`, `GameServicesTests`, `GameSyncTests`, `GameModelsTests`, `DirectivesFeatureTests` **and `PrintQueueFeatureTests`** after every ticket that touches their module. Phase B additionally touches `GameDatabaseTests` and `DevicesFeature` — run those too when it does.
- **Migrations are append-only.** A schema change appends a new `SchemaMigration` to `GameDatabase.manifest` (`app/Modules/GameDatabase/Sources/GameDatabase.swift:47`). Never edit, rename or reorder a shipped one. `SchemaManifestTests` freezes the identifier list; `GoldenSchemaTests` snapshots the schema — regenerate with `RC_REGENERATE_SCHEMA_FIXTURE=1` only when the change is intended, and say so in the commit. **Phase A changes no schema. If a Phase A task finds itself writing a migration, stop — it has left scope.** Exactly one task in this plan (Task 10) writes one.
- **Comment budget is hard:** file header ≤ 10 lines, `///` ≤ 3 lines, inline `//` ≤ 2 lines. No dated history, no rejected alternatives, no rationale for *why we chose this* — that goes to `app/.claude/memory/` (with an index line in `app/.claude/memory/MEMORY.md`) or this plan. Run `./app/scripts/check-comments.sh <paths>` from the repo root.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = module or service name.
- **Loud test doubles:** a shared client's `testValue` uses `unimplemented(...)`; rich fixtures belong on `previewValue`.
- **UI:** never hard-code colours, spacing or font sizes — use `DesignSystem.swift` tokens. **Every system and location designation renders in a monospace token** (`app/CLAUDE.md:32`): `.rcMono`, `.rcMonoSmall`, or the prominence-matched `.rcTitleMono` / `.rcHeadlineMono` / `.rcBodyEmphMono`. A **run title is prose, not a designation** — it does not go in a mono token. List-row structs live in their own file, never beside a `#Preview`.
- **Git:** commit directly to `main`, or to a worktree branch merged to `main` on review. No PRs, no pushing, `origin` is not part of the workflow. One commit per ticket step group is fine; the ticket's `## Comments` records the shas.
- **Naming:** the domain word is **Theatre** (British). A **bench** is one print-capable device's queue. A **lease** is a device reserved by a running directive row. A **scoped** tag carries a theatre or belt; an **unscoped** tag does not.
- **`Sources/Steps/` needs no `Package.swift` edit.** `DirectiveEngine` is a path-based target (`path: "DirectiveEngine/Sources"`, `Package.swift:272`), so SPM picks up subdirectories automatically. `PrintScheduler` is a **peer of `Steps/`, not a member** — it is a scheduler over the world, not a step frame — so it lives at `DirectiveEngine/Sources/PrintScheduler.swift`.
- **`PrintScheduler` and `Bench` are `internal`.** Nothing outside `DirectiveEngine` consumes them; tests reach them through `@testable import DirectiveEngine`. Code blocks below are written without access modifiers where the file's convention allows; match the neighbouring file.
- **Pin every constant explicitly; prove the pin by mutation.** The Stage 2 review found ten guards and constant values that could be deleted or changed with the whole suite green, because **every reader wrote its fixture relative to the constant** (`-PrintJob.deadline - 1`). A Stage 3 test that asserts a value must write the literal, and the implementer must confirm by mutation that changing the constant reddens exactly that test. This applies to every new constant this plan introduces, and there are four.
- **Behaviour-preserving is NOT the default here, unlike Stage 2.** Migrating `EventRun` and `RelayRun` onto one scheduler changes behaviour at four measured policy rows. Every such change is named in its task, gets its own test, and is listed in "Deliberate behaviour changes" below. A change not on that list is out of scope.

---

## What the measurement found (ticket 18, Step 1)

Measured against `main` at `3ae52be`. Every row was read; none is inferred from the audit.

### The five print dispatch sites, as they stand after Stage 2

`rg "kind: .print"` over `app/Modules` returns exactly five production sites, all in `DirectiveEngine/Sources`.

| # | Site | Dispatch | Step | Prints | Bench chosen by | Deadline | Rail short |
|---|---|---|---|---|---|---|---|
| 1 | `RestockRun` | `RestockRun.swift:125` | `stocking` | `ftl_relay`, no quantity, no tags | `PrintJob.bench` | `PrintJob.deadline` | `.wait` (`:116`) |
| 2 | `MineFleetPrint` | `MineFleetPrint.swift:114` | `stocking` | one recipe type, `quantity: missing[type]`, fleet/carrier tag | `PrintJob.bench` | `PrintJob.deadline` | `.wait` (`:94`) |
| 3 | `EventCourierPrint` | `EventCourierPrint.swift:98` | `printing` | `matrix_container` x1, root tag | `PrintJob.bench` | `PrintJob.deadline` | `.wait` (`:88`) |
| 4 | `EventRun` | `EventRun.swift:380` | `printing` | one blueprint-closure type, theatre tag | **hand-rolled**, `EventRun.swift:362-364` | variable, `printSlack` + longest print, from `lastOrderedAt` | `.wait` (`:349`) |
| 5 | `RelayRun` | `RelayRun.swift:348` | **`acquire`** | `ftl_relay`, no quantity, no tags | **hand-rolled** `RelayRun.hub(near:in:)`, `:149-157` | `PrintJob.deadline`, checked in `printing` (`:375`) | **`.stall(.printStockShort)`** (`:344`) |

**Correction to Stage 2's hand-off note.** It said `EventRun.swift:297` and `RelayRun.swift:359` were the two remaining print sites. `EventRun.swift:297` is the head of the `printing` function whose dispatch is at `:380` — right function, and Stage 3 targets it. **`RelayRun.swift:359` is wrong.** `RelayRun.printing` is a pure poll step that dispatches nothing; the `enqueue_print` is issued from `acquire` (`RelayRun.swift:305-353`). A task that migrated `RelayRun.printing` would change nothing and report success.

### The five sites disagree on five separate policies

This is the actual content of Stage 3. Every row is a measured divergence, not a stylistic one.

| Policy | The split |
|---|---|
| **Rail short** | `.wait` at four sites; `.stall(.printStockShort)` at `RelayRun.swift:344`. Not an oversight on either side: `RestockRun.swift:82-85` documents "**Every branch that declines is a `.wait`, never a `.stall`** … dressing idle calm up as a halt spends an operator's attention on nothing", and `RelayRun` is acquiring the one relay its whole run depends on. The two intents genuinely differ. |
| **Depot anchor** | `PrintJob.depot` is `directive.theatreDepot ?? pinned device location` (`PrintJob.swift:30-32`). `EventRun` uses `world.theatreDepot(for:)` with **no fallback** (`:298`). `RelayRun.hub` uses **`carrier.location`** (`:150`) — a device location, which `PrintJob.swift:20-21` explicitly warns against: "Never a device location — a hub that unfurls elsewhere must not drag the run with it". |
| **Bench capability** | `PrintJob.bench` uses `acceptsPrintJobs && !isCarrierHull`. `EventRun` uses **`deviceType == "autofactory"`** (`:363`) — the only such string match in production, and blind to any print-capable vessel not typed `autofactory`. `RelayRun.hub` uses `acceptsPrintJobs`, carrier hulls **allowed**. `PrintQueueFeature` uses a fourth predicate, `Device.canPrint` = `features.contains("print")` (`Printing.swift:132`). |
| **Bench busy** | Owner-scoped `openOperation(for:owner:)` at sites 1-3. Owner-**un**scoped `openOperation(for:)` at `EventRun.swift:373`. **No busy guard at all** in `RelayRun.acquire`. |
| **Fleet freshness before spending** | Depot-wide `PrintJob.fleetEvidenceIsStale` at sites 2, 3 and 4. Per-device `hub.updatedAt > hubFreshness` at `RelayRun.swift:328`. **None at `RestockRun`** — the only `PrintJob` adopter that spends without a pre-spend sweep. |

### Why goal A is blocked today, and by what

**Not by the index.** `operation_one_open_per_device` is keyed on `entityCode` (`Operation.swift:284-287`), so three benches may each hold one live op right now. The blocker is that both print-only missions are strictly serial:

- `MineFleetPrint.stocking` dispatches one job then moves to `printing`; `printing` returns `.wait` until either the **whole recipe** is satisfied or `PrintJob.deadline` (1800 s) expires (`MineFleetPrint.swift:124-138`). The recipe is eleven devices. Two of three autofactories stand idle for up to thirty minutes per job.
- `RestockRun.stocking` dispatches one relay then moves to `printing`; `printing` hands back to `stocking` as soon as no op of its own is open (`RestockRun.swift:159-161`), which is faster, but `stocking` then re-guards on its own open op at the **chosen** bench and declines.

**`RestockRun` already fans out — by accident, as a duplicate spend.** `nextAction` recomputes the bench every tick (`RestockRun.swift:62-66`), and `DirectiveExecutor` does not rewrite `directive.deviceCode` on dispatch. So next tick `PrintJob.bench` skips the bench now carrying our own op, returns a different free one, the owner-scoped guard at `:95` finds nothing there, and `stocking` orders **a second relay**. `CommandGovernor` misses on both keys — the entity code differs and `advanceStep` re-stamps `stepStartedAt`. This is punch-list line 255, filed for this ticket.

That is the whole of Phase A in one sentence: **the over-print bug and goal A are the same mechanism.** The fan-out already happens; it is unaccounted, so the extra prints are waste instead of throughput. Phase A nets demand against what is on order and makes the fan-out deliberate.

### The print queue snapshot, the depth source D7 names

| Question | Answer | Evidence |
|---|---|---|
| Does the device payload carry `print_queue`? | Yes | `openapi-2.5.0-edits.json:908`, `DeviceStatusSchema.print_queue` |
| Does it survive ingestion? | Yes, verbatim, inside the `detail` JSON blob | `Device.detailJSON(from:)` `Device.swift:142-159` keeps everything not in `coreKeys` (`:124-131`) |
| Is it persisted? | Yes | column `"detail" TEXT NOT NULL DEFAULT '{}'`, `Device.swift:756`; no `ALTER TABLE "devices"` exists anywhere |
| Is it already readable in Swift? | Yes | `Device.printQueueItems: [PrintQueueItem]` `Printing.swift:144`; `queuedJobCount` `:159` |
| What is in one entry? | `index`, `deviceType`, `controller`, `tags` — **no id** | `Printing.swift:70-88`, `:147-152`; fixture `PrintingSnapshotTests.swift:56-71` |
| Is the active job in it? | **No** — the active job is a separate `detail["printing"]` block | `Printing.swift:136-138` against `:144`; the two are disjoint |
| Is there a depth scalar? | Not on the device. `queue_length` exists only on `DeviceCommandResponseSchema` (`openapi-2.5.0-edits.json:2538`) and is read nowhere | `rg "queueLength"` returns zero first-party hits |
| Is `Device.queueSize` the depth? | **No, it is the capacity** | `Printing.swift:141-143`; pinned by `PrintingSnapshotTests.swift:117-124` — "an idle autofactory advertises a capacity with an empty `print_queue`" |
| How fresh is it? | **Only as fresh as the last full device read.** The SSE path writes location, containment and `updatedAt` only | `Reconciler.applyEventFields` `:229-264`, `applyDeviceEvent` `:271-320` |

Two consequences the plan is built on. **Depth is `queuedJobCount + (printingSnapshot != nil ? 1 : 0)`**, not `queuedJobCount` and not `queueSize`. And **a queue entry carries no id**, so `Bench.owners` cannot come from the queue — it comes from `operations.directiveID`. Depth and owners are two independent sources that legitimately disagree: a job enqueued by hand from the Print Queue screen adds depth with no owning row. Every decision below says which of the two it trusts.

### Relaxing the index is five changes, not one

The index (`Operation.swift:281-289`) is migration **#20 of 46** in the manifest (`GameDatabase.swift:68`); `Operation.addOwnerColumns` is #44 and already created the covering index `operation_by_directive (directiveID, startedAt)`, so the Stage 3 join is indexed. Relaxing it requires, in the same phase:

| # | Site | What it does | Why the relax alone fails without it |
|---|---|---|---|
| B1 | `CommandClient.swift:247-262` | on confirm, `fetchAll(entityCode + liveCases)`, then marks every **other** open op `.superseded` | Print #2 supersedes print #1. Its comment at `:248-249` names the index as the reason. **The hard blocker: with the index relaxed and this untouched, N-deep queues still cannot exist.** |
| B2 | `Reconciler.swift:121-126` | `entityCode + openCases` into `fetchOne`, then adopt / promote / complete-as-stale | Picks an arbitrary row among N; the "different activity" arm (`:182-195`) completes a random enqueued sibling as stale |
| B3 | `Reconciler.swift:284-286` (SSE path) and `:451-455` (`completeOpenOperation`) | `entityCode + liveCases` into `fetchOne`, no `ORDER BY` | A `print.completed` can close enqueued job #3 and leave the running job open forever |
| B4 | `WorldSnapshot.swift:237-239` and `:353` | `Dictionary(…, uniquingKeysWith: { _, last in last })` keyed by `entityCode` | Silently drops N-1 ops in unspecified row order; every engine consumer below it degrades |
| B5 | `DeviceDetailView.swift:41-45` | `operations.first { entityCode == code && status.isOpen }` over a `startedAt DESC` fetch | A bench that is actively printing renders **"Queued — awaiting start."** with no progress bar (`ActiveTaskCard.swift:149-153`), because a later-started enqueued sibling wins the pick |

**No second partial unique index is needed.** Ticket 18 asked for the audit; the answer is clean. `completion(for:)` (`CommandClient.swift:351-359`) returns `.enqueued` for `.print` and nothing else — `.enqueued` is unreachable through the `default:` arm, which yields only `.deadline` or `.immediate`. `Reconciler` inserts only `.active` rows. So `.print` is provably the only kind that produces an enqueued operation.

**Nothing uses the constraint as flow control.** `rg "SQLITE_CONSTRAINT|onConflict|INSERT OR"` over first-party sources returns two hits, both star upserts. The codebase prevents the violation proactively (B1, and `Reconciler.swift:179-180`) rather than catching it.

**Verified unaffected by the relax** — `.active`-scoped, id-scoped, or set-collapsing: `SidebarProgress.swift:33,44`; `DeadlineScheduler.swift:240,309,319,330`; `Reconciler.swift:212-215`; `StalenessTracker.swift:262-268`; `OperationRetention.swift:56`; `NewStarMapView.swift:206-210` (kind-scoped to travel); `ActivityView.swift` and `ActivityRow.swift` (renders N rows correctly, keyed by id). `PrintQueueFeature` reads `Device` and never `Operation` at all.

### The Print Queue surfaces

`PrintQueueFeature` is a TCA reducer plus two views (`PrintQueueFeature.swift`, `PrintQueueListView.swift`, `PrintQueueDetailView.swift`), presented from `app/macOS/MainFeature.swift:386,436`. `rg -ni "directive"` over the whole target returns **zero matches**. Its target depends on `GameModels` (`Package.swift:636-648`), where `Directive` and `DirectiveKind.title` live (`Directive.swift:36-49`), so the join needs **no new package dependency**.

- List row: `PrintQueueListView.swift:73-152`; the `+N` badge reads `queuedJobCount` at `:91-93`.
- Detail queue rows: `PrintQueueDetailView.swift:257-292`. Each renders index, display name and tags — and the `VStack(alignment: .leading, spacing: 2)` at `:263` already holds the second-line slot the owning run goes in.
- `Directive` has **no title column**. The title is computed: `DirectiveKind.title` (`Directive.swift:36-49`), pinned non-empty by `DirectiveVocabularyTests.swift:17`.
- **There are no GRDB associations anywhere in this app.** Three two-table patterns are established; the best template is a `FetchKeyRequest` that reads both tables and merges in a pure static — `BobnetQueries.swift:46-105`.
- `PrintQueueDetailView.activeJob` (`:135-178`) reads the device's own `printing` block and shows one active job. **That is correct and stays** — a bench prints one thing at a time. What is missing is the owner on the queued rows, not a second active job.

---

## Where the spec did not survive measurement

Seven departures from spec §Stage 3 and from ticket 18's own constraints. Each is a measured finding, not a preference.

### 1. The acceptance criterion's "within two ticks" is unreachable, and should be "within N ticks"

Ticket 18 asks for "three prints in flight simultaneously **within two ticks**". `MissionAction.dispatch` carries a single command (`MissionStepMachine.swift:21`), the engine calls `nextAction` exactly once per directive per evaluation (`DirectiveEngine.swift:261`, with `:450` and `:783` being refresh re-asks), and the tick is 5 s (`DirectiveEngine.swift:50`). One directive therefore fills **one bench per tick**. Three benches take three ticks.

The alternative is a multi-dispatch action, which breaks the spec's own invariant — "`MissionStepMachine` stays pure: no I/O, `world.now` only, **one action per evaluation**" — and `DirectiveExecutor`'s one-transaction-per-transition rule with it. That is a seam change for **ten seconds** of latency against prints that run for minutes.

**This plan restates the criterion: with three autofactories at one depot and a shortfall of at least three types, three prints are in flight within N ticks where N is the bench count, i.e. 15 s.** Task 6's acceptance test asserts exactly that.

### 2. `EventRun.printing` is not "one job per free bench per tick", and no site is

Ticket 18 describes the demand shape as "one job per free bench per tick (the `EventRun.printing` shape)". `EventRun.printing` has a single `first(where:)` at `EventRun.swift:373` and a single `.dispatch` at `:380`, with **no loop over printers**. What it actually does is re-enter its own step, so it fans out across *successive* ticks, one bench each. Its own comment at `:318-319` says so: "Not executed before: several free printers enqueue several levels at once."

Fan-out-over-ticks is the correct shape and this plan adopts it. The phrase "per tick" is the part that does not survive.

### 3. `Bench.owners` is a 0-or-1 array until Phase B, and it says so

Spec's `Bench = (device, activeJob, queueDepth, owners: [directiveID])`. Owners can only come from `operations.directiveID` — a queue entry carries no id. Until the index relaxes, a device holds at most one live op, so `owners` holds at most one element. The type is `[String]` from Task 1 so that Phase B fills it without a signature change, and `PrintSchedulerTests` pins both the 0/1 behaviour in Phase A and the N behaviour in Phase B.

### 4. `completeOpenOperation` cannot select by `detail.params.device_type`, and must not be written as if it can

Ticket 18 specifies: "`completeOpenOperation` for `print.completed` selects the live print op by `detail.params.device_type` == the event's device type, oldest first". Two halves of that are not currently true.

- **The op side is partial.** `detail.params.device_type` exists only on locally-dispatched ops (`CommandClient.swift:214`, `CommandParams.swift:76`). Ops adopted from a device snapshot insert `detail: .object([:])` (`Reconciler.swift:135,190`), so the field is absent exactly when the app did not issue the job.
- **The event side is unproven.** `GameEventEnvelope.deviceType` exists (`GameEventEnvelope.swift:41`) but is discarded before `completeOpenOperation`, which takes only `(deviceCode, source, eventTime, result, allowedKinds)` (`Reconciler.swift:439-445`). **Whether the server populates `device_type` on `print.completed` with the printer's type or the printed device's type is not evidenced anywhere in this repository.** The only documented payload key for that event is `new_device_code` (`GameSync.swift:320`).

**This plan selects the oldest live print op on the bench** — deterministic, needs no field that may be absent, and matches a FIFO queue, which is what a print queue is. Device-type matching is written as a **refinement in Task 11 Step 5, gated on a live probe** that Open Question 3 asks the operator to run. If the probe says the event carries the printed device's type, the refinement lands; if it says the printer's type, the refinement is worthless and is dropped.

### 5. The rail-short policy stays per-site, as a parameter

Ticket 18 says "the reserve rail is checked per job" but does not say what a short rail does. The five sites split 4-1 and both sides are documented as deliberate (see the policy table). Collapsing them silently changes `RelayRun`'s escalation semantics or `RestockRun`'s quiet-calm rule, either of which is a behaviour change nobody asked for.

**`PrintOrder` carries `onRailShort: RailPolicy` with cases `.wait` and `.stall(DirectiveAttentionReason)`.** Every site keeps what it has today. Open Question 1 asks the operator whether to unify later.

### 6. `RestockRun.idleCap = min(10, 3 × benches)` needs the bench count, and `desiredIdle` is the binding term anyway

Ticket 18 specifies the formula and this plan implements it verbatim. It should be recorded that **it will usually change nothing**: `desiredIdle(for:) = min(idleCap, directive.targets.count)` (`RestockRun.swift:142`), and automation-brain ticket 14 measured `targets.count` at 1 in the live row, so `targets.count` binds and the cap never engages. The formula is still right — it stops the cap becoming the binding term once `Brain.tendRestock` grows the target list — but a task that asserts "the cap changed the outcome" will be asserting a case the fixture had to manufacture. Task 8's test manufactures it explicitly and says so.

### 7. `PrintScheduler` lives beside `Steps/`, not inside it

Spec calls it "`PrintScheduler` in `DirectiveEngine`". Everything under `Sources/Steps/` is a step frame answering `next(_ ctx: StepContext) -> StepResult`. `PrintScheduler` answers questions about the world and returns no `StepResult`. Putting it in `Steps/` would make the directory's one rule false. It goes at `DirectiveEngine/Sources/PrintScheduler.swift`; `Steps/PrintJob.swift` calls it.

### 8. `choose` returns a `Bench?`, not a `Device?`

Spec's signature is `choose(job:at:in:) -> Device?`. Every caller then wants the depth and the owners it just computed — to log why a bench was picked, and in Phase B to decide whether queueing behind it is acceptable — and would have to call `benches` again to get them. Returning the `Bench` hands back what was already computed; callers take `.device.deviceCode` at the dispatch. This is the only signature in the spec this plan widens, and it widens rather than narrows, so no caller loses anything.

---

## Deliberate behaviour changes

Stage 2 was behaviour-preserving by default. Stage 3 is not, and this is the complete list. A change not on this list is out of scope; a task that finds itself making one stops and adds a line here first.

| # | Task | Change | Test that pins it |
|---|---|---|---|
| C1 | 6 | `MineFleetPrint` stops waiting for the whole recipe before ordering again; it orders against remaining demand netted by `onOrder` | `MineFleetPrintTests` "three benches carry three types" |
| C2 | 6 | `RestockRun` stops ordering a duplicate relay when the chooser substitutes a bench (punch-list 255) | `RestockRunTests` "a substituted bench does not buy a second relay" |
| C3 | 7 | `EventRun` bench capability moves from `deviceType == "autofactory"` to `acceptsPrintJobs && !isCarrierHull` — it gains print-capable vessels and loses any `autofactory` without `enqueue_print` | `EventRunPrintTests` "a print vessel that is not an autofactory is a bench" |
| C4 | 7 | `EventRun`'s bench-busy guard becomes owner-scoped | `EventRunPrintTests` "a co-tenant's print does not hide a bench" |
| C5 | 8 | `RelayRun` anchors on the theatre depot rather than `carrier.location` | `RelayRunAcquireTests` "acquire prints at the theatre depot, not where the carrier stands" |
| C6 | 8 | `RelayRun` prefers a free bench and excludes carrier hulls | `RelayRunAcquireTests` "acquire skips a busy bench and a carrier hull" |
| C7 | 8 | `RelayRun.acquire` gains an owner-scoped busy guard it has never had | `RelayRunAcquireTests` "acquire does not order twice while its own print is open" |
| C8 | 9 | `RestockRun` gains a pre-spend fleet-evidence sweep, closing automation-brain ticket 14 | `RestockRunTests` "stale fleet evidence buys a sweep before the spend" |
| C9 | 12 | `WorldSnapshot.openOperations` means "the active op per device"; queued ops move to `queuedOperations` | `WorldSnapshotTests` replaces its "one open op per device" case |
| C10 | 13 | `DeviceDetailView` shows the active job, not the newest open one, and says how many are queued behind it | `DeviceDetailViewTests` (new) |

---

## File structure

**New files**

| Path | Responsibility |
| --- | --- |
| `app/Modules/DirectiveEngine/Sources/PrintScheduler.swift` | `Bench`, `PrintOrder`, `RailPolicy`; `benches(at:in:)`, `choose(_:at:in:)`, `onOrder(at:in:)` |
| `app/Modules/DirectiveEngine/Tests/PrintSchedulerTests.swift` | Bench derivation as a table; depth arithmetic; choice order; `onOrder` netting |
| `app/Modules/PrintQueueFeature/Sources/PrintQueueOwners.swift` | `PrintQueueOwners`, the `FetchKeyRequest` joining `operations.directiveID` to `directives`, plus its pure `merge` static |
| `app/Modules/PrintQueueFeature/Tests/PrintQueueOwnersTests.swift` | The merge, over the cases that matter: no owner, one owner, a job nobody owns |
| `app/Modules/DevicesFeature/Tests/DeviceDetailOperationsTests.swift` | Which op the inspector picks with several live on one bench (Phase B) |

**Modified files — Phase A**

| Path | Change |
| --- | --- |
| `DirectiveEngine/Sources/Steps/PrintJob.swift` | `bench(_:)` delegates to `PrintScheduler.choose`; `PrintJob` keeps the depot anchor, the deadline and `stillPrinting` |
| `DirectiveEngine/Sources/RestockRun.swift` | fan-out against `onOrder`; the `min(10, 3 x benches)` cap; the pre-spend fleet sweep |
| `DirectiveEngine/Sources/MineFleetPrint.swift` | fan-out against `onOrder`; `printing` stops blocking on the whole recipe |
| `DirectiveEngine/Sources/EventCourierPrint.swift` | scheduler call; no behaviour change (it prints exactly one courier) |
| `DirectiveEngine/Sources/EventRun.swift` | `printing`'s hand-rolled printer filter and busy guard replaced; `printsInFlight` replaced by `PrintScheduler.onOrder` |
| `DirectiveEngine/Sources/RelayRun.swift` | `acquire` adopts the scheduler; `hub(near:in:)` deleted |
| `PrintQueueFeature/Sources/PrintQueueFeature.swift` | owners in state, from the new `FetchKeyRequest` |
| `PrintQueueFeature/Sources/PrintQueueDetailView.swift` | the owning-run line on each queued row |
| `PrintQueueFeature/Sources/PrintQueueListView.swift` | the owning-run line under the active job |

**Modified files — Phase B**

| Path | Change |
| --- | --- |
| `GameModels/Sources/Operation.swift` | the appended migration relaxing the index; `printedDeviceType` accessor |
| `GameDatabase/Sources/GameDatabase.swift` | the migration appended to the manifest |
| `GameDatabase/Tests/Fixtures/schema.sql` | regenerated deliberately |
| `GameServices/Sources/CommandClient.swift` | the supersede at `:247-262` scoped so it cannot eat a sibling print |
| `GameServices/Sources/Reconciler.swift` | the three `fetchOne`s become deterministic picks |
| `GameSync/Sources/DeadlineScheduler.swift` | passes the operation id it already holds |
| `DirectiveEngine/Sources/WorldSnapshot.swift` | `openOperations` is the active op; new `queuedOperations: [String: [Operation]]` |
| `DirectiveEngine/Sources/PrintScheduler.swift` | real depth; a bench may be chosen while busy |
| `DevicesFeature/Sources/DeviceDetailView.swift`, `ActiveTaskCard.swift` | the active job, plus a queued-behind count |
| `GameServices/Sources/CommandGovernor.swift` | de-dup verified against N identical jobs |

## Order of work and checkpoints

The phase boundary is not negotiable. Phase A must be green and checkpointed before Phase B starts, because Phase A is what delivers goal A and Phase B is where every risk lives.

**Phase A — breadth (tickets 33-40, no schema change)**

1. **Tasks 1-2** (33-34): `PrintScheduler` and its tests. Nothing calls it yet.
2. **Task 3** (35): `PrintJob.bench` delegates. The three migrated sites keep their suites green with no assertion edited.
3. **Tasks 4-5** (36-37): `EventRun` and `RelayRun` adopt it. C3-C7 land here, each with its test.
4. **Task 6** (38): the two print-only missions fan out. C1-C2 land here. **This is the ticket's acceptance test.**
5. **Task 7** (39): `RestockRun`'s pre-spend sweep. C8 lands here; automation-brain ticket 14 closes.
6. **Task 8** (40): the Print Queue shows its owners.

**Checkpoint E** (after Task 6, before Task 7): run the app for one evening with the brain on, at a depot with more than one autofactory. Expected: the Operations Log shows two or more concurrent print ops at that depot attributed to the same run; the Print Queue's `+N` badges move; no run orders a device type it already has on order. Record the observed concurrent-print count — if it is 1, Phase A did not work and Phase B must not start.

**Phase B — depth (tickets 41-47, one migration)**

7. **Task 9** (41): `WorldSnapshot.queuedOperations` first, while the index still holds. It is a pure addition and everything below reads it.
8. **Task 10** (42): the migration, the supersede scope, the golden schema. **The one task that changes schema.**
9. **Task 11** (43): the three `fetchOne`s become deterministic.
10. **Task 12** (44): `openOperations` becomes the active op; the engine's consumers follow.
11. **Task 13** (45): the device inspector stops lying.
12. **Task 14** (46): the scheduler uses real depth; a mission may queue behind itself.
13. **Task 15** (47): the governor is verified against N identical jobs; the stale doc comments come home; the measurement is recorded.

**Checkpoint F** (after Task 14): one evening with the brain on. Expected: a depot whose demand exceeds its bench count shows a bench with `queueDepth > 1` and two owning runs on the Print Queue; a `print.completed` closes the oldest job, not an arbitrary one; the device inspector shows a progress bar for the active job and a count for what is behind it.

**After each of tasks 3, 5, 6, 12 and 14**, run and record the borrow count, the same instrument Stage 2 used:

```bash
cd app/Modules/DirectiveEngine/Sources
grep -c "SalvageRun\.\|RelayRun\.\|RestockRun\.\|MineFleetPrint\.\|HaulRun\.\|EventRun\.\|SurveyRun\.\|MineRun\." *.swift | grep -v ":0$"
```

At `3ae52be` the total over these files is **70**, with `Brain.swift` at 31 and `RelayRun.swift` at 11 the concentrations. Stage 3 should move it down — `RelayRun.relayDeviceType` is borrowed by `RestockRun`, and `RelayRun.idleRelays` by `RestockRun` — but **Stage 3 sets no borrow target.** Its target is the print policy count, which goes from five-ways-split to one. Record the number at each checkpoint and let it be whatever it is.

### One more deliberate behaviour change, found while designing the chooser

| # | Task | Change | Test that pins it |
|---|---|---|---|
| C11 | 3 | A mission no longer dispatches onto a bench that is busy with **another run's** print | `PrintSchedulerTests` "no free bench yields no choice", plus `MineFleetPrintTests` "an all-busy depot waits, it does not stall" |

`PrintJob.bench` ends `?? able.min { $0.deviceCode < $1.deviceCode }` (`PrintJob.swift:46`) — when every bench is busy it returns a busy one. The caller's guard is owner-scoped (`MineFleetPrint.swift:86`), so a **co-tenant's** op there is invisible and the mission dispatches anyway. `CommandClient.swift:247-262` then marks the co-tenant's op `.superseded`, and the co-tenant's run loses track of a print that is still running. Under Phase A's fan-out, benches are busy far more often, so this goes from rare to routine. `PrintScheduler.choose` returns `nil` when no bench can take the job, and the caller waits.

This also forces a small restructure at three sites: today `nextAction` resolves the bench in its opening `guard` and stalls if there is none (`MineFleetPrint.swift:42-46`, `RestockRun.swift:62-66`). Those two cases must separate — **no print-capable device at the depot at all** is `.stall(.unreachableDevice)`; **benches exist but none can take the job** is `.wait`. Task 3 does that separation.

---

## Task 1: `Bench`, `PrintOrder`, and `PrintScheduler.benches`

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/PrintScheduler.swift`
- Test: `app/Modules/DirectiveEngine/Tests/PrintSchedulerTests.swift`

**Interfaces:**
- Consumes: `WorldSnapshot` (`devices: [String: Device]`, `openOperations: [String: Operation]`, `now: Date`), `Device.acceptsPrintJobs` / `isCarrierHull` / `queuedJobCount` / `printingSnapshot` / `queueSize`, `FleetTag`, `DirectiveAttentionReason`.
- Produces: `Bench`, `PrintOrder`, `RailPolicy`, `PrintScheduler.benches(at:in:)`. Tasks 2-8 all consume these names.

- [ ] **Step 1: Write the failing tests**

`app/Modules/DirectiveEngine/Tests/PrintSchedulerTests.swift`. Follow the fixture idiom already established in `Tests/Steps/PrintJobTests.swift:16-79` — copy `bench(_:)`, `op(on:owner:)` and `snapshot(_:open:dispatched:)` from there rather than inventing new ones, and extend `bench` with the arguments below.

```swift
//
//  PrintSchedulerTests.swift
//  Replicould — DirectiveEngine
//
//  Which benches a depot has, how deep each one is, and which one takes the
//  next job.
//

import Foundation
import GameModels
import GameServices
import Testing
import UniverseModels
import Utils

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 1_750_000_000)
private let depot = "AINALRAM-BELT-1"
private let elsewhere = "SAGARMADHA"

/// A print-capable device. `queued` names the device types waiting in its
/// `print_queue`; `printing` names the type on the platen right now.
private func bench(
    _ code: String, type: String = "autofactory", status: String = "idle",
    location: String? = depot, features: [String] = [],
    commands: [String] = ["enqueue_print"], capacity: Int = 10,
    queued: [String] = [], printing: String? = nil, updatedAt: Date = now
) -> Device {
    var detail: [String: JSONValue] = [:]
    if !queued.isEmpty {
        detail["print_queue"] = .array(queued.map { .object(["device_type": .string($0)]) })
    }
    if let printing {
        detail["printing"] = .object(["device_type": .string(printing)])
    }
    return Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100,
        queueSize: capacity, stowedInDeviceCode: nil, controllerDeviceCode: nil,
        attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: commands, features: features, tags: [],
        detail: .object(detail), updatedAt: updatedAt,
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func op(
    on entity: String, owner: String?, status: OperationStatus = .active,
    deviceType: String? = nil, quantity: Int? = nil
) -> GameModels.Operation {
    var params: [String: JSONValue] = [:]
    if let deviceType { params["device_type"] = .string(deviceType) }
    if let quantity { params["quantity"] = .number(Double(quantity)) }
    return GameModels.Operation(
        id: "OP-\(entity)", entityCode: entity, kind: OperationKind.print.rawValue,
        status: status, source: .poll, startedAt: now, completesAt: nil,
        lastConfirmedAt: now, detail: .object(["params": .object(params)]),
        directiveID: owner
    )
}

private func snapshot(
    _ devices: [Device], open: [String: GameModels.Operation] = [:]
) -> WorldSnapshot {
    WorldSnapshot(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        openOperations: open, dispatchedOperations: [:], now: now
    )
}

@Suite("Print scheduler — benches")
struct PrintSchedulerBenchTests {

    @Test("a depot's benches are its print-capable devices, lowest code first")
    func benchesAreCapableDevicesInCodeOrder() {
        let world = snapshot([
            bench("B3"), bench("B1"), bench("B2"),
            bench("X1", commands: []),                    // not print-capable
            bench("X2", location: elsewhere),             // wrong depot
            bench("X3", features: ["cradle", "surge"]),   // a carrier hull
            bench("X4", status: "compacted")              // refuses jobs
        ])

        #expect(
            PrintScheduler.benches(at: depot, in: world).map(\.device.deviceCode)
                == ["B1", "B2", "B3"]
        )
    }

    /// The active job is NOT a `print_queue` entry — it lives in its own
    /// `printing` block — so depth is the queue plus one when the platen is busy.
    @Test("depth counts the active job and the waiting queue")
    func depthCountsActiveAndQueued() {
        let world = snapshot([
            bench("B1", queued: ["mining_drone", "mining_drone"], printing: "ami_transport_controller"),
            bench("B2", queued: ["ftl_relay"]),
            bench("B3", printing: "ftl_relay"),
            bench("B4")
        ])
        let depths = PrintScheduler.benches(at: depot, in: world)
            .reduce(into: [String: Int]()) { $0[$1.device.deviceCode] = $1.queueDepth }

        #expect(depths == ["B1": 3, "B2": 1, "B3": 1, "B4": 0])
    }

    /// `queueSize` is the bench's CAPACITY, never its depth — pinned upstream by
    /// `PrintingSnapshotTests.swift:117-124`. An idle bench advertising ten is empty.
    @Test("an idle bench advertising capacity ten has depth zero")
    func capacityIsNotDepth() {
        let world = snapshot([bench("B1", capacity: 10)])

        #expect(PrintScheduler.benches(at: depot, in: world).first?.queueDepth == 0)
        #expect(PrintScheduler.benches(at: depot, in: world).first?.device.queueSize == 10)
    }

    @Test("owners come from the ops table, never from the queue snapshot")
    func ownersComeFromOps() {
        let world = snapshot(
            [bench("B1", queued: ["mining_drone"]), bench("B2")],
            open: ["B1": op(on: "B1", owner: "D-7")]
        )
        let byCode = PrintScheduler.benches(at: depot, in: world)
            .reduce(into: [String: [String]]()) { $0[$1.device.deviceCode] = $1.owners }

        // B1's queue entry carries no id, so the only owner is the one the op names.
        #expect(byCode == ["B1": ["D-7"], "B2": []])
    }

    @Test("the active job is the bench's live op")
    func activeJobIsTheLiveOp() {
        let mine = op(on: "B1", owner: "D-7")
        let world = snapshot([bench("B1"), bench("B2")], open: ["B1": mine])
        let benches = PrintScheduler.benches(at: depot, in: world)

        #expect(benches.first { $0.device.deviceCode == "B1" }?.activeJob == mine)
        #expect(benches.first { $0.device.deviceCode == "B2" }?.activeJob == nil)
    }

    @Test("a depot with no print-capable device has no benches")
    func noCapableDeviceNoBenches() {
        let world = snapshot([bench("X1", commands: []), bench("X2", location: elsewhere)])

        #expect(PrintScheduler.benches(at: depot, in: world).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `cd app/Modules && swift build --build-tests`

Expected: FAIL to compile, `cannot find 'PrintScheduler' in scope`. A compile failure is the correct red here; there is no symbol yet.

- [ ] **Step 3: Write `PrintScheduler.swift`**

```swift
//
//  PrintScheduler.swift
//  Replicould — DirectiveEngine
//
//  Which benches a depot has, how deep each one is, and which one takes the
//  next job. The one place any mission decides where a print goes.
//

import Foundation
import GameModels
import Utils

/// One print-capable device at a depot, with what it is carrying.
///
/// `queueDepth` comes from the printer's own snapshot; `owners` can only come
/// from the ops table, because a queue entry carries no id.
struct Bench: Equatable, Sendable {
    let device: Device
    let activeJob: GameModels.Operation?
    let queueDepth: Int
    let owners: [String]
}

/// What a short reserve rail does to the run that wanted the print.
enum RailPolicy: Equatable, Sendable {
    case wait
    case stall(DirectiveAttentionReason)
}

/// One job a mission wants printed, and what it wants done if the rail is short.
struct PrintOrder: Equatable, Sendable {
    let deviceType: String
    let quantity: Int?
    let tags: [FleetTag]
    /// The directive id the op row is stamped with.
    let owner: String
    let onRailShort: RailPolicy

    init(
        deviceType: String, quantity: Int? = nil, tags: [FleetTag] = [],
        owner: String, onRailShort: RailPolicy = .wait
    ) {
        self.deviceType = deviceType
        self.quantity = quantity
        self.tags = tags
        self.owner = owner
        self.onRailShort = onRailShort
    }
}

enum PrintScheduler {

    /// Every bench standing at `depot`, lowest device code first.
    ///
    /// A carrier hull is excluded even when it advertises the command: printing
    /// into a vessel a run is about to fly away is a job that leaves with it.
    static func benches(at depot: String, in world: WorldSnapshot) -> [Bench] {
        world.devices.values
            .filter { $0.acceptsPrintJobs && $0.location == depot && !$0.isCarrierHull }
            .sorted { $0.deviceCode < $1.deviceCode }
            .map { device in
                let active = world.openOperation(for: device.deviceCode)
                return Bench(
                    device: device,
                    activeJob: active,
                    queueDepth: depth(of: device),
                    owners: [active?.directiveID].compactMap { $0 }
                )
            }
    }

    /// The bench's load: the waiting queue plus the job on the platen.
    ///
    /// The two live in different blocks and never overlap, and `queueSize` is
    /// the bench's capacity rather than its load.
    private static func depth(of device: Device) -> Int {
        device.queuedJobCount + (device.printingSnapshot != nil ? 1 : 0)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `cd app/Modules && swift test --filter PrintSchedulerBenchTests --event-stream-output-path <path>`

Read the result through the `swift-test-event-stream` skill. Expected: 6 tests, 0 issues, a `runEnded` present.

- [ ] **Step 5: Prove the depth formula is pinned, not merely satisfied**

Mutate `depth(of:)` to `device.queuedJobCount` and re-run. Expected: `depthCountsActiveAndQueued` fails on `B3` (1 becomes 0) and `B1` (3 becomes 2). Restore. Then mutate it to `device.queueSize` and re-run: expected `capacityIsNotDepth` fails. Restore.

**If either mutation leaves the suite green, the test was written relative to the implementation and must be rewritten with literals.** This step is not optional — Stage 2's review found ten constants with no defender for exactly this reason.

- [ ] **Step 6: Comment budget, then commit**

Run: `./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/PrintScheduler.swift`

Commit `PrintScheduler.swift` and `PrintSchedulerTests.swift` with the message `feat(directives): PrintScheduler.benches — a depot's benches and their depth`.

---

## Task 2: `PrintScheduler.choose` and `PrintScheduler.onOrder`

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/PrintScheduler.swift`
- Test: `app/Modules/DirectiveEngine/Tests/PrintSchedulerTests.swift` (add two suites)

**Interfaces:**
- Consumes: `Bench`, `PrintOrder` from Task 1; `WorldSnapshot.openOperations`.
- Produces: `PrintScheduler.choose(_:at:in:) -> Bench?` and `PrintScheduler.onOrder(for:at:in:) -> [String: Int]`. Tasks 3-8 consume both.

**What `onOrder` is for.** Phase A replaces "wait for the clone before deciding again" with "decide again next tick, minus what is already on order". `onOrder` is the *minus*. It counts **only the owner's own open print ops**, and deliberately does not count the printer's `print_queue` entries, because a queue entry carries no id and cannot be attributed to a directive (`Printing.swift:147-152`). Attributing by fleet tag is possible in principle — queue entries do carry `tags` — but a job with no tags (`RestockRun` prints relays untagged, `RestockRun.swift:127`) is unattributable either way, so tag matching would cover some sites and not others. It is recorded as Open Question 2 rather than half-built here.

The consequence to be honest about: a job whose op row was lost is invisible to `onOrder` and can be ordered twice. In Phase A that cannot happen, because Task 3 stops a mission dispatching onto an occupied bench and so no supersede can fire. In Phase B it becomes reachable again, and Task 14 revisits it.

- [ ] **Step 1: Write the failing tests for `choose`**

Append to `PrintSchedulerTests.swift`:

```swift
@Suite("Print scheduler — choosing a bench")
struct PrintSchedulerChoiceTests {
    private func order(_ type: String = "ftl_relay", owner: String = "D-7") -> PrintOrder {
        PrintOrder(deviceType: type, owner: owner)
    }

    @Test("a free bench takes the job, lowest code first")
    func freeBenchLowestCode() {
        let world = snapshot([bench("B2"), bench("B1"), bench("B3")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B1")
    }

    @Test("a busy bench is skipped for a free one")
    func busyBenchSkipped() {
        let world = snapshot(
            [bench("B1", printing: "mining_drone"), bench("B2")],
            open: ["B1": op(on: "B1", owner: "OTHER")]
        )

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B2")
    }

    /// C11. Today `PrintJob.bench` falls back to a busy bench, the caller's
    /// owner-scoped guard misses a co-tenant's op, and the dispatch supersedes it.
    @Test("no bench can take the job, so there is no choice")
    func allBusyYieldsNil() {
        let world = snapshot(
            [bench("B1", printing: "mining_drone"), bench("B2", printing: "ftl_relay")],
            open: ["B1": op(on: "B1", owner: "OTHER"), "B2": op(on: "B2", owner: "D-7")]
        )

        #expect(PrintScheduler.choose(order(), at: depot, in: world) == nil)
    }

    /// A queue snapshot with no matching op still occupies the bench. The
    /// operator can enqueue by hand from the Print Queue screen.
    @Test("a bench queued by hand is occupied even with no op row")
    func queuedByHandOccupies() {
        let world = snapshot([bench("B1", queued: ["ftl_relay"]), bench("B2")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B2")
    }

    @Test("a depot with no benches yields no choice")
    func noBenchesYieldsNil() {
        let world = snapshot([bench("X1", commands: [])])

        #expect(PrintScheduler.choose(order(), at: depot, in: world) == nil)
    }
}

@Suite("Print scheduler — what is already on order")
struct PrintSchedulerOnOrderTests {

    @Test("an owner's open prints at the depot count, by type and quantity")
    func ownOpenPrintsCount() {
        let world = snapshot(
            [bench("B1"), bench("B2"), bench("B3")],
            open: [
                "B1": op(on: "B1", owner: "D-7", deviceType: "mining_drone", quantity: 3),
                "B2": op(on: "B2", owner: "D-7", deviceType: "ftl_relay", quantity: nil)
            ]
        )

        #expect(
            PrintScheduler.onOrder(for: "D-7", at: depot, in: world)
                == ["mining_drone": 3, "ftl_relay": 1]
        )
    }

    /// A job with no quantity is one unit. Written as a literal so that
    /// changing the default reddens this test.
    @Test("a print with no quantity counts as one")
    func missingQuantityIsOne() {
        let world = snapshot(
            [bench("B1")],
            open: ["B1": op(on: "B1", owner: "D-7", deviceType: "ftl_relay")]
        )

        #expect(PrintScheduler.onOrder(for: "D-7", at: depot, in: world) == ["ftl_relay": 1])
    }

    @Test("another run's print is not ours to net against")
    func coTenantDoesNotCount() {
        let world = snapshot(
            [bench("B1")],
            open: ["B1": op(on: "B1", owner: "OTHER", deviceType: "ftl_relay", quantity: 2)]
        )

        #expect(PrintScheduler.onOrder(for: "D-7", at: depot, in: world).isEmpty)
    }

    @Test("a print at another depot is not on order here")
    func otherDepotDoesNotCount() {
        let world = snapshot(
            [bench("B1", location: elsewhere)],
            open: ["B1": op(on: "B1", owner: "D-7", deviceType: "ftl_relay")]
        )

        #expect(PrintScheduler.onOrder(for: "D-7", at: depot, in: world).isEmpty)
    }

    /// An op adopted from a device snapshot carries `detail: {}` — it names no
    /// type. It cannot be netted and must not be counted as a zero.
    @Test("an op that names no device type is not counted")
    func typelessOpNotCounted() {
        let world = snapshot(
            [bench("B1")],
            open: ["B1": op(on: "B1", owner: "D-7")]
        )

        #expect(PrintScheduler.onOrder(for: "D-7", at: depot, in: world).isEmpty)
    }
}
```

- [ ] **Step 2: Run and confirm the two new suites fail**

Run: `cd app/Modules && swift build --build-tests`

Expected: FAIL to compile, `type 'PrintScheduler' has no member 'choose'`.

- [ ] **Step 3: Implement both, appended inside `enum PrintScheduler`**

```swift
    /// The bench that should take `order` at `depot`, or nil when none can.
    ///
    /// Phase A takes only an idle bench: dispatching onto an occupied one
    /// supersedes whatever op it already holds. Task 14 relaxes this to depth.
    static func choose(_ order: PrintOrder, at depot: String, in world: WorldSnapshot) -> Bench? {
        benches(at: depot, in: world).first { $0.queueDepth == 0 && $0.activeJob == nil }
    }

    /// What `owner` already has on order at `depot`, by device type.
    ///
    /// Ops only. A `print_queue` entry carries no id, so it cannot be
    /// attributed to a directive; an op that names no type cannot be netted.
    static func onOrder(
        for owner: String, at depot: String, in world: WorldSnapshot
    ) -> [String: Int] {
        let codes = Set(benches(at: depot, in: world).map(\.device.deviceCode))
        return world.openOperations.values.reduce(into: [String: Int]()) { total, op in
            guard op.kind == OperationKind.print.rawValue,
                  op.directiveID == owner,
                  codes.contains(op.entityCode),
                  let type = op.printedDeviceType
            else { return }
            total[type, default: 0] += op.printedQuantity ?? 1
        }
    }
```

`printedDeviceType` and `printedQuantity` do not exist yet. Add them beside the one existing `extension Operation` that decodes `detail` (`GameModels/Sources/Device.swift:722-730` holds `travelSnapshot` — copy that shape). Put the new extension in `GameModels/Sources/Operation.swift`, after the schema extension:

```swift
extension Operation {
    /// The device type a print op was asked for, when the app issued it.
    ///
    /// Absent on an op adopted from a device snapshot, which carries `{}`.
    public var printedDeviceType: String? {
        detail["params"]?["device_type"]?.stringValue
    }

    /// How many units the print op asked for; nil when it named none.
    public var printedQuantity: Int? {
        detail["params"]?["quantity"]?.intValue
    }
}
```

Check `JSONValue` for an `intValue` accessor (`app/Modules/Utils/Sources/JSONValue.swift:49-52` has `stringValue`). If there is none, add one there in the same shape rather than reaching through `doubleValue` at every call site, and give it its own test in `Utils`.

- [ ] **Step 4: Run the whole `DirectiveEngineTests` target and confirm green**

Run: `cd app/Modules && swift test --filter DirectiveEngineTests --event-stream-output-path <path>`

Expected: every existing case still green (the baseline at `3ae52be` is 1782/1782/0 over 226 suites) plus the 10 new ones, 0 issues, `runEnded` present. Also run `GameModelsTests` — this task added an extension there.

- [ ] **Step 5: Prove `choose`'s ordering is pinned**

Mutate `choose` to drop the `$0.activeJob == nil` conjunct and re-run: expected `allBusyYieldsNil` fails. Restore. Mutate the sort in `benches` to `>` and re-run: expected `freeBenchLowestCode` and `benchesAreCapableDevicesInCodeOrder` both fail. Restore.

- [ ] **Step 6: Comment budget, then commit**

Run: `./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/PrintScheduler.swift app/Modules/GameModels/Sources/Operation.swift`

Commit with the message `feat(directives): PrintScheduler.choose and onOrder`.

---

## Task 3: `PrintJob` delegates to the scheduler; the three migrated sites follow

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Steps/PrintJob.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/MineFleetPrint.swift:41-56`, `RestockRun.swift:61-75`, `EventCourierPrint.swift` (its bench call at `:80`)
- Test: `app/Modules/DirectiveEngine/Tests/Steps/PrintJobTests.swift`, plus the three mission suites

**Interfaces:**
- Consumes: `PrintScheduler.choose(_:at:in:)`, `PrintOrder`.
- Produces: `PrintJob.bench(_:for:) -> Bench?`. Tasks 4-8 call it or `PrintScheduler.choose` directly.

**What changes and what does not.** `PrintJob` keeps the depot anchor (`depot(for:in:)`), the deadline (`PrintJob.deadline = 1800`), `stillPrinting` and `fleetEvidenceIsStale` — those are the step frame and are correct. Only the selector moves. The pinned-device preference at `PrintJob.swift:38-39` goes with it: a pin that is busy must not win over a free bench, and Task 6's fan-out depends on that.

**C11 lands here.** `bench` stops falling back to an occupied bench, and the three callers separate "no benches at all" from "no free bench".

- [ ] **Step 1: Write the failing test for the new caller shape**

In `MineFleetPrintTests`, add:

```swift
    /// C11. Every bench busy is the system working, not a fault. It was
    /// `.stall(.unreachableDevice)` before, via `nextAction`'s opening guard.
    @Test("an all-busy depot waits, it does not stall")
    func allBusyWaits() {
        let world = snapshot(
            [bench("B1", printing: "mining_drone"), bench("B2", printing: "ftl_relay")],
            open: ["B1": op(on: "B1", owner: "OTHER"), "B2": op(on: "B2", owner: "OTHER")]
        )

        #expect(MineFleetPrint().nextAction(directive: row(), world: world) == .wait)
    }

    /// A depot with no print-capable device at all is still a fault: printing
    /// somewhere else would be a fabrication.
    @Test("a depot with no bench stalls")
    func noBenchStalls() {
        let world = snapshot([bench("X1", commands: [])])

        #expect(
            MineFleetPrint().nextAction(directive: row(), world: world)
                == .stall(.unreachableDevice)
        )
    }
```

Write the matching pair in `RestockRunTests` and `EventCourierPrintTests`, using each suite's own fixtures.

- [ ] **Step 2: Run and confirm both fail**

Run: `cd app/Modules && swift test --filter MineFleetPrintTests --event-stream-output-path <path>`

Expected: `allBusyWaits` fails with `.stall(.unreachableDevice)` where `.wait` was expected. `noBenchStalls` passes already — it is the case that does not change, and it is here so a later refactor cannot quietly collapse the two.

- [ ] **Step 3: Replace `PrintJob.bench`**

```swift
    /// The bench that should take `order`, or nil when none at this depot can.
    ///
    /// Nil means every bench is occupied, which is a wait — never a stall, and
    /// never a dispatch onto someone else's job.
    func bench(_ ctx: StepContext, for order: PrintOrder) -> Bench? {
        PrintScheduler.choose(order, at: depot, in: ctx.world)
    }

    /// Whether this depot has any print-capable device at all.
    func hasBench(_ ctx: StepContext) -> Bool {
        !PrintScheduler.benches(at: depot, in: ctx.world).isEmpty
    }
```

Delete the old `bench(_:)` body (`PrintJob.swift:37-47`) entirely, including the pinned-device preference.

**Watch what happens to these two by the end of Phase A.** Tasks 4, 5 and 6 all call `PrintScheduler.choose` directly, because each needs the chosen `Bench` at the dispatch and has already resolved its depot. That may leave `PrintJob.bench(_:for:)` with a single caller — `EventCourierPrint` — and a one-caller wrapper over a one-line call is not a seam, it is a redirect. Do not pre-empt it here; Task 15 Step 3 checks the caller count and deletes it if that is what it finds. `hasBench(_:)` is different and stays: three sites need "does this depot have any printer at all" as a distinct question from "can one take this job".

- [ ] **Step 4: Restructure the three callers**

`MineFleetPrint.nextAction` becomes:

```swift
    public func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        guard let depot = PrintJob.depot(for: directive, in: world) else {
            return .stall(.unreachableDevice)
        }
        let ctx = StepContext(directive: directive, world: world, step: directive.step)
        guard PrintJob(depot: depot).hasBench(ctx) else { return .stall(.unreachableDevice) }
        guard let step = Step(rawValue: directive.step) else {
            logger.notice("\(kind.rawValue, privacy: .public) \(directive.id, privacy: .public): unknown step \(directive.step, privacy: .public) — waiting")
            return .wait
        }
        switch step {
        case .printing: return printing(directive, depot, world)
        case .stocking: return stocking(directive, depot, world)
        }
    }
```

Note the step functions now take the **depot designation**, not a `Device`. Every `hub.location` inside them becomes `depot`, and every `hub.deviceCode` becomes the code of the bench `choose` returns at the moment of dispatch. Do the same in `RestockRun.nextAction` (`:61-75`) and `EventCourierPrint` (`:80`).

- [ ] **Step 5: Run all six targets**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

Expected: `DirectiveEngineTests`, `GameServicesTests`, `GameSyncTests`, `GameModelsTests`, `DirectivesFeatureTests`, `PrintQueueFeatureTests` all green, 0 issues, `runEnded` on each. **No existing assertion may be edited except the ones this task's own tests replace.** If a mission suite reddens on a case this plan does not name, stop and report it — it is a behaviour change nobody authorised.

- [ ] **Step 6: Record the borrow count, comment budget, commit**

Run the borrow-count command from "Order of work" and record the number in the ticket's `## Comments`.

Run: `./app/scripts/check-comments.sh` on every touched path.

Commit with the message `refactor(directives): PrintJob selects through PrintScheduler; a busy depot waits`.

---

## Task 4: `EventRun.printing` adopts the scheduler

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/EventRun.swift:240-250` (`printsInFlight`), `:297-385` (`printing`)
- Test: `app/Modules/DirectiveEngine/Tests/EventRunPrintTests.swift` (or wherever the event print cases live — find it with `rg -l "printing" app/Modules/DirectiveEngine/Tests`)

**Interfaces:**
- Consumes: `PrintScheduler.choose`, `PrintScheduler.onOrder`, `PrintOrder`, `PrintJob.depot(for:in:)`.
- Produces: nothing new. `EventRun.printsInFlight` is deleted; `EventRun.printDeadline(for:in:)` stays — it is the one variable deadline and Task 15 decides whether it comes home.

**Carries C3 and C4.** Two measured behaviour changes, each with a test.

- [ ] **Step 1: Write the two failing tests**

```swift
    /// C3. `EventRun.swift:363` filtered on `deviceType == "autofactory"`, the
    /// only such string match in production. Capability is the predicate.
    @Test("a print vessel that is not an autofactory is a bench")
    func printVesselIsABench() {
        let vessel = bench("B1", type: "fabricator_barge", commands: ["enqueue_print"])
        let world = worldPrinting(depot: depot, devices: [vessel], wanting: ["ftl_beacon": 1])

        guard case let .dispatch(_, deviceCode, _, _) =
            EventRun().nextAction(directive: printingRow(), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(deviceCode == "B1")
    }

    /// C4. The busy guard was owner-unscoped, so a co-tenant's print hid the
    /// bench and the run ordered nothing at all.
    @Test("a co-tenant's print does not hide a bench")
    func coTenantDoesNotHideABench() {
        let world = worldPrinting(
            depot: depot, devices: [bench("B1"), bench("B2", printing: "mining_drone")],
            open: ["B2": op(on: "B2", owner: "OTHER")], wanting: ["ftl_beacon": 1]
        )

        guard case let .dispatch(_, deviceCode, _, _) =
            EventRun().nextAction(directive: printingRow(), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(deviceCode == "B1")
    }
```

`worldPrinting` and `printingRow` are helpers the existing event suite already needs; if it has equivalents under other names, use those instead of adding a second set.

- [ ] **Step 2: Run and confirm both fail**

Run: `cd app/Modules && swift test --filter EventRun --event-stream-output-path <path>`

Expected: `printVesselIsABench` fails (no dispatch — the vessel is invisible to the type match). `coTenantDoesNotHideABench` may already pass, because `B1` is free and `first(where:)` finds it; if it passes, **strengthen it** so `B2` sorts first (rename the codes so the busy bench is `B1` and the free one `B2`) and confirm it then fails on the unscoped guard. A test that cannot fail is not pinning anything.

- [ ] **Step 3: Replace the selector and the in-flight accounting**

Delete `EventRun.printsInFlight(in:)` (`:240-250`) and its call at `:356`. Replace the netting loop with:

```swift
        // `missingTree` counts only what STANDS at the depot, so a job already
        // on order still reads as wanted.
        for (type, onOrder) in PrintScheduler.onOrder(for: directive.id, at: depot, in: world) {
            guard let count = wanted[type] else { continue }
            wanted[type] = count > onOrder ? count - onOrder : nil
        }
```

Replace the printer filter (`:362-364`) and the free-bench pick (`:373`) with:

```swift
        guard let type = order.first(where: { wanted[$0] != nil }),
              let quantity = wanted[type]
        else { return noProgress }

        let job = PrintOrder(
            deviceType: type, quantity: quantity, tags: [tag],
            owner: directive.id, onRailShort: .wait
        )
        guard let chosen = PrintScheduler.choose(job, at: depot, in: world) else { return noProgress }

        return .dispatch(
            kind: .print, deviceCode: chosen.device.deviceCode,
            params: CommandParams(deviceType: type, quantity: quantity, printTags: [tag.string]),
            nextStep: Step.printing.rawValue
        )
```

Note the reordering: the type is chosen **before** the bench. Today the bench is chosen first (`:373`) and the type second (`:376`), which means a depot with a free bench and nothing left to want burns the `noProgress` branch on the wrong reason. The order above asks "is there anything to print?" first.

Keep the `noProgress` deadline expression at `:369-371` exactly as it is — `EventRun`'s variable deadline is out of scope here.

- [ ] **Step 4: Run all six targets and confirm green**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

Expected: all six green. The event suite is the one most likely to redden on an unnamed change; if it does, stop and report which case.

- [ ] **Step 5: Comment budget, then commit**

Run: `./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/EventRun.swift`

Commit with the message `refactor(directives): EventRun prints through PrintScheduler (C3, C4)`.

---

## Task 5: `RelayRun.acquire` adopts the scheduler

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/RelayRun.swift:149-157` (`hub(near:in:)`, deleted), `:305-353` (`acquire`)
- Test: `app/Modules/DirectiveEngine/Tests/RelayRunTests.swift`

**Interfaces:**
- Consumes: `PrintScheduler.choose`, `PrintOrder`, `RailPolicy.stall`, `PrintJob.depot(for:in:)`.
- Produces: nothing. `RelayRun.hub(near:in:)` is deleted; check for external callers with LSP before deleting, and if `findReferences` comes back empty, confirm with a build rather than trusting it.

**Carries C5, C6 and C7 — the largest behaviour change in the plan.** `RelayRun` is the only site that never had a busy guard, prefers no free bench, allows carrier hulls, and anchors on the carrier rather than the theatre. All four change here. It is also the only site that stalls on a short rail, and that does **not** change: it passes `onRailShort: .stall(.printStockShort)`.

- [ ] **Step 1: Write the three failing tests**

```swift
    /// C5. `hub(near:in:)` anchored on `carrier.location` — a device location,
    /// which `PrintJob.swift:20-21` warns against: a hub that unfurls elsewhere
    /// must not drag the run with it.
    @Test("acquire prints at the theatre depot, not where the carrier stands")
    func acquirePrintsAtTheDepot() {
        let carrier = device("C1", location: elsewhere)
        let atDepot = bench("B1", location: depot)
        let world = snapshot([carrier, atDepot, bench("B9", location: elsewhere)])

        guard case let .dispatch(_, deviceCode, _, _) =
            RelayRun().nextAction(directive: acquiring(carrier: "C1", depot: depot), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(deviceCode == "B1")
    }

    /// C6. `hub` preferred "anything but our own carrier", then lowest code —
    /// never a free bench, and a carrier hull was a legal pick.
    @Test("acquire skips a busy bench and a carrier hull")
    func acquireSkipsBusyAndHulls() {
        let world = snapshot(
            [
                bench("B1", printing: "mining_drone"),
                bench("B2", features: ["cradle", "surge"]),
                bench("B3")
            ],
            open: ["B1": op(on: "B1", owner: "OTHER")]
        )

        guard case let .dispatch(_, deviceCode, _, _) =
            RelayRun().nextAction(directive: acquiring(), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(deviceCode == "B3")
    }

    /// C7. `acquire` had no open-op guard at all — alone among the five sites.
    @Test("acquire does not order twice while its own print is open")
    func acquireDoesNotOrderTwice() {
        let world = snapshot(
            [bench("B1", printing: "ftl_relay")],
            open: ["B1": op(on: "B1", owner: "R-1", deviceType: "ftl_relay")]
        )

        #expect(RelayRun().nextAction(directive: acquiring(id: "R-1"), world: world) == .wait)
    }
```

- [ ] **Step 2: Run and confirm all three fail**

Run: `cd app/Modules && swift test --filter RelayRunTests --event-stream-output-path <path>`

Expected: `acquirePrintsAtTheDepot` dispatches to `B9`; `acquireSkipsBusyAndHulls` dispatches to `B1`; `acquireDoesNotOrderTwice` dispatches instead of waiting.

- [ ] **Step 3: Rewrite `acquire`'s tail**

Replace everything from the `hub` guard (`RelayRun.swift:325`) to the dispatch (`:352`) with:

```swift
        guard let depot = PrintJob.depot(for: directive, in: world) else {
            logger.notice("relay run \(directive.id, privacy: .public): no depot stamped")
            return .stall(.unreachableDevice)
        }
        guard !PrintScheduler.benches(at: depot, in: world).isEmpty else {
            logger.notice("relay run \(directive.id, privacy: .public): no print hub at \(depot, privacy: .public)")
            return .stall(.unreachableDevice)
        }

        let rail = PrintRail(reserveFloor: reserveFloor)
        if reserveFloor != nil, rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.acquire.rawValue, thenStall: .printStockShort)
        }
        if rail.printStockIsShort(at: depot, world) {
            let why = rail.printStockShortDiagnosis(at: depot, world)
            logger.notice("relay run \(directive.id, privacy: .public): print stock short at \(depot, privacy: .public) — \(why, privacy: .public)")
            return .stall(.printStockShort)
        }

        // C7: the guard this site never had.
        if world.openOperation(for: directive.deviceCode, owner: directive.id) != nil { return .wait }

        let job = PrintOrder(
            deviceType: Self.relayDeviceType, owner: directive.id,
            onRailShort: .stall(.printStockShort)
        )
        guard let chosen = PrintScheduler.choose(job, at: depot, in: world) else { return .wait }

        return .dispatch(
            kind: .print, deviceCode: chosen.device.deviceCode,
            params: CommandParams(deviceType: Self.relayDeviceType),
            nextStep: Step.printing.rawValue
        )
```

**The C7 guard as written is wrong and must not be shipped that way.** `directive.deviceCode` is the carrier, not the bench, so `openOperation(for: directive.deviceCode, owner:)` asks about the wrong device. This is the same trap punch-list line 255 describes at `RestockRun`: the bench is recomputed each tick, so "is my print open?" cannot be asked of a bench the chooser might have moved on from. Use the instrument Stage 2 built for exactly this, which searches by owner rather than by device:

```swift
        if PrintJob(depot: depot).stillPrinting(
            StepContext(directive: directive, world: world, step: directive.step)
        ) { return .wait }
```

Read `PrintJob.stillPrinting` (`Steps/PrintJob.swift:52-60`) before writing this and confirm it answers "does this owner have an open print anywhere", not "is this device busy". If it answers the latter, this task must widen it and say so.

Also replace the per-device freshness gate at `:328` (`hub.updatedAt > Self.hubFreshness`) with the depot-wide one the other sites use:

```swift
        if PrintJob.fleetEvidenceIsStale(directive, at: depot, in: world) {
            return .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        }
```

placed immediately before the dispatch — last moment before an irreversible spend. Note `Self.hubFreshness` (`RelayRun.swift`, aliased to `PrintRail.hubFreshness`) may become unreferenced; check with LSP and delete it in Task 15 if so, not here.

- [ ] **Step 4: Delete `hub(near:in:)`**

Confirm no other caller with `findReferences`, then delete `RelayRun.swift:149-157` and rebuild. If the build fails, the index was cold and the reference is real.

- [ ] **Step 5: Run all six targets**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

Expected: all six green. `RelayRunTests` is 400+ cases and the most likely to surface an unnamed change; read the failures individually rather than in aggregate.

- [ ] **Step 6: Record the borrow count, comment budget, commit**

Commit with the message `refactor(directives): RelayRun.acquire prints through PrintScheduler (C5, C6, C7)`.

---

## Task 6: The two print-only missions fan out

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MineFleetPrint.swift:78-138`, `RestockRun.swift:85-161`
- Test: `app/Modules/DirectiveEngine/Tests/MineFleetPrintTests.swift`, `RestockRunTests.swift` (and `RelayReturnAndRestockTests.swift`, which holds the `idleCap` cases)

**Interfaces:**
- Consumes: `PrintScheduler.choose`, `PrintScheduler.onOrder`, `PrintOrder`.
- Produces: nothing new.

**This is the task the whole plan exists for, and it carries C1 and C2.** Both missions stop waiting for a clone before deciding again, and both net their demand against `onOrder`. Their `printing` step becomes a thin deadline holder rather than a blocker.

- [ ] **Step 1: Write the acceptance test**

This is the ticket's acceptance criterion, restated per departure 1 as N ticks for N benches. Put it in `MineFleetPrintTests`:

```swift
    /// The Stage 3 acceptance criterion. Three autofactories, a shortfall of at
    /// least three types, and three prints in flight after three evaluations —
    /// one per tick, because `MissionAction.dispatch` carries one command.
    @Test("three benches carry three types")
    func threeBenchesCarryThreeTypes() {
        var world = snapshot([bench("B1"), bench("B2"), bench("B3")])
        var directive = row()
        var open: [String: GameModels.Operation] = [:]
        var dispatched: [String] = []

        for _ in 0..<3 {
            guard case let .dispatch(_, deviceCode, params, next) =
                MineFleetPrint().nextAction(directive: directive, world: world)
            else { return #expect(Bool(false), "expected a dispatch") }
            dispatched.append(deviceCode)
            open[deviceCode] = op(
                on: deviceCode, owner: directive.id,
                deviceType: params.deviceType, quantity: params.quantity
            )
            world = snapshot([bench("B1"), bench("B2"), bench("B3")], open: open)
            directive.step = next
            // The executor re-stamps on advanceStep; the fan-out must not depend
            // on the stamp, so hold it still.
        }

        #expect(Set(dispatched) == ["B1", "B2", "B3"])
        #expect(Set(open.values.compactMap(\.printedDeviceType)).count == 3)
    }
```

The second expectation is the one that matters: three **different** types. A fan-out that ordered the same type three times would satisfy the first and be exactly the duplicate spend this stage is closing.

- [ ] **Step 1b: Write the other two acceptance criteria**

Ticket 18 asks for three things, not one. The other two:

```swift
    /// "With one autofactory, behaviour equals today's." A single bench still
    /// orders one job at a time and waits for it — the fan-out must not turn
    /// into a queue of orders nobody can serve.
    @Test("one bench orders one job and then waits")
    func oneBenchOrdersOneJob() {
        var world = snapshot([bench("B1")])
        let directive = row()

        guard case let .dispatch(_, deviceCode, params, _) =
            MineFleetPrint().nextAction(directive: directive, world: world)
        else { return #expect(Bool(false), "expected a dispatch") }

        world = snapshot(
            [bench("B1", printing: params.deviceType)],
            open: ["B1": op(on: deviceCode, owner: directive.id,
                            deviceType: params.deviceType, quantity: params.quantity)]
        )

        #expect(MineFleetPrint().nextAction(directive: directive, world: world) == .wait)
    }

    /// "A co-tenant's job never blocks or extends another run's deadline."
    /// Two runs, one depot, two benches: each gets one and neither waits on
    /// the other, and neither run's step clock is touched by the other's job.
    @Test("a co-tenant's print neither blocks nor extends this run")
    func coTenantNeitherBlocksNorExtends() {
        let theirs = op(on: "B1", owner: "OTHER", deviceType: "mining_drone")
        let world = snapshot(
            [bench("B1", printing: "mining_drone"), bench("B2")], open: ["B1": theirs]
        )

        guard case let .dispatch(_, deviceCode, _, _) =
            MineFleetPrint().nextAction(directive: row(startedAgo: 60), world: world)
        else { return #expect(Bool(false), "expected a dispatch") }
        #expect(deviceCode == "B2")

        // And the co-tenant's job does not push this run past its own deadline:
        // the deadline is measured from OUR step stamp, never from the bench.
        let past = row(startedAgo: PrintJob.deadline + 1)
        #expect(MineFleetPrint().nextAction(directive: past, world: world) != .wait)
    }
```

**Ticket 18 says to test the co-tenant case "through the real engine".** The unit test above pins the mission's decision; it does not pin what `DirectiveExecutor` and `CommandGovernor` do with two runs dispatching in one tick. Add an engine-level case in `DirectiveEngineTests` alongside it — two `mineFleetPrint` rows at one depot with two benches, one evaluation each, and an assertion that both ops exist and neither is `.superseded`. If that test cannot be written against the existing engine harness, say so in the ticket and record what was pinned at the unit level instead; do not quietly drop it.

- [ ] **Step 2: Write the C2 regression test**

In `RestockRunTests`:

```swift
    /// C2, punch-list line 255. The chooser moves to a free bench each tick,
    /// the owner-scoped guard asks the new bench and finds nothing of ours,
    /// and a second relay is ordered against a demand of one.
    @Test("a substituted bench does not buy a second relay")
    func substitutedBenchBuysNoSecondRelay() {
        let mine = op(on: "B1", owner: "R-1", deviceType: "ftl_relay")
        let world = snapshot([bench("B1", printing: "ftl_relay"), bench("B2")], open: ["B1": mine])

        // Demand is one relay, and one is already on order.
        #expect(RestockRun().nextAction(directive: restocking(id: "R-1", wanting: 1), world: world) == .wait)
    }
```

- [ ] **Step 3: Run and confirm both fail**

Run: `cd app/Modules && swift test --filter "MineFleetPrintTests|RestockRunTests" --event-stream-output-path <path>`

Expected: `threeBenchesCarryThreeTypes` fails on the second iteration — `printing` returns `.wait` rather than a dispatch. `substitutedBenchBuysNoSecondRelay` fails with a `.dispatch` to `B2`.

- [ ] **Step 4: Net `MineFleetPrint.stocking` against `onOrder`**

In `stocking`, immediately after `let missing = Self.remaining(at: depot, in: world)`:

```swift
        var missing = Self.remaining(at: depot, in: world)
        for (type, onOrder) in PrintScheduler.onOrder(for: directive.id, at: depot, in: world) {
            guard let count = missing[type] else { continue }
            missing[type] = count > onOrder ? count - onOrder : nil
        }
        if missing.isEmpty { return .done }
```

**Delete the owner-scoped bench guard at `MineFleetPrint.swift:86`.** `onOrder` now does that job across every bench rather than at one, and leaving both means the first in-flight job blocks the second.

Then replace the dispatch tail so the bench comes from `choose`:

```swift
        let job = PrintOrder(
            deviceType: type, quantity: quantity, tags: [tag],
            owner: directive.id, onRailShort: .wait
        )
        guard let chosen = PrintScheduler.choose(job, at: depot, in: world) else { return .wait }
        return .dispatch(
            kind: .print, deviceCode: chosen.device.deviceCode,
            params: CommandParams(deviceType: type, quantity: quantity, printTags: [tag.string]),
            nextStep: Step.stocking.rawValue
        )
```

**Note `nextStep` is now `stocking`, not `printing`** — the same-step re-entry that makes fan-out work, and the shape `EventRun` already uses.

- [ ] **Step 5: Make `MineFleetPrint.printing` a deadline holder**

`printing` no longer gates the fan-out; it exists so a run that has ordered everything and is waiting on clones still has a deadline. Rewrite it:

```swift
    /// Hold while the ordered clones land. The fan-out happens in `stocking`,
    /// which re-enters itself; this step is reached only when nothing is left
    /// to order, and hands back when the deadline says the orders produced nothing.
    private func printing(_ directive: Directive, _ depot: String, _ world: WorldSnapshot) -> MissionAction {
        if Self.remaining(at: depot, in: world).isEmpty {
            return .advanceStep(nextStep: Step.stocking.rawValue)
        }
        if world.now.timeIntervalSince(directive.stepStartedAt) <= PrintJob.deadline { return .wait }
        logger.notice("mine fleet print \(directive.id, privacy: .public): print produced nothing within the deadline — re-deciding")
        return .advanceStep(nextStep: Step.stocking.rawValue)
    }
```

`stocking` reaches `printing` only when `choose` returns nil (every bench busy) **and** demand remains. Add that transition where the current `.wait` for a full depot sits, so the deadline can still accumulate:

```swift
        guard let chosen = PrintScheduler.choose(job, at: depot, in: world) else {
            return .advanceStep(nextStep: Step.printing.rawValue)
        }
```

Read `MissionAction.wait`'s doc (`MissionStepMachine.swift:23-26`) before choosing between `.wait` and `.advanceStep` here: `.wait` is the only action that does **not** re-stamp `stepStartedAt`, so a `.wait` loop accumulates the deadline and an `.advanceStep` loop resets it. Whichever you pick, the test in Step 8 must pin it.

- [ ] **Step 6: Do the same to `RestockRun.stocking`**

`RestockRun`'s demand is `desiredIdle - idle`, not a per-type dictionary. Net it the same way:

```swift
        let idle = RelayRun.idleRelays(at: depot, in: world).count
        let onOrder = PrintScheduler.onOrder(for: directive.id, at: depot, in: world)[RelayRun.relayDeviceType] ?? 0
        let desired = Self.desiredIdle(for: directive, benches: PrintScheduler.benches(at: depot, in: world).count)
        guard idle + onOrder < desired else { return .wait }
```

and delete the owner-scoped guard at `RestockRun.swift:95`. `desiredIdle` gains the `benches:` argument in Task 7; until then call the one-argument form and change it there.

- [ ] **Step 7: Run all six targets**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

Expected: all six green, both new tests passing. **`RelayReturnAndRestockTests` is the suite most likely to redden here** — it holds the `idleCap`/`desiredIdle` cases at `:377-394`. Read any failure there carefully: a case that asserted "one print, then wait" is asserting the serial behaviour this task deliberately removes, and it should be **rewritten to assert the new sequence**, with a note in the ticket's `## Comments` naming the case and why.

- [ ] **Step 8: Prove the fan-out is pinned**

Mutate `stocking`'s `nextStep` back to `Step.printing.rawValue` and re-run: expected `threeBenchesCarryThreeTypes` fails on iteration two. Restore. Then delete the `onOrder` netting loop and re-run: expected `substitutedBenchBuysNoSecondRelay` fails, and `threeBenchesCarryThreeTypes` fails on its type-count expectation. Restore.

- [ ] **Step 9: Record the borrow count, comment budget, commit**

Commit with the message `feat(directives): print-only missions fan out across benches (C1, C2)`.

**Checkpoint E follows this task.** Do not start Task 7 until it has been run and its observed concurrent-print count recorded.

---

## Task 7: `RestockRun` scales its cap and buys evidence before it spends

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/RestockRun.swift:49-54` (`idleCap`), `:132-143` (`desiredIdle`), `:85-131` (`stocking`)
- Test: `app/Modules/DirectiveEngine/Tests/RelayReturnAndRestockTests.swift`, `RestockRunTests.swift`
- Resolve: `.scratch/automation-brain/issues/14-restockrun-over-print-race.md`

**Interfaces:**
- Consumes: `PrintScheduler.benches`, `PrintJob.fleetEvidenceIsStale`.
- Produces: `RestockRun.desiredIdle(for:benches:)`, replacing `desiredIdle(for:)`. Task 6 Step 6 calls it.

**Carries C8.** This is the ticket that closes automation-brain 14, open since 2026-08-10 and re-confirmed still open by directives ticket 07.

**Read before starting:** `.scratch/automation-brain/issues/14-restockrun-over-print-race.md` in full. Its "The fix" section specifies the gate, the witness, and why `thenStall` must be non-nil. Do not re-derive any of that.

- [ ] **Step 1: Write the failing test for the cap formula**

```swift
    /// Ticket 18's formula. Written with literals rather than in terms of
    /// `idleCap`, so that changing either term reddens this test.
    @Test("the idle cap scales with bench count")
    func idleCapScalesWithBenches() {
        // One bench: three. Four benches: twelve, clipped to ten.
        #expect(RestockRun.desiredIdle(for: wanting(20), benches: 1) == 3)
        #expect(RestockRun.desiredIdle(for: wanting(20), benches: 3) == 9)
        #expect(RestockRun.desiredIdle(for: wanting(20), benches: 4) == 10)
        #expect(RestockRun.desiredIdle(for: wanting(20), benches: 0) == 0)
    }

    /// Departure 6. In the live row `targets.count` is 1, so the cap has never
    /// been the binding term. This fixture manufactures the case where it is.
    @Test("demand still binds below the cap")
    func demandBindsBelowTheCap() {
        #expect(RestockRun.desiredIdle(for: wanting(1), benches: 4) == 1)
    }
```

`wanting(_:)` builds a directive whose `targets` holds that many entries.

- [ ] **Step 2: Write the failing test for the pre-spend sweep**

```swift
    /// C8, automation-brain ticket 14. A printed clone's row lands off the SSE
    /// frame minutes to hours after its op closes, so "no op open" is not
    /// evidence the pool is still short. Measured at 28-117 minutes on 2026-08-10.
    @Test("stale fleet evidence buys a sweep before the spend")
    func staleEvidenceBuysASweep() {
        // Every device row at the depot predates the step stamp, so nothing
        // observed since this step began can vouch for the pool.
        let stale = bench("B1", updatedAt: now.addingTimeInterval(-3600))
        let world = snapshot([stale])

        #expect(
            RestockRun().nextAction(directive: restocking(startedAgo: 60), world: world)
                == .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        )
    }

    /// The gate sits at the last moment before the spend, after every branch
    /// that declines — a vetoed pass must buy no read.
    @Test("a met demand buys no sweep")
    func metDemandBuysNoSweep() {
        let stale = bench("B1", updatedAt: now.addingTimeInterval(-3600))
        let world = snapshot([stale] + idleRelays(1))

        #expect(RestockRun().nextAction(directive: restocking(wanting: 1), world: world) == .wait)
    }
```

- [ ] **Step 3: Run and confirm they fail**

Run: `cd app/Modules && swift test --filter "RestockRunTests|RelayReturnAndRestock" --event-stream-output-path <path>`

Expected: the cap tests fail to compile (`desiredIdle(for:benches:)` does not exist); `staleEvidenceBuysASweep` fails with a `.dispatch`.

- [ ] **Step 4: Implement the cap**

```swift
    /// The most idle relays this will leave parked at the hub, per bench.
    ///
    /// A ceiling on capital held as inventory rather than reserve. Three per
    /// bench, because a bench that finishes should find work waiting.
    public static let idlePerBench = 3
    /// The absolute ceiling, whatever the bench count.
    public static let idleCap = 10

    /// How many idle relays the hub should hold for `directive`: its own
    /// `targets` count, capped at three per bench and ten overall.
    static func desiredIdle(for directive: Directive, benches: Int) -> Int {
        min(idleCap, idlePerBench * benches, directive.targets.count)
    }
```

Keep `idleCap` public and its name unchanged — `RelayReturnAndRestockTests.swift:377,379` reads it, and Task 6 already touched that suite once.

- [ ] **Step 5: Add the pre-spend sweep**

Place it as the **last** gate in `stocking`, after the demand check, after the rail, immediately before the dispatch — the same position `MineFleetPrint.swift:96-100` uses:

```swift
        // Last moment before an irreversible spend, and the one read that can
        // settle it: a clone is PRESENT at the hub, so one scoped sweep sees it.
        if PrintJob.fleetEvidenceIsStale(directive, at: depot, in: world) {
            return .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        }
```

`thenStall` must be non-nil. Ticket 14 gives the reason and it is not negotiable: a nil fallback waits, `.wait` does not re-stamp `stepStartedAt`, and the gate would buy one read every 5-second tick forever.

- [ ] **Step 6: Run all six targets, then resolve the automation-brain ticket**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

Expected: all six green.

Set `Status: resolved` on `.scratch/automation-brain/issues/14-restockrun-over-print-race.md` and append a `## Comments` note with the commit sha, naming which of its two asks landed (the gate) and which did not (it asked for the ordering "census first, reserve veto, then the device sweep" — confirm the implemented order matches, and say so).

- [ ] **Step 7: Prove the cap is pinned**

Mutate `idlePerBench` to 4 and re-run: expected `idleCapScalesWithBenches` fails on the 3-bench case (9 becomes 12). Restore. Mutate `idleCap` to 12 and re-run: expected the 4-bench case fails (10 becomes 12). Restore.

- [ ] **Step 8: Comment budget, commit**

Commit with the message `fix(directives): RestockRun scales its cap and sweeps before it spends (C8)`, and reference automation-brain ticket 14 in the body.

---

## Task 8: The Print Queue shows the run that owns each job

**Files:**
- Create: `app/Modules/PrintQueueFeature/Sources/PrintQueueOwners.swift`
- Create: `app/Modules/PrintQueueFeature/Tests/PrintQueueOwnersTests.swift`
- Modify: `app/Modules/PrintQueueFeature/Sources/PrintQueueFeature.swift:32-33`, `PrintQueueDetailView.swift:257-292`, `PrintQueueListView.swift:96-114`

**Interfaces:**
- Consumes: `GameModels.Operation` (`directiveID`, `entityCode`, `status`), `GameModels.Directive`, `DirectiveKind.title`.
- Produces: `PrintQueueOwners` (a `FetchKeyRequest`) and `PrintQueueOwners.merge(operations:directives:)`. Nothing downstream consumes them.

**No new package dependency.** `Directive` and `DirectiveKind` live in `GameModels`, already a `PrintQueueFeature` dependency (`Package.swift:637`). `DirectiveOwner`'s "driven by X" phrasing lives in `DirectivesFeature` and is **not** reachable; write the string here.

**What can and cannot be shown, and why.** A `print_queue` entry carries no id (`Printing.swift:147-152`), so a *queued* job cannot be matched to an operation row. What the ops table can answer is **which runs have a print open on this bench** — one today, N after Phase B. So this task shows the owner against the **bench**, not against each queue position, and the copy must not imply otherwise. "Queue" gets a footer line naming the owning run(s); it does not get a per-row owner. Task 14 revisits this once `queuedOperations` exists, and even then the mapping to a queue *position* stays unavailable.

- [ ] **Step 1: Write the failing merge test**

```swift
//
//  PrintQueueOwnersTests.swift
//  Replicould — PrintQueueFeature
//

import Foundation
import GameModels
import Testing

@testable import PrintQueueFeature

@Suite("Print queue owners")
struct PrintQueueOwnersTests {

    @Test("a bench's open print names the run that ordered it")
    func openPrintNamesItsRun() {
        let owners = PrintQueueOwners.merge(
            operations: [printOp(on: "B1", directive: "D-7")],
            directives: [directive(id: "D-7", kind: .mineFleetPrint)]
        )

        #expect(owners == ["B1": ["Mine Fleet Print"]])
    }

    @Test("a job nobody owns names nobody")
    func unownedJobNamesNobody() {
        let owners = PrintQueueOwners.merge(
            operations: [printOp(on: "B1", directive: nil)], directives: []
        )

        #expect(owners.isEmpty)
    }

    /// An op stamped with a directive that has since been deleted must not
    /// invent a title, and must not crash.
    @Test("an op whose directive is gone names nobody")
    func missingDirectiveNamesNobody() {
        let owners = PrintQueueOwners.merge(
            operations: [printOp(on: "B1", directive: "D-GONE")], directives: []
        )

        #expect(owners.isEmpty)
    }

    @Test("two runs on one bench are both named, in a stable order")
    func twoRunsBothNamed() {
        let owners = PrintQueueOwners.merge(
            operations: [
                printOp(on: "B1", directive: "D-9", id: "OP-2"),
                printOp(on: "B1", directive: "D-7", id: "OP-1")
            ],
            directives: [
                directive(id: "D-7", kind: .mineFleetPrint),
                directive(id: "D-9", kind: .restockRun)
            ]
        )

        // Oldest first, which is the order the bench will work them.
        #expect(owners == ["B1": ["Mine Fleet Print", "Relay Restock"]])
    }

    @Test("a completed print names nobody")
    func completedPrintNamesNobody() {
        let owners = PrintQueueOwners.merge(
            operations: [printOp(on: "B1", directive: "D-7", status: .completed)],
            directives: [directive(id: "D-7", kind: .mineFleetPrint)]
        )

        #expect(owners.isEmpty)
    }
}
```

`printOp` and `directive` are local fixture helpers; write them in this file. `printOp` defaults to `status: .active`, `kind: OperationKind.print.rawValue`, and takes `id` so ordering can be pinned.

- [ ] **Step 2: Run and confirm it fails**

Run: `cd app/Modules && swift test --filter PrintQueueOwnersTests --event-stream-output-path <path>`

Expected: FAIL to compile, `cannot find 'PrintQueueOwners' in scope`.

- [ ] **Step 3: Write `PrintQueueOwners.swift`**

Follow `BobnetQueries.swift:46-105` — a `FetchKeyRequest` that reads both tables and hands the join to a pure static.

```swift
//
//  PrintQueueOwners.swift
//  Replicould — PrintQueueFeature
//
//  Which directive run ordered the print a bench is working. The queue
//  snapshot carries no id, so this can answer by bench and never by position.
//

import Foundation
import GameModels
import SQLiteData

/// Owning-run titles per bench device code, oldest job first.
struct PrintQueueOwners: FetchKeyRequest {
    typealias Value = [String: [String]]

    func fetch(_ db: Database) throws -> Value {
        let operations = try Operation
            .where { $0.kind.eq(OperationKind.print.rawValue) && $0.status.in(OperationStatus.openCases) }
            .order { $0.startedAt }
            .fetchAll(db)
        let directives = try Directive.all.fetchAll(db)
        return Self.merge(operations: operations, directives: directives)
    }

    /// Both sources are in hand here, which is why the cross-reference is made
    /// in Swift rather than by a join this app has nowhere else.
    static func merge(operations: [Operation], directives: [Directive]) -> Value {
        let byID = Dictionary(directives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return operations
            .sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
            .reduce(into: Value()) { owners, op in
                guard op.status.isOpen, op.kind == OperationKind.print.rawValue,
                      let directiveID = op.directiveID, let directive = byID[directiveID]
                else { return }
                owners[op.entityCode, default: []].append(directive.kind.title)
            }
    }
}
```

The `merge` static re-checks `status.isOpen` and the kind even though `fetch` already filtered — `merge` is the tested surface and must be correct on its own inputs.

- [ ] **Step 4: Wire it into state**

In `PrintQueueFeature.State`, beside the existing `@FetchAll` at `:32-33`:

```swift
    @ObservationStateIgnored
    @Fetch(PrintQueueOwners()) public var owners: [String: [String]] = [:]
```

Match the surrounding declaration style exactly; `PrintQueueFeature.swift:64-67` documents why `selectedDevice` is derived rather than fetched, and the same reasoning applies to anything derived from `owners`.

- [ ] **Step 5: Render it**

In `PrintQueueDetailView`'s `queue(_:)` section (`:216-255`), under the `RCSectionHeader("Queue")` and above the `ForEach`, add the owner line when there is one:

```swift
            if let running = store.owners[device.deviceCode], !running.isEmpty {
                Text("Ordered by \(running.joined(separator: ", "))")
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextTertiary)
            }
```

In `PrintQueueListView`'s active-job block (`:96-114`), add the same line under the target type, using `.rcCaption` / `.rcTextTertiary`.

A run title is **prose, not a designation** — it does not go in a mono token. The device code beside it stays `.rcMonoSmall` as it is today (`PrintQueueListView.swift:88`).

- [ ] **Step 6: Run `PrintQueueFeatureTests` and the other five targets**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

Expected: all six green. `PrintQueueFeatureTests` had 6 cases before this task and gains 5.

- [ ] **Step 7: Look at it**

Build and run the app, open the Print Queue with a run printing, and confirm the line reads sensibly at both surfaces. Take a screenshot into the ticket's `## Comments`. The house rules on colour are in `app/CLAUDE.md`; do not encode meaning in hue.

- [ ] **Step 8: Comment budget, commit**

Commit with the message `feat(printqueue): name the run that ordered each bench's print`.

**Phase A ends here.** Every subsequent task changes the substrate.

---

# Phase B — depth within one bench

Phase A gave every bench at a depot a job. Phase B lets one bench hold several, which is what a depot whose demand exceeds its bench count needs. It is where all the risk in Stage 3 lives, and it must not start until Checkpoint E has been run and recorded.

**The ordering rule for this phase:** additions first, then the migration, then the readers. Task 9 adds `queuedOperations` while the index still enforces uniqueness, so it is a pure addition that changes nothing. Task 10 relaxes the index and scopes the supersede in the same commit, because either alone is worse than neither.

---

## Task 9: `WorldSnapshot` gains `queuedOperations`

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift:29`, `:237-239`, `:353`
- Test: `app/Modules/DirectiveEngine/Tests/WorldSnapshotTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `WorldSnapshot.queuedOperations: [String: [Operation]]`, keyed by device code, oldest first. Tasks 12 and 14 read it.

**A pure addition.** `openOperations` keeps its current meaning until Task 12. Doing it now means the migration in Task 10 lands with the reader already in place.

- [ ] **Step 1: Write the failing test**

```swift
    @Test("a device's live ops are queued oldest first")
    func queuedOpsAreOldestFirst() {
        let older = op(on: "B1", owner: "D-7", id: "OP-1", startedAt: now.addingTimeInterval(-120))
        let newer = op(on: "B1", owner: "D-9", id: "OP-2", startedAt: now.addingTimeInterval(-60))
        let world = WorldSnapshot(
            devices: [:], openOperations: ["B1": older],
            queuedOperations: ["B1": [newer, older]], dispatchedOperations: [:], now: now
        )

        #expect(world.queuedOperations["B1"]?.map(\.id) == ["OP-1", "OP-2"])
    }
```

That test as written pins the *initialiser's* sorting, which means the initialiser must sort rather than trust its caller. Decide deliberately: if `queuedOperations` is sorted at the read site (`:237-239`) and the memberwise init trusts it, then this test is testing nothing and must instead go against the read path. **Read `WorldSnapshot`'s init before writing this** — if the test-facing init is memberwise and unsorted, sort inside it and say so in the ticket.

- [ ] **Step 2: Run and confirm it fails**

Run: `cd app/Modules && swift build --build-tests`

Expected: FAIL to compile — the initialiser has no `queuedOperations:` argument.

- [ ] **Step 3: Add the property and fill it**

At `:29`, beside `openOperations`:

```swift
    /// Every live operation per device, oldest first. One element per device
    /// until the print index relaxes; several on a bench afterwards.
    public let queuedOperations: [String: [GameModels.Operation]]
```

At the construction site (`:353`), beside the existing uniquing dictionary:

```swift
        queuedOperations: Dictionary(grouping: operations.filter(\.status.isOpen), by: \.entityCode)
            .mapValues { $0.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt } },
```

The `id` tie-break matters: `startedAt` is a client clock stamped at dispatch and two ops in one transaction can share it. Without the tie-break the order is unstable across reads, and Task 11's "oldest wins" rule inherits that instability.

- [ ] **Step 4: Run all six targets**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

Expected: all green. Every existing `WorldSnapshot(...)` construction in tests needs the new argument — give it a default of `[:]` on the memberwise init so the ~200 existing call sites do not all have to change, and note in the ticket that the default exists for that reason.

- [ ] **Step 5: Comment budget, commit**

Commit with the message `feat(directives): WorldSnapshot.queuedOperations`.

---

## Task 10: Relax the index, and stop the supersede eating siblings

**Files:**
- Modify: `app/Modules/GameModels/Sources/Operation.swift` (append a migration after `addOwnerColumns` at `:293`)
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift:94` (append to the manifest)
- Modify: `app/Modules/GameServices/Sources/CommandClient.swift:247-262`
- Modify: `app/Modules/GameDatabase/Tests/Fixtures/schema.sql:18-20` (regenerated)
- Test: `app/Modules/GameServices/Tests/CommandClientTests.swift`, `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new in Swift. The invariant changes: **at most one `active` op per device; any number of `enqueued`.**

**The one task in this plan that changes schema.** It carries the migration and the supersede scope in one commit, because relaxing the index without scoping the supersede changes nothing observable (print #2 still kills print #1), and scoping the supersede without relaxing the index makes the second insert fail the constraint.

- [ ] **Step 1: Write the failing test for the supersede scope**

`CommandClientTests.swift:212-217` currently asserts `openCount == 1` — "exactly one open op survives (the new travel)". That case pins the **travel** behaviour, which does not change, so leave it alone and add beside it:

```swift
    /// A second print on a bench queues behind the first. Travel still
    /// supersedes, because a device travels to one place at a time.
    @Test("a second print does not supersede the first")
    func secondPrintDoesNotSupersedeTheFirst() async throws {
        let client = CommandClient.testInstance(database: database)
        _ = try await client.enqueuePrint(
            deviceCode: "B1", params: CommandParams(deviceType: "mining_drone")
        )
        _ = try await client.enqueuePrint(
            deviceCode: "B1", params: CommandParams(deviceType: "ftl_relay")
        )

        let live = try await database.read { db in
            try Operation.where { $0.entityCode.eq("B1") && $0.status.in(OperationStatus.liveCases) }
                .fetchAll(db)
        }

        #expect(live.count == 2)
        #expect(live.filter { $0.status == .active }.count <= 1)
    }
```

**`CommandClient.testInstance` and `enqueuePrint` are placeholders for whatever `CommandClientTests` already uses to stand up a client and issue a tracked command** — read the file and use its own names. `CommandClientTests.swift:212-217` is the nearest case and does exactly this shape for travel; copy its arrange half and change the kind. Do not invent a new harness, and do not stub the network: the supersede fires on *confirm*, so a test that never confirms proves nothing.

The two prints deliberately differ by `device_type`. Two **identical** prints would additionally hit `CommandGovernor`'s de-dup on `paramsDigest` (`:86-101`), which is a separate mechanism, tested separately in Task 15.

- [ ] **Step 2: Run and confirm it fails**

Run: `cd app/Modules && swift test --filter CommandClientTests --event-stream-output-path <path>`

Expected: FAIL — either on the unique constraint at insert, or with `live.count == 1` after the supersede. Record which, because it tells you whether the index or the supersede fires first.

- [ ] **Step 3: Append the migration**

In `Operation.swift`, after `addOwnerColumns`:

```swift
    /// One ACTIVE operation per device; enqueued prints queue behind it.
    public static let relaxOpenIndex = SchemaMigration("Relax 'operations' open index to active only") { db in
        try #sql(#"DROP INDEX IF EXISTS "operation_one_open_per_device""#).execute(db)
        try #sql(
            """
            CREATE UNIQUE INDEX "operation_one_active_per_device"
              ON "operations" ("entityCode")
              WHERE "status" = 'active'
            """
        )
        .execute(db)
    }
```

Append `GameModels.Operation.relaxOpenIndex,` to `GameDatabase.manifest` (`GameDatabase.swift:94`) as entry #47, **after** `TheatreRecord.createTheatres`. Never edit or reorder a shipped entry.

A new index name rather than the old one reused: `DROP INDEX` plus `CREATE INDEX` under the same name would leave two databases with the same name and different predicates depending on migration path, and nothing would tell them apart.

- [ ] **Step 4: Scope the supersede**

At `CommandClient.swift:247-262`, the loop marks every other open op on the device `.superseded`. It must stop doing that between two prints. The narrowest correct rule is **supersede only what this command replaces**, which for every kind except print is "the device's other live op", and for print is "nothing":

```swift
            // A device travels to one place and mines one body, so a new command
            // replaces whatever it was doing. Prints queue instead.
            if kind != .print {
                for var other in openOps where other.id != opID {
                    other.status = .superseded
                    try Operation.upsert { other }.execute(db)
                }
            }
```

Read the surrounding block before writing this: the existing comment at `:248-249` names the index as its reason and must be replaced, not left, because that reason no longer holds.

**Check whether `kind` is in scope at that point.** If it is not, thread it rather than reaching for the op row — `openOps` may not contain the op being confirmed.

- [ ] **Step 5: Regenerate the golden schema, deliberately**

Run: `RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --filter GoldenSchemaTests` from `app/Modules`.

Then read `GameDatabase/Tests/Fixtures/schema.sql` and confirm by eye that the **only** change is the index at `:18-20`. Any other diff means something else moved and the regeneration is not clean. Update `SchemaManifestTests`'s frozen identifier list with the new migration's identifier string, exactly as written.

Say in the commit message that the fixture was regenerated and why.

- [ ] **Step 6: Run all eight targets**

This task touches `GameDatabase` and `GameServices`, so the six become eight: add `GameDatabaseTests` and confirm `DatabaseEraseResetTests` (which asserts the index at `:50-51`) is updated rather than deleted.

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

- [ ] **Step 7: Prove the relax is real**

Insert two `enqueued` print ops on one device directly in a test database and confirm both persist. Then insert two `active` ops on one device and confirm the second is rejected. Both assertions belong in `GameDatabaseTests`, and the second is the one that proves the index still does its remaining job.

- [ ] **Step 8: Comment budget, commit**

Commit with the message `feat(operations): one ACTIVE op per device; prints queue`, and name the regenerated fixture in the body.

---

## Task 11: The three `fetchOne`s pick deterministically

**Files:**
- Modify: `app/Modules/GameServices/Sources/Reconciler.swift:121-126`, `:284-286`, `:438-482`
- Modify: `app/Modules/GameSync/Sources/DeadlineScheduler.swift:186-200`, `:249-255`
- Test: `app/Modules/GameServices/Tests/ReconcilerDeviceEventTests.swift`, `app/Modules/GameSync/Tests/PollAndDeadlineTests.swift`

**Interfaces:**
- Consumes: `Operation.printedDeviceType` (Task 2).
- Produces: `Reconciler.completeOpenOperation(on:source:eventTime:result:allowedKinds:operationID:)` — a new optional `operationID` argument. `DeadlineScheduler` passes it.

**Three sites, three different fixes.** They are grouped because they share one failure mode: an unordered `fetchOne` over `liveCases` returns an arbitrary row once N can exist.

- [ ] **Step 1: Write the failing tests**

```swift
    /// B3. A completion closes the oldest live print, not whichever row the
    /// query plan happened to surface.
    @Test("a print completion closes the oldest live print")
    func completionClosesTheOldest() async throws {
        // Arrange: three print ops on "B1" — id "OP-A" .active startedAt T-120,
        // "OP-B" .enqueued at T-60, "OP-C" .enqueued at T-30. Insert them in
        // the order C, A, B so no natural rowid order matches the answer.
        // Act: apply a `print.completed` event for deviceCode "B1" at T-0.
        // Assert:
        #expect(try await status(of: "OP-A") == .completed)
        #expect(try await status(of: "OP-B") == .enqueued)
        #expect(try await status(of: "OP-C") == .enqueued)
    }

    /// B2. A poll that adopts an activity must not adopt a second one when a
    /// live op already covers it — the new index would reject the insert and
    /// roll back the whole fleet walk.
    @Test("a poll does not adopt a second op for the same activity")
    func pollDoesNotAdoptTwice() async throws {
        // Arrange: "B1" already carries an .active print op. Ingest a device
        // payload whose detail["printing"] block names the same activity.
        // Assert: exactly one .active op on "B1", and the fleet walk did not throw.
        #expect(try await liveOps(on: "B1").filter { $0.status == .active }.count == 1)
    }

    /// The deadline scheduler already holds the id of the op that expired and
    /// must stop throwing it away.
    @Test("an expired deadline closes its own operation")
    func deadlineClosesItsOwnOperation() async throws {
        // Arrange: "B1" carries .active "OP-A" with completesAt in the past and
        // .enqueued "OP-B" started later. Act: run the deadline sweep.
        #expect(try await status(of: "OP-A") == .completed)
        #expect(try await status(of: "OP-B") == .enqueued)
    }
```

`status(of:)` and `liveOps(on:)` are one-line read helpers to write in the test file. **The arrange comments are the specification, not a sketch**: the insert order in the first test is load-bearing — inserting in the answer's order lets an unordered `fetchOne` pass by luck, and the whole point is that it currently passes by luck. Stand up the database and the reconciler however `ReconcilerDeviceEventTests` and `PollAndDeadlineTests` already do; do not invent a second harness.

- [ ] **Step 2: Run and confirm they fail**

Run: `cd app/Modules && swift test --filter "Reconciler|PollAndDeadline" --event-stream-output-path <path>`

- [ ] **Step 3: `completeOpenOperation` selects the oldest, or the named one**

```swift
    guard var op = try Operation.where({
        $0.entityCode.eq(deviceCode) && $0.status.in(OperationStatus.liveCases)
    })
    .order { ($0.startedAt, $0.id) }
    .fetchAll(db)
    .first(where: { operationID == nil || $0.id == operationID })
    else { return false }
```

Read the StructuredQueries API before writing this — if `.order` cannot take a tuple, order by `startedAt` and break the tie in Swift. Do not leave the tie unbroken; two ops dispatched in one transaction share a `startedAt`.

**Departure 4 applies here.** Ticket 18 asks for selection by `detail.params.device_type` matched against the event's device type. That field is absent on adopted ops (`Reconciler.swift:135,190`) and the event's device type is discarded before this function is reached (`:439-445`). **Oldest-first is the rule this task implements.** Open Question 3 asks the operator to run the probe that would justify the refinement; if the answer arrives during this task, add the type match as an additional `first(where:)` predicate **above** the oldest rule, never in place of it.

- [ ] **Step 4: `DeadlineScheduler` passes the id it already holds**

At `:200` and `:255`, `completeOpenOperation(on: op.entityCode, …)` discards `op.id` two lines after asserting `op.status == .active` (`:188-192`). Pass `operationID: op.id`. This is the cheapest of the three fixes and the one with the least room for doubt.

- [ ] **Step 5: `Reconciler.apply`'s adopt/promote arm**

At `:121-126` the `fetchOne` feeds a four-arm switch. Replace it with the same ordered fetch, then:
- the **adopt** arm (`case nil`, `:127-143`) must additionally check that no live op already covers this activity, or a poll during a queued print inserts a duplicate `.active` row and the new index rejects the transaction, rolling back the whole fleet walk (`Reconciler.swift:66-79`);
- the **promote** arm keeps its guards but must promote the op the device is actually running, which is the oldest live one;
- the **complete-as-stale** arm (`:182-195`) is the dangerous one: it currently completes "the op whose activity no longer matches", and with N enqueued siblings that is an arbitrary one. Scope it to `.active` ops only. An `enqueued` print is not stale merely because the device is printing something else — that is precisely a queue.

- [ ] **Step 6: `applyDeviceEvent`'s copy**

`:284-286` is the same unordered `fetchOne` on the SSE path (`GameSync.swift:305-310`). Give it the same ordered fetch. It is a second copy of B3, not a different bug — extract the ordered fetch into one private helper on `Reconciler` and have both call it, or the next change will fix one and not the other.

- [ ] **Step 7: Run all eight targets**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

- [ ] **Step 8: Comment budget, commit**

Commit with the message `fix(operations): a completion closes the op it names, or the oldest`.

---

## Task 12: `openOperations` becomes the active op

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift:26-29`, `:182`, `:186-191`, `:353`
- Test: `app/Modules/DirectiveEngine/Tests/WorldSnapshotTests.swift:161-180`

**Interfaces:**
- Consumes: `queuedOperations` (Task 9).
- Produces: `openOperations` narrowed to `.active`. Every engine consumer listed below inherits the change.

**Carries C9.** The `uniquingKeysWith: { _, last in last }` collapse at `:353` is the last place N ops silently become one, and its doc comment ("**The single OPEN operation per device**") has been false since Task 10 landed.

- [ ] **Step 1: Rewrite the invariant test**

`WorldSnapshotTests.swift:161-180` is titled "the one open op per device are keyed for O(1) lookup". Replace it:

```swift
    @Test("the active op is keyed per device; queued ops are not")
    func activeOpIsKeyedPerDevice() {
        let active = op(on: "B1", owner: "D-7", id: "OP-1", status: .active)
        let queued = op(on: "B1", owner: "D-9", id: "OP-2", status: .enqueued)
        let world = read([active, queued])

        #expect(world.openOperation(for: "B1")?.id == "OP-1")
        #expect(world.queuedOperations["B1"]?.map(\.id) == ["OP-1", "OP-2"])
    }

    /// A bench with nothing on the platen but jobs waiting has no active op.
    @Test("a bench with only queued jobs has no active op")
    func queuedOnlyHasNoActiveOp() {
        let world = read([op(on: "B1", owner: "D-9", id: "OP-2", status: .enqueued)])

        #expect(world.openOperation(for: "B1") == nil)
        #expect(world.queuedOperations["B1"]?.count == 1)
    }
```

`read(_:)` is whatever that suite already uses to build a snapshot from operation rows; if it builds one by hand, this test must go through the real read path (`:237-239` and `:353`), because that is the code being changed.

- [ ] **Step 2: Run and confirm the second fails**

Run: `cd app/Modules && swift test --filter WorldSnapshotTests --event-stream-output-path <path>`

Expected: `queuedOnlyHasNoActiveOp` fails — `openOperations` currently includes `enqueued`, so the queued job is returned as though it were active.

- [ ] **Step 3: Narrow the dictionary**

At `:353`, key `openOperations` on `.active` only. Leave the read at `:237-239` fetching `openCases` — `queuedOperations` needs them, and one query serving both is the point.

Update the doc comments at `:26-29` and `:182`, which now say something false.

- [ ] **Step 4: Walk every consumer**

These call `world.openOperation(for:)` or `openOperation(for:owner:)` and each must be read and classified. Do not change one without saying which class it is in the ticket's `## Comments`:

| Site | Question to answer |
|---|---|
| `Steps/PrintJob.swift:56-58` (`stillPrinting`) | Must widen to `queuedOperations` — a run's queued print is still its print |
| `Steps/TravelTo.swift:56` | Travel is `.active` or nothing; narrowing is correct and changes nothing |
| `EventRun.swift:443,533,703,738,801` | Same: all non-print activities |
| `MineRun.swift:378`, `RepairFleet.swift:85,104`, `RelayRun.swift:242` | Same |
| `MineFleetPrint.swift:86`, `RestockRun.swift:95,159`, `EventCourierPrint.swift:83` | Task 6 deleted or replaced most of these; confirm what remains reads `queuedOperations` |
| `PrintScheduler.benches` | Task 14 |

The rule: **a print site asks `queuedOperations`; everything else keeps `openOperations`.** A site that gets this wrong fails silently — it simply stops seeing its own job.

- [ ] **Step 5: Run all eight targets**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

- [ ] **Step 6: Record the borrow count, comment budget, commit**

Commit with the message `refactor(directives): openOperations means the active op (C9)`.

---

## Task 13: The device inspector stops lying about a busy bench

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DeviceDetailView.swift:32`, `:41-45`, `:319-329`
- Modify: `app/Modules/DevicesFeature/Sources/ActiveTaskCard.swift:20`, `:107`, `:113-118`, `:149-153`
- Create: `app/Modules/DevicesFeature/Tests/DeviceDetailOperationsTests.swift`

**Interfaces:**
- Consumes: `Operation.status`, `OperationStatus.isOpen`.
- Produces: nothing downstream.

**Carries C10, and it is the one user-visible regression the relax introduces.** `openOperation` is `operations.first { entityCode == code && status.isOpen }` over a `startedAt DESC` fetch. With one live op, "newest open" is "the only one". With three, a later-started **enqueued** job wins, `ActiveTaskCard` drops the progress bar and renders **"Queued — awaiting start."** while the printer is visibly printing. `.id(operation.id)` (`ActiveTaskCard.swift:113,118`) then resets the bar's latch whenever the pick flips.

- [ ] **Step 1: Write the failing test**

```swift
//
//  DeviceDetailOperationsTests.swift
//  Replicould — DevicesFeature
//

@Suite("Device detail — which operation the card shows")
struct DeviceDetailOperationsTests {

    /// C10. The enqueued job started later, so a `startedAt DESC` fetch put it
    /// first and the card said "Queued" over a running printer.
    @Test("the card shows the active job, not the newest open one")
    func cardShowsTheActiveJob() {
        let active = op(on: "B1", id: "OP-1", status: .active, startedAt: now.addingTimeInterval(-120))
        let queued = op(on: "B1", id: "OP-2", status: .enqueued, startedAt: now.addingTimeInterval(-30))

        #expect(DeviceOperations.card(for: "B1", in: [queued, active])?.id == "OP-1")
    }

    @Test("a bench with only queued jobs shows the oldest of them")
    func queuedOnlyShowsTheOldest() {
        let first = op(on: "B1", id: "OP-1", status: .enqueued, startedAt: now.addingTimeInterval(-120))
        let second = op(on: "B1", id: "OP-2", status: .enqueued, startedAt: now.addingTimeInterval(-30))

        #expect(DeviceOperations.card(for: "B1", in: [second, first])?.id == "OP-1")
    }

    @Test("the queued-behind count excludes the job on the card")
    func queuedBehindExcludesTheCard() {
        let active = op(on: "B1", id: "OP-1", status: .active)
        let a = op(on: "B1", id: "OP-2", status: .enqueued)
        let b = op(on: "B1", id: "OP-3", status: .enqueued)

        #expect(DeviceOperations.queuedBehind(for: "B1", in: [active, a, b]) == 2)
    }
}
```

- [ ] **Step 2: Run and confirm they fail**

Run: `cd app/Modules && swift test --filter DeviceDetailOperationsTests --event-stream-output-path <path>`

Expected: FAIL to compile — `DeviceOperations` does not exist. The selection logic is being pulled out of the view precisely so it can be tested; a `private var` on a `View` cannot be.

- [ ] **Step 3: Extract the pick into a testable namespace**

New file `app/Modules/DevicesFeature/Sources/DeviceOperations.swift`:

```swift
//
//  DeviceOperations.swift
//  Replicould — DevicesFeature
//
//  Which of a device's live operations the detail card shows, and how many
//  are waiting behind it.
//

import Foundation
import GameModels

enum DeviceOperations {
    /// The job the card should show: what the device is doing now, or the
    /// oldest thing it is about to do.
    static func card(for deviceCode: String, in operations: [Operation]) -> Operation? {
        let live = operations
            .filter { $0.entityCode == deviceCode && $0.status.isOpen }
            .sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
        return live.first { $0.status == .active } ?? live.first
    }

    /// How many of the device's live operations are waiting behind the card's.
    static func queuedBehind(for deviceCode: String, in operations: [Operation]) -> Int {
        let live = operations.filter { $0.entityCode == deviceCode && $0.status.isOpen }
        return max(0, live.count - 1)
    }
}
```

- [ ] **Step 4: Use it in the view**

Replace `DeviceDetailView.swift:41-45` with a call to `DeviceOperations.card(for:in:)`, and pass `queuedBehind` into `ActiveTaskCard` as a new argument. Render it beside the existing status line, in `.rcCaption` / `.rcTextTertiary`, as "2 queued behind" — and render nothing at all when the count is zero, rather than "0 queued behind".

Keep `.id(operation.id)` on the progress bar (`:113,118`). It is correct: when the card's job genuinely changes, the latch should reset. What was wrong was the pick, not the latch.

- [ ] **Step 5: Run all eight targets, then look at it**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

Build and run the app; open a bench with a print running and at least one queued. Confirm the progress bar is present and the count reads correctly. Screenshot into the ticket.

- [ ] **Step 6: Comment budget, commit**

Commit with the message `fix(devices): the task card shows the active job and what waits behind it (C10)`.

---

## Task 14: The scheduler uses real depth

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/PrintScheduler.swift`
- Test: `app/Modules/DirectiveEngine/Tests/PrintSchedulerTests.swift`

**Interfaces:**
- Consumes: `WorldSnapshot.queuedOperations` (Task 9).
- Produces: `choose` may now return an occupied bench; `Bench.owners` may hold several.

**This is what Phase B was for.** Until now `choose` has taken only an idle bench (Task 2). With the substrate able to hold a queue, a depot whose demand exceeds its bench count should queue rather than wait.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test("with every bench busy, the shallowest queue takes the job")
    func shallowestQueueTakesTheJob() {
        let world = snapshot([
            bench("B1", queued: ["a", "b"], printing: "c"),
            bench("B2", queued: ["a"], printing: "c"),
            bench("B3", queued: ["a", "b", "c"], printing: "d")
        ])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B2")
    }

    @Test("equal depth breaks by device code")
    func equalDepthBreaksByCode() {
        let world = snapshot([bench("B2", printing: "a"), bench("B1", printing: "a")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B1")
    }

    @Test("a free bench still beats a shallow queue")
    func freeStillBeatsShallow() {
        let world = snapshot([bench("B1", printing: "a"), bench("B2")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world)?.device.deviceCode == "B2")
    }

    @Test("a bench at capacity takes nothing")
    func fullBenchTakesNothing() {
        let world = snapshot([bench("B1", capacity: 2, queued: ["a"], printing: "b")])

        #expect(PrintScheduler.choose(order(), at: depot, in: world) == nil)
    }

    @Test("two runs on one bench are both owners, oldest first")
    func twoOwnersOnOneBench() {
        let older = op(on: "B1", owner: "D-7", id: "OP-1")
        let newer = op(on: "B1", owner: "D-9", id: "OP-2", status: .enqueued)
        let world = snapshot([bench("B1", printing: "a", queued: ["b"])],
                             queued: ["B1": [older, newer]])

        #expect(PrintScheduler.benches(at: depot, in: world).first?.owners == ["D-7", "D-9"])
    }
```

- [ ] **Step 2: Run and confirm they fail**

Run: `cd app/Modules && swift test --filter PrintScheduler --event-stream-output-path <path>`

Expected: the first four return nil (Task 2's `choose` takes only idle benches); the fifth returns one owner.

- [ ] **Step 3: Widen `choose` and `benches`**

```swift
    /// The bench that should take `order` at `depot`, or nil when none can.
    ///
    /// A free bench beats a shallow queue, a shallow queue beats a deep one,
    /// and the lowest device code breaks every tie.
    static func choose(_ order: PrintOrder, at depot: String, in world: WorldSnapshot) -> Bench? {
        benches(at: depot, in: world)
            .filter { $0.queueDepth < $0.device.queueSize }
            .min { left, right in
                left.queueDepth == right.queueDepth
                    ? left.device.deviceCode < right.device.deviceCode
                    : left.queueDepth < right.queueDepth
            }
    }
```

and in `benches`, take owners from `queuedOperations`:

```swift
                let live = world.queuedOperations[device.deviceCode] ?? []
                return Bench(
                    device: device,
                    activeJob: live.first { $0.status == .active },
                    queueDepth: depth(of: device),
                    owners: live.compactMap(\.directiveID)
                )
```

**`queueSize` as the capacity is a real reading of the field but an unproven one at the boundary.** `Printing.swift:141-143` documents it as capacity, and `PrintingSnapshotTests.swift:117-124` pins an idle bench advertising ten. What is *not* evidenced anywhere is whether a `quantity: 3` job occupies one queue slot or three. `fullBenchTakesNothing` above pins the one-slot-per-job reading. Open Question 4 asks the operator to settle it; until then, a job's quantity is not counted against capacity, and that is a deliberate under-count that risks a rejected enqueue rather than a lost one.

- [ ] **Step 4: Revisit `onOrder`'s blind spot**

Task 2 recorded that `onOrder` misses a job whose op row was lost, and that Phase A made this unreachable by never dispatching onto an occupied bench. Task 14 makes it reachable again. Decide, and write the decision into the ticket:

- if Task 10's supersede scoping is complete, a print op is never superseded and the blind spot stays closed — assert that with a test rather than reasoning about it;
- if it is not, `onOrder` must widen to `queuedOperations` and take the max against the printer's queue per type, which the "Where the spec did not survive measurement" section explains and Task 2 declined to build.

- [ ] **Step 5: Run all eight targets**

Run: `cd app/Modules && swift test --event-stream-output-path <path>`

- [ ] **Step 6: Prove the ordering is pinned**

Mutate the `min` comparator to prefer the deepest queue and re-run: expected `shallowestQueueTakesTheJob` and `freeStillBeatsShallow` both fail. Restore. Mutate the capacity filter to `<=` and re-run: expected `fullBenchTakesNothing` fails. Restore.

- [ ] **Step 7: Record the borrow count, comment budget, commit**

Commit with the message `feat(directives): the scheduler queues behind a busy bench`.

**Checkpoint F follows this task.**

---

## Task 15: The governor, the doc comments, and the measurement

**Files:**
- Modify: `app/Modules/GameServices/Sources/CommandGovernor.swift:84-106` (if the test in Step 1 says so)
- Modify: the doc comments listed below
- Modify: `.scratch/directives-architecture/punch-list.md`

**Interfaces:** none.

**The tidy-up ticket, and the one that records what Stage 3 actually achieved.**

- [ ] **Step 1: Test the governor against two identical jobs**

`CommandGovernor` de-dups on `(directiveID, step, entityCode, kind, paramsDigest, startedAt >= owner.since, status != .failed)` (`:86-101`). Two identical prints from one run in one step on one bench are refused as `.deferred(.duplicate)`.

Write the test that decides whether that is right:

```swift
    /// A run that genuinely wants two of the same thing on the same bench in
    /// the same step. Does the governor let it, and should it?
    @Test("two identical prints in one step are de-duplicated")
    func twoIdenticalPrintsAreDeduplicated() async throws {
        // Arrange: one CommandOwner (directiveID "D-7", step "stocking",
        // since T-60). Act: dispatch `enqueue_print` twice on "B1" with the
        // SAME CommandParams — same deviceType, same quantity, same tags, so
        // the same paramsDigest.
        #expect(second == .deferred(.duplicate))
        #expect(try await liveOps(on: "B1").count == 1)
    }
```

Then decide, and record the decision in the ticket:
- **If the missions never do this**, the guard is correct and the test pins it as intended behaviour. `MineFleetPrint` orders `quantity: n` in one job rather than n jobs (`MineFleetPrint.swift:114-118`), and `RestockRun` orders one relay at a time against a demand that `onOrder` decrements — so on the evidence in this plan, neither does. Prefer this reading; changing a de-dup guard to permit something nothing asks for is how duplicate spends get built.
- **If a mission does need it**, the digest must gain a discriminator, and that is a Stage 3 change with its own test, not a one-line relax.

- [ ] **Step 2: Retire the doc comments the relax made false**

Every one of these states or relies on "one open op per device". Each must be corrected to "one active op per device; prints queue", or deleted where the sentence no longer earns its place:

`GameModels/Sources/Operation.swift:11-16`, `:104-106`, `:260-261`; `DirectiveEngine/Sources/WorldSnapshot.swift:26-29`, `:182`; `GameSync/Sources/OperationRetention.swift:42-43`; `GameServices/Sources/CommandClient.swift:208-210`, `:248-249`; `GameServices/Sources/Reconciler.swift:179-180`; `docs/superpowers/specs/2026-07-27-orrery-travel-indicators-design.md:87`.

The last is a shipped design doc rather than code. Add one line to it saying the invariant changed and where, rather than rewriting it — it is a record of what was decided then.

- [ ] **Step 3: Delete what the migrations orphaned**

Check with LSP, then confirm with a build: `RelayRun.hubFreshness` (if Task 5 left it unreferenced), `PrintRail.hubFreshness` (if `RelayRun` was its only reader), `EventRun.printsInFlight` (deleted in Task 4 — confirm nothing calls it), `RestockRun.pollInterval` if it is still there.

An empty `findReferences` is a cold index, not proof. Delete, build, and let the compiler answer.

- [ ] **Step 4: Work the punch list**

Close these, each with the sha:
- line 249, "Two print sites remain outside `PrintJob`" — closed by Tasks 4 and 5.
- line 255, "`RestockRun.printing` is chooser-scoped and defeated by substitution" — closed by Task 6 (C2).
- line 13, "`MineFleetPrint.stocking` has no deadline above its open-op guard" — Task 6 deleted that guard; confirm the deadline question is now moot and say why, or leave it open with a fresh reason.
- line 246, "All 13 travel sites use the unowned `openOperation` guard" — **not** closed by Stage 3. Task 12 narrowed `openOperations` to `.active`, which changes what that guard sees. Re-read the line and restate it against the new meaning.

Add any new deferrals with `file:line` and why.

- [ ] **Step 5: Record the measurement**

In the ticket's `## Comments`, record:
- the borrow count at each of the five checkpoints, and the final number against the 70 measured at `3ae52be`;
- **the print policy count: five-ways-split before, one after** — enumerate the five rows from the policy table and say, for each, what the single answer now is and which task made it so;
- the observed concurrent-print counts from Checkpoints E and F;
- every case where a mutation probe failed to redden, and what was done about it.

- [ ] **Step 6: Run all eight targets one last time, from scratch**

Run: `cd app/Modules && swift build --build-tests` from clean, then the full suite.

A from-scratch build is the check that Stage 2 ran at its merge and it caught nothing — which is the point of running it anyway.

- [ ] **Step 7: Commit**

Commit with the message `chore(directives): Stage 3 tidy-up — doc comments, orphans, the measurement`.

---

## Open questions for the operator

Four decisions, not tasks. Two of them block nothing; the third wants an answer before Task 11 and the fourth before Task 14.

1. **The rail-short policy stays split 4-1, and this plan does not unify it.** `RelayRun.acquire` stalls with `.printStockShort` when the reserve rail is short; the other four wait. Both are documented as deliberate — `RestockRun.swift:82-85` says a decline is never a stall because "dressing idle calm up as a halt spends an operator's attention on nothing", and `RelayRun` is acquiring the single relay its run exists to place. Departure 5 keeps both by making it a `PrintOrder` parameter. **Is that the end state, or should every print site eventually behave one way?** Nothing breaks either way; it is a question about how much of your attention a short rail deserves.

2. **`onOrder` attributes by operation, never by fleet tag.** A queue entry carries `tags` (`Printing.swift:147-152`), so a job could in principle be attributed to a theatre — but `RestockRun` prints relays untagged (`RestockRun.swift:127`), so tag matching would cover three sites and not the other two. This plan uses ops alone and records the gap. **Worth closing by tagging every print, including relays?** That is one line at each dispatch and would make the printer's own queue a second witness for demand, which would in turn close the "op row was lost" blind spot Task 14 Step 4 has to reason about instead.

3. **Blocks Task 11 Step 3.** Ticket 18 specifies that a `print.completed` should select its operation by matching `detail.params.device_type` to the event's device type. **Nothing in this repository evidences what the server puts in that field** — whether `device_type` on a `print.completed` names the printer or the thing printed. The only documented payload key for that event is `new_device_code` (`GameSync.swift:320`). This plan implements oldest-first, which needs no such field. **Would you run one live probe** — trigger a print, capture the `print.completed` frame, and paste the payload into the ticket? If it names the printed device's type, the refinement is worth adding above the oldest rule. If it names the printer's, the refinement is worthless and the question closes for good.

4. **Blocks Task 14 Step 3.** `Device.queueSize` is the bench's capacity, and the scheduler uses it as the ceiling on depth. **What is not evidenced is whether a `quantity: 3` job takes one queue slot or three.** `MineFleetPrint` routinely orders multi-unit jobs (`MineFleetPrint.swift:114-118`). This plan assumes one slot per job, which under-counts and risks a rejected enqueue rather than a lost one — the safer of the two failure modes, but still a guess. One live observation of a multi-unit print's `print_queue` settles it.

---

## What this plan deliberately does not do

- **It does not add a multi-dispatch `MissionAction`.** Departure 1. Fan-out is across ticks; three benches fill in fifteen seconds.
- **It does not touch the 5 s tick or the per-directive `WorldSnapshot.read`.** Spec §Out of scope names a shared per-tick world as "a Stage 3/4 performance ticket, added when bench count multiplies rows". Phase B multiplies operation rows per device, not device rows, and `queuedOperations` is built from the same single query that already runs. **Measure it at Checkpoint F rather than assuming**: if a depot with four benches and deep queues moves the tick's read time materially, that is the moment the shared-world ticket becomes real, and it belongs to Stage 4's plan.
- **It does not unify the print deadline.** `EventRun`'s is variable (`printSlack` plus the longest blueprint print time, measured from `lastOrderedAt`); the other four are flat `PrintJob.deadline` from `stepStartedAt`. The variable one is doing real work for a mission that orders a dependency tree. Task 15 checks whether it can come home; on the evidence so far it should not.
- **It does not reconcile `Device.canPrint` with `isPrintHub`.** `PrintQueueFeature` filters printers on `features.contains("print")` (`Printing.swift:132`); the engine uses `availableCommands.contains("enqueue_print")` (`Device.swift:177`). The two can disagree, and after Task 4 the engine's answer is the only one used for dispatch — so the screen could list a device the scheduler will never choose. **This is a real inconsistency and it is deferred deliberately**, because settling it means deciding which of the two the server actually guarantees, which is a live-probe question like Open Questions 3 and 4. Task 15 adds it to the punch list rather than guessing.

## Hand-off to ticket 19 (Stage 4)

Three things Stage 4's plan inherits:

- **`PrintScheduler.choose` is the API `StageFleetRun` prints through.** Spec §Stage 4 says "print the recipe at the depot (Stage 3 scheduler)". `PrintOrder(deviceType:quantity:tags:owner:onRailShort:)` is the whole interface; a `FleetRecipe`'s `carried` dictionary maps onto one `PrintOrder` per type, and `onOrder` nets the fan-out exactly as `MineFleetPrint` does after Task 6. `StageFleetRun` should be written as a fan-out from the first line rather than converted from a serial loop later.
- **`MineFleetPrint` is the template, and after Task 6 it is a short one.** Spec §Stage 4 generalises `MineRecipe` into `FleetRecipe`. `MineFleetPrint.remaining(at:in:)` plus the `onOrder` netting plus `PrintScheduler.choose` is the entire print half of a staging run; what `StageFleetRun` adds is stow, adopt, tag and the replicant stall.
- **The reserve rail is per-job and stays that way.** `PrintRail(reserveFloor:)` defaults to `BrainCeiling.aggregateSpendFloor` (35,078). A `stageFleet` prints eleven-plus devices against that floor, so Stage 4 must decide whether a staging run checks the rail once per job (as every site does today) or once per recipe. Once per job is the current behaviour and the safer default; once per recipe would let a run commit to a fleet it cannot finish.

## Definition of done per ticket

- The ticket's tests exist and were run through the JSON event stream; **all six targets** are green (eight for the Phase B tickets that touch `GameDatabase` and `DevicesFeature`).
- Every constant or guard the ticket introduces was **proved by mutation** — the mutation was made, the expected test reddened, and the mutation was reverted. The ticket says which mutations were run.
- The migrated mission's existing suite passes **with no assertion edited**, except where this plan names a deliberate behaviour change (the C-list) and gives it its own test.
- `check-comments.sh` exit 0 on touched paths.
- If a schema changed: `GoldenSchemaTests` fixture regenerated deliberately, `SchemaManifestTests` updated, and the commit message says so. Exactly one ticket in this plan should be doing this.
- The borrow count was recorded at the checkpoints that ask for it, and did not rise.
- A memory note under `app/.claude/memory/` only for a fact a competent reader could not recover from the code; otherwise none.
- Anything a review deferred is a line on `punch-list.md`, with its `file:line` and why.
- `Status: resolved` + commit sha(s) in the ticket's `## Comments`.

## A note on how this plan was verified, and how it was not

Ticket 18's Step 1 was answered by four parallel research passes over `main` at `3ae52be`. **The Swift LSP tool was not available to any of them**, so every `file:line` here was established by exhaustive `rg` sweeps and direct reads rather than by semantic navigation. That is accurate for what it claims — a line either says what is quoted or it does not — but it is weaker than LSP for the one question that matters when deleting: "is anything else calling this?" Tasks 5, 12 and 15 all delete symbols, and each says to confirm with LSP and then with a build.

Three claims in the inherited notes turned out to be wrong when read against the code, and all three would have produced a task that changed nothing and reported success: `RelayRun`'s print site is in `acquire` and not `printing`; `EventRun.printing` dispatches one job per tick and not one per free bench; and the index is not what blocks goal A. The counter-question that found them is the one Stage 2 ended on and it still works: *what result would have falsified this, and was that result reachable?*
