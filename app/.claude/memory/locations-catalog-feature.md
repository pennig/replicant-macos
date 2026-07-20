---
name: locations-catalog-feature
description: "LocationsFeature (Catalog › Locations) — hierarchical stellar-locations catalog; domain+client+persistence in UniverseModels, feature in LocationsFeature."
metadata: 
  node_type: memory
  type: project
  originSessionId: e3ef9db6-4597-4fb4-af77-8a4641c22a7f
---

The **Locations** catalog (sidebar Catalog › Locations, three-pane) lists known stellar locations as a disclosure tree: system → (belts + planets) → (moons + Lagrange points). Each planet lists its moons then its five synthesized Lagrange points (`SYSTEM-n-L[1-5]`, always L1–L5 like the star map's OrreryMapping; `LocationKind.lagrange` "scope" icon; `lagrangeNode`); hydrated `Planet.lagrange` SpecialSites overlay inventory/device badges + roll up onto the planet. Selecting one hydrates via `body()` (attaches to the parent planet — `applying(.special)` now derives the parent from the designation when `parent_planet` is absent; lagrange DTO now maps inventory too) and shows `LagrangeInspector`; valid travel target. Sites/salvage/shops/events don't appear as rows — they bubble up into the detail pane via `StarSystem` roll-ups.

**Layering (deliberate):**
- **`UniverseModels`** (shared, no SceneKit) owns the domain + data access: `LocationModels.swift` (`StarSystem`/`Planet`/`Moon`/`Belt`/`ResourceSite`/`SalvageSite`/`SpecialSite`/`Shop` + roll-ups + `applying(_ BodyDetail)` merge), `LocationDTOs.swift` (all-optional `Decodable` DTOs decoded via **JSON round-trip** of the generated body with `.convertFromSnakeCase`, since the generated client types every location block as opaque freeform `*Payload`), `LocationsClient.swift` (`footprint()`/`system(_:)`/`body(_:)`; 403→`LocationsError.notExplored`), `LocationRecords.swift` (persistence). Also now home to the hoisted census `Star` + `StarsClient`, `Position`, `Recon`/`LifeTier`, and `InventoryItem` (moved out of StarMap).
- **`LocationsFeature`** owns UI: `LocationNode.swift` (pure tree builder + `LocationSort`/`LocationFilter`), `LocationsFeature.swift` (reducer: selection/sort/filter + hydrate-on-select), `LocationsListView.swift` (OutlineGroup disclosure list), `LocationDetailView.swift` (polymorphic inspector). Wired in `macOS/MainFeature.swift` (`.locations` sidebar case + Scope + content/detail routing).

**Persistence = blob-per-system, NOT normalized tables** (chosen because detail is always fetched/rendered as a whole polymorphic system; mirrors `Device.detail`): `SystemDetail` (one row per explored system holding the mapped `StarSystem` as JSON + denormalized `recon`) + `LocationFootprint` (the `GET /v1/locations` holdings overlay). Migrations registered in `ReplicantApp.bootstrapDatabase`. The tree + roll-ups are rebuilt in memory.

**Key behaviors:** census `Star` table (populated by the Stars view — Locations does NOT re-survey) drives the list + the explored/uncharted filter; hydration is lazy (select an explored system → `system(_:)`; select a body → `body(_:)` merged into the blob). Distance sort is computed locally from the active replicant's current-star `Position` (census `distance_from_replicant` is stale after travel).

**Scan ingestion (BUILT):** shops, `system_objects` (megastructures + incoming-asteroid threats), and `outer_system` (Kuiper/Oort) come ONLY from `POST replicants/{code}/scan`, not `locations/{star}` — see [[location-sites-endpoint]]. `ScanDTOs.swift` maps the scan → `StarSystem`; `LocationsClient.scan`/`scanAndPersist`; `StarSystem.mergingScan` overlays it while keeping hydrated body detail. Triggered by (a) an explicit "Scan System" button on the current system's inspector, and (b) a passive GameSync route (`locations.scan` in ReplicantApp) that re-scans on arrival/megastructure/object/shop/location-event relay events (scan is free/read-like per the user; excludes scan-echo types to avoid feedback loops; coalesced via LockIsolated). Detail pane renders a Structures & Objects section (progress bars, red threats w/ deadlines).
