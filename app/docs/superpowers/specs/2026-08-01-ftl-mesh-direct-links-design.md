# FTL mesh: draw direct links, not the closure

**Date:** 2026-08-01
**Status:** Design approved, ready for planning

## Problem

The galaxy map draws an edge between every pair of relay systems. With 11 relays that is
55 edges — exactly `C(11,2)`, a complete clique — and each new relay adds N more, so the
noise grows quadratically. At 20 relays it would be 190 edges.

This is not merely noisy, it is **wrong**. `ftlLinks` stores the backend's *closure*, not
the relay network's topology. Per the FTL authority rule, within a connected subgraph there
are no hops, so every relay's network view reports every other relay in its subgraph
regardless of distance. The map renders those closure pairs as though each were a physical
link.

Measured on the live database and confirmed by probe:

- 11 relays, 55 stored edges, one single component.
- Only **22** of the 55 are within the 7.5 ly relay range.
- The longest edge currently drawn is ARCTURUSAN↔SHERATANON at **19.03 ly** — 2.5× the range.

`GET devices/4FE22109/network` (ALPHERATOZ, probed 2026-08-01) returns `range_ly: 7.5` and
**all 10** peers, with `distance_ly` from 6.46 out to 18.06. Exactly one of those ten
(ATIANFU, 6.46 ly) is a real link.

## Key finding

`app_schemas_devices_NetworkConnectionSchema` carries **`distance_ly`** per connection, and
`app_schemas_devices_DeviceNetworkSchema` carries **`range_ly`** for the relay. Both are
already in `openapi.json` and already decoded by the generated client — and both are
discarded today at `DevicesClient.swift:190`, which keeps only `connection.star`.

So a direct link is exactly:

```
distance_ly <= range_ly
```

using the server's own numbers, per relay. No star positions, no geometry, no hardcoded
constant. This matters because ranges are **heterogeneous**: a `system_hub` carries an
integrated relay with a longer range (~12.5 ly) than a standalone `ftl_relay` (7.5 ly), so
any single global threshold would be wrong as soon as a hub is deployed.

## Design

### 1. A pure reduction in `GameModels`

`DevicesClient.relayLinks` (`GameServices/Sources/DevicesClient.swift:173`) currently does
I/O and edge resolution in one closure, which is untestable without the network. Split them.

New value type beside `FTLLink`, modelling one relay's network view:

```swift
public struct RelayNetworkView: Equatable, Sendable {
    public let star: String
    public let rangeLy: Double?
    public let connections: [Connection]

    public struct Connection: Equatable, Sendable {
        public let star: String
        public let distanceLy: Double?
    }
}
```

And one entry point:

```swift
extension FTLLink {
    public static func resolve(from views: [RelayNetworkView]) -> [FTLLink]
}
```

`relayLinks` then does only I/O: walk the roster, map each response into a
`RelayNetworkView`, call `resolve`. This matches how `OrreryLayout` and `MissionStepMachine`
are factored — a pure resolver with the I/O at the edge.

`resolve` internally performs three steps, each independently testable:

1. **Closure set** — every reported connection as an `FTLLink`, annotated with its distance.
2. **Direct set** — connections where `distanceLy <= rangeLy`.
3. **Component-parity repair** — see §3.

### 2. Union semantics for heterogeneous ranges

`relayLinks` already unions every relay's view into a `Set<FTLLink>`, and `FTLLink`
canonicalises endpoint order, so reciprocal reports collapse. Keeping that structure means a
link is drawn when **either** endpoint's range covers the distance: a 12.5 ly hub contributes
its own long edges from its own view, while the 7.5 ly relay at the far end does not.

This requires no extra code, and it is the safe direction — a union can never split a
component the server considers whole.

### 3. Component-parity repair

Filtering could in principle disconnect what the server considers one network (a relay whose
view failed to read, an unexpected range asymmetry, a borderline float). The map would then
lie in the opposite direction, showing two networks where there is one.

