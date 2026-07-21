# In-system device, travel & site visualization — execution plan

Status: **complete** — all five phases plus the deferred-polish list landed 2026-07-14 (see
the "Overall" and "Deferred polish — ALL DONE" sections below). Kept as the execution record.
(Header corrected 2026-07-21 — it previously still said "planned (not started)".)

This plan lives in `NewStarMapFeature` — the raw-Metal star map (the wired-in "Stars"
view). It does NOT touch the legacy SceneKit `StarMapFeature`.

## Goals

1. Visualize an **unbounded** number of devices (typically ≤11) at **any** location in a
   system: planet, moon (dozens per planet), asteroid belt, system object/structure, or
   one of the **5 Lagrange points** per planet (`SYSTEM-n-L[1-5]`, e.g. `SOL-5-L4`).
2. Visualize a ship on a **multi-leg, location→location** trip across systems
   (e.g. `AINALRAM-BELT-1 → … → SOL-3-1`, 3 legs), watchable in-orrery on its
   intra-system legs.
3. Visualize **mining sites, salvage sites, and location inventory**.

## Data sources (settled decisions)

- **Own devices — authoritative:** the live `Device` roster. `Device.location`
  (`Device.swift:34`) is a full location code (any kind). Updated by event + polling data.
- **Other players' devices — from the scan blob / per-location detail:** `LocatedDevice`
  (`deviceCode`/`deviceType`/`status`) — no owner field, so ownership is unmarked. The
  per-location GET returns devices at **every** location type (planet/moon/belt/Lagrange),
  so belt/Lagrange rosters are available on-demand; the system-scan blob only carries
  planet/moon device arrays coarsely.
- **Merge** by `deviceCode`, own wins (own roster gives live status + inspector). Cluster
  per location.

## Probe findings (confirmed live, 2026-07 — AINALRAM / SOL / SHERATANON)

- **Lagrange grammar:** `SYSTEM-n-L[1-5]` (e.g. `SOL-5-L4`); detail carries
  `lagrange.parent_planet = SYSTEM-n`, `l_point`, `orbital_distance_au` = the parent
  planet's AU. Lagrange points are frequently the system `entry_point`.
- **Belt grammar:** `SYSTEM-BELT-k`; belt sites `SYSTEM-BELT-k-SITE-N` (`site_index` is
  sparse, e.g. 0/120/121/124); belt detail also has a location-level `inventory` roll-up.
- **Per-location GET `locations/{code}` returns `devices` at ALL location types** — belt
  (`autofactory`/`heaven_vessel`) and Lagrange (`ftl_relay`) both showed stationed
  devices. Devices carry no owner/`replicant_code` → dedup vs. own roster for ownership.
- **System objects:** `SYSTEM-OBJ-n`. Megastructure = `progress_percentage` +
  `requirements{device_type:{current,remaining,complete,required}}`. `incoming_asteroid`
  = `impact_target` (a body designation), `orbital_distance_au`, `impact_eta`,
  `impact_likelihood`, `progress_pct`, `status`. Outer: `SYSTEM-KUIPER` / `SYSTEM-OORT`
  (each with `distance_au`).
- **Presence-gated:** `locations/{code}` requires a replicant in the system (403 otherwise).

## Data shapes confirmed (UniverseModels/Sources/LocationModels.swift)

- `Planet.lagrange: [SpecialSite]` (`kind == .lagrange`, `parentBody`, designation `…-L4`).
  **Lagrange data already exists** — the orrery just doesn't render it.
- `ResourceSite` (mining): `designation` `…-SITE-N`, `remaining: [String: Double]` (% per resource).
- `SalvageSite`: `designation` `…-SAL-N`, `depleted: Bool`, `resourcesAvailable: [String]`, `salvageType`.
- `InventoryItem`: `resourceType`, `quantity`. Hangs off planet/moon/belt/structure.
- `Belt`: no `devices`/`salvage`/`moons`; has `sites`, `inventory`, `density`, `richness`.
- `SpecialSite` (structures/objects/kuiper/oort): `orbitalDistanceAu`, `inventory`,
  `requirements` (megastructure), `progressPercentage`, `deadline`. No `devices` in model.
- `BodyIndicators` already has `.device/.salvage/.miningSite/.inventory/.life` cases.

## Guiding architecture: one layer-aware location resolver

