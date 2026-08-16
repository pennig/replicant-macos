# 07 — `WorldSnapshot` owner-aware ops + `isFresh`; fix the two open co-tenant print guards

Type: task
Status: resolved
Blocked by: 02
Labels: directives-architecture, stage-0

Spec S0.6. `WorldSnapshot.openOperation(for:)` answers "is anyone's op open on this device"; a mission can't ask "is MY op open". `dispatchedOperations` is reconstructed by joining `.commandDispatched` log rows on `operationID`. Freshness is a raw `updatedAt` compare at ~36 sites. `RestockRun.stocking` (was `:104`) and `EventCourierPrint`'s printer guard (was `:81`) still wait on any op at the printer with the guard ABOVE the deadline — the co-tenant defect `1994d07`/`75ca544` fixed in `EventRun`/`MineFleetPrint`.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/RestockRun.swift`, `EventCourierPrint.swift`
- Test: `app/Modules/DirectiveEngine/Tests/WorldSnapshotTests.swift`, `RelayReturnAndRestockTests.swift`, `EventRunTests.swift` (courier print cases) — extend

**Interfaces:**
- Produces:
  ```swift
  extension WorldSnapshot {
      /// The device's live op only when it belongs to `owner`; nil owner keeps today's meaning.
      public func openOperation(for deviceCode: String, owner directiveID: String?) -> GameModels.Operation?
      /// `device.updatedAt >= watermark`. The one freshness predicate missions use from now on.
      public func isFresh(_ device: Device, since watermark: Date) -> Bool
      /// Ops this directive dispatched, by op id — read off `operations.directiveID` first,
      /// falling back to the log join for rows written before ticket 02.
      public let dispatchedOperations: [String: GameModels.Operation]   // unchanged name, new source
  }
  ```
- Consumes: `Operation.directiveID` (02).

---

- [ ] **Step 1: Failing tests (WorldSnapshotTests)**

```swift
@Test func openOperationWithOwnerFiltersByDirective() {
    // devices: PRINTER; openOperations: PRINTER → op{directiveID: "OTHER"}
    #expect(world.openOperation(for: "PRINTER", owner: "MINE") == nil)
    #expect(world.openOperation(for: "PRINTER", owner: "OTHER") != nil)
    #expect(world.openOperation(for: "PRINTER", owner: nil) != nil)
}
@Test func isFreshComparesUpdatedAtToWatermark() { /* t0-1 vs t0 → false; t0 → true */ }
@Test func dispatchedOperationsReadsTheOwnerColumn() async throws {
    // seed two ops: one with directiveID == D (no log entry), one legacy (log entry with operationID, no directiveID)
    // WorldSnapshot.read(...) → both present
}
```

- [ ] **Step 2: Implement**

In `WorldSnapshot.read`: `let owned = try Operation.where { $0.directiveID.eq(directiveID) }.fetchAll(db)`; union with the log-join set (existing code) into `dispatched`. Add the two functions.

- [ ] **Step 3: Fix the two guards**

`RestockRun.stocking`: reorder so the print deadline (`RestockRun.printDeadline` off `stepStartedAt`) is checked BEFORE `if world.openOperation(for: hub.deviceCode, owner: directive.id) != nil { return .wait }` — and the guard is now owner-scoped, so a co-tenant's job neither blocks the enqueue nor extends the deadline. Same shape in `EventCourierPrint` at the printer guard. Match `MineFleetPrint.printing`'s post-`75ca544` structure exactly (read it first).

Extend `RelayReturnAndRestockTests`: with a co-tenant op open on the hub owned by another directive, `stocking` still enqueues; with the run's OWN print open, it waits; with own print open past the deadline it stalls `.printBlockedOnComponents` (or whatever reason `MineFleetPrint` uses — mirror it). Same for the courier.

- [ ] **Step 4: Migrate the obvious call sites to `isFresh`**

Mechanical: every `device.updatedAt >= directive.stepStartedAt` / `< stepStartedAt` compare in `DirectiveEngine/Sources` becomes `world.isFresh(device, since: directive.stepStartedAt)` / `!isFresh`. LSP-find them (`updatedAt` references in the module). Do NOT change any compare against `world.now - interval` (those are age gates, not watermarks). Behaviour identical; this is what lets Stage 2's `ConfirmRow` sub-machine be a one-line replacement later.

- [x] **Step 5: Run `DirectiveEngineTests` in full; commit**

`feat(engine): owner-aware open ops, isFresh, and the last two co-tenant print guards`. Close automation-brain ticket 14 (`RestockRun` over-print race) with a comment pointing here.

## Comments

Landed as three commits (small pieces, per the task's interruption-safety
instruction) rather than one: `6e9d027` (steps 1–2, `WorldSnapshot`),
`c5c2d3f` (step 3, the two guards), `053b9a4` (step 4, the 13-site `isFresh`
migration). This bookkeeping commit closes out step 5 under the ticket's own
named message.

All five targets green through the JSON event stream: DirectiveEngineTests
1408/1408 (1399 baseline + 9 new), GameServicesTests 280/280, GameSyncTests
65/65, DirectivesFeatureTests 260/260, GameModelsTests 119/119.

Automation-brain ticket 14 found OPEN (`Status: needs-triage`), not closed or
absent. Added a comment there rather than marking it resolved: this ticket's
guard fix (owner-scoping + deadline-above-guard in `RestockRun.printing`) is a
different defect from ticket 14's over-print race (a printed clone's device
row racing its op's close), and the race ticket 14 describes is still open —
see the comment on that ticket for the full account.
