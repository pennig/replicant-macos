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

The eliminated completion fetch was ~1,772 rows, now returned as the 3-row worklist directly.

**The mission-log-fallback fetch had the identical defect, and it shipped bigger.** `dispatchRows` fed
`dispatchedIDsByDirective`, which exists for exactly one job: attributing a mission op (`print`/`travel`)
with **no** `directiveID` owner column — a pre-owner-column row, traceable only through the log that
dispatched it. It originally fetched every `commandDispatched` entry for the whole batch (~1,778 rows) to
serve that one narrow need, and — same shape as the anti-join bug above — `missionOpsByID` was a flat,
batch-wide `[id: Operation]` lookup with no owner check, so a directive whose log happened to name an
op another directive's `directiveID` column already claimed got handed that op too. An owned op is
already found by `operation.directiveID.in(ids)`, so the fallback is redundant for it; the fetch is now
filtered to entries naming a mission-kind op whose OWN `directiveID` is NULL:

```swift
let nullOwnedMissionOpIDs = GameModels.Operation
    .where { $0.directiveID.is(nil) && $0.kind.in(WorldSnapshot.dispatchedKinds) }
    .select(\.id)
DirectiveLogEntry.where {
    $0.directiveID.in(ids) && $0.kind.eq(.commandDispatched) && $0.operationID.isNot(nil)
        && ($0.operationID ?? "").in(nullOwnedMissionOpIDs)
}
```

`theLogFallbackNeverCrossAttributesAnOwnedOperation` pins this — an op D2 owns, named only in D1's log,
must never appear in D1's `dispatchedOperations` — and goes red under the mutation of dropping the
`nullOwnedMissionOpIDs` filter; `aNullOwnerMissionOpIsAttributedByItsDispatchersLog` pins that the
legitimate fallback still works. `operation_by_directive (directiveID, startedAt)` keeps this an indexed
`SEARCH`, not a scan.

**What ships, measured on the live database, same 22-directive roster:** the audit anti-join returns its
3-row worklist directly (was ~1,772 to derive it); the mission-log fallback now reads ~182 rows (was
~1,778, unfiltered). The slice's total `directiveLogEntries` reads per tick: **3,553 (original) → ~1,781
(audit anti-join alone) → ~185 (both fixes)** — a ~95% reduction from where this note started.

**A related shape, found but NOT fixed here.** `auditOpsByID` (the audit half, a few paragraphs up) is
ALSO a flat, batch-wide `[id: Operation]` lookup with no owner-column check. Unlike the mission half,
this is not obviously a bug: the audit half is deliberately scoped by the LOG ENTRY's own `directiveID`,
not the operation's, because its job is "does MY dispatch of this op still need closing" — a question the
op's owner column doesn't answer and was never meant to gate (see "kept kind-agnostic on purpose" above).
Whether an op named in two directives' logs should audit-close for both, or only one, is a real open
question this note does not resolve — flag it before assuming the audit half needs the same fix.

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
