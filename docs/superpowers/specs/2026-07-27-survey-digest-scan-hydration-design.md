# Survey-digest scan hydration

**Date:** 2026-07-27
**Status:** approved, ready to implement

Fold the `report.scans[]` block that API v2.3.3 added to `ami.survey.digest`
events into the local locations catalog, so a Survey Run hydrates the physical
data for every planet and moon it scans — instead of leaving each body a stub
until someone drills into it and pays a `GET locations/{designation}` per body.

## Why this matters

An AMI-adopted survey drone emits **zero** per-device events; every movement and
scan it performs is rolled into its controller's `ami.*.digest` (see the
`ami-drones-are-event-silent` memory note). Before v2.3.3 the digest reported
only *counts*, so a survey that scanned nine bodies produced no usable location
data at all. `report.scans[]` is the first time that intel reaches the client.

The orrery renders off a `@Fetch` over `SystemDetail`. Writing scans into that
blob makes it re-render live as digests land mid-survey, with **no star-map
changes whatsoever**.

## The payload

Verified against the live app database on 2026-07-27: 493 `ami.survey.digest`
rows, of which 32 carry the new `scans` key and 11 carry a non-empty array.
`report.scans[]` is the only place `scans` appears anywhere in the event log.
`belt_search` digests carry the key but have been empty in every observed sample.

Each entry is `{device_code, scan_target, scan_type, report}` in two shapes.

### `scan_type: "planet"`

```json
{
  "device_code": "A1D08194",
  "scan_target": "UDKUDUA-7",
  "scan_type": "planet",
  "report": {
    "planet": {
      "designation": "UDKUDUA-7", "name": null, "type": "Super Earth",
      "atmosphere": "none", "axial_tilt_deg": 45.2, "density_gcc": 5.24,
      "in_habitable_zone": false, "life_stage": "none", "magnetic_field": true,
      "mass_earth": 8.4084, "orbital_distance_au": 1.525,
      "orbital_period_days": 1025.39, "radius_earth": 2.0678, "rings": false,
      "rotation_period_hours": 75, "species_name": null,
      "surface_gravity": 1.97, "surface_temp_c": -140, "surface_temp_k": 133,
      "tags": ["high_gravity", "potential_habitable", "rocky"]
    },
    "moons": [
      {"designation": "UDKUDUA-7-1", "name": null, "scanned": false, "type": "Icy"},
      {"designation": "UDKUDUA-7-2", "name": null, "scanned": false, "type": "Rocky"}
    ]
  }
}
```

### `scan_type: "moon"`

```json
{
  "device_code": "A1D08194",
  "scan_target": "UDKUDUA-3-2",
  "scan_type": "moon",
  "report": {
    "moon": {
      "designation": "UDKUDUA-3-2", "name": null, "type": "Rocky",
      "density_gcc": 1.08, "has_atmosphere": false,
      "has_subsurface_ocean": false, "life_stage": "none",
      "mass_earth": 0.008208, "orbital_distance_km": 528629.7,
      "orbital_period_hours": 765.94, "radius_earth": 0.3468,
      "species_name": null, "surface_gravity": 0.0682,
      "surface_temp_c": 65, "surface_temp_k": 338,
      "tags": ["cratered", "rocky"], "tidally_locked": false,
      "salvage": [ { "designation": "…-SAL-1", "location": "…",
                     "name": "Derelict Survey Probe", "depleted": false,
                     "salvage_type": "derelict_probe",
                     "resources_remaining": {"conductive": 214, …} } ]
    }
  }
}
```

Three facts drive the design:

1. The moon fields (`has_atmosphere`, `has_subsurface_ocean`,
   `orbital_distance_km`, `orbital_period_hours`, `tidally_locked`) are exactly
   what the orrery's physical-fidelity work consumes.
2. Salvage `resources_remaining` is **absolute units** — the only source of a
   site's totals, which the catalog otherwise never learns.
