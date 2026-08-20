# 13 — Residual cleanups from the batched-tick branch

Status: ready-for-agent
Blocked by: —

Five small items the whole-branch review triaged as follow-up rather than
merge-blocking. Independent of each other; batch them.

## Duplicate small-table reads in `WorldView.read(from:core:now:)`

Three tables `WorldCore.read` already fetched get read or recomputed again:

- `Replicant.all` (`WorldView.swift:178`) — `core` exposes only the derived
  `replicantHostDevices`, not the raw rows.
- `TheatreRecord` (`WorldView.swift:171`) — `WorldCore.read` fetches it at
  `WorldCore.swift:133` and discards it.
- `SalvageTargetPlanner.meshSystems` over all 863 devices
  (`WorldView.swift:190`) — `WorldCore.read` computes it at `WorldCore.swift:112`
  and discards it.

All small; all once per tick rather than once per directive. Widening `WorldCore`
to carry them was forbidden while the branch was in flight to keep its shape
stable — that constraint is now spent, so reconsider it here.

## The brain's generation tag is loop-local

`DirectiveEngine.swift:108` declares `generation` inside `start()`, so a
`stop()`→`start()` cycle resets it to 0. A pre-stop brain task that survived
cancellation (suspended in a non-cooperative await) can resume, call
`finishBrainTick(1)`, match the NEW loop's generation-1 slot and release it while
that loop's brain tick is still running — permitting two concurrent brain ticks.

Same exposure as the code before the branch, so not a regression. Hoisting
`generation` to a monotonic actor field closes it in about two lines.

## `WorldTick.generation` is production-dead

Set at `WorldTick.swift:54`, read nowhere in production. The spec designed it as
the executor's staleness guard; the implementation solved staleness with
`AsyncStream(bufferingPolicy: .bufferingNewest(1))` instead — a better choice,
which made the field vestigial. Both test seams pass `generation: 0`.

A maintainer will reasonably assume executors compare it. Delete it, or document
it as the brain slot's key only.

## The `IN` lists are unchunked

`DirectiveSlice.readAll` binds `allWanted` as the union of every running
directive's full `targets` array. One roaming directive on the live database
already carries **564 targets**; the union is ~570 bindings today and two such
runs double it. SQLite's `SQLITE_MAX_VARIABLE_NUMBER` is 32,766 on modern builds
and 999 on older ones, and crossing it throws for the whole tick rather than
degrading.

Compounding it: a throw inside `WorldTick.read` propagates to `runTick`, which
logs and returns — so *no* directive evaluates and the brain does not tick that
cycle. Before the branch, one directive's failed read stalled one directive. The
tick self-heals on the next cycle, so this is a robustness fix rather than a live
fault. Chunk the `IN` lists.

## The `PausedDirectiveDelta` suite doc still carries the false framing

`WorldTickTests.swift:684-686` asserts "a pause landing mid-tick is honoured on
the NEXT tick, up to 5s later". The tests underneath it now prove otherwise: the
pause is erased by the whole-row write and must be re-applied. The final fix wave
corrected the two test docs but was never pointed at the suite-level one above
them, so this is the first thing a reader meets and the last place still saying
it. One-line fix; see ticket 10 for the underlying defect.

## Two comments whose guarantees became temporal

- `DirectiveExecutor.swift:285-287` still argues `.opCompleted` writes are
  idempotent because "the engine runs one executor per directive, so there is no
  second writer to race". That held when the worklist was read at the top of each
  evaluation, strictly after the previous evaluation's write. The worklist is now
  read at tick time and the write happens later, so the guarantee is temporal
  (narrow window, plus `bufferingNewest(1)`) rather than structural. Worst case is
  a duplicate timeline row.
- The spec's decision 2 sentence — "per-directive cancellation, error isolation
  and write concurrency are unchanged" — is true of *evaluation* isolation and
  false of *read* isolation, per the `IN`-list item above. Correct the sentence.

**Done when:** each item is either fixed or has a one-line note in the code saying
why it stands.