After filtering, compare connected components of the direct set against components of the
closure. If they disagree, add back closure edges — shortest first — until they match.
Kruskal-style: union-find seeded with the direct edges, then walk the remaining closure edges
in ascending `distance_ly`, adding any that join two distinct components.

This makes the invariant explicit:

> **Drawn components always equal server components.**

It also makes the union-vs-intersection question in §2 non-load-bearing. If hub range
semantics turn out to be asymmetric in a way we guessed wrong, the repair restores
connectivity instead of silently drawing a fractured network.

The repair pool (closure minus direct) always has usable distances, so this ordering is
well-defined: by the fail-open rule below, an edge with a nil `range_ly` or nil `distance_ly`
is classified *direct* and never reaches the pool. An edge only lands in the pool if every
view reporting it gave both numbers and found `distance > range`.

### 4. Roster fix: match the relay *feature*, not the device type

`FTLMeshRefresher.swift:67` builds its roster with `deviceType.eq("ftl_relay")`. But
`SalvageTargetPlanner.meshSystems` (`SalvageTargetPlanner.swift:52`) matches
`features.contains("relay")` and documents exactly why:

> "a `system_hub` contains an integrated relay and genuinely does mesh its system, so
> matching on the capability rather than the device type is correct HERE"

The two disagree today. A `system_hub` would be **invisible to the map's mesh entirely**,
independent of range. Fold the refresher's roster onto the same feature check so the map and
the planner agree on what a mesh node is.

`features` is stored as `[String].JSONRepresentation`, so JSON containment in a
StructuredQueries predicate may be awkward; fetching candidate devices and filtering in Swift
is an acceptable implementation if so — the relay roster is small.

The existing lack of a *status* filter is deliberate and stays: a deactivated relay returns
no connections, so it drops out of the resolved edge set naturally.

## Storage consequence

Filtering at consumption means the closure is **never persisted**. On today's data the table
goes from 55 rows to 22, and growth becomes roughly linear rather than quadratic — average
degree stays near-constant (~4) as the network spreads spatially, so 100 relays would store
on the order of 200 rows rather than 4,950.

This requires **no schema migration**. `FTLLinkRecord` keeps its exact shape and simply holds
fewer, truer rows. `distance_ly` is deliberately not persisted: the renderer can derive
segment length from star positions it already has, since one world unit is one light-year
(`Star.swift:8`).

## What is not changing

- `FTLLinkRecord`, its schema, and `replace(with:into:now:)` — unchanged.
- `FTLMesh.build` (`FTLMesh.swift:29`) — still resolves stored links against terrain.
- The mesh's relevance-field contribution and its rendering pipeline.
- The refresher's triggers, debounce, and best-effort-per-relay behaviour.

## Accepted trade

The table stops answering "are these two systems in one network?" in a single lookup;
that now needs a traversal. Nothing does this today — the star map (`NewStarMapView.swift:86`)
is the only reader, and the directive engine derives mesh membership from device rows on
purpose. If a consumer needs it later, union-find over ~n edges is trivial.

## Behaviour on nil fields

Both `range_ly` and `distance_ly` are optional in the generated types. If either is missing,
**keep the edge** — fail open. A slightly noisy map is better than a missing link, and the
parity repair cannot misfire as a result.

## Testing

The resolver is pure and table-driven:

- Uniform range: a clique of closure edges reduces to only those within range.
- Heterogeneous range: a 12.5 ly hub keeps a 10 ly edge that its 7.5 ly peer does not report
  as direct (union semantics).
- Parity repair: a filtered set that fragments a component is repaired to one component, and
  the repair chooses the shortest available closure edge.
- Parity no-op: when the direct set already matches, no edges are added.
- Nil `range_ly` / nil `distance_ly`: edge kept.
- Empty views, single relay with no connections: no edges, no crash.

A regression fixture built from the real 11-relay data asserts 55 closure pairs reduce to the
22 in-range edges and that all 11 systems remain in one component.

## Expected result

ALPHERATOZ drops from 10 drawn lines to 1 — its only in-range peer is ATIANFU at 6.46 ly —
rendering as a spur off the network, which is the truth.
