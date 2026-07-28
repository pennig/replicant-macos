---
name: new-star-map-feature
description: "NewStarMapFeature — the raw-Metal Stars view (the only star map; the SceneKit one is gone). Structure, the three focus levels, the live-data path, and where the real documentation lives."
metadata:
  node_type: memory
  type: project
  originSessionId: acf63055-6a9a-4ae6-b6f4-c4d5ed6f2b46
---

`NewStarMapFeature` (`Modules/NewStarMapFeature`) is **the** star map — the sidebar's
"Stars" view (`SidebarItem.stars`). The SceneKit `StarMapFeature`, the "Stars (New)"
split, `SidebarItem.starsNew` and the `ChamakuyData` stand-in system are all **gone**;
there is no SceneKit anywhere in the app. The module name is the one leftover from the
port — there is no "old" star map for it to be "new" relative to. Renaming it to
`StarMapFeature` is a recorded nicety (review item M9), not a pending migration.

> **This note was rewritten 2026-07-28 to delete a long migration diary.** It had
> accumulated as a chronological port log — phase-by-phase status, commit hashes, plan
> paths under `~/Library`, and "deferred follow-up" lists that had all long since
> landed. At least one of its load-bearing claims had gone silently false (it said the
> orbit clock *freezes* at body level; it now runs unconditionally — the freeze was
> removed once the renderer tracked the drilled planet). Keep this note structural.
> **Do not turn it back into a changelog** — that is what git and the plan docs are for.

## Where the real documentation is

Prefer these over this note for anything detailed; they live in the repo and are
maintained:

- `Modules/NewStarMapFeature/README.md` — what the module is and its SPM/Metal setup.
- `Modules/NewStarMapFeature/HANDOFF.md` — **the design rationale and the rendering /
  camera invariants.** Read its Invariants section before changing anything about
  rendering or the camera; most decisions there were made against a specific
  alternative, and the reasoning is not recoverable from the code.
- `Modules/NewStarMapFeature/IN_SYSTEM_VISUALIZATION_PLAN.md` — the execution record for
  devices/travel/sites in-system (all phases complete; see [[in-system-viz-plan]]).

## Shape

- **Pure, unit-tested logic** (portable Swift, no Metal): `Star`, `Galaxy`, `FTLMesh`,
  `DataFilter`, `RelevanceField`, `LabelEngine`/`LabelSelection`, `Ship`,
  `TurntableCamera`, `Math`, plus the orrery's `OrreryLayout` / `OrreryMapping` /
  `OrreryGeometry` / `MoonTiering` / `PlanetMaterial`.
- **Metal**: `StarField.metal`, `Orrery.metal`, `Overlays.metal`, `Tonemap.metal`,
  `StarFieldRenderer`, `MetalStarView`, the texture caches. Shared C structs in
  `CShaderTypes` — wiring explained in [[metal-spm-integration]].
- **TCA split**: the reducer owns declarative intent (focus level, selection, filters,
  transition lock); the camera and renderer stay imperative behind the `MetalStarView`
  `NSViewRepresentable`, which forwards input outcomes back as actions. Renderer state is
  mirrored in, never owned by, the store.

## Three focus levels

`StarMapFocus` = `.galaxy` → `.system(designation)` → `.body(designation)`, and the two
transitions are the same move one level apart. The invariant that makes them read as one
continuous zoom: **the drilled star IS the orrery's sun** — there is no separate sun body,
so the star→sun handoff is the same object with the same temperature-derived appearance.
`focusedStarIndex` is deliberately never cleared on zoom-out.

Live data is read straight from SQLite: the census `Star` table for the galaxy and the
per-system `SystemDetail` JSON blobs for the orrery. The view holds these as view-local
`@FetchAll`s — a **documented exception** to the query-in-state house rule, with the
reasoning written at the declaration site (the renderer's inputs are read-only and never
reach the reducer).

## Sibling notes, by topic

Overlays and live data [[star-map-live-overlays]] · orrery sizing/spacing
[[orrery-layout-tuning]] · rings, axial tilt, rotation and the moon block
[[orrery-physical-fidelity]] · procedural planet surfaces [[planet-texturing]] ·
many-moon tiering and the swarm band (see the orrery notes) · nebulae
[[nebula-playground]] · solar flares [[flare-playground]] · main-thread cost and the
fixes for it [[starmap-main-thread-load]], [[starmap-hydrate-fly-hitch]],
[[metal-hud-glass-hitch]] · travel/transit code resolution
[[travel-system-proxy-codes]].
