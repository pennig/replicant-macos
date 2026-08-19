# Logistics charts aggregate in SQL, not in Swift

The Haul Yields screen used to observe a bounded `@FetchAll` of 1,000 rows
(`LogisticsFeature.displayLimit`) and fold every figure from that array in
Swift. Measured 2026-08-19 on the live database: 3,847 trips in nine days,
500–700 a day, 684 on the busiest. So 1,000 rows was **under two days** — the
"7 days", "30 days" and "All" charts every one showed the same truncated slice
and disagreed with their own labels. The KPI tiles and the day/resource/source
breakdowns were all wrong by the same cut.

Raising the limit only moves the date at which it lies again, and an unbounded
`@FetchAll` is the exact shape that produced the AttributeGraph "exhausted data
space" crash in `EventLogFeature` (see [event-log-feature](event-log-feature.md)).
So the fold moved into SQLite:

- **`HaulYieldDigest: FetchKeyRequest`** runs four statements under one
  `WHERE "collectedAt" >= ?` window and returns a `YieldSummary` — a small
  value the view observes instead of an array of rows. What it returns is
  fixed in size however large the window grows.
- **`YieldSummary.rows` is a display slice**, capped at
  `HaulYieldDigest.tableRowLimit` (100), read only by the ledger table.
  `tripCount` is the honest count and the table's "+ n more trips in this
  range" line is the difference. **A table bound is not a chart bound** — that
  conflation was the whole bug.
- `perType` is a JSON blob, so the six per-resource sums are
  `SUM(json_extract(perType, '$.<key>'))`, projected positionally onto
  `TotalsRow`/`DayRow`. A transposed pair swaps two resources silently;
  `theSixResourceSumsDecodeOntoTheirOwnResource` pins each with a distinct value.
- Days group by `date(collectedAt, 'localtime')`. Dates are stored as **UTC
  text**, so grouping without it files every trip made after local midnight
  under the following day. Measured on the live table (operator at UTC−5), the
  2026-08-18 bucket held 684 trips grouped in UTC against 723 grouped locally.
- `HaulYield.addCollectedAtIndex` backs the window. Verified with
  `EXPLAIN QUERY PLAN`: the aggregates use it as a covering index and the
  `ORDER BY collectedAt DESC LIMIT 100` slice walks it backward instead of
  sorting. All four statements together measured 7ms.

**Consequence for callers:** `LogisticsFeature.State.init()` now resolves
`@Dependency(\.date.now)` to cut the window, so any test constructing it must
supply `$0.date`. The cutoff is pinned when the request is built, not when it
runs, so `LogisticsView`'s `.task` rebuilds it on appear — otherwise a
long-open window drifts.

Related: [fetchall-fetches-on-the-writer](fetchall-fetches-on-the-writer.md),
[json-projection-over-blob-decode](json-projection-over-blob-decode.md),
[logistics-haul-yields](logistics-haul-yields.md).
