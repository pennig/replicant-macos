# 14 — Per-machine `enum Step: String`; unknown step → `.wait` everywhere

Type: task
Status: open
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

- [ ] **Step 1: Freeze tests first**

For each machine add `@Test func stepVocabularyIsFrozen() { #expect(<Machine>.Step.allCases.map(\.rawValue) == ["…", …]) }` with today's literal list copied from the file (the audit lists them; re-read the source). Run: they fail (`Step` has no `allCases` yet).

- [ ] **Step 2: Convert one machine at a time**

Start with `RestockRun` (2 steps), then `MineFleetPrint`, `EventCourierPrint`, `HaulRun`, `MineRun`, `RelayRun`, `SurveyRun`, `SalvageRun`, `EventRun`. For each: replace the `static let x = "x"` block with the enum; every `Step.x` reference to a `String` context becomes `Step.x.rawValue` (the compiler finds them — `MissionAction` payloads are `String`); `nextAction` as in Interfaces. Where a mission compares `entry.step == Step.x` on log entries, that is `Step.x.rawValue`. `SalvageRun`: delete `retiredSteps` and its `case` arm. `EventRun`/`RestockRun`/`MineFleetPrint`/`EventCourierPrint`: the "unknown → first step" behaviour is replaced by `.wait`; if any test relied on it, the test encoded a bug — change the test and note it in `## Comments`.

- [ ] **Step 3: Run `DirectiveEngineTests` in full after each machine; one commit per machine**

`refactor(<machine>): typed Step enum, unknown step waits`. Then a final commit deleting `retiredSteps`.