3. The digest nests `moons` as a **sibling** of `planet`; the existing
   `scan.completed` result nests it **inside** the planet block. So
   `RawScanEventResult` cannot be reused verbatim.

Structurally absent from every digest scan: the body's `devices`,
`resource_sites`, and `inventory`. This is the constraint the merge design turns
on.

## Architecture

### 1 · Wire DTOs — `UniverseModels/Sources/LocationDTOs.swift` (internal)

```swift
struct RawSurveyScan: Decodable {
    var deviceCode: String?
    var scanTarget: String?
    var scanType: String?
    var report: RawSurveyScanReport?
}

struct RawSurveyScanReport: Decodable {
    var planet: RawScannedBody?
    var moon: RawScannedBody?
    var moons: [RawMoon]?      // sibling of `planet`, unlike scan.completed
}
```

`RawScannedBody` is reused unchanged — it already decodes a physical block from
the same object plus a nested `salvage` array, and the absent
`sites`/`devices`/`inventory` simply decode to nil. `RawBodyPhysical` gains one
field: `speciesName`.

### 2 · `BodyObservation` — a partial observation, not a `BodyDetail`

The load-bearing decision. Modelling a digest scan as `BodyDetail` and folding it
in with `StarSystem.applying(_:)` would **erase** the body's `sites`, `devices`,
and `inventory` on every scan: `upsertPlanet` preserves only salvage, lagrange,
and moons, taking everything else from the incoming value — which for a digest is
empty. A distinct type makes that asymmetry unrepresentable rather than a comment
someone has to remember.

```swift
public struct BodyObservation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case planet, moon }
    public var kind: Kind
    public var designation: String
    public var name: String?
    public var type: String?
    public var lifeStage: String?
    public var inHabitableZone: Bool?
    public var orbitalDistanceAu: Double?
    public var physical: BodyPhysical
    public var salvage: [SalvageSite]
    public var moons: [Moon]        // roster stubs, planet scans only
}
```

New merge entry point:

```swift
extension StarSystem {
    public func observing(_ observation: BodyObservation) -> StarSystem
}
```

**Planet semantics.** Locate the planet by designation, appending a fresh one if
the roster doesn't know it. Overwrite `type`, `typeEstimated = false`,
`lifeStage`, `inHabitableZone`, `orbitalDistanceAu`, `physical`, and
`recon = .scanned`. Merge the moon roster through the existing
`mergingMoons(fresh:into:)` so a previously scanned moon is not downgraded to a
stub. Set `moonCount` from the merged roster and `moonCountEstimated = false`.
Leave `sites`, `devices`, `inventory`, `salvage`, `lagrange`, and `events`
untouched.

**Moon semantics.** Seed the parent planet when absent, by the same rule
`seedingParent(of:)` uses (designation minus the trailing `-N`). Locate or append
the moon; overwrite `type`, `lifeStage`, `physical`, `recon = .scanned`. Upsert
salvage preserving each existing site's `remainingPct` — the digest carries no
percentages, and clobbering them would destroy the only live figures we hold.
`depleted` is taken *from* the scan rather than preserved: a scan is a fresh
observation of the site's state, so it is the one path that can clear a stale
local flag as well as set one (`salvage.depleted`'s payload key is still
unconfirmed, so a wrong local flag is a real possibility). Leave `sites`,
`devices`, and `inventory` untouched.

Only fields the payload actually carries are written: a nil `type` or
`lifeStage` in the observation leaves the cached value in place.

### 3 · Decode facade — `LocationDecoding`

```swift
public struct SurveyScanReport: Equatable, Sendable {
    public var deviceCode: String?
    public var body: BodyObservation
    public var salvage: [SalvageObservation]
}

extension LocationDecoding {
    public static func surveyScans(from body: some Encodable) throws -> [SurveyScanReport]
}
```

One decode yields both halves, unlike the `scan.completed` path which decodes
twice (`scanResultBody` then `salvageObservations(fromScanResult:)`). That split
exists to keep absolute unit counts off `SalvageSite`, which carries
percentages — `SalvageObservation` is already a separate type, so pairing the two
on the report preserves the rule while sparing a second pass.

