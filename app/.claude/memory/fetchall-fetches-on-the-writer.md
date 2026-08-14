---
name: fetchall-fetches-on-the-writer
description: "Every @FetchAll/@FetchOne in this app re-runs on the WRITER connection, so an expensive observed query taxes every database write in the app — the root cause of slow catch-up ingestion"
metadata:
  node_type: memory
  type: project
---

**`SQLiteData`'s `FetchKey.subscribe` builds its observation with `ValueObservation.tracking`**, which GRDB
classifies `.nonConstantRegionRecordedFromSelection`. `ValueConcurrentObserver.swift:756` states the
consequence in its own comment: *"When the tracked region is not constant, we can't perform concurrent
fetches… Conclusion: fetch from the writer connection."*

So a `@FetchAll`'s re-fetch is **not** a background read on a pool reader. It runs inside the writer's
dispatch queue after each commit that touches its region, and the *next* write waits on it. Cost of an
observed query is therefore charged to **every write to the tables it reads**, app-wide — 99 observed
queries live in `*/Sources` as of 2026-08-14. A `DatabasePool` does not save you here.

## The incident this was found through (2026-08-14)

Launch catch-up processed **964 events in 260.5 s**, a hard floor of ~230 ms/event, CPU pegged. Zero
inter-event gaps over 1 s, so no network paging was involved, and the cost was flat across event types —
`bobnet.new` (no device code, no device write) cost the same as `ami.mining.digest`.

Cause: `MainFeature.State` built `EventLogFeature.State()` unconditionally at launch, and its
`@FetchAll(EventLog.order { $0.receivedAt.desc() }.limit(1000))` subscribes **eagerly** — the Event Log
window being closed, and `.events` never being read, changed nothing. Every `EventLogClient.record`
write re-ran that query on the writer.

Measured against a copy of the live database (91,500 `eventLogs` rows), per single-row upsert:

| state | per write |
|---|---|
| no observer | 0.3 ms |
| observer alive (shipped behaviour) | 287 ms |
| observer alive, `receivedAt` indexed | 99 ms |
| observer alive, indexed, `limit(200)` | 19 ms |

So ~188 ms was the unindexed full scan + temp b-tree sort, and ~80 ms was decoding 1,000 rows averaging
896 bytes of JSON payload. **Debug vs release is irrelevant** — `swift test -c release` measured 292 ms
against debug's 287. Fixed by making the state window-scoped (0.31 ms closed / 99.9 ms open), an
append-only index migration, and `EventLogRetention`.

## Diagnosing another one

The live `eventLogs.receivedAt` column is a per-event ingestion timestamp, so **consecutive-row deltas
measure the dispatch loop directly** — no instrumentation needed:

```sql
SELECT (julianday(receivedAt) - julianday(lag(receivedAt) OVER (ORDER BY receivedAt)))*86400.0 AS dt
FROM eventLogs WHERE provenance='catchUp';
```

A flat floor across unrelated event types means a per-dispatch cost, not a handler. To attribute it, copy
the live DB (`sqlite3 "$DB" ".backup copy.db"`), open it as a `DatabasePool` in a test, and time
`database.write` with and without the suspect state alive. To assert it without timing, install a
`Configuration.prepareDatabase` trace counting `SELECT`s against the table — see
`EventLogObservationLifetimeTests`.

## Still open (measured, not fixed)

- **`LocationsFeature.State` holds `@FetchAll(SystemDetail.all)`** and is alive from launch. That is 419
  rows carrying **9.1 MB** of `systemJSON`, decoded on the writer on every `systemDetails` write — which
  is exactly what the Survey Run automation produces. `LocationsFeature`'s own read path was optimised by
  [[locations-forest-inventory-index]]; this observation was not.
- **`DevicesFeature.State` holds `@FetchAll(Device.order { $0.deviceType })`** (459 rows), alive from
  launch, and `Reconciler.applyEventFields` writes `devices` on *every* device-carrying event.
- **`directiveLogEntries` reached 101,927 rows** (9,442 when [[survey-fleet-repair-build]] measured it).
  `DirectiveLogRetention` exempts open runs, so a long-lived `haulRun` keeps its whole log forever.

Related: [[event-log-feature]] (this window's third distinct pathology),
[[json-projection-over-blob-decode]] (the same decode-vs-project trade, on the read side).
