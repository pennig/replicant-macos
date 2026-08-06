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

## Fix round 1: repeated STEP → repeated CYCLE

The coordinator verified concern #1 against the live database and it held:
the running `haulRun`'s newest entries are a genuine **period-3 cycle**
(`assigning → surveying → hauling`, repeating) with zero *adjacent*
duplicates — exactly the run the operator described as "a loop... over and
over," and exactly the case round 1's step-only collapsing could not touch.

### What changed

- **`DirectiveLogCollapsing.swift`** — generalized from "collapse adjacent
  identical steps" to "collapse a maximal run of ≥2 consecutive repetitions
  of a period-`p` step cycle, `p` in `1...maxPeriod`, preferring the
  smallest `p`." `DirectiveTimelineDisplayRow` now carries `unit:
  [DirectiveLogEntry]` (one repetition's entries, in fetch order) instead of
  a single `entry`, plus the same `count` — now counting *repetitions*, not
  raw entries. `maxPeriod = 4`. The old single-step behavior is exactly the
  `p = 1` case and is unchanged (all 4 round-1 tests pass unmodified).
  `longestCycle(in:from:)` tries `period = 1, 2, 3, 4` in order and returns
  the first that repeats ≥2 times fully; because a genuine period-`p`
  sequence never spuriously satisfies a smaller period (its own elements
  differ within one repetition), trying small-to-large and stopping at the
  first hit is sufficient to always prefer the smallest true period — no
  extra harmonic-detection logic was needed. `matches` requires non-nil
  `step` at every compared position (not just the unit's first element), so
  a `kind` without a `step` (a repoint, a stall, a completion) can never
  silently join a cycle.
- **`DirectiveTimelineRow.swift`** — now takes `cycleSteps: [String] = []`
  alongside `entry`/`count`; when a collapsed row spans more than one
  distinct step it renders `cycleSteps.joined(separator: " → ")` instead of
  the single entry's own summary line (e.g. `assigning → surveying →
  hauling`), so the `×N` pill reads against something legible instead of
  just the cycle's first line repeated.
- **`DirectiveDetailView.swift`** — feeds `row.unit[0]` as the display
  entry (for icon/tint/timestamp), `row.unit.compactMap(\.step)` as
  `cycleSteps`, and `row.count` as before.
- **`DirectiveTimeline.swift`** — `rawFetchLimit` raised from 500 to 1000
  (see below); no other change (the `matches`/period generalization lives
  entirely in the pure transform, not the query).
- **`DirectiveLogCollapsingTests.swift`** — added 3 tests: a period-2 cycle
  collapsing to one row; a cycle that changes shape partway staying as two
  separate collapsed rows (never merged into a false longer-period read);
  and the coordinator's literal 24-entry Haul Run fixture (the period-3
  cycle interrupted once by an `assigning, confirming, dispatching` beat).
  All 5 round-1 tests (including `capsToTheNewestEntries`, which reads
  `rawFetchLimit` symbolically and needed no edit) still pass.

### Period bound

`maxPeriod = 4`. Every `MissionStepMachine`'s step vocabulary was read
directly (`HaulRun`, `SurveyRun`, `SalvageRun`, `RelayRun`, `RestockRun`):
Haul Run's steady-state polling loop (`assigning → surveying → hauling`) is
the largest known *live, repeating* sub-cycle at period 3 — the other
machines' larger step counts (Survey Run has 13, Relay Run 13) are linear
once-through progressions, not loops. 4 gives one step of headroom beyond
the one known real cycle without inviting a coincidental match: at `p = 5`
a window needs 10 consecutive matching entries to trigger, which starts
trading specificity for reach with no known mission to justify it.

### The 24-entry fixture

Collapses to **5 display rows**: a period-3 cycle ×2, then three individual
rows (`assigning`, `confirming`, `dispatching` — the repoint), then a
period-3 cycle ×5. The repoint's three entries never merge into either
surrounding cycle (each fails every period check against its neighbors),
so it stands fully apart between two collapsed groups — the reading the
brief asked for.

### `rawFetchLimit` re-derived: 500 → 1000

Cycle collapsing compresses far harder than round 1's step-only version, so
500 was re-measured directly against the live database using the actual
`collapse` algorithm (period 1–4, ≥2 reps): the running `haulRun`'s newest
500 raw rows collapse to only **37** display rows — well short of the 100
budget. 1000 raw rows collapse to **103**, clearing the budget as a single
bounded fetch (Swift's `.prefix(entryLimit)` in the view caps the excess).
Checked against all 10 other historical directive logs on the account too:
none exceeds ~700 raw entries total, so 1000 fully covers them uncapped.
`rawFetchLimit` is now `1000`.

### Verification

- `swift build --build-tests` — clean.
- `./app/scripts/check-comments.sh` over every touched file — clean, no
  output; comment line counts re-verified by hand against the ≤6/≤3/≤2
  budget.
- `DirectivesFeatureTests` (`--test-product`): 146 tests / 15 suites (was
  143/15 after round 1 — delta is the 3 new tests), 0 failed, `runEnded`
  confirmed.
- `DirectiveEngineTests` (`--test-product`): 714 tests / 95 suites, 0
  failed — unchanged, unaffected.

### Concerns

- `cycleSteps` (and the `×N`/joined-summary rendering) still has no
  UI/snapshot coverage, same caveat as round 1 — verified by inspection and
  a clean build only, not a running app screenshot.
- `maxPeriod = 4` is a judgment call grounded in the five known
  `MissionStepMachine`s today; a future mission with a genuinely 5-or-more
  step polling loop would render as individual rows rather than collapse,
  degrading gracefully (not crashing, not over-matching) but not compress
  as well as it could until the bound is revisited.
- `rawFetchLimit = 1000` is calibrated to the one account this repo has
  live data for; an account that ran the same directive uninterrupted for
  much longer than this one could still undershoot the display budget on
  its oldest, most-compressible stretches — an explicitly accepted
  "thin timeline" risk per the original brief, not a new one.