A new pure, unit-testable `OrreryLayout`, built from `(SystemModel, center, scale,
orbitClock, reveal)`, that resolves any location code to a world position for the current
focus level. It replaces the four duplicated orbit/projection sites in
`StarFieldRenderer` (`placedOrreryBodies`, `orreryPips`, `currentOrbiterWorldPosition`,
scaffold math) and becomes the shared truth for placement, pips, device clusters, ship
endpoints, and picking.

```
struct OrreryLayout {
    func planetPosition(_ id: String) -> SIMD3<Float>?
    func moonPosition(_ id: String) -> SIMD3<Float>?        // body level only
    func lagrangePosition(_ id: String) -> SIMD3<Float>?    // SYSTEM-n-L[1-5]
    func beltAnchor(_ id: String) -> SIMD3<Float>?          // deterministic point on the ring
    func structurePosition(_ id: String) -> SIMD3<Float>?   // orbitalDistanceAu @ stable angle
    func position(ofLocation code: String) -> SIMD3<Float>? // top-level, level-aware dispatch
}
```

**Level-awareness is the crux:** at system level a moon collapses onto its parent planet
(devices cluster there); at body level the drilled planet's moons and Lagrange points
resolve individually.

---

## Phase 1 — Location taxonomy, Lagrange geometry & the resolver

Keystone. Ships as a pure refactor + Lagrange scaffold; no UX change → safe to land first.

**STATUS (2026-07-14): keystone landed, builds clean, tested.**
- ✅ Model: `LagrangePoint` on `OrreryPlanet`, `OrreryStructure` list on `SystemModel`
  (`OrreryModels.swift`); populated in `OrreryMapping` (`lPointNumber` parser + `structures`).
- ✅ `OrbitTiming` + pure `OrreryLayout` resolver (`OrreryLayout.swift`): orbiter / Lagrange
  (L1–L5) / belt-anchor / structure / level-aware `position(ofLocation:)`.
- ✅ Renderer routed onto `OrreryLayout` — deleted its duplicated `orbitAngle` /
  `orbitPeriodSeconds` / `minOrbitPeriodDays`; `placedOrreryBodies` / `orreryPips` /
  `currentOrbiterWorldPosition` now call the resolver. Behavior-preserving.
- ✅ Moon-cap fix: force-include every interesting moon past the cap (`bodyModel`).
- ✅ Tests: `OrreryLayoutTests` (5) + Lagrange/structure + moon-cap mapping tests, all pass.
- ⏭️ **Rescoped into Phase 2:** the faint L-point scaffold markers (6) and the
  projection/push consolidation (7). Rationale: the valuable dedup (orbit math) is done;
  visible L-point markers and a shared projector are only *exercised* by Phase 2 picking +
  Phase 3 device pips, so they'll be added and visually verified there rather than as
  un-exercised additions now.
- ⚠️ Pre-existing unrelated failure: `OrreryMappingTests.surfaceTemperatureShapesLavaAndIceCaps`
  (PlanetMaterial polar-ice ramp; untouched by this work).

1. **Model:** carry Lagrange points into `SystemModel`. Add `lagrange: [LagrangePoint]`
   to `OrreryPlanet` (from `Planet.lagrange`); add belt/object/structure anchor metadata to
   `BeltModel` / a new `OrreryStructure`. (`OrreryModels.swift`, `OrreryMapping.swift`)
2. **Lagrange geometry** (`OrreryGeometry.swift`): schematic positions from a planet's
   *live* orbit position + the star — L1/L2/L3 collinear on the star–planet radial (small
   offsets), L4/L5 at ±60° along the orbit. Deterministic, legible, not physically exact.
   Add faint L-point scaffold markers.
3. **Belt anchor:** deterministic angle on the belt ring (hash of designation).
4. **Structure anchor:** reuse the hazard radial (`orbitalDistanceAu` @ `phaseDeg`),
   generalized beyond `incoming_asteroid`.
5. **Moon cap fix** (`OrreryMapping.bodyModel`, currently `maxMoons: 18`): raise/curate,
   and **force-include any moon hosting a device, site, salvage, or travel endpoint**;
   `log` what's dropped instead of silent truncation.
6. **Build `OrreryLayout`** and route the four existing sites onto it (behavior-preserving).
   Extract the **single projection helper** (`worldToView`) that `emitShipProjection` /
   `orreryPips` / `encodeLabels` / `pickStar` each re-implement, and the **single
   `systemPush` recession transform** they mirror the shader with by hand.

