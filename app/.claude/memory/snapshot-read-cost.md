# WorldSnapshot.read cost — what actually dominates it

Diagnosed from `.scratch/potential_cpu_usage_issue.trace` (20.4s Time Profiler,
Debug build) and measured against a copy of the live database.

## The shape

`DirectiveEngine.makeExecutor` gives every running directive its own `Task` on a
5s clock, each calling `WorldSnapshot.read` independently. Cost is therefore
`directives x per-read`. In the trace, 82% of all process CPU was inside
`evaluateOnce`, and `machine.nextAction` plus `recordCompletedOps` were 0.1%
combined — the engine spent its whole budget building the input, none evaluating
it.

## What was expensive, per read, worst directive

| | before | after |
|---|---|---|
| `StarSystem` blobs, one per target | 154.9 ms (303 targets) | 1.0 ms |
| whole-row `Star` decode for `[String: Position]` | 63.1 ms | 6.8 ms |
| 26,070 ISO-8601 timestamps | 12.8 ms | 3.1 ms |
| `auditLog`, unbounded | 40.7 ms (7,746 rows) | unchanged |
| `IN` clause over its dispatched ids | 89.3 ms (2,087 ids) | unchanged |
| `peers`, all open directives | 0.4 ms (19 rows) | unchanged |

## The trap worth remembering

**A scope that names a growing set bounds nothing.** `systems` was scoped to the
directive's targets *because* blobs are expensive, but a roaming Survey or
Salvage Run accumulates targets forever — one live run reached 303, so the read
decoded ~7 MB of JSON every five seconds. Every reader asks
`world.system(directive.currentTarget)` and none looks ahead, so the current
target is the real scope.

## The audit log was mostly rows nothing could act on

Most `.commandDispatched` entries name **no operation**: a `.simple` verb creates
no `Operation`, so `operationID` is nil and `recordCompletedOps` rejects the row
on its first guard. On the live fleet those were the majority — 3,594 of a
salvage run's 7,794 audit rows, and *all* 2,214 of one haul run's. They are
filtered in SQL now.

Do not read a nil `operationID` as an unresolved dispatch. An anti-join on
`operationID` counts them as unresolved (`NULL = NULL` is never true) and makes
the audit pass look broken when it is working: every dispatch that names a real
operation already had its `.opCompleted` entry.

`dispatchedOperations` used to read those ids into Swift and bind them as an `IN`
list — 2,100 host parameters, growing for the directive's whole life, against
SQLite's 32,766 ceiling. It is one query with a subquery now, which needs
`directive_log_by_directive_kind` to be a covering index; without that index the
one-query form is *slower* than the old two-query shape on a directive with
nothing dispatched.

The legacy fallback is still live — 1,669 operations carry no `directiveID` and
are findable only through their own dispatch entry. Do not delete that arm
without backfilling the column first.

## Still unbounded

`peers` is `O(D²)` across the fleet, invisible at 19 open directives and around
1.8 s/tick at 300.

`LocationFootprint` is read whole (26,070 rows) and 16 ms of its 21.7 ms is
materializing `fetchedAt`. No consumer needs 26,070 dates — `HaulRun.survey` and
`PrintRail.footprintCensusIsStale` want the max, `printStockIsShort` wants one
location's. Narrowing it means scoping a safety rail's input set, so it was left
alone deliberately.

## Measure in both build configurations

The first hand-written timestamp parser was 14x faster than Foundation in
release and **4x slower in debug** — unoptimized Swift pays for nested helpers
and `Range.contains` per digit, where Foundation's parser is precompiled. See
[[fast-iso8601-parsing]].
