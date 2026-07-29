---
name: sqlite-db-location
description: "Filesystem path to the running app's SQLite DB, for direct inspection with sqlite3"
metadata: 
  node_type: memory
  type: reference
  originSessionId: acf63055-6a9a-4ae6-b6f4-c4d5ed6f2b46
---

The app's live SQLite database (SQLiteData `defaultDatabase`) is at:
`~/Library/Containers/name.pennig.replicould/Data/Library/Application Support/SQLiteData.db`
(bundle id `name.pennig.replicould`; WAL-mode, `-wal`/`-shm` alongside).

Inspect directly with the `sqlite3` CLI even while the app runs (WAL allows concurrent readers) — invaluable for debugging data disconnects:
`sqlite3 -header -column "$DB" "SELECT ... "`. Key tables: `stars` (census/galaxy terrain — `explored`, `estimatedPlanets`, `fullyScannedAt`; NOTE this lags real scan state), `systemDetails` (per-system scan blob: `designation`, `systemJSON`, `recon`, `systemScanned` — decode planets via `json_array_length(json_extract(systemJSON,'$.planets'))`), plus devices/replicants/operations/etc.

Gotcha that bit us: `stars.explored` and `stars.estimatedPlanets` are UNRELIABLE relative to `systemDetails` (a fully-scanned system can show `explored=0`; estimate can differ from the real planet count). The star map's galaxy view must merge `systemDetails.recon` over the census row. See [[new-star-map-feature]].

`stars.fullyScannedAt` is now trustworthy (2026-07-29). It was written by nothing at all — null on all 14,122 rows — and is now stamped on every catalog write via `SystemDetail.persist`, plus backfilled for the 31 systems that were already surveyed. See [[system-detail-persist-choke-point]].
