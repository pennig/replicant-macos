# 03 — Governor de-dup on `(directive, step, device, kind, params)`

Type: task
Status: resolved
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

- [x] **Step 1: Failing test**

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

- [x] **Step 2: Implement**

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

- [x] **Step 3: Executor**

`DirectiveExecutor.apply` `.dispatch` → `.deferred(reason)` already logs and returns `true` with no state change; confirm the log line prints `reason.rawValue` so `duplicate` is visible in OSLog. No re-stamp. Add to `DirectiveEngineTests.swift` an engine-level test: a fixture machine whose step returns `.dispatch(kind: .simple("activate"), …, nextStep: <same step>)`; with the real governor over a stubbed client, tick three times; assert the client was called once and `stepStartedAt` did not move after the first tick.

- [x] **Step 4: Audit the same-step dispatch sites**

Using LSP, list every `.dispatch(` whose `nextStep` equals the current step (the audit found: `RelayRun.fetch` travel, `RelayRun.returnHome`, `SurveyRun.travel`/`returnHome`, `SalvageRun.travel`/`positioning`, `MineRun.travel`/`returnHome`, `EventRun.departing`/`returning`, `EventRun.printing`). For each, confirm the intended semantics survive: a tracked-kind re-dispatch is now refused while an identical earlier one in this step entry exists — which is what the `openOperation` guard already tried to do, so behaviour is unchanged when the op is open and SAFER when it closed but the row lags. Record the list in `## Comments`.

- [x] **Step 5: Run targets, commit**

`feat(governor): defer identical dispatches inside one step entry`.

## Comments

Status: resolved. Commit: `3b1aec7` — `feat(governor): defer identical dispatches inside one step entry` (implementation + tests + this bookkeeping, one commit).

**Step 3 verified, no code change**: `DirectiveExecutor.apply`'s `.dispatch` → `.deferred(reason)` branch already logged `reason.rawValue` and returned `true` with zero state change (`DirectiveExecutor.swift:50-54`), so `duplicate` surfaces in OSLog for free and `CommandDeferral.duplicate` needed no executor change. Proved by the new end-to-end test (`DirectiveEngineTests.sameStepDispatchReachesTheClientOnceOverTheRealGovernor`): a fixture machine dispatching `.simple("activate")` into its own step, ticked three times through the REAL `CommandGovernor` (only `gameClient`/`commandClient` stubbed), calls the client exactly once and leaves `stepStartedAt` fixed after tick 1. Confirmed non-vacuous by temporarily disabling the dedup block (`if let owner, false {`) and re-running: `calls.value` came back `3`, not `1`.

**Step 4 audit** — every `.dispatch(` in `app/Modules/DirectiveEngine/Sources/`, each site read in full (not just grep-matched):

Same-step sites (nextStep == the dispatching function's own step), all TRACKED kinds (`.travel`/`.print`), so the pre-existing `openOperation` guard already protected the in-flight case — this ticket's dedup adds the same-step-but-op-closed case:
- `RelayRun.fetch` → travel (Step.fetching) — in the original list
- `RelayRun.travel` → travel (Step.travelling) — **NOT in the original list; the audit missed it**
- `RelayRun.emplace` → travel (Step.emplacing) — **NOT in the original list; the audit missed it**
- `RelayRun.returnHome` → travel (Step.returning) — in the original list
- `SurveyRun.travel` → travel (Step.travelling) — in the original list
- `SurveyRun.returnHome` → travel (Step.returning) — in the original list
- `SalvageRun.travel` → travel (Step.travelling) — in the original list
- `SalvageRun.position` → travel (Step.positioning) — in the original list (as "positioning")
- `MineRun.returnHome` → travel (Step.returning) — in the original list
- `EventRun.printing` → print (Step.printing) — in the original list
- `EventRun.departing` (carrier leg only) → travel (Step.departing) — in the original list
- `EventRun.returning` → travel (Step.returning) — in the original list

**Correction to the original list**: `MineRun.travel` (Step.travelling) is NOT a same-step site — it dispatches travel with `nextStep: Step.confirmingArrival`, a distinct step (MineRun already uses the dispatch/confirm split shape here, unlike the other runs' travel steps). The original audit's "MineRun.travel/returnHome" pairing was copied from the sibling files' shape without verifying MineRun's own; only `MineRun.returnHome` is real.

Every other `.dispatch(` site in the engine (RelayRun.acquire/stowing/deactivateSource, SurveyRun.configure/launch/deployBots/armBots/stowBots, SalvageRun.configure/launch/deployBots/armBots/stowBots, MineRun.attach/detach/adopt/arm, EventRun.loading/staging/collecting/recovering/depositing, HaulRun.dispatchAssignment, MineFleetPrint.stocking, RestockRun.stocking, EventCourierPrint.printing) dispatches into a DIFFERENT step, several of them explicitly by design for untracked `.simple`/immediate verbs (comments at `RelayRun.swift:575-578`, `SalvageRun.swift:573-577` name this outright). No site dispatches an untracked kind into its own step — the class of bug this ticket retires structurally cannot occur anywhere in the current engine; the dedup is defense-in-depth for the tracked sites (closed-but-lagging row) and a guard against a future same-step immediate dispatch being added without this being noticed.

**Discipline**: `check-comments.sh` on the three touched files flags eight pre-existing lines in `DirectiveEngineTests.swift` (lines 809-1803, all far from this ticket's additions at lines 10-282) — confirmed via `git diff` that none fall inside this ticket's changed ranges.
