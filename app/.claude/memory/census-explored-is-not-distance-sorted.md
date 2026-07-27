---
name: census-explored-is-not-distance-sorted
description: "The per-replicant census is sorted by CURRENT distance while explored is HISTORY, so explored systems do not cluster in the early pages — never stop the walk early."
metadata: 
  node_type: memory
  type: project
  originSessionId: f384f769
---

`GET /v1/replicants/{code}/stars` is sorted by **current** distance from that replicant. `explored` is **history**. The two are unrelated, so explored systems do **not** cluster in the first pages — every system the probe has since travelled away from sinks to wherever its distance now puts it.

`NewStarMapFeature.runSurvey` used to stop the overlay walk at the first page carrying no explored systems on exactly that false assumption. Measured live 2026-07-27 for replicant `99380EDF` (parked at AINALRAM), 141 pages × 100:

- explored systems sat on pages **1, 2, 3, 12, 13, 28** — page 4 was already empty
- the walk stopped at page 4 and wrote 25 of 29 systems, silently losing **MENKENTAR, SOL, UNALEDI, URCALIS**
- `SOL` was on page **13**, 39.5 ly out, `explored: true, has_life: true`

The damage was not cosmetic: the Locations catalog gates both its "Explored" filter and its hydrate-on-select on `stars.explored`, so a missed row is a system you cannot open (the endpoint itself would have served it — see [[location-endpoint-presence-gate]]).

**There is no cheap complete alternative.** Checked all three: `GET /v1/stars` (the single-request full catalogue) carries no per-replicant knowledge at all; the census honours no `explored` query filter (passing `explored=true` is silently ignored, `total_stars` unchanged at 14,066); and `per_page` is clamped at 100 (asking 200 returns 100 — see [[paged-endpoint-maxima]]). So completeness costs ~141 requests against the governor's 120/min read budget, which is why the exhaustive walk stays on the deliberate, rate-limited Survey action rather than anything automatic.

The cheap partial repair is `GET /v1/locations`: anything you hold at a location proves you reached its system, so `LocationsClient.refreshFootprint` marks those systems explored on the one request the Locations screen already makes. It is strictly additive (a holdings overlay, not a knowledge index — a system you hold nothing in is simply absent, and absence must never clear the flag). Coverage is genuinely partial: 7 systems here versus the census's 29, and of the 4 missing rows it fixed only SOL.

Both paths are locked by tests that fail against the old code: `SurveyOverlayTests` (NewStarMapFeature) and `FootprintExplorationTests` (GameServices).

Related: [[sqlite-db-location]] already warned that `stars.explored` lags `systemDetails`; this is the mechanism behind that lag.
