---
name: json-projection-over-blob-decode
description: "Let SQLite project fields out of systemJSON instead of decoding whole StarSystem blobs. WorldView.beltsBySystem 73.9ms → 13.7ms/tick. Includes the json_each malformed-blob trap and why JSONB alone would be SLOWER."
metadata:
  node_type: memory
  type: project
---

`WorldView.beltsBySystem` decoded every surveyed `systemJSON` blob on every
5-second brain tick to read three fields per belt. It now asks SQLite for those
three fields with `json_each` over `$.belts`, so the read scales with the belt
count instead of with every surveyed system's whole object graph. Measured
release-build against a copy of the live DB (264 surveyed systems, 110 belts):
**73.9 ms → 13.7 ms warm** (168 ms cold), byte-identical output — same 110
systems, same 110 belts, zero mismatches. `WorldView.read` also stopped pulling
the blobs into memory at all: `surveyedSystems` is now a `select { $0.designation }`
rather than a whole-row fetch, so 5.9 MB never crosses into Swift.

**`json_each` raises on invalid JSON and takes the WHOLE query down with it.**
The decode path degraded per row — one malformed blob meant "no belt data for
that system" and the read continued. Reproducing that needs the argument
sanitized, not the rows filtered: `json_each(CASE WHEN json_valid(x) THEN x ELSE
'{}' END, '$."belts"')`. A `WHERE json_valid(x)` clause happens to work but
depends on the planner filtering before the table-valued join, which is not a
guarantee; the `CASE` holds under any plan (verified by forcing the malformed row
to sort first). It costs ~6.7 ms → ~13.7 ms, still ~5× better than decoding.
`WorldViewBeltProjectionTests.aMalformedBlobDegradesInsteadOfFailingTheRead`
pins it — seed through the model, then corrupt the column with raw SQL, because
symbol interpolation renders qualified names (`"systemDetails"."designation"`)
that an INSERT column list and an UPDATE SET both reject.

**Accepted loss:** the old path tallied decode failures and logged one
breadcrumb. SQLite drops an invalid blob before Swift sees it, so a malformed row
is now indistinguishable from a system with no belts. Counting them costs a
second full `json_valid` pass every tick for a condition that has never occurred
(all 264 rows are valid), so the tally was not worth buying back.

**JSONB would NOT remove the Swift decode, and migrating the column alone makes
things slower.** `_CodableJSONBRepresentation` writes `jsonb(<text>)` and reads
`SELECT json("column")` before running `JSONDecoder` on the result
(`Codable+JSONB.swift:14`, `:87`) — SQLite's JSONB is an internal binary format
no Swift decoder understands. Measured over the same 264 rows: reading the text
blobs takes 6.2 ms, the `json()` round-trip of a JSONB column 11.3 ms. What JSONB
*does* buy is the projection: `json_extract` of a scalar 10.3 ms → 1.3 ms,
`json_array_length` 8.3 ms → 0.4 ms, a `json_tree` roll-up 21.9 ms → 12.3 ms, and
15% smaller storage (5,959 KB → 5,053 KB). **So the win is querying it, not
storing it** — migrate the column only together with queries that stop
materializing whole values.

Two constraints if that migration happens: `jsonEach()` and the other builder
JSON APIs require the column to already carry a JSON representation, which is why
this projection uses `#sql` with interpolated static symbols against the TEXT
column; and every JSONB API is gated `@available(macOS 26)`. GRDB links the
system SQLite (`GRDBSQLite/module.modulemap` declares `link "sqlite3"`), 3.54.0
here, well past the 3.45 JSONB floor.

The remaining consumer of the same escape hatch is `LocationForest.fetch`, which
decodes all 264 blobs per search keystroke (~72 ms, growing ~47 rows/day since
the survey brain started charting). Same treatment applies — see
[locations-forest-inventory-index](locations-forest-inventory-index.md), whose
nested roll-ups (`allResourceSites`, `allDevices`, `allInventory`) need
`json_tree` rather than `json_each`, and which has no builder wrapper at all.
