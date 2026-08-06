# The directive log: bound the READ, not the rows (2026-08-06)

Supersedes the "needs a per-directive row cap" conclusion in
[survey-fleet-repair-build](survey-fleet-repair-build.md). Deleting rows was the
wrong shape; the fix is a windowed query.

## What the log actually looks like

Measured on the live database with one running `haulRun`:

    9,071 entries on that one directive, growing ~680 in a few hours
    8,951 of them `.stepStarted`            (98.7%)
      112 of them `.commandDispatched`      (1.2% — the repoints)
     ~132 bytes per row, 1.35 MB for the whole table

**Rows are cheap and disk was never the problem.** The cost was that
`WorldSnapshot.read` fetched every one of a directive's entries on each 5-second
tick, on runs that never terminate.

## `WorldSnapshot.log` is windowed; `auditLog` is the escape hatch

`log` now carries the newest `WorldSnapshot.logWindow` (500) entries, still
ascending — several consumers do `world.log.reversed()` to walk newest-first and
depend on that order.

**A naive window would have been silently wrong for one consumer.**
`DirectiveExecutor`'s `.opCompleted` audit pass resolves ops from
`.commandDispatched` entries, and an op dispatched before the cutoff could stay
open and never be audited when it closed. Hence `WorldSnapshot.auditLog`: the
FULL `.commandDispatched`/`.opCompleted` history, never windowed but kind-scoped,
so it grows with dispatches (work actually done) rather than with ticks.

Every other consumer is safe by construction: `SurveyRun.saw` and
`SalvageRun.saw` filter to the current step by time, and
`SurveyRun.dispatchRounds` / `SalvageRun.stepEntryCount` / `HaulRun
.dispatchAttemptCount` walk newest-first with early breaks.

**The one accepted degradation:** `dispatchAttemptCount` walks back to the last
`.resolved`. If more than 500 entries separate two resolutions its count
under-reports, so the retry limit fires later than intended. Still bounded by the
window, and it cannot produce a spin.

**Never fix this class by not WRITING the entries.** Three loop bounds count
exactly those `.stepStarted` rows — `SurveyRun.dispatchRounds`,
`SalvageRun.stepEntryCount`, `HaulRun.dispatchAttemptCount` — including the one
that stops the survey bot loops spinning forever. Suppressing writes would
silently unbound them.

## The timeline collapses a repeating CYCLE, not a repeated step

The mission detail view rendered as "a loop of surveying, assigning and hauling
over and over", because the query fetched the newest 100 entries and ~99 of them
were step transitions.

**The first fix attempt — collapsing consecutive IDENTICAL steps — was a no-op on
the real data, and measuring is what caught it.** A Haul Run's live sequence has
zero adjacent duplicates; it rotates:

    assigning → surveying → hauling → assigning → surveying → hauling → …

interrupted by `dispatching → confirming` when it repoints. What repeats is a
period-3 cycle, not a step.

`DirectiveLogCollapsing` therefore collapses a run of ≥2 repetitions of a
period-p unit, `p ≤ maxPeriod` (4), **preferring the smallest p** — a period-3
cycle also matches period 6, which would halve the count. `matches` compares
`kind` as well as `step`, so a `.commandDispatched` repoint breaks a cycle
instead of being absorbed into it, which is the entire point. The 24-entry live
sample renders as 5 rows.

`entryLimit` (100) is now the DISPLAY budget and `rawFetchLimit` (1000) the raw
fetch, sized so the collapsed result still fills the pane. The fetch stays a
single bounded `.limit()` — an unbounded `@FetchAll` over this never-pruned table
has crashed the app before (see [event-log-feature](event-log-feature.md)).

The transform is a SwiftUI-free namespace on purpose: pure logic hung off a
`View` traps with signal 5 under `swift test` (see
[swiftui-view-statics-trap-in-tests](swiftui-view-statics-trap-in-tests.md)).

## A dispatch entry names what it did

`commandDispatched` summaries read `Dispatched set_directive to <code>` and
nothing more, so a repoint was indistinguishable from any other command.
`CommandParams.summaryDetail` now supplies the salient field — destination,
device type, target, or a `set_directive`'s `collect` pile — and the executor
appends it. Empty params degrade to the old text with no dangling separator.

Related: [directives-feature](directives-feature.md),
[operations-table-retention](operations-table-retention.md),
[haul-run-design](haul-run-design.md).
