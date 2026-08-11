# Spec: Multiple Theatres

Status: needs-triage
Date: 2026-08-11

## Problem

The brain has exactly one logistics centre, and it is derived rather than declared:
`WorldView.hubLocation` (`app/Modules/DirectiveEngine/Sources/WorldView.swift:275`) returns
the richest stocked print-capable device's location whose system is meshed. Every inward
operation in the engine resolves against that single value — haul delivery, restock, prune's
root, mine-site ranking, each mission's `originDesignation`.

One centre does not scale with distance. Haul round-trips grow without bound, every belt in
the galaxy is ranked from one point, and survey roams from one origin. The operator wants
several centres: places to explore outward from and accrete resources inward to, so that a
second area of the galaxy can print its own mine fleets rather than ferrying to the first.

A second, sharper failure already exists in the code and is reachable today. The account's
primary replicant now stands in `OMEROPE`, in a 12-star pocket ~316 ly from `AINALRAM` whose
nearest external neighbour is 178 ly away. Relay range is 7.5 ly. That pocket can never join
the home mesh, so it is a genuinely disconnected second component. Two call sites break the
moment a relay is planted there:

- `HaulTargetPlanner.swift:78` admits a pile when its system and the delivery system are both
  in `meshSystems` — a flat `Set<String>` carrying no connectivity. It would assign a ferry
  across 316 ly.
- `PrunePredicate.swift:103` roots the reclaim path-union at the single hub's system. Pocket
  relays lie on no `AINALRAM`→target path, so every one reads **reclaimable** — the exact
  "reclaim the entire mesh" failure the comment at `PrunePredicate.swift:100` says this
  capability must not have, now reachable because the anchor is in another component.

## Decisions taken

1. **Recognition is three-tier, first match wins**: an operator pin, then an owned `system_hub`
   device, then today's derivation. The System Hub device is *evidence*, never a requirement —
   it costs 6,800 units and 16 h and rises with count, and `AINALRAM` has none, so a hard
   dependency would de-recognise the only working theatre on day one.
2. **Territory**: inward operations (haul, restock, prune, resupply) filter to the theatre's own
   mesh component and then take the nearest theatre within it. Outward operations (survey, mesh
   growth, mine-site ranking) take the nearest theatre by straight-line distance, with no
   component filter — they target unmeshed systems by definition and have no component to
   belong to. Same-component is a filter, not a partition; distance is what decides.
3. **The brain proposes, the operator establishes.** The brain ranks candidate systems and shows
   its reasoning; creating a theatre is an operator action. This follows two existing precedents:
   `SurveyTargetSuggestions` offers ranked systems without acting, and `mineFleetPrint` is an
   operator-invoked printer against a computed shortfall.
4. **The word is Theatre.** British spelling matches the repo (`roamCentre`, `Civilisations`).
   It does not collide with `roamCentre`, which is a *point* one Survey Run expands from — a
   Theatre is the region, and its depot supplies the `roamCentre`. It does not collide with the
   game's System Hub device.

## Domain model

```swift
public struct Theatre: Equatable, Sendable, Identifiable {
    /// The depot location IS the identity. A theatre that moves is a different
    /// theatre, and a stateless brain must name the same one every tick from
    /// world state alone — the same reason `hubLocation` returns a designation.
    public var id: String { depot }
    /// Where stock and printing actually live, e.g. `AINALRAM-BELT-1`.
    public let depot: String
    /// `SiteAssay.system(of: depot)`.
    public let system: String
    public let origin: Origin
    public let readiness: Readiness
    /// Total units at the depot, as `LocationFootprint` reports them.
    public let stock: Int

    public enum Origin: Equatable, Sendable {
        case pinned
        case systemHub(String)   // the claiming device's code
        case derived
    }

    public enum Readiness: Equatable, Sendable {
        /// Depot has print capability and non-zero stock. Missions may use it.
        case operational
        /// Recognised but has no usable depot yet. Visible in the UI with what
        /// is missing; no mission will resolve against it.
        case claimed(missing: Set<Shortfall>)
    }

    /// What a `.claimed` theatre still lacks. Exactly the three clauses of the
    /// existing `hubLocation` predicate, reported individually instead of
    /// collapsing to nil — which is the whole point of the state.
    public enum Shortfall: Equatable, Sendable, CaseIterable {
        case noPrintCapableDevice
        case noStock
        case offMesh
    }
}
```

`claimed` is not a nicety — it is the state `OMEROPE` occupies right now. The system holds a
replicant, a `heaven_vessel` and a `system_ward`, and no autofactory and no stock. Modelling it
means the app can show the operator exactly what standing up a theatre still needs, which is the
workflow they are in the middle of.

For a `.systemHub`-originated theatre the depot is **not** the hub's own location: a System Hub
sits at a planetary L4/L5 while stock sits at a belt. The depot is the richest stocked
print-capable location in the claimed system, and its absence is what makes the theatre
`.claimed` rather than `.operational`.

