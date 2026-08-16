# 01 — Re-pin line numbers, build, warm the LSP

Type: task
Status: open
Blocked by: —
Labels: directives-architecture, stage-0

Every later ticket cites `file:line` as of `main` at `ab472ba` (2026-08-16). Lines drift. This ticket makes the worktree buildable, warms the index, and re-pins the anchors the Stage 0 tickets edit so the executor never edits the wrong block.

**Files:**
- Read only. Output is a `## Comments` note on this ticket with the re-pinned lines.

---

- [ ] **Step 1: Build and link the index**

Run from the repo root:

```bash
cd app/Modules && swift build --build-tests && ./scripts/link-index-store.sh
```

Expected: build succeeds; the script reports the symlink present.

- [ ] **Step 2: Run the baseline suites through the event stream**

Use the `swift-test-event-stream` skill. Run `DirectiveEngineTests`, `GameServicesTests`, `GameSyncTests`, `GameModelsTests`, `DirectivesFeatureTests` and record pass/fail counts per target in this ticket's `## Comments`. Any red test here is pre-existing; note it so later tickets don't inherit it as theirs.

- [ ] **Step 3: Re-pin the anchors**

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

- [ ] **Step 4: Resolve**

Set `Status: resolved`. No commit (nothing changed).
