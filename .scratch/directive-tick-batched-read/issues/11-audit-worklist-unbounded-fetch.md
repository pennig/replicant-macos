# 11 — The audit worklist still fetches unbounded to find three rows

Status: ready-for-agent
Blocked by: —

`DirectiveSlice.swift:80-102` fetches **every** `.commandDispatched` row and
**every** `.opCompleted` row for all running directives, every tick, then does a
per-directive set-difference in Swift. Both fetches are unbounded and grow
monotonically with directive age.

Measured on the live database:

| | rows |
|---|---|
| `dispatchRows` fetched | 1,778 |
| `completedIDs` fetched | 1,775 |
| **the worklist those 3,553 rows produce** | **3** |

The batched-tick branch's spec promised "7,954 → 4 rows". The shipped code reads
3,553 to find 3 — better than the 22× original, and still one of the three
unbounded growth axes that spec set out to close.

**Why it ended up in Swift.** The first implementation used a SQL anti-join whose
`NOT IN` exclusion set was scoped `directiveID IN (batch)` rather than correlated
per row. That is only equivalent to N individual reads while no operation id is
named by two different directives' log entries — an invariant nothing in the
schema enforces (there is no constraint on `directiveLogEntries.operationID`).
Rather than ship on an unproven invariant, it moved to Swift.

**The objection is solvable in SQL.** A *correlated* anti-join is exact per
directive. Verified against the live database as returning the same 3 rows:

```sql
NOT EXISTS (SELECT 1 FROM directiveLogEntries c
            WHERE c.directiveID = e.directiveID
              AND c.kind = 'opCompleted'
              AND c.operationID = e.operationID)
```

Check whether the query DSL can express a correlated `NOT EXISTS` directly; if
not, the `#sql` macro can, and `references/subqueries.md` in the
`pfw-structured-queries` skill covers the shapes available.

**Keep the guard that made the Swift version correct.** The existing test
`aSiblingsCompletionOfTheSameOperationIDNeverClosesMyDispatch` pins exactly the
case the batch-wide scoping got wrong. It must stay green.

**Done when:** the worklist is derived without fetching the full dispatch and
completion history, that test still passes, and the row counts above are
re-measured and recorded.