## Recognition — `TheatreRegistry`

A pure function of device rows, pins and mesh components, evaluated once per tick alongside the
rest of `WorldView.read(from:now:)`:

1. Every pin becomes a theatre, `origin: .pinned`.
2. Every owned `system_hub` device whose system holds no pin becomes a theatre,
   `origin: .systemHub(code)`.
3. For each mesh component holding no `.operational` theatre after steps 1–2, apply the existing
   `WorldView.hubLocation` rule *within that component* — richest stocked print-capable
   location, designation as tie-break — and emit `origin: .derived`.

   `.operational`, not merely "any theatre", is load-bearing: a pin or a hub claim that has no
   usable depot yet must not suppress derivation, or pinning an empty system would blind the
   brain to a working depot elsewhere in the same component. A component may therefore hold both
   a `.claimed` pin and a `.derived` operational theatre at once, and that is the correct reading
   of a claim that has not been stood up yet.

Step 3 is what keeps `AINALRAM` working with no migration and no operator action: today's
single derived hub is re-derived as the home component's theatre, unchanged.

Ordering and tie-breaks are total, so a stateless brain names the same theatres every tick.
This preserves the existing invariant documented at `WorldView.swift:271-274` and its reason.

## Mesh components

`MeshGraph` gains component labelling — a BFS over the same edge rule it already uses
(`MeshGraph.init(hopRange:)`, `SalvageTargetPlanner.relayRangeLY = 7.5`). Membership continues
to come from device rows via `SalvageTargetPlanner.meshSystems(in:)`, never from the `ftlLinks`
table, per the rule at `MissionStepMachine.swift:136`.

That rule is worth restating because the live data confirms it: `ftlLinks` holds 20,910 rows with
distances up to 59.55 ly, every one stamped `rangeA = rangeB = 7.5`. Whatever that table records,
it is not "pairs within range", and component labelling must not read it.

**Per-endpoint range.** A System Hub's built-in relay reaches 15 ly against a plain relay's 7.5.
No hub exists on the account yet, so whether a link forms at `min` or `max` of the two endpoints'
ranges is unverified. **Assume `min` until a hub is standing and it can be measured.**
Over-estimating connectivity is the dangerous direction — it is precisely what produces a 316 ly
ferry — while under-estimating only means a theatre services fewer systems than it could. Record
the measurement as a memory note when the first hub lands.

Component identifiers are per-tick and derived; nothing persists them. Directives store a depot
designation, so a component relabelling between ticks cannot churn directive rows.

## Resolvers

```swift
extension WorldView {
    /// Inward. The theatre that can actually service `system`: same mesh
    /// component, then nearest. nil when nothing reaches it.
    public func theatre(servicing system: String) -> Theatre?

    /// Outward. The nearest theatre by straight-line distance, meshed or not.
    public func theatre(nearest system: String) -> Theatre?
}
```

One implementation with a predicate, not two ranking paths — they differ only by the component
filter, and keeping them one function is what stops them drifting apart. Both rank by
`(distance, depot designation)` so the order is total and stable across ticks. Both consider
only `.operational` theatres.

## Call-site migration

| Site | Today | Becomes |
| --- | --- | --- |
| `HaulTargetPlanner.swift:78` | both ends in `meshSystems` | both ends in the delivering theatre's component |
| `PrunePredicate.swift:103,123` | one union rooted at the single hub | one union per theatre over its own component; a relay is reclaimable only if useless in its own theatre's union |
| `WorldView.swift:275` | single richest print location globally | tier 3 of recognition, applied per component |
| `Brain.ensureOne` | one `salvageRun`/`haulRun`/`relayRun` globally, scoped by kind | one per theatre, scoped by (kind, theatre) |
| `MineSitePlanner.swift:42` | ranks belts from the one hub | ranks from `theatre(nearest:)`; a belt competes in that theatre only |
| `RelayRun.swift:904,925` | return leg flies to the one hub | flies to its own directive's theatre depot |
| `SalvageRun.swift:216` | `hubSystem` from the one hub | its directive's theatre's system |
| `RestockRun` | one, hub-owned | one per theatre |
| `MineRun.swift:287` | hub | its directive's theatre |
| `HaulRun.swift:119,145` | `RelayRun.hubLocation` ?? delivery | its directive's theatre depot |
| `Brain.swift:358,387,430` | `originDesignation` off `hubLocation` | off the directive's theatre |
| `Brain.swift:1333` | why-view focus = `hubLocation` | focus = the row's theatre |
| `BrainWhyView.swift:610` | one hub line | one group per theatre |

