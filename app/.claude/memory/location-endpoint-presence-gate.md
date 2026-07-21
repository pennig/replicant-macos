---
name: location-endpoint-presence-gate
description: "GET locations/{designation} is gated on replicant PRESENCE, not exploration; 403 = \"No replicant in system\"."
metadata: 
  node_type: memory
  type: reference
  originSessionId: ec7b3f36-b374-4ce1-bea7-72549c0edf22
---

`GET locations/{designation}` returns 200 (full scanned/estimated detail) **only while one of your replicants is currently in that system**. Otherwise it returns **HTTP 403 with `{"error":"No replicant in system"}`** — even for systems you have previously explored and fully scanned.

Verified live 2026-07-04: `locations/KRIOS` (current system, replicant 99380EDF present) → 200 with planets_scanned 3/3; `locations/SANSUNU` and `locations/TENEGSHE` (unexplored, no replicant) → 403 "No replicant in system".

`LocationsClient` (GameServices; moved out of UniverseModels 2026-07-21, M1) maps this 403 → `LocationsError.noReplicantInSystem` (renamed 2026-07-04 from the misleading `.notExplored`, which implied an exploration gate). Consequence to keep in mind: selecting a previously-scanned system the replicant has since left (with no cached `SystemDetail` blob) still returns no live detail — it falls back to the cached blob, or stays a census leaf.

Because a detail blob can only be fetched while present, and reaching a system marks it explored (census `explored: true`), **a persisted `SystemDetail` blob implies the system is explored** — this invariant backs the Locations "Explored" filter fix in [[locations-catalog-feature]] (`LocationTree.forest`: `star.explored || details[designation] != nil`), which covers stale local census flags. See [[location-sites-endpoint]].
