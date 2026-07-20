---
name: star-map-live-overlays
description: "How the Metal star map's current-location reticle, FTL mesh, and ships are sourced from real backend/device data"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3d7a2f1f-f6d8-4395-b3e5-793910a4836b
---

The Metal star map (`NewStarMapFeature`, the only wired-in "Stars" entry — `MainFeature.swift` uses `NewStarMapView`; the SceneKit `StarMapFeature` is dead code) originally faked three overlays. As of 2026-07-09 they're real, all folded through the `[Star]` terrain + a `StarMapOverlays` value that `MetalStarView` rebuilds the renderer on:

- **Current-location reticle** (gold): `Star.isCurrentLocation`, set in `NewStarMapView` from the active `Replicant.currentStar` (system designation, e.g. `AINALRAM`). Renderer picks `playerStarIndex` = firstIndex where `isCurrentLocation`, fallback nearest-Sol. Was hard-coded to nearest-Sol.
- **FTL mesh**: nodes = `Star.hasFTLRelay`, set from the live `Device` roster (`deviceType == "ftl_relay"`, location→system prefix). Edges = **real** links from `GET /v1/devices/{code}/network` (`getV1DevicesDeviceCodeNetwork`, `DeviceNetworkSchema.connections[].star`, `range_ly`). Wired via `DevicesClient.relayLinks([RelayNode]) -> [FTLLink]` (GameServices). `ftl_beacon` is NOT a mesh node (its /network returns 400 "Device does not support relay"). Mesh is hidden until the user presses **M** (`meshActive`); the LayerRail `.relay` toggle is still presentational/unwired. Was faked from `Star.entryPoint != nil` + a proximity graph. **As of 2026-07-10 the edges are PERSISTED**: `FTLLinkRecord` `@Table("ftlLinks")` in GameModels (edges-only: id=`A|B`, a, b, updatedAt; full-replace via `FTLLinkRecord.replace(with:into:now:)`), registered in `GameDatabase`. Rebuilds run through `@Dependency(\.ftlMeshRefresher)` (`FTLMeshRefresher`, GameServices) which reads the relay roster from the Device table + resolves `relayLinks` + replaces the table. Two triggers: the view's `.onChange(of: relayNodes)` → reducer `.refreshMesh` (roster changes), AND GameSync's `ftlMeshRoute` (id `ftl.mesh`, type `event`) on `relay_activated`/`relay_deactivated` events (liveness flips that don't change the roster — a deactivated relay's /network returns empty `connections`, so it drops out naturally; no status filter). View renders `@FetchAll(FTLLinkRecord.all)`, not feature state.
- **Ships**: from `Device`s with a travel `derivedActivity` — origin/destination systems from `travelSnapshot`, trip window from `startedAt`/`completesAt`. `Ship` now uses media-time `departedMedia`/`arrivesMedia` (clamped, no loop); renderer converts the wall-clock `ShipRoute` dates once at build. Was two hard-coded demo ships.

`FTLLink`/`RelayNode` live in GameModels. `NewStarMapFeature` gained a `GameServices` dep. See also [[new-star-map-feature]], [[device-command-shapes]].
