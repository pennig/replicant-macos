# Repoint summary report

## Problem

`DirectiveExecutor.apply`'s `.dispatch` case wrote every `commandDispatched`
timeline entry with the same generic text — `"Dispatched \(kind.rawValue) to
\(deviceCode)"` — so a Haul Run repoint (the interesting event: a transport
controller pointed at a different stockpile) was indistinguishable from any
other dispatch in the timeline. The salient parameter (`configuration["collect"]`
on a `set_directive` repoint) sat right there in `CommandParams` and never
reached the log.

## Change

Read `app/Modules/GameServices/Sources/CommandParams.swift` in full and cross-
referenced every real `MissionAction.dispatch` call site across
`app/Modules/DirectiveEngine/Sources/*.swift` (`SurveyRun`, `SalvageRun`,
`HaulRun`, `RelayRun`, `RestockRun`) to see which `CommandParams` fields real
dispatches actually set. Only four ever are: `destination` (travel),
`deviceType` (print), `target` (stow), and `directive`+`configuration`
(set_directive). Fields like `resourceType`/`mode`/`channel`/`text`/`index`/
`devices`/`resources` exist on the struct but are set only by UI-issued
commands that never route through `DirectiveExecutor` (confirmed:
`commandGovernor.dispatch` — the only call site that writes a
`commandDispatched` entry — has exactly one caller, `DirectiveExecutor.swift`
itself), so they were deliberately left out per the "do not invent parameters
that do not exist" constraint.

Added a computed `CommandParams.summaryDetail: String?` (in `CommandParams.swift`)
that picks the one salient field, in priority order: `destination` →
`deviceType` → `target` → (`configuration["collect"]` as `"collect <pile>"`,
else the bare `directive` name). This lives entirely on `CommandParams` — no
mission-kind branching, no HaulRun special case.

`DirectiveExecutor.swift` gained a small private `dispatchSummary(kind:
deviceCode:params:)` helper that appends `" — \(detail)"` when
`summaryDetail` is non-nil, and returns the unchanged old text otherwise (no
dangling separator). The one call site inside `.dispatch`'s `.accepted` branch
now calls this helper instead of building the string inline.

No `DirectiveLogKind` was touched — `commandDispatched` still fires from the
same place, only its `summary:` text formatting changed. No mission file was
edited; the engine still returns one `MissionAction` and does no logging
itself.

## Exact summary format

`"Dispatched \(kind.rawValue) to \(deviceCode)"`, plus `" — \(detail)"` when
`CommandParams.summaryDetail` is non-nil.

Real example (Haul Run repoint):

    Dispatched set_directive to 7D1569BF — collect OCHIRD-5-1

Other shapes now produced:
- Travel: `Dispatched travel to VES1 — SOL-3-1` (names the destination)
- Print: `Dispatched enqueue_print to HUB1 — relay` (names the device type)
- Stow: `Dispatched stow to REL1 — CARRIER1` (names the carrier target)
- Empty params (e.g. `launch`/`activate`/`deploy`): `Dispatched launch to
  VES1` — unchanged, no trailing separator.

## Tests

Added to `DirectiveEngine/Tests/DirectiveEngineTests.swift`:
- Extended `dispatchAdvancesTheStepAndLogsIt` (existing travel-dispatch test)
  with an assertion that the entry's summary now names the destination.
- New `setDirectiveDispatchNamesTheCollectPile` — a `set_directive` dispatch
  with `configuration: ["collect": ..., "deliver": ...]` produces `"Dispatched
  set_directive to AMI1 — collect OCHIRD-5-1"`.
- New `dispatchWithEmptyParamsDegradesToTheOldSummary` — a `CommandParams()`
  dispatch (e.g. `launch`) produces the unchanged old text with no dangling
  separator.

Searched the whole repo for any other test asserting on the executor-generated
summary text (`grep -rn "Dispatched\b"` across all non-`.build` test files).
Found none — the only other places that reference `"Dispatched travel to
VES1"`-style strings (`OpCompletedAuditTests.swift`,
`DirectiveEngineTests.swift`'s stale-arrival race test) hand-seed their own
`DirectiveLogEntry` fixtures directly into the database rather than asserting
against `DirectiveExecutor`'s generated text, so they were unaffected and left
untouched.

## Verification

Setup: `cd app/Modules && swift build --build-tests` (clean), then
`./scripts/link-index-store.sh` (already linked).

- `swift build --build-tests`: clean, no errors (one pre-existing unrelated
  warning in `DirectivesClearAndBrainTests.swift` about an unused result,
  present before this change).
- `swift test --test-product DirectiveEngineTests --disable-xctest
  --event-stream-version 0 --event-stream-output-path
  .build/events-directiveengine.jsonl`: **714 test functions / 95 suites / 0
  failed** (baseline was 712/95 — the +2 is the two new tests added; the third
  test change extended an existing test in place). No started-but-never-ended
  (crashed) tests; `runEnded` fired once.
- `swift test --test-product GameServicesTests ...`: 219 tests / 28 suites, 0
  failed (covers `CommandParams`/`CommandGovernor`/`CommandClient`).
- `swift test --test-product DirectivesFeatureTests ...`: 139 tests / 14
  suites, 0 failed (covers `DirectiveLogPresentation`, the UI consumer of
  `DirectiveLogEntry.summary`).
- `app/scripts/check-comments.sh` on both changed files: exit 0.
- Comment budget hand-counted: `CommandParams.summaryDetail`'s `///` is 3
  lines; `DirectiveExecutor.dispatchSummary`'s `///` is 3 lines. No file
  header touched.

## Concerns

- `summaryDetail`'s priority order (`destination` → `deviceType` → `target` →
  configuration-collect-or-directive) assumes each mission dispatch site sets
  at most one of these fields at a time, which is true for every dispatch
  call site in the current codebase (verified by reading all of them). If a
  future dispatch ever sets more than one (e.g. `destination` alongside
  `configuration`), the priority order silently picks `destination` — worth
  revisiting if that shape appears.
- The `"collect \(value)"` special-case only fires for the literal key
  `"collect"` in `configuration`. `SurveyRun`'s `survey_system` config
  (`planets`/`moons`/`recall`) and `SalvageRun`'s `gather_salvage` config
  (`location`/`recall`) fall through to the bare `directive` name instead
  (e.g. `"— survey_system"`, `"— gather_salvage"`) rather than naming their
  own configuration fields. This satisfies the letter of the task (only a
  `set_directive` repoint, a travel, and an empty-params case were required)
  and is a reasonable generic default, but a future pass could extend
  `summaryDetail` with per-key fallbacks (e.g. `location` from
  `gather_salvage`'s config) if those directives' timelines turn out to need
  the same treatment.
