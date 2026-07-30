---
name: event-log-feature
description: "EventLogFeature — power-user SSE event ledger window (Tools menu), persisted EventLog table, unhandled flag + filter; JSONTreeView now shared from UI. Ledger query is capped at displayLimit — an unbounded fetch crashed the app via AttributeGraph 'exhausted data space'."
metadata: 
  node_type: memory
  type: project
  originSessionId: 0cce860f-354a-42d6-abf2-6d242eb69a96
---

SSE Event Log: a Raw-API-style diagnostic that persists **every** dispatched event and shows its full envelope in the shared JSON tree. Built 2026-07-20.

- **Capture point:** `EventLogClient.record` (GameServices) is called from `EventRouter.dispatch` in `GameSync/Sources/EventRoute.swift` — the single choke point. `isHandled = hasSpecificRoute || event.deviceCode != nil` (exact inverse of the existing "⚠️ UNHANDLED" rule). `testValue`/`previewValue` are no-ops so routing tests aren't touched.
- **Table:** `EventLog` (`GameModels/Sources/EventLog.swift`), PK = stream id (upsert dedupes catch-up vs stream), typed metadata columns + `payload` JSONValue blob. `EventLog.envelopeJSON` folds columns+payload back into one object for the detail tree. Registered in `GameDatabase.migrator()`. NOT cleared on logout (user-managed; clear via window button).
- **Module:** `EventLogFeature` — `EventLogView` (2-col split), list/row/detail, `@FetchAll` reloaded via `state.$events.load(query)` for the "unhandled only" filter. Hosted in its own window (Tools ▸ Event Log, ⌥⌘E) scoped through `MainFeature.eventLog`, mirroring `RawAPIWindow`.
- **The ledger query MUST stay capped — `EventLogFeature.displayLimit` (1000).** On 2026-07-30 the app died with `AttributeGraph precondition failure: exhausted data space` (SIGABRT) after 5½h uptime. Cause: `@FetchAll(EventLog.order { $0.receivedAt.desc() })` was unbounded, and `SelectableList` is **not virtualized** — it is `ScrollView { LazyVStack { ForEach } }`, and a `LazyVStack` must measure its rows to size the scroll view, so it allocates AttributeGraph nodes for every row. `eventLogs` is written by the stream and **never pruned** (15,839 rows over 4 days at ~400–660/hour), so the graph grew until AG aborted mid-layout — the backtrace is pure layout (`ScrollViewLayoutComputer` → `LazyVStackLayout` → `measureEstimates` → `ForEachState.forEachItem` → `Node::allocate_value`), no update loop involved. **The filter reload must carry the same `.limit`**, or toggling "unhandled only" silently re-opens the unbounded fetch. Two consequences worth knowing: the table still grows (only the *query* is bounded — see [[operations-table-retention]] for the pruning precedent), and **any other `SelectableList` over an unbounded table has the same latent bug** (`stars` is already at 14,122 rows).
- **JSONTreeView is now shared from the `UI` module** (moved out of RawAPIFeature; `UI` gained a `Utils` dep). `JSONTreeView`/`JSONTreeNode` are public. Reuse it anywhere: `JSONTreeView(node: JSONTreeNode(value: someJSONValue))`. See [[event-stream-migration]], [[monospace-system-names]].
