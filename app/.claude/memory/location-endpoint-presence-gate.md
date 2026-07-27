---
name: location-endpoint-presence-gate
description: "CORRECTED 2026-07-27: GET locations/{designation} is gated on EXPLORATION, not presence — its 403 \"No replicant in system\" message lies."
metadata: 
  node_type: memory
  type: reference
  originSessionId: ec7b3f36-b374-4ce1-bea7-72549c0edf22
---

`GET locations/{designation}` returns 200 (full scanned/estimated detail) for **any system the census marks `explored: true`**, whether or not a replicant is currently there. It returns **HTTP 403 `{"error":"No replicant in system"}`** for systems you have never explored.

**The 403's message is misleading — it names presence but the server is testing exploration.** That wording is what produced the earlier reading of this note (2026-07-04), which concluded the gate was presence. The evidence then was consistent with both rules by accident: the one 200 happened to be the replicant's *current* system, and the two 403s (`SANSUNU`, `TENEGSHE`) were unexplored at the time. `TENEGSHE` is explored now and serves 200 with no replicant in it.

Re-verified live 2026-07-27, both replicants parked at AINALRAM / ASTELLIO:

- explored, **no replicant present** → 200 full detail: `SOL` (8 planets / 28 moons scanned), `UNALEDI`, `MENKENTAR`, `URCALIS`, `ABSOLETNO`
- census `explored: false` → 403: `DABAH`, `MORIVA`, `CANOPUS`, `SADACHIBIA`

So a previously-scanned system the replicant has since left **can** be rehydrated from scratch — there is no need for a cached `SystemDetail` blob and no need to travel back. That is what makes the Locations catalog's hydrate-on-select work for a distant system, and it is why `stars.explored` being wrong was fatal rather than cosmetic: the flag, not the endpoint, was the thing standing in the way (see [[census-explored-is-not-distance-sorted]]).

`LocationsClient` maps the 403 → `LocationsError.noReplicantInSystem`. The name now mirrors the server's wording rather than its behaviour; treat it as "detail unavailable — system not explored". Renaming it is safe but untaken, since every call site already treats it as best-effort.

The old derived invariant still holds and is still useful: a persisted `SystemDetail` blob implies the system is explored (you could only ever have fetched one for an explored system), which backs `LocationTree.forest`'s `star.explored || details[designation] != nil` in [[locations-catalog-feature]]. See [[location-sites-endpoint]].
