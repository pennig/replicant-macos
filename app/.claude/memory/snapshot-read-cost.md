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

## Still unbounded

`auditLog` is the one query in the read with no `LIMIT`, and its dispatched ids
feed an `IN` clause that grows with it — together ~130 ms on a long-lived
directive, rising for as long as the directive runs. `peers` is `O(D²)` across
the fleet, invisible at 19 open directives and around 1.8 s/tick at 300.

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
