# 15 — Typed `DirectiveLogEntry` columns; `MissionLogBudget` and `DirectiveStallDetail` read columns

Type: task
Status: open
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

- [ ] **Step 1: Migration + struct + golden schema (as ticket 02's steps 1–2)**

- [ ] **Step 2: Executor writes the columns**

`entry(_:_:_:step:operationID:deviceCode:id:at:)` gains `commandKind: String? = nil, targetDeviceCode: String? = nil, detail: String? = nil`. The `.dispatch` accepted path passes `commandKind: kind.rawValue, targetDeviceCode: deviceCode`; `stall(_:reason:detail:)` passes `detail:`. Summary strings unchanged.

- [ ] **Step 3: Readers use columns**

`MissionLogBudget.dispatchRounds(_:dispatch:confirm:kind:)`: `guard entry.kind == .commandDispatched, entry.step == confirm, entry.commandKind == kind.rawValue`. `lastDispatch`: `if let k = entry.commandKind, let d = entry.targetDeviceCode { return .dispatched(kind: k, deviceCode: d) }` — for a legacy row (nil columns) fall back to the old split ONCE, and delete that fallback in Stage 2 (note it in the code with a one-line comment). Delete `.unreadable`; fix `MineRun.confirmArm` (`:483-491`) and `EventRun.confirmStage` (`:578-580`) which switch on it — the `.unreadable` arm's behaviour ("refuse to read evidence that does not parse") becomes unreachable; remove the arm.

`DirectiveStallDetail.detail(for:in:)`: read `entry.detail`; fall back to the prefix parse only when `detail == nil` (legacy rows); delete the fallback in Stage 2.

- [ ] **Step 4: Tests**

Extend the executor dispatch test: the `.commandDispatched` entry carries `commandKind == "travel"`, `targetDeviceCode == "V1"`. `MissionLogBudgetTests` (create if absent): `lastDispatch` on typed rows; `dispatchRounds(kind:)` counts typed rows and ignores a summary that would have matched by prose but has a different `commandKind`. `DirectiveStallDetailTests`: reads the column.

- [ ] **Step 5: Run all targets; commit**

`feat(log): typed commandKind/targetDeviceCode/detail on directive log entries`.
