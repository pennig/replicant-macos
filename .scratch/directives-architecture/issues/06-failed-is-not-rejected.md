# 06 — `.failed` is not `.rejected`: bounded transient retry

Type: task
Status: open
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
