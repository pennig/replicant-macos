# 15 — Typed `DirectiveLogEntry` columns; `MissionLogBudget` and `DirectiveStallDetail` read columns

Type: task
Status: resolved
Blocked by: 02
Labels: directives-architecture, stage-1

Spec S1.6. `MissionLogBudget.dispatchRounds(kind:)` and `lastDispatch` recover "which verb went to which device" by splitting the human-readable summary `"Dispatched <kind> to <device> — …"` on spaces (`MissionLogBudget.swift` was `:44-47, :78-82`); `LastDispatch.unreadable` exists only because the contract is prose. `DirectiveStallDetail` parses `"<reason.rawValue>: <detail>"` out of the newest `.stalled` summary (`DirectiveStallDetail.swift:15-27` ↔ `DirectiveExecutor.swift:368`). Columns, not prose. The summary string stays for display.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (`DirectiveLogEntry` + migration), `app/Modules/GameDatabase/Sources/GameDatabase.swift` (append)
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift` (`entry(…)` writes the columns; `dispatch` passes kind/device; `stall` passes detail), `MissionLogBudget.swift`, `app/Modules/DirectivesFeature/Sources/DirectiveStallDetail.swift`
- Test: `SchemaManifestTests`, `GoldenSchemaTests` (regenerate deliberately), `DirectiveEngineTests` (log assertions), `MineRunTests`/`EventRunTests` (the `lastDispatch` consumers), `DirectiveStallDetailTests`

**Interfaces:**
- Produces on `DirectiveLogEntry`: `commandKind: String?` (the `OperationKind.rawValue` for `.commandDispatched`), `targetDeviceCode: String?` (the device the command went to — distinct from the existing `deviceCode`, which is the built-in-row key), `detail: String?` (the stall detail for `.stalled`). Migration `"Add 'commandKind','targetDeviceCode','detail' to 'directiveLogEntries'"`.
- Produces: `MissionLogBudget.LastDispatch` loses `.unreadable` (`case dispatched(kind: String, deviceCode: String)`, `case nothingSent`).
- Consumes: 02 (not strictly, but the same "no prose" idea; ordering only).

---

- [x] **Step 1: Migration + struct + golden schema (as ticket 02's steps 1–2)**

- [x] **Step 2: Executor writes the columns**

`entry(_:_:_:step:operationID:deviceCode:id:at:)` gains `commandKind: String? = nil, targetDeviceCode: String? = nil, detail: String? = nil`. The `.dispatch` accepted path passes `commandKind: kind.rawValue, targetDeviceCode: deviceCode`; `stall(_:reason:detail:)` passes `detail:`. Summary strings unchanged.

- [x] **Step 3: Readers use columns**

`MissionLogBudget.dispatchRounds(_:dispatch:confirm:kind:)`: `guard entry.kind == .commandDispatched, entry.step == confirm, entry.commandKind == kind.rawValue`. `lastDispatch`: `if let k = entry.commandKind, let d = entry.targetDeviceCode { return .dispatched(kind: k, deviceCode: d) }` — for a legacy row (nil columns) fall back to the old split ONCE, and delete that fallback in Stage 2 (note it in the code with a one-line comment). Delete `.unreadable`; fix `MineRun.confirmArm` (`:483-491`) and `EventRun.confirmStage` (`:578-580`) which switch on it — the `.unreadable` arm's behaviour ("refuse to read evidence that does not parse") becomes unreachable; remove the arm.

`DirectiveStallDetail.detail(for:in:)`: read `entry.detail`; fall back to the prefix parse only when `detail == nil` (legacy rows); delete the fallback in Stage 2.

- [x] **Step 4: Tests**

Extend the executor dispatch test: the `.commandDispatched` entry carries `commandKind == "travel"`, `targetDeviceCode == "V1"`. `MissionLogBudgetTests` (create if absent): `lastDispatch` on typed rows; `dispatchRounds(kind:)` counts typed rows and ignores a summary that would have matched by prose but has a different `commandKind`. `DirectiveStallDetailTests`: reads the column.

- [x] **Step 5: Run all targets; commit**

`feat(log): typed commandKind/targetDeviceCode/detail on directive log entries`.

## Comments

Resolved in `445a015` (columns + readers) and `4e06484` (review fix).

Seven targets green: DirectiveEngineTests 1670, DirectivesFeature 288, DevicesFeature 167, GameSync 81,
GameServices 324, GameModels 149, **GameDatabase 27** (SchemaManifest + GoldenSchema). From-scratch
`swift build --build-tests` clean.

**Schema, verified line by line.** The manifest diff is one appended line; no shipped migration was
edited, renamed or reordered. The identifier is byte-identical in `Directive.swift` and
`SchemaManifestTests`. The regenerated golden fixture diff is **one hunk on one line** — the three
columns appended to `CREATE TABLE "directiveLogEntries"` — with nothing else moved anywhere in the
file. Regeneration was deliberate and stated in the commit body.

**`dispatchRounds(kind:)` needed the legacy fallback that the ticket only gave `lastDispatch`.** The
ticket is silent rather than prohibitive, and the migration hazard is identical for both readers.
Without it, an `eventRun` live across the upgrade counts 0 rounds and re-sends its leg. The exposure is
exactly one leg: `EventRun.stageRounds`' `.depositResources` (`EventRun.swift:594`) has no live-row
guard, and the run's own comment explains why a duplicate cannot be caught downstream — a deposit
leaves no local proof, because a hold may carry more than the option asked for. `depositRounds` is
guarded by `cargoUsed > 0` and targets the depot, so its duplicate is only a redundant unload.

The nil-gate is on `commandKind` specifically, not an `else` after the whole guard. That distinction
matters: the flat shape would let a **typed** row carrying a different kind fall through into the prose
parse and match on its summary.

**Stage 2 now has THREE prose fallbacks to delete, not two:** `MissionLogBudget.lastDispatch`,
`MissionLogBudget.dispatchRounds(kind:)`, and `DirectiveStallDetail.detail(for:in:)`. Each carries a
one-line marker comment.

**`DirectiveStallDetail` still parses the summary prefix, deliberately.** The gate is load-bearing, not
vestigial: the entry records no reason of its own, so without it a typed `.stalled` entry written for an
earlier, different reason would hand its detail to the row's current reason. Making the reader wholly
prose-free needs a fourth `reason` column, which cannot be added here without breaking the frozen
migration identifier.

**`.unreadable` had no dedicated arm** — it fell through to the same tail an unmatched `.dispatched`
takes, so "refuse to read evidence that does not parse" was in practice "buy one refresh, then stall on
the deadline". `MineRun.confirmArm` now re-dispatches, reachable only for a legacy row whose prose also
fails to parse; `arming` re-derives from live `armState` rather than blind-resending, and the path
self-heals in one round because the re-dispatch writes typed columns.

The ticket's Step 4 says the executor test should assert `targetDeviceCode == "V1"`; the fixture's real
device code is `VES1`. The ticket text was wrong, not the code.
