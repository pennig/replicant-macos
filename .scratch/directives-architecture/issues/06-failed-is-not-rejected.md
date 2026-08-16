# 06 — `.failed` is not `.rejected`: bounded transient retry

Type: task
Status: claimed
Blocked by: 02
Labels: directives-architecture, stage-0

Spec S0.5. `DirectiveExecutor` stalls `.commandRejected` on both `.rejected(message)` and `.failed(message)` (was `DirectiveExecutor.swift:72-74`). `.failed` covers transport errors and every undeclared HTTP status (429/500/503 throw a decode error because the `default` schema forbids the `error` key), so a transient 503 puts a mission into `needsAttention` for a human. A 4xx is a real rejection; a failure is retried a bounded number of times inside the step, then stalls under its own name.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (`DirectiveAttentionReason.commandFailed` + the three switches)
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift`
- Test: `app/Modules/GameModels/Tests/DirectiveVocabularyTests.swift` (extend), `app/Modules/DirectiveEngine/Tests/DirectiveEngineTests.swift` (extend)

**Interfaces:**
- Produces: `DirectiveAttentionReason.commandFailed` — `displayName "Command failed"`, guidance `"The server or the connection failed while sending the last command. It was retried three times. Retry once the service is reachable, or skip this target."`, `brainDisposition .retry`.
- Produces: `DirectiveExecutor.failedDispatchBudget: Int = 3`.
- Consumes: `Operation.directiveID/step` (ticket 02) to count failures.

---

- [ ] **Step 1: Failing tests**

`DirectiveVocabularyTests`: `.commandFailed` has a display name, guidance, and `brainDisposition == .retry`; `CaseIterable` count incremented.

`DirectiveEngineTests`:
```swift
@Test func transientFailureWaitsThenStallsAtBudget() async throws {
    // governor stub returns .dispatched(.failed("503")) every time
    // tick 1,2,3: row still .running, step unchanged, three .failed op rows exist for (directive, step)
    // tick 4: row .needsAttention with attentionReason == .commandFailed
}
@Test func rejectionStallsImmediately() async throws { /* .rejected("400") → .commandRejected on tick 1 */ }
```
(The `.failed` op rows are written by `CommandClient` in production; in this test the governor is stubbed, so seed them by making the stub ALSO insert the row, or drive through the real governor over a stubbed `CommandClient` that returns `.failed` and inserts — prefer the latter, it is the shape ticket 02 built.)

- [ ] **Step 2: Implement**

In the `.dispatch` case split the outcome:
```swift
case let .rejected(message):
    await stall(directive, reason: .commandRejected, detail: message); return false
case let .failed(message):
    let failures = await failedDispatches(for: directive)   // count ops: directiveID, step, status .failed, startedAt >= stepStartedAt
    if failures < Self.failedDispatchBudget {
        logger.notice("directive \(directive.id): \(kind.rawValue) failed (\(failures)/\(Self.failedDispatchBudget)) — \(message) — will retry")
        return true
    }
    await stall(directive, reason: .commandFailed, detail: message); return false
```
`failedDispatches(for:)` is one `database.read` over `Operation`.

- [ ] **Step 3: Brain**

`Brain`'s stall response already keys off `brainDisposition`; `.retry` classification means the brain's bounded auto-retry (`Brain.retryBudget = 3`) applies. No brain code change; add the reason to any test that enumerates the retry set.

- [ ] **Step 4: Run targets; commit**

`feat(engine): retry transient command failures before stalling`.

## Comments

Status: BLOCKED (not resolved, not committed). Vocabulary (`DirectiveAttentionReason.commandFailed`, its three switches) and the executor's split `.dispatch` outcome + `failedDispatchBudget`/`failedDispatches(for:)` are implemented and correct in isolation — proven by `budgetArithmeticAloneOverAStubbedGovernor` (stubbed `commandGovernor`, bypasses the real actor): exactly 3 retries, 3 `.failed` rows, 4th tick stalls `.commandFailed`. That test also caught a real off-by-one in the ticket's own step-2 sketch — `CommandClient` writes each attempt's `.failed` row *before* returning, so `failedDispatches` always counts the current attempt's own row; the literal `<` from the sketch stalls on tick 3 (only 2 retries), not tick 4. Fixed to `<=`.

**The REQUIRED shape — driving through the real `CommandGovernor` (ambiguity 1) — is RED and stays red**: `transientFailureWaitsThenStallsAtBudget` shows `calls.value == 1`, not 3. Root cause: `CommandGovernor.dispatch`'s per-step dedup (ticket 03, `CommandGovernor.swift:85-104`) matches on `directiveID + step + entityCode + kind + paramsDigest + startedAt >= owner.since` with **no status filter** — a `.failed` (terminal, unsuccessful) row satisfies it exactly as a `.completed` one would. Ticket 05 requires `owner.since` (= `directive.stepStartedAt`) to stay fixed across a same-step retry so the budget window can't slide; that same fixed `since` is what makes every retry attempt after the first match the first attempt's now-`.failed` row and get deferred `.duplicate` — forever. `CommandGovernorTests.releasesTheClaimAfterARejection` didn't catch this because it dispatches with `owner: nil`, which skips the dedup block entirely.

Net effect if shipped as-is: the FIRST transient failure permanently wedges the directive `.running` (a `.deferred` outcome is a no-op, so nothing ever re-checks the budget) — worse than pre-ticket behaviour, which at least stalled and surfaced to an operator. This is a real ticket-03/ticket-06 conflict, not a test artifact: any production mission whose step logic re-issues the same dispatch after a terminal-but-failed op (the shape ticket 06 exists to retry) hits it. The fix I'd propose — scope `CommandGovernor`'s dedup match to `OperationStatus.liveCases` (or explicitly exclude `.failed`) so a closed-but-unsuccessful row no longer counts as "already went out this step" — touches `CommandGovernor.swift`, which is shared account-wide infrastructure outside this ticket's file list and outside my authority to change unilaterally. Left for the controller to rule on (ticket 05 precedent: "per coordinator ruling" for an out-of-list fix).

Files touched: `Directive.swift`, `DirectiveExecutor.swift`, `DirectiveVocabularyTests.swift`, `DirectiveEngineTests.swift` (all per the ticket's list), plus `BrainDispositionTests.swift` (`GameModels/Tests`) — added `.commandFailed` to its hard-coded `retry` array per ambiguity 2 ("add the new reason to any test that enumerates the retry set"); the two `allCases`-sweep tests in `BrainStallResponseTests.swift` and `DirectiveVocabularyTests`/`DirectiveSchemaTests` needed no edit, they cover the new case automatically. No `CaseIterable`-count assertion exists anywhere in the codebase to increment (ambiguity 3 describes a mechanism this repo doesn't have); the sweep tests are the completeness net instead.

Full suite via the JSON event stream: DirectiveEngineTests 1398/1398 attempted, 1 failing (`transientFailureWaitsThenStallsAtBudget`, the documented red above) — all others pass, including the 2 new passing tests. GameServicesTests 279/279, GameSyncTests 65/65, DirectivesFeatureTests 260/260, GameModelsTests 119/119 — all green, confirming the vocabulary change is otherwise inert to the other four targets. Nothing committed; working tree left as-is for the controller.
