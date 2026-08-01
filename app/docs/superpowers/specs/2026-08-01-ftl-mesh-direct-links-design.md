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

## Storage model: keep the closure, filter on read

The closure is **persisted in full**, with the metrics needed to classify each row. Filtering
to direct links happens in the read path, not at ingest.

The reason is not the subgraph lookup (with direct-links-only, a second component is visible
on the map and a union-find away in code). It is **revisability**. We do not know whether a
12.5 ly hub links to a 7.5 ly relay 10 ly away — that depends on whether reach is symmetric,
and it cannot be tested until a hub exists. If the closure were discarded at ingest and the
rule were wrong, correcting it would require a full mesh rebuild: `FTLMeshRefresher`
documents this as "the single most expensive refresh an event can trigger" (O(relays) serial
network reads), and it only fires on roster changes or relay liveness flips — so a wrong
guess could sit stale indefinitely. With the closure retained, the rule is a read-side
predicate and correcting it is immediate.

Two consequences make this strictly better than filtering at ingest:

- **The parity repair (§3) becomes exact.** It no longer has to reconstruct which systems the
  server considers connected — the closure *is* that answer.
- **The table stops being a trap.** The `ftl-authority-rule` memory warns "do not mistake
  those rows for physical links," a warning that exists because these rows already misled a
  design session. A row carrying `18.06 ly` beside a `7.5 ly` range is self-evidently not a
  link.

**Cost is negligible.** 100 relays is 4,950 rows (~300 KB); 500 relays is 124,750 rows. Revisit
this decision if the relay count ever approaches 500 — below that, the quadratic row count is
not worth engineering against.

## Design

### 1. Ingest keeps the metrics

`DevicesClient.relayLinks` (`GameServices/Sources/DevicesClient.swift:173`) currently does I/O
and edge resolution in one closure, which is untestable without the network. Split them.

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

And a pure resolver producing persistable rows:

```swift
extension FTLLinkRecord {
    public static func rows(from views: [RelayNetworkView], now: Date) -> [FTLLinkRecord]
}
```

`relayLinks` then does only I/O: walk the roster, map each response into a `RelayNetworkView`.
This matches how `OrreryLayout` and `MissionStepMachine` are factored — a pure resolver with
the I/O at the edge.

**Both endpoint ranges must be merged across views.** When relay A's view reports peer B, that
view knows A's range but not B's. So `rows(from:)` first builds a `star -> rangeLy` map across
*all* views, then stamps each canonical edge with `rangeA`/`rangeB` by lookup. A relay whose
view failed to read contributes no range, leaving nil (see fail-open, below).

### 2. Schema: three columns, append-only

`FTLLinkRecord` gains three nullable columns:

| column | meaning |
| --- | --- |
| `distanceLy` | the server's `distance_ly` for this pair |
| `rangeA` | range of the relay at endpoint `a` |
| `rangeB` | range of the relay at endpoint `b` |

Per the append-only rule this is a **new** `SchemaMigration` appended to
`GameDatabase.manifest` — three `ALTER TABLE ... ADD COLUMN` statements, never an edit to
`createFTLLinks`. `SchemaManifestTests` gains the new identifier and `GoldenSchemaTests` is
regenerated with `RC_REGENERATE_SCHEMA_FIXTURE=1`.

The migration also **clears the table**. Existing rows have no metrics, and under fail-open
they would all classify as direct — reproducing today's hairball until the next rebuild. The
mesh is a wholesale-rebuilt cache, so dropping it is safe; the map shows no mesh until the
next refresh fires.

Note `FTLLinkRecord.replace` inserts row-by-row in a loop (`FTLLink.swift:84`). That is fine
at today's scale inside one transaction, but should be batched if row counts grow.

### 3. The read path: one query, one reduction

The filter and the parity repair live together in a single `FetchKeyRequest`, so they run once
per database change on the database queue — not per SwiftUI body evaluation:

```swift
public struct DirectFTLLinks: FetchKeyRequest {
    public struct Value: Equatable, Sendable {
        public var links: [FTLLink] = []
    }

    public func fetch(_ db: Database) throws -> Value {
        Value(links: Self.reduce(rows: try FTLLinkRecord.all.fetchAll(db)))
    }

    /// Pure: closure rows in, direct links out (with parity repair).
    static func reduce(rows: [FTLLinkRecord]) -> [FTLLink]
}
```

This follows `BobnetChannelList` (`BobnetQueries.swift:46`) exactly — fetch the rows, delegate
to a pure `static` reduction, return an `Equatable, Sendable` `Value`. The reduction is
therefore unit-testable with no database.

