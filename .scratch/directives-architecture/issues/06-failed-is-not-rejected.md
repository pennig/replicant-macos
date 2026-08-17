# 06 — `.failed` is not `.rejected`: bounded transient retry

Type: task
Status: resolved
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

- [x] **Step 1: Failing tests**

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

- [x] **Step 2: Implement**

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

- [x] **Step 3: Brain**

`Brain`'s stall response already keys off `brainDisposition`; `.retry` classification means the brain's bounded auto-retry (`Brain.retryBudget = 3`) applies. No brain code change; add the reason to any test that enumerates the retry set.

- [x] **Step 4: Run targets; commit**

`feat(engine): retry transient command failures before stalling`.

## Comments

Status: resolved. Vocabulary (`DirectiveAttentionReason.commandFailed`, its three switches) and the executor's split `.dispatch` outcome + `failedDispatchBudget`/`failedDispatches(for:)` are implemented, verified in isolation by `budgetArithmeticAloneOverAStubbedGovernor` (stubbed `commandGovernor`, bypasses the real actor): exactly 3 retries, 3 `.failed` rows, 4th tick stalls `.commandFailed`. That test also caught a real off-by-one in the ticket's own step-2 sketch — `CommandClient` writes each attempt's `.failed` row *before* returning, so `failedDispatches` always counts the current attempt's own row; the literal `<` from the sketch stalls on tick 3 (only 2 retries), not tick 4. Fixed to `<=`.

