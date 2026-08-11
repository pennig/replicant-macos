# Multiple Theatres Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Tickets live one per file under `.scratch/multi-theatre/issues/`; steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalise the brain's single derived logistics hub into several recognised Theatres, each a depot to explore outward from and accrete resources inward to, so the fleet can operate in more than one area of the galaxy.

**Architecture:** A `Theatre` is a value derived once per tick from device rows, operator pins and mesh components — recognised, never placed, exactly as `hubLocation` is today. `WorldView` carries the set plus two resolvers: inward operations filter to the theatre's own mesh component and then take the nearest, outward operations take the nearest with no filter. Every mission that reads the global hub instead reads the theatre named on its own directive row.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26+), Composable Architecture, SQLiteData + GRDB, StructuredQueries, Swift Testing, swift-openapi-generator.

**Spec:** `.scratch/multi-theatre/spec.md` — read it before starting. It carries the four decisions and the reasoning behind each; this plan carries only the work.

## Global Constraints

Every task's requirements implicitly include this section.

- **LSP setup, once per worktree, before anything else:** `cd app/Modules && swift build --build-tests`, then `./scripts/link-index-store.sh`. Without the second the index returns zero references silently. LSP root is `app/Modules/`, not the repo root.
- **Use Swift-LSP for navigation and verification**, not grep, for anything in `app/Modules/`. An empty `findReferences` on same-session code is a cold index, never proof a symbol is unused — fall back to `swift build --build-tests`.
- **Read test results from the Swift Testing JSON event stream** via the `swift-test-event-stream` skill. Never parse console text; a grep for "fail" false-positives on test method names.
- **Migrations are append-only.** A schema change appends a new `SchemaMigration` to `GameDatabase.manifest`. Never edit, rename or reorder a shipped one. `SchemaManifestTests` freezes the identifier list; `GoldenSchemaTests` snapshots the schema — regenerate with `RC_REGENERATE_SCHEMA_FIXTURE=1` only when the change is intended.
- **Comment budget is hard:** file header ≤ 6 lines, `///` ≤ 3 lines, inline `//` ≤ 2 lines. No dated history, no rejected alternatives, no rationale for *why we chose this* — that goes to `app/.claude/memory/` or this plan. Run `./app/scripts/check-comments.sh <paths>` from the repo root.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = module or service name.
- **Loud test doubles:** a shared client's `testValue` uses `unimplemented(...)`; rich fixtures belong on `previewValue`.
- **UI:** never hard-code colours, spacing or font sizes — use `DesignSystem.swift` tokens. Every system and location designation renders in a monospace token (`.rcMono`, `.rcMonoSmall`, `.rcTitleMono`, `.rcHeadlineMono`, `.rcBodyEmphMono`). List-row structs live in their own file, never beside a `#Preview`.
- **Git:** commit directly to `main`, or to a worktree branch merged to `main` on review. No PRs, no pushing, `origin` is not part of the workflow.
- **Naming:** the domain word is **Theatre** (British spelling). It is not `Centre` — `roamCentre` is an existing and different thing — and it is not the game's `system_hub` device.

## File Structure

**New files**

| Path | Responsibility |
| --- | --- |
| `app/Modules/DirectiveEngine/Sources/Theatre.swift` | The `Theatre` value type, its `Origin`, `Readiness` and `Shortfall` |
| `app/Modules/DirectiveEngine/Sources/TheatreRegistry.swift` | Three-tier recognition, one pure function |
| `app/Modules/DirectiveEngine/Sources/TheatreSiteRanking.swift` | Ranks candidate systems for a new theatre; read-only |
| `app/Modules/GameModels/Sources/TheatrePin.swift` | The `theatrePins` row type and its migration |
| `app/Modules/LogisticsFeature/Sources/TheatresTab.swift` | The Theatres list screen |
| `app/Modules/LogisticsFeature/Sources/TheatreRow.swift` | One theatre's list row (own file — preview JIT crash) |
| `app/Modules/LogisticsFeature/Sources/EstablishTheatreSheet.swift` | Pin a depot, optionally queue the `system_hub` print |
| `app/Modules/DirectiveEngine/Tests/TheatreRecognitionTests.swift` | Recognition ordering, readiness, resolvers |
| `app/Modules/DirectiveEngine/Tests/MeshComponentTests.swift` | Component labelling |
| `app/Modules/DirectiveEngine/Tests/MultiTheatreHaulTests.swift` | Component filter and round-trip ranking |

**Modified files**

| Path | Change |
| --- | --- |
| `app/Modules/DirectiveEngine/Sources/MeshGraph.swift` | `components()` labelling |
| `app/Modules/DirectiveEngine/Sources/WorldView.swift` | `theatres` + two resolvers; `hubLocation` becomes a shim, then goes |
| `app/Modules/DirectiveEngine/Sources/HaulTargetPlanner.swift` | Component filter, round-trip ranking |
| `app/Modules/DirectiveEngine/Sources/PrunePredicate.swift` | One union per theatre |
| `app/Modules/DirectiveEngine/Sources/Brain.swift` | `ensureOne` per theatre; origins; why-view focus |
| `app/Modules/DirectiveEngine/Sources/{RelayRun,RestockRun,SalvageRun,MineRun,HaulRun,MineSitePlanner}.swift` | Resolve the directive's theatre |
| `app/Modules/GameModels/Sources/Directive.swift` | `theatreDepot` column + migration |
| `app/Modules/GameModels/Sources/Star.swift` | `region`, `hasHub` columns + migration |
| `app/Modules/GameServices/Sources/StarsClient.swift` (and ingestion) | Carry `region` / `has_hub` through |
| `app/Modules/DirectivesFeature/Sources/{DirectiveRow,DirectiveTargetsSection,BrainWhyView}.swift` | Show and group by theatre |
| `app/Modules/LogisticsFeature/Sources/LogisticsFeature.swift` | Host the Theatres tab |

## Tasks

| # | Ticket | Depends on |
| --- | --- | --- |
| 01 | Mesh component labelling | — |
| 02 | Theatre model and pin storage | — |
| 03 | Theatre recognition | 01, 02 |
| 04 | WorldView theatres and resolvers | 03 |
| 05 | Directive theatre column and adoption | 04 |
| 06 | Brain liveness per theatre | 04, 05 |
| 07 | Haul component filter and round-trip ranking | 04 |
| 08 | Prune per theatre | 04 |
| 09 | Mission theatre resolution | 05 |
| 10 | Retire the hubLocation shim | 06, 07, 08, 09 |
| 11 | Star region and hub ingestion | — |
| 12 | Theatre site ranking | 04 |
| 13 | Logistics Theatres screen | 04, 12 |
| 14 | Theatre on directive rows and the why-view | 05, 10 |

Tasks 01, 02 and 11 have no dependencies and may run in parallel. Task 10 is the gate that proves nothing still depends on a single global hub — it must not be skipped or folded into an earlier task.

## Verification at the end of every task

```
cd app/Modules && swift build --build-tests
swift test --event-stream-output-path /tmp/theatre-events.json
```

Read the result from the event stream per the `swift-test-event-stream` skill. The suite is ~335 tests today; a task that reduces the passing count has broken something regardless of what its own new tests say.
