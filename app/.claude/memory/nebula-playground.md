---
name: nebula-playground
description: "NebulaField — reworked nebulae as soft billboard dust clouds, wired into the live map; the standalone NebulaPlayground tuning tool has been removed"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5cb3d2a0-2560-44dc-a47f-10bc5d262084
---

Nebula rework in `NewStarMapFeature`: the old `AmbientField` scattered fixed-pixel point sprites (clamped 1–6px in `StarField.metal`), which read as a conglomeration of dots. The rework renders **world-space billboard puffs** (`NebulaPuff` in ShaderTypes.h) whose overlap reads as diffuse gas.

- `NebulaField.swift` — deterministic generator, three styles (`NebulaStyle`: puffs / filaments / turbulent-fBm), CPU value-noise domain-warp, a two-tone palette, and **star diffusion**: puffs within `starAvoidRadius` of a surveyed star are thinned + spread wispier (via a `StarGrid` spatial hash). `NebulaConfig` = generation knobs (need CPU rebuild).
- **Live map (kept):** `StarFieldRenderer` draws a nebula billboard pass (`nebula_vertex`/`nebula_fragment` in `StarField.metal`, `NebulaRenderParams` uniform — the per-frame render half) in the pre-pass over the ambient dust, diffused against the real surveyed stars; it recedes+fades with a drill-in via the shared `Uniforms`. The old point-sprite nebula loop was removed from `AmbientField` (dust/protostar/shell kept).

**Status (2026-07-20):** defaults are settled and the tuning surfaces are gone. The in-situ `NebulaTunerPanel`/`MetalStarView.applyNebula` HUD was already removed (defaults baked). The standalone playground tuning tool was **removed** this session at the user's request — deleted `NebulaPlayground.swift` (`NebulaPlaygroundView`/`NebulaRenderer`/`MetalNebulaView`), `NebulaPlaygroundShaders.metal` (the self-contained `neb_*` billboard/star/tonemap pipeline), and the playground-only `NebulaUniforms` C struct from `ShaderTypes.h`. `NebulaField` + the live nebula pass (`NebulaPuff`/`NebulaConfig`/`NebulaStyle`/`NebulaRenderParams`) all stay — they're what the live map uses. Sibling [[flare-playground]] is a separate tool and was NOT touched. New star map itself is [[new-star-map-feature]].

New files in the SPM synchronized `Sources/` folder are auto-included; `XcodeWrite` errors on group insertion ("folders" mode) but still writes the file content — see [[pbxproj-link-is-manual]].
