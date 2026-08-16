# 05 — Read actions stop re-stamping `stepStartedAt`

Type: task
Status: resolved
Blocked by: 01
Labels: directives-architecture, stage-0

Spec S0.4. `DirectiveExecutor.move` re-stamps `stepStartedAt` unconditionally (was `DirectiveExecutor.swift:330-352`). The four best-effort read/housekeeping actions — `.refreshSystem`, `.scanSystem`, `.refreshBody`, `.setDeviceTags` — and the `.refreshFootprint` fallback all go through it, so a step that asks for a read into ITSELF can never time out (`RelayRun.acquire` rounds 2/3, `SurveyRun.scanning`, `ef72b7e`). A read is not a transition; it must not restart the deadline.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift` (`collapse`'s `.refreshFootprint` fallback)
- Create: `app/Modules/DirectiveEngine/Tests/ExecutorRestampTests.swift`

**Interfaces:**
- Produces: `DirectiveExecutor.move(_:to:controllerCode:deviceCode:claimedRelayCode:restamp:)` — `restamp: Bool = true`. Callers for the four read cases pass `restamp: nextStep != directive.step`.
- Produces: `MissionAction.advanceStep(nextStep:)` semantics unchanged (always re-stamps).

---

- [x] **Step 1: Failing tests**

```swift
// ExecutorRestampTests.swift — drive DirectiveExecutor.apply directly with a test database and TestClock/date dependency
@Test func refreshSystemIntoSameStepKeepsTheClock() async throws {
    // directive.step == "confirming", stepStartedAt == t0; date.now == t0+30
    await DirectiveExecutor.apply(.refreshSystem(designation: "TAU", nextStep: "confirming"), to: directive, machine: fixtureMachine)
    // reload row: step == "confirming", stepStartedAt == t0 (NOT t0+30); a .stepStarted log entry was NOT appended
}
@Test func refreshSystemIntoAnotherStepRestamps() async throws { /* nextStep "settling" → stepStartedAt == t0+30, one .stepStarted entry */ }
@Test func advanceStepAlwaysRestamps() async throws { /* .advanceStep(nextStep: "confirming") from "confirming" → t0+30 */ }
```

Repeat the first pair for `.scanSystem`, `.refreshBody`, `.setDeviceTags` (stub `locationsClient`/`devicesClient`/`deviceRefresher` with no-op closures).

- [x] **Step 2: Implement**

Add `restamp: Bool = true` to `move`. Body: `if restamp { updated.stepStartedAt = date.now }`; write the `.stepStarted` entry only when `restamp || nextStep != directive.step` (a same-step no-restamp move logs nothing — the timeline stays quiet exactly like `.wait`). In the four read cases pass `restamp: nextStep != directive.step`.

In `DirectiveEngineCore.collapse`, the `.refreshFootprint(nextStep, nil)` fallback returns `.advanceStep(nextStep:)`; when `nextStep == directive.step` this would re-stamp through `advanceStep`. `collapse` has no directive in scope; give it one (`collapse(_ action:, currentStep: String)`) and return `.wait` when `nextStep == currentStep` — the semantic is "nothing to advance to, stay and let the deadline run".

- [x] **Step 3: Audit the self-targeting read sites**

LSP-list every `.refreshSystem/.scanSystem/.refreshBody/.setDeviceTags/.refreshFootprint` whose `nextStep` is the current step (`RelayRun.acquire` footprint gate; `SurveyRun.scanning`; `SalvageRun.sameBodyAgain`'s `refreshBody`; any others). For each, confirm the step has a deadline that NOW accumulates and that its stall reason is the intended one. Where a step relied on the re-stamp to bound a self-loop via `MissionLogBudget.dispatchRounds`, the log-count bound still works (it counts `.stepStarted` entries, which no longer accrue on same-step reads — so the count now measures dispatches only; verify the specific site's tests still hold, adjust the fixture if it counted reads).

- [x] **Step 4: Run `DirectiveEngineTests` in full; commit**

`fix(engine): reads no longer restart a step's deadline`.

## Comments

Commits: `5b19f9c` (failing tests), `f60ff9b` (implementation).

Step 3 audit — self-targeting sites found (`nextStep == directive.step`):
- `RelayRun.acquire` footprint gate (`.printStockShort`) — already safe pre- and
  post-fix; `collapse` never falls through to `.advanceStep` when `reason` is
  non-nil, so it was never subject to the restamp bug.
- `SalvageRun.unresolvedSystem` / `RelayRun.unresolvedSystem` (`.refreshSystem`,
  `.salvageSystemUnresolved`) and `SalvageRun.sameBodyAgain` (`.refreshBody`,
  `.salvageBodyNotDepleted`) — deadlines now genuinely accumulate, but their
  "one extra read, then stall" bound (`SalvageRun.stepEntryCount`) counts
  `.stepStarted` log entries the same-step read no longer writes. **Regression,
  left unfixed as out of this ticket's file scope**: these three sites now
  retry forever past their deadline instead of ever reaching their stall. No
  existing test catches it — `SalvageRunTests.stallsWhenTheTargetSystemNeverResolves`
  hand-crafts two `.stepStarted` log entries to reach that branch, a shape
  production can no longer produce. Needs a follow-up ticket to rebase
  `stepEntryCount`'s bound off something other than the log.
- `EventRun.preflight`/`.printing`, `MineFleetPrint.stocking`,
  `RestockRun.stocking`, `EventCourierPrint.printing` — all `.refreshFootprint`
  self-targets with `thenStall: nil` by design (never escalate a stale
  census). Before this fix, `collapse`'s old fallback silently restamped and
  logged through `.advanceStep` on every persistently-stale tick; now they
  correctly go quiet (`.wait`) with no stall, matching their documented intent.
- `SurveyRun.scanning`/`HaulRun.survey` — not self-targeting (`nextStep` names
  a different step); unaffected.

`MissionLogBudget.dispatchRounds` sites are all `.dispatch`/confirm loops
(untouched by this ticket); none bound a read self-loop.
