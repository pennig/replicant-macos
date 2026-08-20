# Spec — one batched world read per directive tick

Status: approved (design), not yet implemented
Date: 2026-08-20
Owner: Matt

## Problem

The app burns roughly half a core continuously while idle, enough to spin the
fans. A Time Profiler trace (`.scratch/directive_cpu_usage.trace`, 495s,
280,546 samples at 1ms) attributes it almost entirely to the directive engine.

Measured across eight independent 60s windows, total app CPU is 49–60% of one
core and `DirectiveEngineCore.evaluateOnce` is 64–73% of it every time. Taking
the 60–120s window as representative (32.02s CPU in 60s wall):

| path | share | CPU |
|---|---|---|
| `DirectiveEngineCore.evaluateOnce` | 69.5% | 22.24s |
| └ `WorldSnapshot.read` | 65.1% | 20.85s |
| `DirectiveEngineCore.tickBrain` → `Brain.report` | 7.6% | 2.45s |
| `DeadlineScheduler.run` | 7.0% | 2.24s |
| `GameSyncEngine` / `EventRouter.dispatch` | 4.7% | 1.52s |
| `PollCoordinator.refresh` | 4.7% | 1.49s |

Cross-cutting: `JSONDecoder` is 35.4% of app CPU, Swift generic-metadata
instantiation inside the decode loop is 15.0%, and `sqlite3_step` is only
19.2%. This is row and JSON **decoding** cost, not query execution cost.

### Root cause

`reconcileExecutors` spawns one `Task` per `.running` directive, each looping
`evaluateOnce` then `sleep(5s)`. The live database has **22 running
directives**, so `WorldSnapshot.read` runs 4.4 times per second — and 13 of its
19 fields depend only on the database, not on the directive. All 22 executors
independently re-read and re-decode identical data.

Per-second decode load, measured against the live database:

| fetch | rows | ×22 ÷ 5s | share of app CPU |
|---|---|---|---|
| `Device.all` | 836 (200KB JSON) | 3,678 rows/s | 21.1% |
| `LocationFootprint.all` | 28,158 | 123,895 rows/s | 14.8% |
| `LocationEvent.all` | 184 (252KB JSON) | 810 rows/s | 8.9% |
| `Operation` (`dispatched`) | 3,867 | ~773 rows/s | 9.7% |
| `DirectiveLogEntry` (`auditLog`) | 7,954 | ~1,591 rows/s | 0.8% |

That is ~131,000 rows and ~2 MB of JSON re-decoded every second, of which 21/22
is redundant.

Three separate axes make it worse over time: `locationFootprints` grows as the
map is explored (28,158 rows today); `dispatchedOperations` re-fetches every
operation a directive has *ever* dispatched (1424, 1250 and 1085 rows for the
three oldest running directives); and `auditLog` is unbounded the same way.
`idlePlanBackoff` gates only `resolveExtendQueue`, which runs *after* the
snapshot — the expensive part has no throttle at all.

## Constraint that shapes the design

25 source files and 56 test files read `WorldSnapshot` / `WorldView`. Both
public shapes stay byte-identical; only their **production** changes. The
existing tests are the regression net.

## Decisions

1. **One batched read per tick.** The supervisor opens ONE transaction per tick
   covering the global fields plus every running directive's scoped rows, then
   hands each executor its slice. Preserves the single-transaction consistency
   invariant the file documents twice — and strengthens it, since all 22
   directives now see one world instead of 22 reads at 22 instants.
2. **Executors stay concurrent.** One `Task` per directive as today; each takes
   its slice, runs its machine, and applies its own write in its own
   transaction. Per-directive cancellation, error isolation and write
   concurrency are unchanged.
3. **The brain shares the batch.** `WorldView` is derived from the same
   transaction rather than re-reading eight of the same tables, so the brain and
   the directives decide from an identical world.
4. **Two scoped sets, not one blended set.** `dispatchedOperations` narrows to
   `kind IN ('print','travel')`; the audit pass gets its own set of unmatched
   dispatches.

Rejected: staggering executor phase (Matt: keep them in phase); moving JSON
columns into typed columns via sqlite-data (parked, larger change, revisit
after this lands); a retention-window narrowing (the constant is unprovable and
too short silently stalls a relay run).

## Design

### Types

- **`WorldCore`** — the 13 global fields: `devices`, `openOperations`,
  `queuedOperations`, `footprints`, `starPositions`, `components`,
  `blueprintBills`, `blueprintComponents`, `blueprintPrintTimes`, `theatres`,
  `locationEvents`, `replicantHostDevices`, `peers`.
- **`DirectiveSlice`** — the 5 scoped fields: `log`, `auditLog`,
  `dispatchedOperations`, `systems`, `siteAssays`. Field names match
  `WorldSnapshot`'s exactly; only the queries behind `auditLog` and
  `dispatchedOperations` narrow. `WorldSnapshot.auditLog` keeps its name and
  type and now carries only unmatched dispatches.