**Tests (`OrreryTests`, pure):** Lagrange positions at known angles; belt/structure
anchors; level-aware resolution (moon→parent at system level, discrete at body level);
moon-cap force-include; CPU-vs-GPU projection parity assert (must match
`Shaders.metal overlayPushed`).

**Risk:** projection/push consolidation must provably match the shader.

---

## Phase 2 — Orrery picking

1. `pickLocation(atViewPoint:) -> String?` mirroring `pickStar` against `OrreryLayout`
   anchors (nearest within pixel radius, frontmost wins). Drop the `guard !systemFocused`
   bail for this path.
2. `MetalStarView`: when `systemFocused`, single-click selects a location, double-click on
   a planet drills in (augmenting the HUD-list affordance).
3. Reducer: add `locationSelected(String)` → drives a new **location dossier**.

**Tests:** feature tests for the new actions; pure pick-math tests.

**STATUS (2026-07-14): landed, builds clean, tested.**
- ✅ `StarFieldRenderer.pickLocation` — candidates = sun/central + orbiters + (system level)
  Lagrange/belts/structures via `OrreryLayout`; disc test + pixel-radius fallback, frontmost
  wins. `isDrillablePlanet` gates the double-click drill.
- ✅ Faint Lagrange tick markers (`OrreryGeometry.lagrangeColor`) added in `orreryPips`
  (system level; moons carry none). Structure markers deferred (mostly off-frame / hazards
  already mark objects).
- ✅ Reducer: `selectedLocation` state + `locationSelected` action; mutually exclusive with
  star/ship selection; cleared on any drill/zoom (anchors are level-specific).
- ✅ `MetalStarView.mouseDown`: orrery branch (single-click → select w/ double-click
  deferral; double-click a planet → drill). Galaxy path unchanged.
- ✅ Location dossier card in `SystemHUD` (top-trailing): kind + designation (mono) +
  basic facts + indicators, resolved level-aware from the orrery model. Device rosters /
  sites / inventory land in Phases 3 & 5.
- ✅ Tests: `locationSelectionIsExclusiveAndClearsOnLevelChange` + pick-math covered by
  `OrreryLayoutTests`.
- ⏭️ Note: `planet.lagrange` is populated by per-location hydration (Phase 3 wiring), so
  L-point markers/picking become fully exercisable once that data flows; the resolver,
  picking, dossier, and markers are all in place now.
- ⏭️ Projection consolidation (Phase-1 item 7): pickLocation is self-contained (mirrors
  pickStar); a shared projector is still deferred to Phase 3's overlay work where a 5th
  consumer justifies migrating the existing sites in one verifiable pass.

---

## Phase 3 — Device clusters at rest (headline feature)

**Merge:** own devices (roster, filtered to focused system/body, keyed by
`device.location`, live status) + other devices (scan `LocatedDevice`, stale), dedup by
`deviceCode` (own wins) → `[locationCode: DeviceCluster]` (own count, other count,
representative status).

**Render — generalize the ship overlay, don't add a third path:** promote
`ShipProjectionModel` / `ShipOverlayLayer` from "ships" to **positioned entities**. The
renderer projects each cluster anchor via Phase-1 `worldToView` and pushes
`[ProjectedEntity]`; the SwiftUI layer floats **one cluster badge per location**
(glyph + count). Tap → expand to a small list → own device opens the Devices inspector
(existing `delegate(.openDevice)`), other device shows read-only info.

- **One badge per location** (not per device) keeps on-screen icon count ≈ occupied
  locations → perf bounded even with dozens of devices. Gate projection to focused
  system/body only.

**Verify first (`probe-api`):** does the scan return other-player devices beyond
planet/moon? If so, extend the model here.

**Tests:** cluster-merge (dedup/counts) pure tests; feature tests for tap → open/inspect.

**STATUS (2026-07-14): landed, builds clean, tested.**
- ✅ Domain (`DeviceCluster.swift`): `ClusterDevice` / `DeviceCluster` (anchor + own-first
  devices, count/hasOwn/primaryType) / `ProjectedCluster` / `DeviceClusterProjectionModel`,
  and a pure `DeviceClustering.clusters(own:others:layout:)` merge (dedup by code, own wins,
  group by `OrreryLayout.anchor`).
