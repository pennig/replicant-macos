# Directives Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Tickets live one per file under `.scratch/directives-architecture/issues/`; steps use checkbox (`- [ ]`) syntax for tracking. Claim a ticket by setting `Status: claimed` before touching code; resolve it by setting `Status: resolved` and appending a `## Comments` note with the commit sha(s).

**Goal:** Retire the three mechanical bug classes that account for half of the Directives incidents (stale evidence, step-machine clock/guard mechanics, tag/lease scoping) by giving the substrate op ownership and honest clocks, giving the engine one typed tag/ownership/launch vocabulary, and turning the copied mission idioms into a step library — then use those seams to build the print scheduler (goal A) and the fleet-provisioning executor (goal B).

**Architecture:** Five stages. Stage 0 changes `operations`, `Reconciler`, `CommandGovernor`, `DirectiveExecutor` and `WorldSnapshot` so every command has an owner and every arrival is one transaction. Stage 1 introduces `FleetTag`, `Ownership`, `Directive.launch`, per-machine `Step` enums, typed log columns and a persisted `theatres` table. Stages 2–4 are designed in `spec.md` and planned by their own tickets (17–19) using `superpowers:writing-plans` once Stages 0–1 have landed, because their exact shape depends on what those stages leave behind.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26+), Composable Architecture, SQLiteData + GRDB, StructuredQueries, Swift Testing, swift-openapi-generator.

**Spec:** `.scratch/directives-architecture/spec.md` — read it first. It carries the seven locked decisions (D1–D7) and the per-stage design; this plan carries only the work.

**Punch list:** `.scratch/directives-architecture/punch-list.md` — small things a review deliberately did not fix. Add a line whenever you defer something; work the list at the end of the effort.

## Global Constraints

Every task's requirements implicitly include this section.

- **LSP setup, once per worktree, before anything else:** `cd app/Modules && swift build --build-tests`, then `./scripts/link-index-store.sh`. Without the second the index returns zero references silently. LSP root is `app/Modules/`, not the repo root.
- **Use Swift-LSP for navigation and verification**, not grep, for anything in `app/Modules/`. An empty `findReferences` on same-session code is a cold index, never proof a symbol is unused — fall back to `swift build --build-tests`.
- **Read test results from the Swift Testing JSON event stream** via the `swift-test-event-stream` skill. Never parse console text; a grep for "fail" false-positives on test method names. Run the whole `DirectiveEngineTests`, `GameServicesTests`, `GameSyncTests`, `GameModelsTests` and `DirectivesFeatureTests` targets after every ticket that touches their module — the recurrence history of this feature is exactly "green in the module I edited, red in the sibling".
- **Migrations are append-only.** A schema change appends a new `SchemaMigration` to `GameDatabase.manifest` (`app/Modules/GameDatabase/Sources/GameDatabase.swift:47`). Never edit, rename or reorder a shipped one. `SchemaManifestTests` freezes the identifier list; `GoldenSchemaTests` snapshots the schema — regenerate with `RC_REGENERATE_SCHEMA_FIXTURE=1` only when the change is intended, and say so in the commit.
- **Comment budget is hard:** file header ≤ 6 lines, `///` ≤ 3 lines, inline `//` ≤ 2 lines. No dated history, no rejected alternatives, no rationale for *why we chose this* — that goes to `app/.claude/memory/` (with an index line in `app/.claude/memory/MEMORY.md`) or this spec. Run `./app/scripts/check-comments.sh <paths>` from the repo root.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = module or service name.
- **Loud test doubles:** a shared client's `testValue` uses `unimplemented(...)`; rich fixtures belong on `previewValue`.
- **UI:** never hard-code colours, spacing or font sizes — use `DesignSystem.swift` tokens. Every system and location designation renders in a monospace token. List-row structs live in their own file, never beside a `#Preview`.
- **Git:** commit directly to `main`, or to a worktree branch merged to `main` on review. No PRs, no pushing, `origin` is not part of the workflow. One commit per ticket step group is fine; the ticket's `## Comments` records the shas.
- **Line numbers in tickets are as of `main` at `ab472ba` (2026-08-16).** They drift. Ticket 01 re-pins them; every later ticket says "at or near".
- **Naming:** the domain word is **Theatre** (British). A **bench** is one print-capable device's queue. A **lease** is a device reserved by a running directive row. A **scoped** tag carries a theatre or belt; an **unscoped** tag does not (the word "bare" in older notes means unscoped).