Unknown `scan_type` values yield no report and are logged by the caller.

### 4 · Client — `GameServices/Sources/LocationsClient.swift`

```swift
@discardableResult
public func ingestSurveyScans(payload: [String: JSONValue]) async throws -> Int
```

Mirrors `ingestScanResult`. Groups reports by system (the designation prefix, as
`ingestScanResult` already does), then one transaction per system:

- read the cached `SystemDetail`, or seed `StarSystem(designation:recon: .visited)`
- capture `knownPct` from `knownSalvageSites` **before** merging
- apply each observation in turn via `observing(_:)`
- restore salvage percentages, then upsert the blob
- for each `SalvageObservation`, upsert a `SiteAssay` using the same
  `impliedTotal(remaining:percentRemaining:)` inference and `raising` merge

Returns the number of bodies persisted. Best-effort and idempotent throughout.

### 5 · Route — `GameServices/Sources/LocationsIngestion.swift`

One new case in `catalogRoute()`, the declared dispatch table for
payload-scraped catalog updates:

```swift
case "ami.survey.digest":
    _ = try? await locationsClient.ingestSurveyScans(payload: payload)
```

Digests arrive ~40/hour, so an absent or empty `scans` array must return before
any database access. Unknown `scan_type`s log at `.notice` — the level unhandled
events use — so a future belt or star scan surfaces in the log rather than
vanishing.

### 6 · New domain fields

- `BodyPhysical.speciesName: String?` — present on both planet and moon blocks,
  null in every observed sample, and absent from the codebase entirely today.
- `Moon.lifeStage: String?` — `Planet` has it, `Moon` does not, so a moon's life
  stage is currently dropped even on the existing `GET locations/{moon}` path.
  This fixes that too.

Both are Optional, so synthesized `Decodable` uses `decodeIfPresent` and existing
`SystemDetail` blobs still decode. No hand-written decoder is needed, unlike
`Belt` and `SalvageSite` which added non-optional collections.

## Behaviour deliberately unchanged

**Drill-in still fetches.** `hydrateBody` keeps firing on body drill-in and
location select. A digest scan carries no `devices`, `sites`, or `inventory`, so
skipping the fetch would hide another player's ship parked at the body. The win
is that the orrery renders correct physics *immediately* on drill-in rather than
after a round trip, and the fetch then tops up live occupancy.

## Out of scope

- `report.progress`, `busy`, `idle`, `assigned_this_tick`, `cruising` — survey
  queue telemetry, not location data. Scan counts stay owned by `hydrateSystem`.
- The `belt_search` report block (`belt`, `active_sites`, `max_sites`,
  `total_resources_available`) — its `scans` array is empty in every observed
  sample. Handled by the unknown-`scan_type` log path if that changes.
- Any star-map change. The `@Fetch` over `SystemDetail` already covers it.

## Testing

**`UniverseModelsTests`** — fixtures captured verbatim from the live database:
the `UDKUDUA-7` planet with its two-moon roster, the `UDKUDUA-7-1` moon, and the
`UDKUDUA-4-1` moon carrying salvage.

- every field of both shapes lands on `BodyPhysical` / `BodyObservation`
- `observing` does **not** clear a body's existing `sites`, `devices`, or
  `inventory`
- a planet observation does not downgrade an already-scanned moon to a stub
- a moon observation seeds its parent planet when the roster lacks it
- salvage upsert preserves existing `remainingPct` and `depleted`
- a `SystemDetail` blob encoded before `speciesName`/`lifeStage` still decodes
- an unknown `scan_type` and a malformed report are dropped, not thrown

**`GameServicesTests`** — `ingestSurveyScans` writes `SystemDetail` and
`SiteAssay`, seeds an unknown system, groups a multi-system digest correctly, is
idempotent across a replayed event, and no-ops on an absent or empty `scans`
array without touching the database.