- ✅ `OrreryLayout.anchor(ofLocation:)` — returns the drawn anchor code + position (moon →
  planet at system level); `position(ofLocation:)` delegates.
- ✅ Renderer: `updateDeviceClusters` + `emitClusterProjection` each frame (system focus
  only, opacity = `orreryReveal`), pushes `[ProjectedCluster]` via `onClustersProjected`.
- ✅ `LocationClusterLayer.swift`: one tappable badge-per-location (glyph + count, accent if
  own), frame-locked; tap → `locationSelected(anchorCode)`.
- ✅ View: `deviceClusters` merges own roster (all location types, live status) + scan-blob
  planet/moon others; wired to `MetalStarView` + `SystemHUD`. Location dossier now lists the
  devices at the selected location (own → "View" into inspector via `viewDeviceRequested`;
  foreign → muted), scrollable past a handful.
- ✅ Tests: `clusteringDedupsOwnOverOthersAndGroupsByAnchor`, `anchorCodeCollapsesToTheDrawnLevel`.
- ⏭️ Own devices anchor at **any** location type (planet/moon/belt/Lagrange/structure) with
  no extra fetch — Lagrange badges resolve from the parent planet, so they light up now.
  Other-players' devices at belt/Lagrange/structure need per-location hydration (deferred);
  scan blob only carries planet/moon others today.
- ⏭️ Occupied-Lagrange marker brightening skipped — the device badge is the occupancy signal.
- ⏭️ Projection still has two paths (ship + cluster emit duplicate the world→screen math);
  unify in Phase 4 when ships are reworked (the justifying moment to migrate both).

---

## Phase 4 — Multi-leg, location→location travel

Highest complexity; isolated. Keep `Ship.position` pure/deterministic for unit testing.

1. **Carry legs to the renderer:** replace `ShipRoute`'s system-only `from`/`to` with the
   full `TravelSnapshot.legs` (location codes + per-leg `timeSeconds` + `type`). Build
   per-leg media-time windows from `departedAt` + cumulative `timeSeconds`.
   (`StarMapOverlays.swift`, `NewStarMapView` ships builder.)
2. **`Ship` → polyline** (`Ship.swift`): `position(at:)` finds the active leg by time and
   interpolates between endpoints **resolved through `OrreryLayout`** at the current focus
   level. Galaxy scale: intra-system cruise legs collapse to the star (ship parks);
   surge/jump legs span stars. System scale: the cruise leg animates between
   belt/planet/jump-point anchors.
3. **Show ships in-orrery:** relax the `overlayDim` gate (`StarFieldRenderer.swift:753`,
   `:91`) so a ship whose *active leg* is in the focused system stays visible & placed;
   galaxy-only legs still fade on drill-in.
4. Ship head/trail unify onto the Phase-3 entity overlay.

**Tests (`TravelSnapshotTests`/`TravelFlowTests`):** per-leg progress at boundary times;
endpoint resolution per level; galaxy-vs-system placement of a mixed cruise+jump itinerary.

**STATUS (2026-07-14): landed, builds clean, tested.**
- ✅ `RouteLeg` on `ShipRoute` (location-level from/to + seconds); view populates from
  `TravelSnapshot.legs`.
- ✅ `Ship` reworked to a multi-leg polyline (`Ship.Leg` carries system-star indices +
  location codes + media window). `position(at:)` interpolates the active leg's system
  endpoints (cruise legs park at a star, jump legs span stars); `ribbonProgress` keeps the
  drawn ribbon's tail tracking the head; `orreryPosition(at:resolve:)` places the ship on
  an intra-system cruise leg inside the orrery (nil if the active leg leaves the system).
- ✅ Renderer `applyOverlays`: builds per-leg media windows anchored backward from arrival
  (the live block lists only remaining legs); `emitShipProjection` now places in-orrery
  ships via the active layer's `OrreryLayout` at `orreryReveal` opacity, falling back to the
  galaxy straight-line placement (fading with `overlayDim`) — so a ship is watchable on its
  intra-system legs and fades with the galaxy otherwise.
- ✅ Tests: `multiLegShipParksThenMovesThenParks`, `orreryPositionResolvesOnlyIntraSystemLegs`,
  `noLegsFallsBackToStraightLine` (+ existing progress/interp).
- ⏭️ In-orrery ships render as the SwiftUI ship icon only (no GPU comet head/trail
  in-orrery); the galaxy keeps the comet head + dashed ribbon. Fine — the icon is the
  tappable representation.
