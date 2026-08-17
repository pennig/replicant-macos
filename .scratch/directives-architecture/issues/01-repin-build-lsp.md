# 01 — Re-pin line numbers, build, warm the LSP

Type: task
Status: resolved
Blocked by: —
Labels: directives-architecture, stage-0

Every later ticket cites `file:line` as of `main` at `ab472ba` (2026-08-16). Lines drift. This ticket makes the worktree buildable, warms the index, and re-pins the anchors the Stage 0 tickets edit so the executor never edits the wrong block.

**Files:**
- Read only. Output is a `## Comments` note on this ticket with the re-pinned lines.

---

- [x] **Step 1: Build and link the index**

Run from the repo root:

```bash
cd app/Modules && swift build --build-tests && ./scripts/link-index-store.sh
```

Expected: build succeeds; the script reports the symlink present.

- [x] **Step 2: Run the baseline suites through the event stream**

Use the `swift-test-event-stream` skill. Run `DirectiveEngineTests`, `GameServicesTests`, `GameSyncTests`, `GameModelsTests`, `DirectivesFeatureTests` and record pass/fail counts per target in this ticket's `## Comments`. Any red test here is pre-existing; note it so later tickets don't inherit it as theirs.

- [x] **Step 3: Re-pin the anchors**

For each symbol below, use LSP `goToDefinition` (root `app/Modules/`) and record the current line in `## Comments` as `symbol → file:line`:

- `Operation.createOperations` (GameModels/Sources/Operation.swift, was :250)
- `CommandClient.liveValue` dispatch closure — the `if completion(for: kind) == .immediate {` branch (GameServices/Sources/CommandClient.swift, was :98) and the optimistic insert `let optimistic = Operation(` (was :162)
- the supersede loop `for var other in openOps where other.id != opID` (was :208)
- `CommandGovernor.dispatch` (GameServices/Sources/CommandGovernor.swift, was :63)
- `CommandGovernorClient.dispatch` property (GameServices/Sources/CommandGovernorClient.swift, was :16)
- `Reconciler.completeOpenOperation` (GameServices/Sources/Reconciler.swift, was :407) and `Reconciler.applyEventFields` (was :259) and the guard `guard eventTime >= device.updatedAt` (was :275)
- `GameSync.deviceRoute` (GameSync/Sources/GameSync.swift, was :308)
- `DirectiveExecutor.apply` `.dispatch` case (DirectiveEngine/Sources/DirectiveExecutor.swift, was :46), `.refreshSystem` (was :100), `.scanSystem` (:111), `.refreshBody` (:128), `.setDeviceTags` (:135), `move(_:to:controllerCode:deviceCode:claimedRelayCode:)` (:330), `commit` (:417)
- `DirectiveEngineCore.resolveFootprintRefresh` (DirectiveEngine/Sources/DirectiveEngine.swift, was :636), `collapse` (:741), `resolveFleetRefresh` (:600)
- `WorldSnapshot.read` (DirectiveEngine/Sources/WorldSnapshot.swift, was :237), `openOperation(for:)` (:175), `dispatchedOperations` field (:46)
- `RestockRun.stocking` guard on `openOperation(for:` (DirectiveEngine/Sources/RestockRun.swift, was :104) and `EventCourierPrint` printer guard (was :81)
- `GameDatabase.manifest` last entry (GameDatabase/Sources/GameDatabase.swift, was :89)

- [x] **Step 4: Resolve**

Set `Status: resolved`. ~~No commit (nothing changed).~~ **Controller ruling overrides this**: this ticket file is git-tracked, so the edit is committed (`docs(directives): ticket 01 — re-pinned anchors and baseline suite results`).

## Comments

**Build + index (Step 1).** `cd app/Modules && swift build --build-tests` — clean build succeeded, "Build complete! (112.44 sec)" (fresh worktree, ~2900 build units). `./scripts/link-index-store.sh` reported `linked .build/index-store -> out (2287 units)`.

