# 03 — Governor de-dup on `(directive, step, device, kind, params)`

Type: task
Status: open
Blocked by: 02
Labels: directives-architecture, stage-0

Spec S0.2. A mission that dispatches an immediate verb into its own step re-POSTs every 5 s forever and re-stamps its deadline each time (the `ab36b7d` class, eight incidents). With ticket 02 every dispatch leaves an owned row, so the governor can refuse an identical repeat inside the same step entry. A refused repeat is a deferral: no write, no re-stamp, the step deadline accumulates.

**Files:**
- Modify: `app/Modules/GameServices/Sources/CommandGovernor.swift`, `CommandGovernorClient.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift` (`.deferred(.duplicate)` handling — no code change needed if the executor already treats every deferral identically; verify and add a debug log naming the reason)
- Create: `app/Modules/GameServices/Tests/CommandDedupTests.swift`
- Test: `app/Modules/DirectiveEngine/Tests/DirectiveEngineTests.swift` (one end-to-end case)

**Interfaces:**
- Produces: `CommandDeferral.duplicate` (new case, `rawValue "duplicate"`).
- Consumes: `CommandOwner`, `Operation.directiveID/step/paramsDigest` (ticket 02).

---

- [ ] **Step 1: Failing test**

```swift
// CommandDedupTests.swift
@Test func identicalDispatchInsideOneStepEntryIsDeferred() async throws {
    // seed: an op row {directiveID: "D1", step: "activating", entityCode: "R1", kind: "activate",
    //        paramsDigest: CommandParams().dedupKey, startedAt: t0 + 1}
    let owner = CommandOwner(directiveID: "D1", step: "activating", since: t0)
    let result = await governor.dispatch(.simple("activate"), on: "R1", params: CommandParams(), owner: owner)
    #expect(result == .deferred(.duplicate))
    // and the stubbed commandClient must NOT have been called
}
@Test func sameDispatchAfterStepRestartIsAllowed() async throws {
    // same seed but owner.since = t0 + 2 (later than the row's startedAt) → reaches the client
}
@Test func differentParamsAreNotDuplicates() async throws { /* destination A vs B */ }
@Test func unownedDispatchIsNeverDeduped() async throws { /* owner nil → reaches the client */ }
```

- [ ] **Step 2: Implement**

In `CommandGovernor.dispatch`, after the in-flight guard and before the budget read:

```swift
if let owner {
    @Dependency(\.defaultDatabase) var database
    let digest = params.dedupKey
    let dup = (try? await database.read { db in
        try Operation
            .where {
                $0.directiveID.eq(owner.directiveID)
                    && $0.step.eq(owner.step)
                    && $0.entityCode.eq(deviceCode)
                    && $0.kind.eq(kind.rawValue)
                    && $0.paramsDigest.eq(digest)
                    && $0.startedAt >= owner.since
            }
            .fetchOne(db)
    }) ?? nil
    if dup != nil {
        logger.debug("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): deferred (duplicate in step \(owner.step, privacy: .public))")
        return .deferred(.duplicate)
    }
}
```

Add `case duplicate` to `CommandDeferral` with a doc line: "An identical command already went out in this step entry."

- [ ] **Step 3: Executor**

`DirectiveExecutor.apply` `.dispatch` → `.deferred(reason)` already logs and returns `true` with no state change; confirm the log line prints `reason.rawValue` so `duplicate` is visible in OSLog. No re-stamp. Add to `DirectiveEngineTests.swift` an engine-level test: a fixture machine whose step returns `.dispatch(kind: .simple("activate"), …, nextStep: <same step>)`; with the real governor over a stubbed client, tick three times; assert the client was called once and `stepStartedAt` did not move after the first tick.

- [ ] **Step 4: Audit the same-step dispatch sites**

Using LSP, list every `.dispatch(` whose `nextStep` equals the current step (the audit found: `RelayRun.fetch` travel, `RelayRun.returnHome`, `SurveyRun.travel`/`returnHome`, `SalvageRun.travel`/`positioning`, `MineRun.travel`/`returnHome`, `EventRun.departing`/`returning`, `EventRun.printing`). For each, confirm the intended semantics survive: a tracked-kind re-dispatch is now refused while an identical earlier one in this step entry exists — which is what the `openOperation` guard already tried to do, so behaviour is unchanged when the op is open and SAFER when it closed but the row lags. Record the list in `## Comments`.

- [ ] **Step 5: Run targets, commit**

`feat(governor): defer identical dispatches inside one step entry`.