- ⏭️ 3+-distinct-system trips: head placement is correct per-leg, but the drawn galaxy
  ribbon is a straight origin→dest (head projected onto it). A system-node polyline ribbon
  would make 3+-system routes exact; deferred (rare; the common 2-system trip is exact).
- ⏭️ Projection consolidation (Phase-1 item 7) NOT done — `emitShipProjection` /
  `emitClusterProjection` still each carry the world→screen math. Deferred to a cleanup
  pass; both work and are isolated.

---

## Phase 5 — Sites, salvage & inventory

Additive; data already hangs off bodies.

- Belt pips: belts render no indicators today — add `.miningSite`/`.inventory` pips
  (`BeltModel`, `BodyIndicators` cases exist).
- **Location dossier** (from Phase 2): mining sites (per-resource `remaining` %), salvage
  (`depleted`, `resourcesAvailable`), inventory roll-up (`resourceType`/`quantity`).
- Optional: depleted-vs-active salvage pip treatment.

**Tests:** presentation-mapping pure tests.

**STATUS (2026-07-14): landed, builds clean, tested.**
- ✅ Belt indicators: `BeltModel.indicators` (mining/inventory) set in mapping; `orreryPips`
  draws a pip row at the belt's ring anchor so a belt reads its contents like a planet.
- ✅ Location dossier enriched: a `LocationDetail` (mining `ResourceSite` w/ live-resource
  summary, `SalvageSite` w/ depleted/resources, `InventoryItem` roll-up) dug from the
  persisted blob for the selected planet/moon/belt/structure, rendered as scrollable
  sections beneath the device list (capped so a busy location can't overrun the card).
- ✅ Test: `beltIndicatorsFromSitesAndInventory`.

---

## Overall (2026-07-14): all five phases landed, app builds clean, module tests green
(aside from the pre-existing unrelated `surfaceTemperatureShapesLavaAndIceCaps`).

## Deferred polish — ALL DONE (2026-07-14)
- ✅ Projection consolidation: shared `projectViewPoint(world:…)` on the renderer; both
  `emitShipProjection` and `emitClusterProjection` use it (one world→screen map).
- ✅ In-orrery ship comet heads: `encodeOrreryShipHeads` draws a glow head for ships on an
  intra-system leg (placed via `OrreryLayout`), alongside the tracking SwiftUI icon.
- ✅ Multi-system polyline ribbon: `Ship.nodeStars` (distinct system nodes); the renderer
  builds one ribbon segment per hop (`shipSegments`), each drawn with per-segment
  head-projection progress (`segmentProgress`) so the comet tail flows across a 3+-system
  route. `shipDashCyclePixels` generalized to arbitrary endpoints.
- ✅ Occupied-Lagrange brightening: an occupied L-point tick renders in the device tint
  (and slightly larger) under its cluster badge; empty points stay faint scaffold.
- ✅ Other players' devices at belt/Lagrange/structure: `Belt` & `SpecialSite` gained
  `devices: [LocatedDevice]` (back-compat `decodeIfPresent`); the DTO threads `devs` into
  them; `locationSelected` fires a best-effort per-location `hydrateBody` (cancel-in-flight)
  that merges the roster; the cluster builder reads belt/lagrange/structure devices. Tested
  via `beltLevelDecodesSitesRemainingAndInventory` (now asserts a decoded device).

Note: adding stored fields to shared `UniverseModels` structs → cleaned `Modules/.build`
before `swift test` (SPM stale-layout). Xcode `BuildProject` unaffected.

---

## Cross-cutting

- **Design system:** new colors/spacing via `DesignSystem.swift` tokens (add, don't inline, 
  and reuse whenever semantically aligned).
  Orrery pip tints live in `OrreryGeometry` as the Metal-side source — extend there.
  System/location names render in a mono token per project rule.
- **Sequencing:** 1 is the keystone (2–5 consume the resolver); 2 before 3 (clusters need
  picking); 4 is riskiest/isolated; 5 additive. Each phase ships independently and leaves
  the map fully working.

## Before Phase 1 code

- `probe-api` GET on a live scanned system: confirm real `location`-code strings for
  belts/Lagrange/objects/structures, and whether other-player devices appear beyond planet/moon.
- Decide: location dossier as a new HUD panel vs. reuse of `SystemDossier` chrome.
