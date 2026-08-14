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

## The device cold load (fixed 2026-08-14)

`DevicesFeature`'s walk ran one `database.write` per device, so every `devices` observer re-fetched 458
times. Observers **add up rather than sharing a fetch** — measured one observer 4,621 ms across the walk,
three 12,922 ms — and four are alive from launch (`DevicesFeature`, `LocationsFeature`, `DirectivesFeature`,
`BobnetFeature.relays`). `Reconciler.ingest` gained an array form applying the walk in one transaction:
**38.7 s → 1.17 s, and 15.9 s → 0.48 s on a second run — 33× both times.** Absolute figures swing 2–3×
between runs on this machine; trust the within-run ratio, never a cross-run comparison.

## The Locations catalog: the blob was NOT the cost

The first draft of this note claimed `LocationsFeature.State`'s `@FetchAll(SystemDetail.all)` cost ~165 ms
per `systemDetails` write by dragging 9.1 MB of `systemJSON` across. **That attribution was wrong**, and it
came from measuring the whole `State` and naming the member that looked expensive. Measured in one run,
per `systemDetails` write against 418 stored systems:

| observer alive | per write |
|---|---|
| none | 0.13 ms |
| `@FetchAll(SystemDetail.all)` (the whole rows, blobs included) | 3.6 ms |
| a blob-free `@Selection` projection of the same rows | 4.05 ms |
| **`@Fetch(LocationForest)` alone** | **101.5 ms** |
| the whole `LocationsFeature.State` | 104.3 ms |

Reading 9.1 MB of TEXT into Swift Strings is ~3 ms; `systemJSON` decodes lazily in `SystemDetail.system()`,
not at fetch. **A narrowing to a stamps projection plus an in-play blob cache was built, measured, and
reverted** — it was 4.05 ms against 3.6 ms, i.e. marginally worse, for a cache, a publisher bridge and a
forced-reload parameter. Same shape as the read-time SQL projection [[locations-forest-inventory-index]]
measured and rejected: measure the member, not the aggregate, before optimising it.

The real cost is the forest rebuild, and it fires on far more than surveys — a `locationFootprints` write
measured **0.15 ms alone against 111.8 ms with the forest observation alive**, and footprints wrote 1,340
rows in a single hour on 2026-08-14 against `systemDetails`' 50–76 *per day*. `LocationsFeature.State` is
alive from launch, so every one of those writes blocks the writer for ~110 ms.

## The forest rebuild (fixed 2026-08-14)

`@Fetch(LocationForest)` re-runs on every write to `systemDetails`, `locationFootprints`, `stars` or
`replicants`, and footprints are the frequent one. Profiled per rebuild, **two whole-table row decodes
were 75 of the 101 ms**: `Star` at 58 ms for 14,995 rows and `LocationFootprint` at 17 ms for 14,562,
against 11 ms for the tree build itself and ~1–2 ms for everything else.

The list reads **7 of `Star`'s 15 columns** and 6 of `LocationFootprint`'s 7. Selecting exactly those
through `@Selection` projections (`CensusRow`, `FootprintRow`) measured **Star 91.2 → 14.9 ms and
footprints 22.0 → 9.3 ms in one run** — the unread columns include three `Date`s, and `Date` decoding is
what made a whole row expensive. Whole fetch **100.9 → 42.7 ms**; end-to-end, a `locationFootprints` write
with `LocationsFeature.State` alive went **111.8 → 34.9 ms**.

Note what did NOT work first: narrowing the *`SystemDetail`* observation, which looked like the obvious
9.1 MB offender and was worth 3.6 ms. Profile the fetch's stages before choosing one.

## Still open (measured, not fixed)

- **`@Fetch(LocationForest)` still costs ~35 ms per rebuild**, and it still rebuilds from scratch on every
  observed write. Cutting it further means changing *what it observes or when it runs*, not what it
  selects — the remaining time is spread thin (11 ms tree build, 10 ms stars, 8 ms footprints).
- **`LocationsFeature.State` holds `@FetchAll(Device.all)`** (11.6 ms per `devices` write against 0.46 ms
  bare). Much less costly since the walk batched, but still charged to every device-carrying event.
- **`directiveLogEntries` reached 101,927 rows** (9,442 when [[survey-fleet-repair-build]] measured it).
  `DirectiveLogRetention` exempts open runs, so a long-lived `haulRun` keeps its whole log forever.

Related: [[event-log-feature]] (this window's third distinct pathology),
[[json-projection-over-blob-decode]] (the same decode-vs-project trade, on the read side).
