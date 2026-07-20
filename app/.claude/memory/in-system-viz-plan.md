---
name: in-system-viz-plan
description: Execution plan for in-system device/travel/site visualization in NewStarMapFeature (the last core Star Map piece)
metadata: 
  node_type: memory
  type: project
  originSessionId: 5055d0f1-b018-4177-84ed-c7dbca42bf82
---

The Star Map's last big core feature: visualize (1) unbounded devices (~≤11) at any
location in a system — planet, moon, belt, structure/system-object, or the 5 Lagrange
points per planet (`SYSTEM-n-L[1-5]`, e.g. `SOL-5-L4`); (2) multi-leg location→location
ship travel across systems (e.g. `AINALRAM-BELT-1 → … → SOL-3-1`), watchable in-orrery on
intra-system legs; (3) mining/salvage sites + location inventory.

STATUS: Phase 1 keystone landed (2026-07-14) — `OrreryLayout` pure resolver +
`OrbitTiming` (SYSTEM-n-L[1-5] Lagrange / belt-anchor / structure / level-aware
`position(ofLocation:)`), renderer routed onto it (duplicated orbit math deleted),
`OrreryStructure`+`LagrangePoint` model fields, moon-cap force-include; tested, builds.
Phase 2 landed (2026-07-14): `StarFieldRenderer.pickLocation` (candidates via OrreryLayout,
disc+pixel-radius, frontmost) + `isDrillablePlanet`; faint Lagrange tick markers in
orreryPips; reducer `selectedLocation`+`locationSelected` (exclusive, cleared on drill/zoom);
MetalStarView orrery-click branch (single=select, double planet=drill); location dossier card
in SystemHUD (kind/designation/facts/indicators, level-aware). Tested, builds.
`planet.lagrange` populated by per-location hydration (Phase 3 wires the fetch), so L-point
markers/picking fully light up then. Projection consolidation still deferred to Phase 3.
Phase 3 landed (2026-07-14): DeviceCluster.swift (ClusterDevice/DeviceCluster/ProjectedCluster/
DeviceClusterProjectionModel + pure DeviceClustering.clusters merge), OrreryLayout.anchor(ofLocation:)
(moon→planet rollup), renderer emitClusterProjection each frame (system focus, opacity=orreryReveal),
LocationClusterLayer badge-per-location (tap→locationSelected), view merges own roster (all location
types, no extra fetch) + scan-blob planet/moon others, dossier lists devices w/ View-into-inspector.
Tested, builds. Own devices anchor at any location incl Lagrange (resolves from parent planet).
Other-players' devices at belt/lagrange still need per-location hydration (deferred). Projection
still 2 paths (ship+cluster) — unify in Phase 4.
Phase 4 landed (2026-07-14): RouteLeg on ShipRoute (location-level legs+seconds); Ship reworked to
multi-leg polyline (Ship.Leg: system-star indices + location codes + media window), position(at:)
parks on cruise legs / spans on jumps, ribbonProgress tracks the tail, orreryPosition(at:resolve:)
places ships on intra-system legs inside the orrery; renderer builds per-leg windows anchored
backward from arrival, emitShipProjection places in-orrery ships via OrreryLayout (opacity=orreryReveal)
else galaxy straight-line (fade w/ overlayDim). Tested, builds. Deferred: in-orrery ships show as
SwiftUI icon only (no GPU comet head there); 3+-system galaxy ribbon is straight origin→dest (head
projected); projection consolidation (ship+cluster emit) still not unified — cleanup pass.
Phase 5 landed (2026-07-14): BeltModel.indicators (mining/inventory) + belt-anchor pip row;
location dossier enriched with LocationDetail (mining sites w/ remaining-resource summary,
salvage w/ depleted/resources, inventory roll-up) dug from the persisted blob, scrollable
sections capped in the card. Tested, builds.

ALL 5 PHASES + ALL DEFERRED POLISH COMPLETE (2026-07-14). Deferred items done: projection
consolidation (shared projectViewPoint); in-orrery ship comet heads (encodeOrreryShipHeads);
multi-system polyline ribbon (Ship.nodeStars + shipSegments + per-segment segmentProgress);
occupied-Lagrange tick brightening; other-players' devices at belt/lagrange/structure (Belt &
SpecialSite gained `devices` w/ back-compat decode, DTO threads them, locationSelected fires
best-effort per-location hydrateBody, cluster builder reads them). Adding fields to shared
UniverseModels structs → rm -rf Modules/.build before swift test (SPM stale-layout). Feature
is functionally complete. Pre-existing unrelated failing test: surfaceTemperatureShapesLavaAndIceCaps
(PlanetMaterial ice ramp, untouched — worth a separate look).

Full plan lives in the repo: `Modules/NewStarMapFeature/IN_SYSTEM_VISUALIZATION_PLAN.md`.
5 phases: (1) location taxonomy + Lagrange geometry + a pure layer-aware `OrreryLayout`
resolver (keystone; also folds moon-cap fix + belt/structure anchors + collapsing the 4
duplicated orbit/projection sites); (2) orrery picking; (3) device clusters at rest
(generalize the ship SwiftUI overlay to positioned entities, one badge-with-count per
location); (4) multi-leg ship polyline via the resolver + relax `overlayDim` so ships show
in-orrery; (5) sites/salvage/inventory dossier + belt pips.

Settled data-source decision: **own devices = live `Device` roster (authoritative,
`Device.location` is a full code); other players' devices = scan blob
`Planet.devices`/`Moon.devices` (`LocatedDevice`, stale but shown); merge by deviceCode,
own wins.** Lagrange data already exists in the model (`Planet.lagrange: [SpecialSite]`) —
just not rendered. Before Phase 1: probe-api a live scanned system to confirm real
belt/Lagrange/structure `location` strings and whether other-player devices appear beyond
planet/moon.

Related: [[new-star-map-feature]], [[star-map-live-overlays]], [[orrery-layout-tuning]],
[[location-sites-endpoint]], [[travel-block-leg-vs-route]], [[device-command-shapes]].
