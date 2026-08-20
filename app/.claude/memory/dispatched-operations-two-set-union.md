---
name: dispatched-operations-two-set-union
description: "Why WorldSnapshot.dispatchedOperations unions a kind-filtered mission set with a kind-agnostic audit set instead of one query; the SQL-matched audit worklist behind it. 2026-08-20."
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

**Why the audit worklist matches in SQL, not Swift** (commit `b3eb309`): `auditLog` used to be every
`.opCompleted` plus every `.commandDispatched` naming an op, unbounded and un-deduped in Swift — 7,954
rows on the oldest directive to find 4 actionable ones. An anti-join
(`operationID NOT IN (subquery of already-closed ids)`) now does the matching in the query itself, so
`auditLog` is just the live worklist: an unmatched dispatch, kind-agnostic, never windowed by count
(unlike `log`'s 500-row window) because it is bounded by ops actually in flight, not by directive age.

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