`reduce` works in three steps:

1. **Direct set** — rows where `distanceLy <= max(rangeA, rangeB)`.
2. **Closure components** — union-find over *all* rows. This is the server's answer, free.
3. **Parity repair** — union-find seeded with the direct set, then walk the remaining rows in
   ascending `distanceLy`, adding any that join two distinct components, until component count
   matches step 2.

`NewStarMapView.swift:137` then feeds `StarMapOverlays.ftlLinks` from this instead of
`ftlLinkRecords.map(\.link)`. `FTLLink` stays a plain endpoint pair and the renderer is
untouched.

The reduction is expressed in Swift rather than pure SQL because step 3 needs the closure
regardless. If direct links are ever wanted *without* the repair, the SQL form is:

```sql
WHERE distanceLy IS NULL OR rangeA IS NULL OR rangeB IS NULL
   OR distanceLy <= max(rangeA, rangeB)
```

The null clauses are load-bearing, not defensive: SQLite's two-argument `max` returns NULL if
either argument is NULL, so the bare comparison evaluates to NULL and silently *drops* rows
that the fail-open rule requires be kept.

Aside, out of scope: the query currently sits as `@FetchAll` in the view
(`NewStarMapView.swift:86`) rather than in `@ObservableState`, which deviates from the
house standard. Not this change's job.

### 4. Union semantics for heterogeneous ranges

`max(rangeA, rangeB)` means a link is drawn when **either** endpoint can reach that far: a
12.5 ly hub links to a 7.5 ly relay 10 ly away. This is the safe direction — a union can never
split a component the server considers whole — and because it is one word in one predicate,
switching to `min` is trivial if hub behaviour proves otherwise.

### 5. Component-parity repair

Filtering could in principle disconnect what the server considers one network (a relay whose
view failed to read and left nil ranges on both sides of a long edge, an unexpected asymmetry,
a borderline float). The map would then lie in the opposite direction, showing two networks
where there is one. The repair in §3 enforces the invariant:

> **Drawn components always equal server components.**

This makes the union-vs-intersection guess in §4 non-load-bearing for correctness: a wrong
guess costs a slightly wrong *set of lines*, never a fractured network.

The repair pool (closure minus direct) always has usable distances: by fail-open, a row with a
nil `distanceLy` or nil ranges classifies as *direct* and never reaches the pool.

### 6. Roster fix: match the relay *feature*, not the device type

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

The existing lack of a *status* filter is deliberate and stays: a deactivated relay returns no
connections, so it drops out of the resolved edge set naturally.

## Behaviour on nil fields

Both `range_ly` and `distance_ly` are optional in the generated types, and a failed relay read
leaves a nil range. If any of `distanceLy`, `rangeA`, `rangeB` is missing, **treat the row as
direct** — fail open. A slightly noisy map beats a missing link, and the parity repair cannot
misfire as a result.

## What is not changing

- `FTLLink` — stays a plain canonical endpoint pair.
- `FTLMesh.build` (`FTLMesh.swift:29`), the relevance-field contribution, and the render
  pipeline.
- The refresher's triggers, debounce, and best-effort-per-relay behaviour.
- `StarMapOverlays`' shape.

## Testing

The ingest resolver and the read reduction are both pure and table-driven.

**`FTLLinkRecord.rows(from:)`**
- Ranges are merged across views: an edge reported only by A still carries B's range from B's
  own view.
- A relay whose view is absent leaves nil ranges rather than dropping the edge.
- Reciprocal reports collapse to one canonical row.

**`DirectFTLLinks` reduction**
- Uniform range: a closure of 55 pairs reduces to the 22 within 7.5 ly, all 11 systems still
  one component (fixture built from the real relay data).
- Heterogeneous range: a 12.5 ly hub keeps a 10 ly edge its 7.5 ly peer does not.
- Parity repair: a direct set that fragments a component is repaired to one component, and it
  chooses the shortest available closure edge.
- Parity no-op: when the direct set already matches, no edges are added.
- Two genuine components stay two — the repair does not over-merge.
- Nil `distanceLy` / nil ranges: row kept as direct.
- Empty table and a single relay with no connections: no edges, no crash.

**Schema**
- `SchemaManifestTests` identifier list updated; `GoldenSchemaTests` fixture regenerated.
- Migration clears pre-existing rows.

## Expected result

ALPHERATOZ drops from 10 drawn lines to 1 — its only in-range peer is ATIANFU at 6.46 ly —
rendering as a spur off the network, which is the truth.
