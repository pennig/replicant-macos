# 14 — Per-machine `enum Step: String`; unknown step → `.wait` everywhere

Type: task
Status: resolved
Blocked by: 01
Labels: directives-architecture, stage-1

Spec S1.5 / D6. Every machine holds its steps as `static let` strings inside `enum Step` and `nextAction` switches on `directive.step` with a `default`. Four machines route an unknown string to their first step (`RestockRun :77`, `MineFleetPrint :47`, `EventCourierPrint :57`, `EventRun :151`), five to `.wait`. The column stays `String`; the machine's switch becomes exhaustive so a renamed or missing case is a compile error, and the unknown-string policy is one rule.

**Files:**
- Modify: all nine machines under `app/Modules/DirectiveEngine/Sources/` (`SurveyRun`, `SalvageRun`, `HaulRun`, `RelayRun`, `MineRun`, `EventRun`, `RestockRun`, `MineFleetPrint`, `EventCourierPrint`); `MissionRegistry.swift`; `SalvageRun.retiredSteps` (`:62`) — delete, an unknown string is now `.wait` + one log line.
- Test: each machine's test suite must stay green (they construct `Directive(step: "…")` with strings — unchanged); add one test per machine: `Step.allCases.map(\.rawValue)` equals the previous literal list (freeze the vocabulary; a rename is then deliberate).

**Interfaces:**
- Produces per machine: `public enum Step: String, CaseIterable, Sendable { case acquire, printing, … }`, `public var firstStep: String { Step.acquire.rawValue }`, and in `nextAction`:
  ```swift
  guard let step = Step(rawValue: directive.step) else {
      logger.notice("\(kind.rawValue) \(directive.id): unknown step \(directive.step) — waiting")
      return .wait
  }
  switch step { case .acquire: … }   // exhaustive, no default
  ```
- Produces: `MissionRegistry.firstStep(for:) -> String` non-optional (see ticket 13).
- Consumes: nothing.

---

- [x] **Step 1: Freeze tests first**

For each machine add `@Test func stepVocabularyIsFrozen() { #expect(<Machine>.Step.allCases.map(\.rawValue) == ["…", …]) }` with today's literal list copied from the file (the audit lists them; re-read the source). Run: they fail (`Step` has no `allCases` yet).

- [x] **Step 2: Convert one machine at a time**

Start with `RestockRun` (2 steps), then `MineFleetPrint`, `EventCourierPrint`, `HaulRun`, `MineRun`, `RelayRun`, `SurveyRun`, `SalvageRun`, `EventRun`. For each: replace the `static let x = "x"` block with the enum; every `Step.x` reference to a `String` context becomes `Step.x.rawValue` (the compiler finds them — `MissionAction` payloads are `String`); `nextAction` as in Interfaces. Where a mission compares `entry.step == Step.x` on log entries, that is `Step.x.rawValue`. `SalvageRun`: delete `retiredSteps` and its `case` arm. `EventRun`/`RestockRun`/`MineFleetPrint`/`EventCourierPrint`: the "unknown → first step" behaviour is replaced by `.wait`; if any test relied on it, the test encoded a bug — change the test and note it in `## Comments`.

- [x] **Step 3: Run `DirectiveEngineTests` in full after each machine; one commit per machine**

`refactor(<machine>): typed Step enum, unknown step waits`. Then a final commit deleting `retiredSteps`.

## Comments

Resolved in `0d6f6c1`, `cd18738`, `1ba0a25`, `890bf6f`, `c006c86`, `c384816`, `357b8a3`, `76e9fc3`,
`8d4c7de` (one per machine), `34a4205` (`MissionRegistry.firstStep` non-optional), `7e813de`
(delete `retiredSteps`), `4fdf0a9` (review fixes).

Six targets green: DirectiveEngineTests 1662, GameServices 324, GameSync 81, GameModels 149,
DirectivesFeature 287, DevicesFeature 167. From-scratch `swift build --build-tests` clean. D6 held —
`git diff --name-only` touches zero files matching migrat/schema/golden, and `Directive.step` is still
a `String` column.

**All nine frozen vocabularies were verified against `git show e3e2326:<Machine>.swift`** rather than
against the enums just written, and every list matches in contents and in order. No step was renamed,
dropped, added or reordered. `SalvageRun`'s four retired names (`emplacing`, `activating`,
`confirmingRelay`, `restocking`) were never in its step set — they lived in `retiredSteps` — so their
absence from the frozen list is correct.

**Four machines changed behaviour**: `RestockRun`, `MineFleetPrint`, `EventCourierPrint` and `EventRun`
routed an unknown step to their first step and now return `.wait`. The other five were already `.wait`.
Zero `default` arms survive in the nine `nextAction` switches.

**Three tests changed and one deleted, each adjudicated:**

- `EventCourierPrintTests.unknownStepRejoins` → `unknownStepWaits`. The old test genuinely encoded the
  bug: it fed step `"stowing"` into a world with a spare matrix and asserted `.advanceStep(.replicating)`
  — pinning "an unknown string is resolved by whatever the first-step handler happens to compute".
- `EventRunReturnTests.unknownStepWaits` added; no prior test pinned `EventRun`'s `default: preflight`.
  Falsifiable — `EventRunFixtures.world` seeds 500k stock and a fresh footprint, so the old default would
  have returned `.advanceStep(.printing)` or `.advanceStep(.recovering)`, never `.wait`.
- `SalvageRunRepairTests.aRowOnARetiredStepReEntersAtPreflight` → `formerRelayStepNamesNowWait`.
- `SalvageRunRepairTests.aRetiredRowAtTheHubDoesNotDeployBotsThere` **deleted**. Its travel half is
  genuinely covered by `SalvageRunTravelTests.dispatchesTravelToTheTarget` (`SalvageRunTests.swift:331`),
  whose exact-dispatch assertion strictly subsumes the deleted `!= .advanceStep(.deployingBots)`. The
  deleted fixture's planted relay was incidental — `SalvageRun.travel` branches only on system equality.

**Two things review caught.** The ticket's literal log-line example omits `privacy: .public`, and five
machines already had it — following the example verbatim would have censored, in Console, exactly the
line that names a stalled directive and its offending step. Restored on all nine. And `RestockRun` and
`MineFleetPrint` changed behaviour with nothing pinning it; both now have a test whose fixture would
have returned a concrete `.dispatch(print, …)` under the old code, so the assertion can fail.

`MineRun` and `SurveyRun` still have no unknown-step test. Pre-existing, behaviour unchanged here, on the
punch list.

**Console text changed**: the log prefix moved from prose ("haul run …") to `\(kind.rawValue)`
("haulRun …"), consistently across all nine.