**Interim block, now resolved.** The required shape — driving through the real `CommandGovernor` (ambiguity 1) — first came back RED: `transientFailureWaitsThenStallsAtBudget` showed `calls.value == 1`, not 3. Root cause: `CommandGovernor.dispatch`'s per-step dedup (ticket 03, `CommandGovernor.swift:85-104`) matched on `directiveID + step + entityCode + kind + paramsDigest + startedAt >= owner.since` with **no status filter** — a `.failed` (terminal, unsuccessful) row satisfied it exactly as a `.completed` one would, and ticket 05's fixed `owner.since` meant every retry after the first matched the first attempt's now-`.failed` row and got deferred `.duplicate` forever. Coordinator ruling: exclude `.failed` from the dedup match (`CommandGovernor.swift`, `&& $0.status.neq(OperationStatus.failed)`) — the dedup exists to refuse a repeat that already succeeded or is in flight, and a `.failed` row is neither. Fixed, verified against all of ticket 03's own tests (`CommandDedupTests`'s 4 pre-existing cases + `sameStepDispatchReachesTheClientOnceOverTheRealGovernor` + all 6 `CommandGovernorTests`) — **none of them encoded the bug**: every seeded/stubbed row in that suite used `.completed`, so nothing needed correcting, only extending. Added `CommandDedupTests.aFailedRowDoesNotSuppressARetryButACompletedRowStillDoes`, which pins a `.failed` row NOT suppressing a retry side-by-side with the same row updated to `.completed` still suppressing one — confirmed non-vacuous by reverting the fix and watching it fail for the right reason (`called.value == false`, the stub never reached).

**Double-execution risk (asked for explicitly), and the ruling it produced:** a transport failure is ambiguous — the command may have landed and only the response was lost — so a retry can double-execute. Surveyed every `OperationKind` this retry path can reach: state-target verbs (`travel`, `mine`, `adopt`/`release`/`attach`/`detach`, `stow`, `set_directive`, `configure`, `repair`, `recall`, activation/deactivation, `scan`/`census`/`search`) converge to the same state or get rejected by the server as already-there on a repeat — safe either way, still get the bounded retry. Four verbs are genuinely NOT idempotent: **`print`** (a queue accepts a second enqueue with nothing to reject it — burns blueprint cost twice, leaves a stray device), **`collect_resources`/`deposit_resources`** (a fixed `resources` quantity map, not "move everything" — a repeat double-moves that quantity), and **`dequeuePrint`** (removes a queued job by POSITION — after a real-but-lost-response first attempt the queue has shifted, so a repeat removes a *different* job than intended; not currently dispatched by any mission, added anyway since the set is defined by the verb, not today's call sites).

**Coordinator ruling (overriding the ticket): these four get NO retry** — `DirectiveExecutor.nonRetryableKinds` stalls `.commandFailed` on the first `.failed`, same as budget exhaustion, skipping the counter entirely. The asymmetry decided it: a wrongly-stalled `print` costs one click on Retry; a wrongly-repeated one costs materials and a stray device to clean up. Everything else keeps the bounded three-attempt retry. Pinned by `DirectiveEngineTests.nonRetryableVerbStallsOnFirstFailureNoRetry` (one dispatch, immediate stall) beside `transientFailureWaitsThenStallsAtBudget` (a retryable verb still takes three).

Files touched: `Directive.swift`, `DirectiveExecutor.swift`, `DirectiveVocabularyTests.swift`, `DirectiveEngineTests.swift` (ticket's list); `BrainDispositionTests.swift` (`GameModels/Tests`, ambiguity 2's hard-coded retry array); `CommandGovernor.swift` + `CommandDedupTests.swift` (ticket 03's files, under the coordinator's explicit ruling — see above).

**Combined worst case, corrected by review** (first stated as 12, itself arithmetically inconsistent with its own "3 × 3" — the real figure is **16**, traced by the reviewer through the actual code rather than reasoned once from the two budget constants). `.commandFailed`'s `brainDisposition == .retry` means `Brain`'s existing bounded auto-retry (`Brain.retryBudget = 3`) applies with no brain code change, but `Brain.stallResponse`'s retry (`DirectiveResolutionClient.retry`, `DirectiveResolutionClient.swift:79-83`) re-stamps `stepStartedAt` — the exact timestamp `failedDispatches(for:)` reads its window from — so each brain retry doesn't add to the in-step count, it starts a FRESH one. One natural step entry plus up to 3 brain-driven re-entries is **4 step entries**, each opening its own window of `failedDispatchBudget + 1 = 4` dispatch attempts (1 initial + 3 in-step retries) before that entry's own stall. **Retryable verb, persistent failure: up to 4 × 4 = 16 dispatch attempts** before `Brain.retryEpisode`'s count of `.resolved` entries (written by that same brain retry) reaches `retryBudget` and the stall escalates to an operator instead. **Non-retryable verb** (the four `nonRetryableKinds`): each step entry's in-step multiplier is 1, not 4 — **4 step entries × 1 = up to 4 dispatch attempts**, not the 3 first stated (same off-by-one as the 12).

**Provenance comments removed** (review finding, `app/CLAUDE.md`'s comments rule — a pointer names where the contract lives, never who decided it): `CommandGovernor.swift`'s de-dup exclusion and `CommandDedupTests`'s new seam test both said "ticket 06" in-line; rewritten to state the rule itself (a `.failed` row didn't land, so it's a retry not a duplicate) with no ticket number. No code change, comments only; `GameServicesTests` re-run green (280/280) to confirm.

Full suite via the JSON event stream, final state: DirectiveEngineTests 1399/1399, GameServicesTests 280/280, GameSyncTests 65/65, DirectivesFeatureTests 260/260, GameModelsTests 119/119 — all green (baseline 2117 + 6 new tests across the run = 2123).

Commits: `e40bbe1` (WIP checkpoint — vocabulary + retry counter, before the governor fix), `037852c` (`fix(governor): exclude .failed ops from the per-step de-dup`), `7c2dac3` (bookkeeping, superseded), `6241ddc` (`fix(engine): non-idempotent verbs get no in-step retry on .failed`), `b7d52c5` (bookkeeping, superseded), plus this final bookkeeping commit (worst-case correction + provenance-comment cleanup).
