---
name: ftl-mesh-incremental-fold
description: "SHIPPED 2026-08-06: a relay.* event folds in ONE relay's network view instead of reading every relay; two escalation predicates (join / split) decide when a single view provably can't describe the change. The split check must use the RAW direct filter — DirectFTLLinks.reduce's parity repair answers it by construction. UPDATED 2026-08-15: the star map's roster trigger folds too (it CAN name which relay moved), and the appear-path TTL was 30s against a 5-minute sweep — together they were burning 329 reads per Stars visit."
metadata:
  type: project
---

Amends [[ftl-authority-rule]] and [[star-map-live-overlays]], both of which still
describe the mesh as recomputed wholesale on every roster or liveness change. Neither
trigger works that way now — see the roster section below.

## What changed

`GameSync.ftlMeshRoute` calls `ftlMeshRefresher.noteRelayChanged(event.deviceCode)` before
`invalidate(.ftlMesh)`. The refresh drains that note: **exactly one attributed relay** takes
the fold-in path (one `GET devices/{code}/network`); a burst or an unattributed event (nil
`deviceCode`) takes the full sweep. The note lives
in a `LockIsolated<Pending>` owned by `liveValue`, so the debounce and the
never-read-on-the-router's-dispatch-path rule (V3.4-B2) are both untouched.

## The roster trigger folds too (2026-08-15)

The claim above that a roster change "is not recoverable from a roster diff" was **false, and
it cost 329 API reads per Stars-view visit**. `.onChange(of: relayNodes)` is handed both the
old and the new roster, so `RelayNode.changed(from:to:)` names exactly the relays that were
added, removed, or moved star; `NewStarMapFeature` notes each code instead of `nil`, and a
one-relay change now folds. Several changed codes still sweep, which is the same
`Pending.soleCode` rule the event route obeys — nothing in `FTLMeshRefresher` changed.

Folding a roster change is safe because `incremental` was already built for exactly these
shapes: an added relay is the activation case, and a removed one is the defunct-star case
below, which needs no network read at all.

**Measured before the fix (live, 329 relays / 53,956 closure rows):** each sweep was 329
serial reads pinned at the limiter's 60/min ceiling — 5m13s — and mesh reads were 144 of 213
total API calls in one ten-minute window, with the reads budget sitting at `0 ≤ floor 12` so
every device confirm-read was deferred. The traffic tracked the Stars view exactly: it
stopped for the 16 minutes the window was on Directives and resumed on return.

The second half was the TTL. `FTLMeshRefresher.domainRegistration` took `DomainRegistration`'s
30-second default, and a sweep runs for five-plus minutes — so the domain was **always** stale
on the appear path and every revisit bought a whole sweep. It is now `15 * 60`, which must
stay longer than one sweep. An `invalidate` still outranks the TTL, so a relay event refreshes
at once.

## Why one view is nearly enough

A relay's network view reports **every peer in its subgraph**, and rows are canonical pairs,
so that one read carries every closure pair the relay is an endpoint of. Activation is
therefore locally exact — *except* where the change moves pairs the view never mentions.
`FTLLinkRecord.incremental` has two predicates for that, and they are genuinely
complementary (neither subsumes the other):

- **join** — the view's peers span more than one component of the untouched stored closure.
  The server's closure then also gained pairs *between* those components. A peer the stored
  closure has never heard of counts as its own singleton component, which is what makes the
  first event after a cleared table (the `addLinkMetrics` migration) rebuild rather than
  half-fill.
- **split** — dropping these rows disconnects stars the mesh still holds. Caught by comparing
  component counts before/after over the stars still present in both.

**The split check must use the raw `DirectFTLLinks.isDirect` filter, never
`DirectFTLLinks.reduce`.** The parity repair exists to guarantee drawn components equal
closure components, so a repaired graph answers "did this split?" by construction and always
says no. Written against `reduce`, the reclaim-a-cut-vertex case returns
`needsFullSweep == false` and the stale cross-component rows survive. This is the same
masking the mesh design doc warned makes the union-vs-intersection rule hard to test.

## The rest of the shape

- **A star with no relay left in the roster is defunct** — its rows drop with no network read
  at all. This is the reclaim case, and it is why `incremental` takes `relaysByStar` rather
  than deriving the star from the event's device: a reclaimed relay is stowed, and
  `Device.location` is nil by the time we look.
- **Drones are not mesh nodes.** The roster predicate is `features.contains("relay")`; no
  `mining_drone`/`survey_drone`/`transport_drone`/`maintenance_drone` carries it, so none has
  edges to clean up. Only relays and `system_hub`s do.
- **Two relays in one system escalate** (`relaysByStar[star] > 1`). Either view alone
  understates that star's reach — the `system_hub`-beside-a-standalone case.
- **Peer ranges come off the stored closure.** A lone view knows its own range but never its
  peer's, and there is no second view here for `rows(from:)`'s cross-view merge to work on.
  Left nil they fail open, and a 10 ly pair between two 7.5 ly relays would draw as a real
  link. The view's own `rangeLy` overrides the stored value; peers are read from whichever
  stored row names them.
- **A failed read leaves a nil view**, which holds that star's rows rather than mistaking
  silence for a dark relay. Only the roster can retire a star's edges.

Storage is unchanged — still the full closure, still `FTLLinkRecord`, no migration.
