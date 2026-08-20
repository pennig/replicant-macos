---
name: dispatched-operations-two-set-union
description: "Why WorldSnapshot.dispatchedOperations unions a kind-filtered mission set with a kind-agnostic audit set instead of one query; the audit worklist is a correlated SQL NOT EXISTS anti-join, correlated on directiveID AND operationID. 2026-08-20."
metadata:
  type: feedback
---

`WorldSnapshot.dispatchedOperations` fetches two differently-scoped sets and unions them into one
`[String: Operation]`. A single `kind IN (print, travel)` filter looks equivalent and is not: it
silently breaks completion detection for every other kind.

**The mission half** (`missionOps`) is filtered to `WorldSnapshot.dispatchedKinds` (`print`, `travel`),
every status. That is the only shape any mission machine reads: `EventRun` / `RelayRun` /
`Steps/PrintJob` read `print`; `Steps/TravelTo` reads `travel`. Before this narrowing the query fetched
every kind a directive ever dispatched — 1,424 rows for the oldest running directive, 3,867 across all
22 — decoding JSON `detail` on rows nothing read.

**The audit half** (`auditOps`) is the ops named by `auditLog`, fetched by id with NO kind filter.
`DirectiveExecutor.recordCompletedOps` looks up `world.dispatchedOperations[operationID]` for ops of
ANY kind to decide whether a dispatched op reached a terminal state and write its `.opCompleted` entry —
`launch`, `recall`, `deploy`, everything. Kind-filtering this half would silently and permanently stop
the audit pass closing every non-mission kind, with no pre-existing test positioned to notice; this was
caught by design review, not by a failing test.

**Why the audit worklist is now a correlated SQL anti-join, not a Swift set-difference.** `auditLog`
went through three shapes. It used to be every `.opCompleted` plus every `.commandDispatched` naming an
op, unbounded and un-deduped in Swift (commit `f6f9426`'s predecessor) — 7,954 rows on the oldest
directive to find 4 actionable ones. An earlier commit (`b3eb309`) tried a SQL anti-join
(`operationID NOT IN (subquery of already-closed ids)`), but the subquery's exclusion set was scoped
across the WHOLE BATCH, not per directive — only correct while no operation id is ever named by two
different directives, an invariant nothing in the schema enforces. `f6f9426` retreated to Swift: two
unbounded fetches (every `.commandDispatched` and every `.opCompleted` row for the batch) followed by a
per-directive set-difference.

Ticket 11 replaced that set-difference with a query correlated on **both** columns — `directiveID` AND
`operationID` — which `NOT IN` structurally cannot express (a `NOT IN` exclusion set is one flat list, not
a per-row pairing) but `NOT EXISTS` can:

```swift
DirectiveLogEntry.where { entry in
    entry.directiveID.in(ids) && entry.kind.eq(.commandDispatched) && entry.operationID.isNot(nil)
        && !DirectiveLogEntry.as(ClosingCompletion.self).where { completion in
            completion.directiveID.eq(entry.directiveID)
                && completion.kind.eq(.opCompleted)
                && completion.operationID.eq(entry.operationID)
        }.exists()
}
```

`ClosingCompletion` is a `Table.as(_:)` self-join alias — without it the inner query's unaliased
`"directiveLogEntries"` shadows the outer reference and the correlation silently breaks. This is exact
per directive with no batch-wide assumption, dropping either half of the correlation reopens the
same-operation-id bug (`aSiblingsCompletionOfTheSameOperationIDNeverClosesMyDispatch` pins it, and stays
red under that mutation). `directive_log_by_directive_kind` (`directiveID, kind, operationID`) makes both
the outer scan and the inner subquery an indexed `SEARCH`, the inner one a covering-index point lookup —
`EXPLAIN QUERY PLAN` confirms neither side is a table scan.

Measured on the live database: the eliminated completion fetch was 1,772 rows, now returned as the 3-row
worklist directly. The dispatch-rows fetch (1,775) is unrelated to this fix and still runs — it also
feeds `dispatchedOperations`' log-fallback attribution for mission ops with no `directiveID` owner column
(pre-owner-column rows), a different consumer of the same table this ticket left alone. So the audit
computation itself collapsed from ~3,547 fetched rows to 3; the slice's total `directiveLogEntries` reads
per tick went from ~3,547 to ~1,778.

**Consumers, so `dispatchedKinds` isn't re-widened by accident:**
- `RelayRun.printedRelayCode` — names a clone off a COMPLETED print, hours after it closed.
- `printDiagnosis` — needs `.superseded` to distinguish "superseded" from "never dispatched".
- `Steps/TravelTo.lastTravelCompletion` — post-dates a device row against its last completed travel.
- `EventRun`, `Steps/PrintJob` — read `print` mission-side.

Widen `dispatchedKinds` only alongside a new consumer that reads the added kind.

**Why `dispatchedOperations` must never be folded into `openOperations`.** The two overlap on every
still-open op, but `dispatchedOperations` deliberately also carries CLOSED ones — that's the entire point
of the audit half. `openOperations` is the lookup a mission reads to ask "is this device busy right now?"
(`WorldSnapshot.openOperation(for:)`). Merge the two and a closed op sitting in that lookup reads as still
in-flight, so a device that finished its job would keep reading as busy. They stay two separate properties
for exactly this reason.

Related: [[directive-log-window-and-timeline]] (a different bound, on `log`), [[operations-table-retention]].