- **`WorldSnapshot`** — unchanged public shape, plus an internal init composing
  it from `core + slice + now`.
- **`WorldTick.read(db:now:)`** — returns `(core, [directiveID: DirectiveSlice],
  view, running)` from one transaction.

`WorldSnapshot.read(from:now:directive:)` remains, reimplemented as a
single-directive call through the new path, so `WorldSnapshotTests` and the 13
mission machines are untouched.

### Batching the scoped queries

- `log` and the audit query batch with `WHERE directiveID IN (…)`.
- `systems` / `siteAssays` fetch the **union** of all directives'
  `wanted` / `decoded` designation sets once; each slice takes its subset in
  memory. Note `wanted`/`decoded` depend on the vessel's location, so slices are
  built after `core.devices` within the same transaction.

### Loops

The supervisor, brain and executor loops collapse into one 5s tick loop:

```
tick:
  1. ONE db.read → (core, slices, view, running)
  2. publish immutable bundle, stamped with a monotonic tick generation
     (an executor uses it to tell a fresh bundle from the one it already
     evaluated, so a slow evaluation never re-runs against stale input)
  3. reconcile executors from `running` (its separate read disappears)
  4. wake executors → concurrent evaluate → own write txn each
  5. Brain.report(view)
```

### Narrowing

- `dispatchedOperations`: add `kind IN ('print','travel')`. 3,867 → 689 rows.
  Safe because every consumer outside the audit pass — 10 sites across
  `EventRun`, `RelayRun`, `Steps/PrintJob` and `Steps/TravelTo` — already
  filters on `kind == print` or `kind == travel`, and none reads any other kind.
- `auditLog`: a `NOT EXISTS` query returning `.commandDispatched` entries with
  no matching `.opCompleted`, plus the operations they name, **any kind**.
  7,954 → 4 rows. This also deletes the `alreadyLogged` set from
  `recordCompletedOps`, since SQL now does that filtering.
- The `kind` filter must NOT be applied to the audit set: `recordCompletedOps`
  looks up ops of any kind, and filtering it would silently stop writing
  `.opCompleted` entries for `launch`, `recall`, `deploy` and the rest. This is
  the single reason the two sets cannot be merged back into one.
- Rewrite the out-of-date doc comment on `dispatchedOperations`
  (`WorldSnapshot.swift:41-49`), which names only the audit pass as the reason
  for keeping closed rows; there are in fact eight consumers.

## Behaviour deltas

**A directive paused mid-tick is honoured on the next tick**, up to 5s later,
because the directive row now comes from the batch rather than a fresh read at
the top of `evaluateOnce`. The existing comment justifying that re-read ("the
row is the checkpoint a relaunch resumes from") must be updated to say the
checkpoint is now read at tick time.

That is the only behaviour delta. In particular `RelayRun.printDiagnosis` and
`RelayRun.printedRelayCode` are unaffected: they need print ops of *every
status* including `.superseded` and `.completed`, and the `kind` filter removes
no print op of any status. The narrowing drops only kinds no consumer reads.

Not a new risk: `operations` carries a unique index
`operation_one_active_per_device`, so a conflicting claim already fails at write
time rather than relying on read freshness. Executors already run concurrently
(the trace shows up to 6 inside `evaluateOnce` at once), so a shared snapshot
widens an existing window rather than opening a new one.

## Verification

- All 56 existing test files pass unchanged. This is the primary evidence.
- A test asserting one tick issues **one** read transaction, not N.
- Tests pinning each narrowed query against fixtures containing rows they must
  **exclude** as well as rows they must keep, each exclusion proved by mutation.
  (Fixtures written relative to the constant they test leave the constant's
  value undefended — pin the roots explicitly.)
- A test that `recordCompletedOps` still writes `.opCompleted` for a terminal
  `launch` op — the kind the narrowed `dispatchedOperations` deliberately drops,
  and the failure the two-set split exists to prevent.
- A test that a directive paused mid-tick resumes no action, pinning the one
  behaviour delta rather than leaving it to inspection.
- Re-profile against a fresh trace and compare to the estimate below.

## Expected result

Arithmetic from the measured shares, **not** a measured result:

| component | today | after |
|---|---|---|
| global read (54%, done 22×) | 54% | ~2.5% |
| directive-scoped read | ~11% | ~2.5% |
| non-read `evaluateOnce` | 4.5% | 4.5% |
| `tickBrain` | 7.6% | ~2% |
| everything else | 22.9% | 22.9% |
| **total** | **100%** | **~34%** |

That is ~18% of a core against today's 53%. The real number gets claimed only
after re-profiling.
