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

Commits: `5b19f9c` (failing tests), `f60ff9b` (implementation), `d646ad1`
(follow-up failing tests), `18e5a95` (follow-up fix), `6d702e7` (review:
comment-budget trim), `fdd4427` (review: one read per backstop, not one per
tick).

Step 3 audit — self-targeting sites found (`nextStep == directive.step`):
- `RelayRun.acquire` footprint gate (`.printStockShort`) — already safe pre- and
  post-fix; `collapse` never falls through to `.advanceStep` when `reason` is
  non-nil, so it was never subject to the restamp bug.
- `SalvageRun.unresolvedSystem` / `RelayRun.unresolvedSystem` (`.refreshSystem`,
  `.salvageSystemUnresolved`) and `SalvageRun.sameBodyAgain` (`.refreshBody`,
  `.salvageBodyNotDepleted`) — deadlines now genuinely accumulate. Their "one
  extra read, then stall" bound used `SalvageRun.stepEntryCount`, a log-count
  re-entry budget that counted `.stepStarted` entries the same-step read no
  longer writes, so first landed these three sites retried forever instead of
  ever reaching their stall. **Fixed per coordinator ruling** (this was judged
  worse than the bug the ticket fixes, and in scope by the ticket's own step 3
  text): `stepEntryCount` removed; `unresolvedSystem`/`sameBodyAgain` now bound
  the retry with a second, additive time window
  (`systemUnresolvedRetryWindow` / `bodyUnresolvedRetryWindow`, both 60s) read
  off the same `stepStartedAt` the deadline already reads. Elapsed time alone
  is sufficient once a same-step read stops resetting it, and stays correct
  after an operator Retry — `DirectiveResolutionClient.retry` stamps
  `stepStartedAt = now` directly, a write path this ticket does not touch. The
  hand-crafted double-`.stepStarted` log fixtures (a shape production can no
  longer produce) are replaced with pure `stepStartedAt`-elapsed fixtures at
  all three sites, confirmed RED against the pre-fix implementation.
  **Second review round**: the first cut spent a read on EVERY tick across the
  60s window (~12 reads) rather than one, reversing the deleted design's own
  "one is enough" rationale without ever surfacing that as a choice. Traced
  both suggested fixes: gating on the system/body record's own freshness is
  unusable — `LocationsClient.hydrateSystem`/`hydrateBody` write nothing on a
  failed fetch, so a persistently-failing read never produces a freshness
  signal; gating on the directive row's own `updatedAt` looked workable but
  is unsafe — `verify` calls both `unresolvedSystem` and `sameBodyAgain`,
  which would share one `updatedAt` watermark and could suppress each
  other's read. Landed a third option instead: `unresolvedReadBand` (5s, one
  engine tick), the narrow width right past each deadline in which the one
  read fires; the rest of the (unchanged, 60s) window is a plain wait, then
  the stall. Pure function of elapsed time, no shared mutable state. Each
  site now has a test walking its whole window at 5s ticks asserting exactly
  one read and the same stall/reason at the same bound.
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
