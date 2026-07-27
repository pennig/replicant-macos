---
name: operations-table-retention
description: "The operations table had NO retention until 2026-07-27 — nothing ever deleted an op row. OperationRetention now prunes terminal ops older than 7 days, swept hourly off DeadlineScheduler's loop."
metadata:
  node_type: memory
  type: reference
---

**Until 2026-07-27 nothing pruned the `operations` table.** Ops are created
optimistically on dispatch and adopted from device snapshots, closed by
`Reconciler`/`DeadlineScheduler`, and were then kept forever. `ActivityView`
(sidebar "Operations Log"), `DeviceDetailView` and `SidebarView` all do a bare
`@FetchAll(Operation.order { $0.startedAt.desc() })` with **no status filter**,
so every row ever written rendered.

That surfaced when the stale-`final_arrives_at` bug ([[travel-block-leg-vs-route]])
produced 218 dead `unknown` rows in one day and left the log 68% noise (321 rows
total, 225 of them `unknown`). One-off purge predicate, if it ever recurs — the
signature is a deadline that predates the op's own start, which is physically
impossible:

```sql
DELETE FROM operations
WHERE status='unknown' AND completesAt IS NOT NULL AND completesAt < startedAt;
```

Scope it to `unknown` deliberately: `completed` rows with the same bogus
`completesAt` are honest history (the trip really did finish, an arrival event
closed it) and should stay.

`OperationRetention.sweep` (GameSync) now prunes **terminal ops older than 7
days**, called on an hourly throttle from `DeadlineScheduler.run()` — that loop
is the only periodic one in GameSync and retention needs no timeliness at all.
Two invariants in the predicate, both load-bearing:

- **Terminal only.** An open op is never pruned however old: an ancient `active`
  row is a bug worth seeing, and deleting one would punch a hole in the "one open
  op per device" partial unique index that dispatch relies on.
- **Aged on `startedAt`**, the one timestamp set once and never rewritten.
  `lastConfirmedAt` moves under every re-arm, so a re-armed op would never age out.

Note `unknown` is terminal and NOT in `OperationStatus.openCases`, so stale
`unknown` rows never block a mission or earn a re-poll — they were pure UI noise,
not a correctness problem. See [[directives-feature]].