## Ticket index

Stage 0 — Substrate (all `task`; run in order; 08 optional-deferrable)

| # | Ticket | Blocked by |
|---|---|---|
| 01 | Re-pin line numbers, build, LSP warm-up | — |
| 02 | `operations` ownership columns + rows for immediate verbs | 01 |
| 03 | Governor de-dup on `(directive, step, device, kind, params)` | 02 |
| 04 | Arrival is one transaction; same-second tolerance | 01 |
| 05 | Read actions stop re-stamping `stepStartedAt` | 01 |
| 06 | `.failed` is not `.rejected`: bounded transient retry, `.commandFailed` | 02 |
| 07 | `WorldSnapshot` owner-aware ops + `isFresh`; fix the two open co-tenant print guards | 02 |
| 08 | Reads off the SSE dispatch path (mark + drain) | 04 |

Stage 1 — Typed vocabulary

| # | Ticket | Blocked by |
|---|---|---|
| 09 | `FleetTag` value type + `Device.fleetTags`/`carries` | 01 |
| 10 | Replace the six formatters / seven parsers; fleet refresh fetches scoped + unscoped | 09 |
| 11 | `Ownership.resolve` + one `owningTheatre`; delete the two `owningStatuses` copies | 10 |
| 12 | Survey / Salvage / RepairFleet adopt "scoped tag outranks location" | 11 |
| 13 | `Directive.launch` factory; thirteen sites; launchers stamp theatre; theatre picker; retire the `AINALRAM-BELT-1` UI literal | 11 |
| 14 | Per-machine `enum Step: String`; unknown step → `.wait` everywhere | 01 |
| 15 | Typed `DirectiveLogEntry` columns; `MissionLogBudget` and `DirectiveStallDetail` read columns | 02 |
| 16 | Persistent theatre identity (`theatres` table, sticky recognition) | 11 |

Stages 2–4 — planning tickets (`Type: task`, output = a plan file + tickets 20+)

| # | Ticket | Blocked by |
|---|---|---|
| 17 | Write the Stage 2 (step library) plan from spec §Stage 2 | 07, 14, 15 |
| 18 | Write the Stage 3 (print scheduler) plan from spec §Stage 3 | 17 |
| 19 | Write the Stage 4 (StageFleet + growFleet) plan from spec §Stage 4 | 18 |

## File structure

**New files (Stages 0–1)**

| Path | Responsibility |
| --- | --- |
| `app/Modules/GameServices/Sources/CommandOwner.swift` | The `(directiveID, step, since)` value the governor de-dups on |
| `app/Modules/GameServices/Tests/CommandDedupTests.swift` | Governor de-dup |
| `app/Modules/GameServices/Tests/ReconcilerDeviceEventTests.swift` | Single-transaction arrival + tolerance guard |
| `app/Modules/GameModels/Sources/FleetTag.swift` | `FleetTag`, `Goal`, `Scope`, `MatchPolicy` |
| `app/Modules/GameModels/Tests/FleetTagTests.swift` | Parse/format/match |
| `app/Modules/GameModels/Sources/TheatreRecord.swift` | The `theatres` row + migration |
| `app/Modules/DirectiveEngine/Sources/Ownership.swift` | `Ownership.resolve`, `Holder`, `Via` |
| `app/Modules/DirectiveEngine/Sources/TheatreResolver.swift` | The one `owningTheatre` rule |
| `app/Modules/DirectiveEngine/Sources/DirectiveLaunch.swift` | `Directive.launch(...)` |
| `app/Modules/DirectiveEngine/Tests/OwnershipTests.swift` | Lease derivation, per-theatre scoping |
| `app/Modules/DirectiveEngine/Tests/DirectiveLaunchTests.swift` | Factory invariants per kind |
| `app/Modules/DirectiveEngine/Tests/ExecutorRestampTests.swift` | S0.4 + S0.5 |

**Modified files (Stages 0–1)**