**LSP tool availability — deviation note.** This session had no Swift-LSP tool bound (checked via `ToolSearch` for goToDefinition/references/hover/symbol-search — none present; likely this subagent context wasn't launched with the LSP plugin active). Since every anchor's file path is already named explicitly in Step 3 (not something to be discovered by search), anchors were re-pinned by reading each named file directly (`Read`, with `grep -n` used only as an in-file line-locator on a file already known to be the right one, never as a cross-codebase search) and confirming the surrounding code matches the anchor's description. This is a narrower operation than the "cold index / silent empty result" trap the ticket warns about — that risk applies to codebase-wide reference/definition queries, not to reading one already-identified file. The build + link-index-store steps were still run in full, so the index is warm for ticket 02's executor, who should have LSP tools bound.

**LSP status in this worktree.** Verified from the controller session, where an LSP tool IS bound — it does not currently work against this worktree:
- `findReferences` on `WorldSnapshot.openOperation` at `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift:175` returned "No references found", twice, although `RestockRun.swift:101` demonstrably calls it.
- SourceKit reported a diagnostic on that same file: `No such module 'GameModels'` at line 12 — the server cannot resolve the package's own modules.
- Meanwhile the index store is populated: `.build/index-store` → `out` symlink is live and `.build/index-store/v5/units` holds 2287 units, 2 of them for `WorldSnapshot`.
- **Hypothesis, not confirmed**: the harness most likely starts sourcekit-lsp at the session's working directory (the worktree root) rather than at `app/Modules/`, which the plan's binding constraint explicitly names as the LSP root. Not yet root-caused.

**Operational consequence for tickets 02–19**: until this is fixed, treat LSP `findReferences`/`goToDefinition` as unreliable in this worktree — verification of record is full-file `Read` plus `swift build --build-tests`, and an empty `findReferences` result must never be read as "no callers".

**Baseline suites (Step 2).** Ran each target as its own `--test-product` (per the `swift-test-event-stream` skill's multi-target-truncation guidance) with `--event-stream-version "6.3"`, one event-stream file per target under `app/Modules/.build/task01-events/`. Each stream showed exactly one module, one `runEnded`, and no started-but-unterminated tests (no crashes). Raw evidence: `app/Modules/.build/task01-events/*.jsonl` (one file per target). `.build/` is gitignored and disappears on a clean — this is evidence for now, not an archive.

| Target | Total | Passed | Failed | Skipped | Crashed |
|---|---|---|---|---|---|
| DirectiveEngineTests | 1567 | 1567 | 0 | 0 | 0 |
| GameServicesTests | 304 | 304 | 0 | 0 | 0 |
| GameSyncTests | 78 | 78 | 0 | 0 | 0 |
| GameModelsTests | 140 | 140 | 0 | 0 | 0 |
| DirectivesFeatureTests | 287 | 287 | 0 | 0 | 0 |
| **Total** | **2376** | **2376** | **0** | **0** | **0** |

No pre-existing red tests. All five targets are fully green as of this baseline.

**Re-pinned anchors (Step 3).** Root `app/Modules/`. "Δ" is the shift from the ticket's stale line (positive = moved down).

| Symbol / fragment | File | Stale line | Current line | Δ |
|---|---|---|---|---|
| `Operation.createOperations` | `GameModels/Sources/Operation.swift` | 250 | **250** | 0 (unchanged) |
| `CommandClient.liveValue` dispatch closure — `if completion(for: kind) == .immediate {` | `GameServices/Sources/CommandClient.swift` | 98 | **98** | 0 (unchanged) |
| optimistic insert `let optimistic = Operation(` | `GameServices/Sources/CommandClient.swift` | 162 | **162** | 0 (unchanged) |
| supersede loop `for var other in openOps where other.id != opID` | `GameServices/Sources/CommandClient.swift` | 208 | **208** | 0 (unchanged) |
| `CommandGovernor.dispatch` | `GameServices/Sources/CommandGovernor.swift` | 63 | **71** | +8 |
| `CommandGovernorClient.dispatch` property | `GameServices/Sources/CommandGovernorClient.swift` | 16 | **18** | +2 |
| `Reconciler.completeOpenOperation` | `GameServices/Sources/Reconciler.swift` | 407 | **407** | 0 (unchanged) |
| `Reconciler.applyEventFields` | `GameServices/Sources/Reconciler.swift` | 259 | **259** | 0 (unchanged) |
| guard `guard eventTime >= device.updatedAt` | `GameServices/Sources/Reconciler.swift` | 275 | **275** | 0 (unchanged) |
| `GameSync.deviceRoute` | `GameSync/Sources/GameSync.swift` | 308 | **308** | 0 (unchanged) |
| `DirectiveExecutor.apply` `.dispatch` case | `DirectiveEngine/Sources/DirectiveExecutor.swift` | 46 | **46** | 0 (unchanged) |
| `.refreshSystem` case | `DirectiveEngine/Sources/DirectiveExecutor.swift` | 100 | **100** | 0 (unchanged) |
| `.scanSystem` case | `DirectiveEngine/Sources/DirectiveExecutor.swift` | 111 | **111** | 0 (unchanged) |
| `.refreshBody` case | `DirectiveEngine/Sources/DirectiveExecutor.swift` | 128 | **128** | 0 (unchanged) |
| `.setDeviceTags` case | `DirectiveEngine/Sources/DirectiveExecutor.swift` | 135 | **135** | 0 (unchanged) |
| `move(_:to:controllerCode:deviceCode:claimedRelayCode:)` | `DirectiveEngine/Sources/DirectiveExecutor.swift` | 330 | **330** | 0 (unchanged) |
| `commit` | `DirectiveEngine/Sources/DirectiveExecutor.swift` | 417 | **417** | 0 (unchanged) |
| `DirectiveEngineCore.resolveFootprintRefresh` | `DirectiveEngine/Sources/DirectiveEngine.swift` | 636 | **636** | 0 (unchanged) |
| `collapse` | `DirectiveEngine/Sources/DirectiveEngine.swift` | 741 | **741** | 0 (unchanged) |
| `resolveFleetRefresh` | `DirectiveEngine/Sources/DirectiveEngine.swift` | 600 | **600** | 0 (unchanged) |
| `WorldSnapshot.read` | `DirectiveEngine/Sources/WorldSnapshot.swift` | 237 | **237** | 0 (unchanged) |
| `openOperation(for:)` | `DirectiveEngine/Sources/WorldSnapshot.swift` | 175 | **175** | 0 (unchanged) |
| `dispatchedOperations` field | `DirectiveEngine/Sources/WorldSnapshot.swift` | 46 | **46** | 0 (unchanged) |
| `RestockRun.stocking` guard on `openOperation(for:` | `DirectiveEngine/Sources/RestockRun.swift` | 104 | **101** | −3 |
| `EventCourierPrint` printer guard `guard let printer = MineFleetPrint.printer(for: directive, in: world) else {` | `DirectiveEngine/Sources/EventCourierPrint.swift` | 81 | **75** | −6 |
| `GameDatabase.manifest` last entry (now `Blueprint.addComponents,`) | `GameDatabase/Sources/GameDatabase.swift` | 89 | **91** | +2 |

Notes on the moved/renamed set:
- None of the ~26 anchors were renamed or removed — every symbol/fragment still exists, under the same name, in the same file.
- **File correction, not a move**: the ticket's Step 3 groups "`RestockRun.stocking` guard … and `EventCourierPrint` printer guard" under one file annotation (`DirectiveEngine/Sources/RestockRun.swift`). `EventCourierPrint` is actually declared in its own file, `DirectiveEngine/Sources/EventCourierPrint.swift` — confirmed via `grep -rn "struct EventCourierPrint"` across `DirectiveEngine/Sources/`. Later tickets citing this anchor should use the `EventCourierPrint.swift` path.
- The four line-number moves (`CommandGovernor.dispatch` +8, `CommandGovernorClient.dispatch` +2, `RestockRun.stocking` guard −3, `GameDatabase.manifest` last entry +2) are all small, consistent with incidental edits above each anchor in the commits since `ab472ba` (e.g. the manifest gained `LocationEvent.addChosenOption` and `Blueprint.addComponents` as its last two entries).
- Spot-checked three of the moved anchors by reading the file at the new line: `CommandGovernor.swift:71` is `func dispatch(`; `GameDatabase.swift:91` is `Blueprint.addComponents,` (manifest's last entry, confirmed by reading lines 89–91); `EventCourierPrint.swift:75` is `guard let printer = MineFleetPrint.printer(for: directive, in: world) else {`. All three match their anchor description exactly.

**Discipline.** `git status` after all four steps: clean except this ticket-file edit (`.build/` artifacts under `app/Modules/.build/` are gitignored and were not staged). No source files were touched.