`RelayRun.hubLocation(in:)` (`RelayRun.swift:925`) exists so that the mission and the brain share
one rule; the test at `RelayReturnAndRestockTests.swift:266` pins that they agree and warns that a
disagreement flies a carrier to the wrong place. That test generalises to "every theatre resolver
agrees per directive" and must not be dropped.

## Schema — append-only, per the migration rule in `app/CLAUDE.md`

- New table `theatrePins(location TEXT PRIMARY KEY NOT NULL, createdAt TEXT NOT NULL)`.
- `ALTER TABLE directives ADD COLUMN theatreDepot TEXT` — which theatre the row serves. Null on
  legacy rows; the first tick after migration stamps them with the single existing theatre, which
  is correct because there is exactly one today.
- `ALTER TABLE stars ADD COLUMN region TEXT`.
- `ALTER TABLE stars ADD COLUMN hasHub INTEGER NOT NULL DEFAULT 0`.

Each is a new `SchemaMigration` appended to `GameDatabase.manifest` — never an edit to a shipped
one. `SchemaManifestTests` freezes the identifier list and `GoldenSchemaTests` snapshots the
result; regenerate the latter with `RC_REGENERATE_SCHEMA_FIXTURE=1`.

**Ingestion gaps this closes.** The stars payload carries `region` and `has_hub` and the app drops
both — the local `stars` table has no column for either, so the app cannot currently see a hub or
a region even once one exists. Travel's `hub_bonus` is a response field on a preview rather than a
persisted row, so it is a display change on the travel preview sheet, not a migration.

## The proposal ranking — `TheatreSiteRanking`

A read-only ranking pass, no new acting capability. Candidate systems scored on:

- uncollected and in-ground value within a radius that no existing `.operational` theatre services
- whether the system is surveyed (unsurveyed value is unknown, not zero)
- whether a replicant is present or reachable — command authority is the hard prerequisite
- distance to the nearest existing theatre, where farther is better up to a point: a theatre 10 ly
  from another is redundant

Surfaced in the why-view and in Logistics ▸ Theatres as ranked candidates with reasoning, the same
shape as `SurveyTargetSuggestions`. Establishing does exactly two things: writes a pin, and
optionally queues the `system_hub` print. Everything downstream is recognition.

## UI

- **Logistics ▸ Theatres.** `LogisticsFeature` is today only the haul-yield ledger, so this is
  growth rather than conflict. Per theatre: depot, origin badge (pinned / hub-claimed / derived),
  readiness with its shortfall, component size, stock by type, the directives it owns, and its
  slice of the existing yield ledger.
- **Directives.** Every row gains its theatre — `DirectiveRow.swift`, and the coverage line in
  `DirectiveTargetsSection.swift:83`. The list groups or filters by theatre.
- **Brain why-view.** `BrainWhyView.swift:610` prints one hub line today; it becomes one group per
  theatre, each carrying that theatre's five goal lines.
- **Locations / Stars.** An "Establish theatre here" action, and the ranked-candidate list.
- **Star map.** Once `hasHub` and `region` ingest, hub-claimed systems and region membership are
  drawable; the map already decorates per star.

Every designation rendered in monospace, per the naming rule in `app/CLAUDE.md`.

## Testing

- `MeshGraph` component labelling: two disjoint sets stay disjoint; a relay that bridges them
  merges them in one tick.
- `HaulTargetPlanner`: a pile in another component is never assigned. Pin this with the real
  `OMEROPE`/`AINALRAM` numbers — it is the 316 ly regression.
- `PrunePredicate`: with two theatres, neither theatre's relays are reclaimable on account of the
  other's unreachability. Extends the existing whole-mesh-reclaim test to a second component.
- Recognition ordering: pin beats hub beats derived; a component with no theatre gets a derived
  one; ties resolve identically across ticks.
- Readiness: a claimed-but-depotless theatre is never returned by either resolver.
- Migration: legacy directives with null `theatreDepot` adopt the single existing theatre.
- `Brain.ensureOne`: one row per (kind, theatre). The duplicate-commit guard that runs inside the
  write transaction (see `brain-salvage-build`) must stay correct when the candidate set is
  theatre-scoped.

Read results from the Swift Testing JSON event stream via the `swift-test-event-stream` skill,
never by parsing console text.

## Out of scope

- Establishing `OMEROPE`. That is a 6,800-unit print, a 316 ly flight and an autofactory to
  follow — operator work, by decision 3.
- Autonomous theatre creation (`growFleet`). Decision 3 defers it.
- Cross-theatre resupply. The component filter makes it impossible by construction, and the
  premise of the feature is that each theatre prints locally.
- The `ftlLinks` 59 ly anomaly. Noted above, unrelated to this work.

## Known residuals

- Retry amplification (recorded in `brain-salvage-build`: a brain retry re-arms the mission's own
  re-entry budget) is untouched and gets multiplied by theatre count.
- The 15 ly System Hub range is from the docs and unmeasured; see the `min` assumption above.