| Path | Change |
| --- | --- |
| `app/Modules/GameModels/Sources/Operation.swift` | `directiveID`, `step`, `paramsDigest` + migration |
| `app/Modules/GameModels/Sources/Directive.swift` | `.commandFailed` reason; `DirectiveLogEntry` typed columns + migration |
| `app/Modules/GameModels/Sources/Device.swift` | `fleetTags`, `carries(_:policy:)` |
| `app/Modules/GameDatabase/Sources/GameDatabase.swift` | Append the four migrations |
| `app/Modules/GameServices/Sources/CommandParams.swift` | `dedupKey` |
| `app/Modules/GameServices/Sources/CommandClient.swift` (+ extensions) | Owner threaded; immediate verbs write rows |
| `app/Modules/GameServices/Sources/CommandGovernor.swift`, `CommandGovernorClient.swift` | `owner:` param, `.duplicate` deferral |
| `app/Modules/GameServices/Sources/Reconciler.swift` | `applyDeviceEvent` (combined), tolerance |
| `app/Modules/GameSync/Sources/GameSync.swift` | `deviceRoute` uses the combined call; marks instead of reads (08) |
| `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift` | owner on dispatch, `.duplicate`, `.failed` budget, `move(restamp:)`, typed log columns |
| `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift` | `resolveFleetRefresh` fetches scoped + unscoped |
| `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift` | owner-aware `openOperation`, `dispatchedOperations` by column, `isFresh`, `TheatreResolver` |
| `app/Modules/DirectiveEngine/Sources/WorldView.swift` | `TheatreResolver`, theatres from persisted rows |
| `app/Modules/DirectiveEngine/Sources/Brain.swift` | `Ownership` views, `Directive.launch`, `persistTheatres`, `owningStatuses` deleted |
| `app/Modules/DirectiveEngine/Sources/{SurveyRun,SalvageRun,HaulRun,RelayRun,MineRun,EventRun,RestockRun,MineFleetPrint,EventCourierPrint}.swift` | `Step` enums, `FleetTag`, owner-aware guards |
| `app/Modules/DirectiveEngine/Sources/{RepairFleet,MineRecipe,TheatreRegistry,MissionLogBudget,MissionRegistry}.swift` | `FleetTag`, sticky recognition, typed log reads |
| `app/Modules/DirectivesFeature/Sources/{DirectivesFeature,NewDirectiveFeature,NewSalvageRunFeature,NewHaulRunFeature,DirectiveRow,DirectiveGroup,DirectiveTargetsSection,DirectiveStallDetail}.swift` | `Directive.launch`, theatre picker, `FleetTag`, `theatreDepot` in place of the literal |
| `app/Modules/DevicesFeature/Sources/DeviceListAttention.swift` | `Ownership` view |

## Order of work and checkpoints

1. Ticket 01, then 02→03, 04, 05 in any order, then 06, 07, then 08 (deferrable).
   **Checkpoint A:** run the app for one full evening with the brain on. Expected: Operations Log shows immediate verbs attributed to their run; no `.simple` re-issue loops in the log (grep the OSLog for repeated `Dispatched <verb>` within one step); RestockRun no longer waits on a co-tenant's print.
2. Tickets 09→10→11→12, 13, 14, 15, 16.
   **Checkpoint B:** stand up a second theatre by pinning; tag one survey vessel `auto:survey:<B>` while it stands near A; confirm the brain launches B's survey with it and A's does not claim it. Print Mine Fleet in B does not reserve A's ferries.
3. Tickets 17→18→19 each produce a plan + tickets and stop for operator review before the build begins.

## Definition of done per ticket

- The ticket's tests exist and were run through the JSON event stream; the whole affected targets are green.
- `check-comments.sh` exit 0 on touched paths.
- If a schema changed: `GoldenSchemaTests` fixture regenerated deliberately, `SchemaManifestTests` updated.
- A memory note under `app/.claude/memory/` only for a fact a competent reader could not recover from the code; otherwise none.
- Anything a review deferred is a line on `punch-list.md`, with its `file:line` and why it was deferred.
- `Status: resolved` + commit sha(s) in the ticket's `## Comments`.
