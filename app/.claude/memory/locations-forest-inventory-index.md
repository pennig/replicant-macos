---
name: locations-forest-inventory-index
description: "Locations catalog QUERY-side perf — the forest rebuild was O(stars × footprints); rolled up to an index. Measured 1.20s → 0.12s, inventory sort 8.9s → 0.015s."
metadata:
  node_type: memory
  type: project
---

The Locations list took seconds to repaint on an active-replicant switch and on
every search keystroke. Both paths call `fetch.load(request)`, so the whole cost
is one `LocationForest.fetch`. **Measured in a RELEASE build against a copy of
the live DB** (14,122 `stars`, 264 `systemDetails`, 7,569 `locationFootprints`):

    whole fetch                    1.20 s   →  0.12 s
      LocationTree.forest          0.906 s  →  0.021 s
        hasInventory × 14,122      0.673 s  →  0.0004 s
        sort by distance           0.013 s
      decode 264 system blobs      0.089 s     (unchanged — now the floor)
      all SQL                      0.047 s     (never the problem)
    forest with the inventory sort 8.85 s   →  0.015 s

**Root cause:** `LocationTree.hasInventory(includeDescendants:)` scanned the
ENTIRE footprint dictionary — `location == designation || hasPrefix(designation +
"-")` — once per system. That is O(stars × footprints) ≈ 107 M string comparisons
per rebuild. `inventoryTotal` did the same scan *inside a sort comparator*, which
is where the 8.85 s inventory sort came from.

**Why it appeared in August 2026 and not before:** the code was always quadratic;
the second factor grew. `locationFootprints` is written by
`LocationsClient.refreshFootprint()`, one row per location where the account has
anything — and most rows are resource-site markers (7,335 of 7,569 are not
Lagrange points; only 226 carry `resources > 0`). The survey automation shipped
2026-08-06 and has been charting continuously since, so the table went from small
to galaxy-wide. **sqlite-data 1.7 → 1.9 was the suspect and is exonerated**: every
SQL fetch in the request totals 0.047 s of a 1.20 s call.

**Fix:** `LocationInventoryIndex` (internal, in `LocationNode.swift`) — built once
per `forest(...)`, it credits each footprint's `resources` to every ancestor
designation by splitting on `-`, so `hasInventory` and `inventoryTotal` become
dictionary lookups. Splitting on the separator (not `hasPrefix`) is what keeps
`SOL` from claiming `SOLARIS-1`; `LocationInventoryIndexTests` pins the new index
against the exact scan it replaces over that trap. The inventory sort additionally
keys each system once before sorting instead of per comparison.

**Second fix, same day — the search term narrows the blob read too.** The star
query filtered on the search term but `SystemDetail.all` did not, so typing "SO"
decoded all 264 blobs to render the ten systems that could match. A blob is only
ever read through a star of its own designation, so binding one `like` pattern
and applying it to both queries is exact. Whole fetch, measured release-build:

    search "S"        102 ms →  49 ms
    search "SO"        88 ms →  12 ms
    search "SOL"       81 ms →   9 ms
    search "SOLARIS"   82 ms →   8 ms
    search ""         129 ms → 133 ms   (unchanged: `%%` matches everything)

The budget is **<150 ms, tighter on the search flow** — so the typing path now
has an order of magnitude of headroom and the empty-search path has about two
weeks of it. `LocationForestSearchTests` guards the invariant the narrowing
rests on: if the two predicates ever drift apart, a hydrated system silently
downgrades to a census leaf, which no existing test would have caught.

**The remaining floor is the blob decode**, 0.072–0.089 s for 264 rows, and it
grows linearly with charted systems (142 → 264 in four days). It is now the
whole of the empty-search cost that isn't the 34 ms `stars` read, so the
initial-load path — opening the tab, clearing the field, changing sort/filter,
switching the active replicant — is what the JSON projection would buy next. This is the same
`systemJSON` decode escape hatch [brain-survey-goal-build](brain-survey-goal-build.md)
flagged for `WorldView.read`, and the same automation drives both numbers.
`NewStarMapFeature`'s `SystemDecodeCache` is the shape to reuse when it bites.

**Method note:** the first isolated micro-benchmark of the footprint scan reported
68 ms and nearly retired this hypothesis. Synthetic designations don't share
prefixes the way real ones do, so `hasPrefix` bailed on the first character far
more often — it understated the real cost ~10×. Same lesson as
[scroll-anchor-forces-foreach-walk](scroll-anchor-forces-foreach-walk.md): measure
against the real store, not a shaped-alike harness. The recipe that worked was a
temporary `@Suite(.enabled(if: env["RC_BENCH_DB"] != nil))` test opening
`DatabaseQueue(path:)` on a copy of the live DB (see
[sqlite-db-location](sqlite-db-location.md)) and timing each stage with
`ContinuousClock`; deleted once the numbers were recorded.

See [locations-list-flatten-perf](locations-list-flatten-perf.md) for the RENDER
side of this same list — that note fixed the view, this one the query behind it.
