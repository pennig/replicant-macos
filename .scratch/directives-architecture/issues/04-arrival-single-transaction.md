# 04 — The arrival is one transaction; same-second tolerance

Type: task
Status: open
Blocked by: 01
Labels: directives-architecture, stage-0

Spec S0.3. `GameSync.deviceRoute` closes the op in one write (`Reconciler.completeOpenOperation`) and writes `device.location` in a second (`Reconciler.applyEventFields`), with an optional network read between. A tick between them sees "op closed, old location" and re-commands travel (`582d10b`, `5a4fd77`; five incidents). Separately, `applyEventFields`' guard `eventTime >= device.updatedAt` compares a second-granular server timestamp against a sub-second client timestamp and drops the location write (`Reconciler.swift` was `:275`, memory says "still unfixed").

**Files:**
- Modify: `app/Modules/GameServices/Sources/Reconciler.swift`
- Modify: `app/Modules/GameSync/Sources/GameSync.swift` (`deviceRoute`)
- Create: `app/Modules/GameServices/Tests/ReconcilerDeviceEventTests.swift`
- Test: `app/Modules/GameSync/Tests/GameSyncTests.swift` (extend the arrival case)

**Interfaces:**
- Produces:
  ```swift
  extension Reconciler {
      /// One transaction: close the open op the event completes (if any) AND apply the
      /// envelope's location/stow. Returns whether an op was closed.
      @discardableResult
      public func applyDeviceEvent(
          deviceCode: String, event: GameEventEnvelope,   // the type deviceRoute already holds
          location: String?, stow: StowChange?, eventTime: Date
      ) async -> Bool
  }
  ```
  `completeOpenOperation` and `applyEventFields` stay public (other callers: poll path, DeadlineScheduler, tests) but `deviceRoute` stops calling them separately.
- Consumes: `Reconciler.applyOperationEvent(event)`'s classification (which events close which kinds) — refactor its body into a private `completionPlan(for event) -> (result, allowedKinds)?` that both `applyOperationEvent` and `applyDeviceEvent` use.

---

- [ ] **Step 1: Failing tests**

```swift
// ReconcilerDeviceEventTests.swift
@Test func arrivalClosesOpAndWritesLocationAtomically() async throws {
    // seed: device V at "SOL-1" updatedAt t0; open travel op on V (startedAt t0)
    // act: applyDeviceEvent(travel.arrived at "TAU-2", eventTime t0+60)
    // assert in ONE read: op.status == .completed AND device.location == "TAU-2"
}
@Test func opClosingEventPatchesEvenWhenRowLooksNewer() async throws {
    // seed: device updatedAt = t0+61.5 (a read issued after the arrival second), location "SOL-1", open op
    // act: arrival eventTime = t0+61 (second granularity)
    // assert: location == "TAU-2" (unconditional patch because the op closed)
}
@Test func nonClosingEventUsesOneSecondTolerance() async throws {
    // seed: no open op; device updatedAt = t0+61.4, location "SOL-1"
    // act: device.moved-style event, location "SOL-2", eventTime t0+61 → applied (61+1 >= 61.4)
    // act: eventTime t0+59 → NOT applied
}
@Test func eventPatchStampsClientClock() async throws {
    // after a patch, device.updatedAt == date.now (the test clock), not eventTime
}
```

Note the seed helper must write the `Device` and `Operation` rows through `Device.upsert`/`Operation.insert` in the test database (`GameDatabase.bootstrap()`), the pattern in `ReconcilerOperationTests.swift`.

- [ ] **Step 2: Implement `applyDeviceEvent`**

One `database.write`:
1. `completionPlan(for: event)` → if non-nil, run the body of `completeOpenOperation` (kind/skew guards intact) inline; remember `closed: Bool`.
2. Fetch the device; if missing return `closed`.
3. If `closed` → apply `location`/`stow` unconditionally. Else → `guard eventTime.addingTimeInterval(1) >= device.updatedAt else { return closed }` then apply.
4. `device.updatedAt = date.now` (client clock, S0.3 rationale: an event *is* an observation and every mission watermark is client-clock). Upsert.

Keep `applyEventFields`' body but change ITS guard to the same 1 s tolerance and ITS stamp to `date.now` so the two paths agree (poll-path callers unaffected).

- [ ] **Step 3: `deviceRoute` uses it**

Replace the `applyOperationEvent` … `applyEventFields` pair with one `applyDeviceEvent(...)` call. The `print.completed` clone read and the post-close `.high` read remain, AFTER the call (ticket 08 moves them off the path).

- [ ] **Step 4: Run `GameServicesTests` + `GameSyncTests` + `DirectiveEngineTests`; commit**

`fix(sync): close the op and patch the row in one transaction`. Then write a memory note `app/.claude/memory/arrival-single-transaction.md` (+ index line) recording that the same-second drop is closed and WHY the op-closing patch is unconditional; update `confirm-steps-need-fresh-evidence.md`'s "still-unfixed door" sentence to point at it.
