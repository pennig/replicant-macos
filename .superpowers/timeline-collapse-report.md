# Timeline collapse: consecutive step repeats

## Problem

`DirectiveTimeline.fetch(_:)`'s custom-mission branch (keyed by `directiveID`,
the one a Haul Run uses) had no treatment for `.stepStarted` noise, unlike the
built-in-directive branch which excludes the kind outright. A Haul Run
re-dispatches the same step on every poll tick while awaiting completion, so
the newest `entryLimit` (100) raw rows were almost entirely repeats of
whichever step happened to be running, burying the interesting repoint
entries.

## What changed

- **`DirectiveLogCollapsing.swift`** (new) — a pure, SwiftUI-free namespace
  enum. `collapse(_:[DirectiveLogEntry]) -> [DirectiveTimelineDisplayRow]`
  folds adjacent entries that share a non-nil `step` and the same `kind` into
  one row carrying a repeat `count`. `step` is set only on `.stepStarted`, so
  a distinct-step progression (Survey Run) and any entry kind without a step
  never collapse; an entry of a different kind (e.g. a repoint) sitting
  between two same-step entries keeps them as separate rows.
- **`DirectiveTimelineRow.swift`** — extended (not relocated) with an
  optional `count: Int = 1`; when `count > 1` it renders a `×N` pill using the
  existing `rcPill(.neutral)` modifier and `.rcMonoSmall`/`.rcTextTertiary`
  tokens (the same pattern already used for queue-count pills elsewhere).
- **`DirectiveTimeline.swift`** — `entryLimit` (100) is now documented as the
  *display* budget. A new `rawFetchLimit` (500) is the raw fetch size for the
  `directiveID` branch's bounded query; the `deviceCode` branch is unchanged
  (it already excludes `.stepStarted` and never needed the larger window).
- **`DirectiveDetailView.swift`** — `timelineSection` now runs
  `DirectiveLogCollapsing.collapse(store.timeline.entries)` and takes
  `.prefix(DirectiveTimeline.entryLimit)` before rendering, feeding each
  collapsed row's `entry`/`count` into `DirectiveTimelineRow`.
- **`DirectiveTimelineTests.swift`** — `capsToTheNewestEntries` updated to
  assert against `rawFetchLimit` instead of `entryLimit`, since the raw fetch
  size changed for the branch it exercises.
- **`DirectiveLogCollapsingTests.swift`** (new) — 4 tests against the pure
  transform: a consecutive run collapses to one row with the right count; two
  same-step runs separated by another entry stay separate; a
  Survey-Run-shaped sequence of distinct steps collapses to nothing; empty
  input returns `[]`.

## The two numbers

- **`entryLimit = 100`** (unchanged) — the display budget, i.e. the most rows
  a pane renders after collapsing.
- **`rawFetchLimit = 500`** (new) — 5× the display budget. Queried the live
  database's running `haulRun` and its nine other historical custom-mission
  logs directly: the worst observed same-step burst (consecutive
  `.stepStarted` entries for one step before advancing) was 39 in a single
  run, so 500 raw rows comfortably covers several such bursts while still
  landing well inside "500" (matching the magnitude already established by
  the prior `WorldSnapshot.logWindow = 500` bound) rather than an unbounded
  fetch. It is a single bounded `.limit()` query, never an unbounded one.

Live-data caveat: the currently-running `haulRun` referenced in the task
brief (9,071→9,171 log entries as of this run) happens to have **zero**
adjacent same-step duplicates right now — each of its `surveying` /
`assigning` / `hauling` transitions currently occurs exactly once per cycle
before advancing, so collapsing is a no-op for that specific run at this
moment. Bursts up to 39-long were found in other, smaller historical runs on
the same account, which is what `rawFetchLimit`'s multiplier is calibrated
against. The transform is correct and will compress heavily the moment a
step re-enters itself on consecutive ticks (the documented cause of the
98.7% `.stepStarted` figure in the task brief); it simply has nothing to
compress in this particular live snapshot.

## Verification

- `swift build --build-tests` — clean.
- `./app/scripts/check-comments.sh` over every touched/added file — clean,
  no output.
- `DirectivesFeatureTests` (`--test-product DirectivesFeatureTests`): 143
  tests / 15 suites, 0 failed, `runEnded` confirmed (baseline was 139/14 —
  the delta is the 4 new collapsing tests + their 1 new suite).
- `DirectiveEngineTests` (`--test-product DirectiveEngineTests`): 714 tests /
  95 suites, 0 failed — matches baseline exactly (unaffected by this change).

## Concerns

- The `×N` pill has no dedicated snapshot/UI test — only the pure transform
  is unit-tested, per the task's SwiftUI-free requirement. Visual placement
  (between the summary text and the timestamp) was chosen by inspection of
  `DirectiveTimelineRow`'s existing `HStack`, not verified against a running
  app build (blocked by the Keychain login wall for scratch builds).
- `rawFetchLimit`'s 39-burst calibration comes from a small sample (10
  historical directive logs on one account); a run with much longer bursts
  (dozens of ticks stuck on one step) could still exhaust the raw window
  before collapsing fills the display budget — it would degrade to fewer
  than 100 display rows rather than crash or go unbounded, which matches the
  brief's "may render as very few" framing as an accepted risk, not a bug.
