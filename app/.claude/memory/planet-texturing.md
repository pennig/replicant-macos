---
name: planet-texturing
description: Orrery planet surface texturing — PlanetType/PlanetMaterial → OrreryBodyUniform → orrery_body_fragment procedural shading.
metadata: 
  node_type: memory
  type: project
  originSessionId: 2fa1442d-23a2-40a9-a345-7421b89fa097
---

Orrery planets are procedurally textured (not flat-shaded) in NewStarMapFeature. Pipeline:
`PlanetType` (classifies backend `type` string; `.unknown(String)` keeps raw label) →
`PlanetMaterial.surface(for:lifeStage:estimated:tags:)` → `PlanetSurface` (base/detail
albedo, `PlanetSurfaceStyle`, life 0…1, estimated bool, `SurfaceModifiers`) → packed into
`OrreryBodyUniform` (in `StarFieldRenderer.bodyUniform`) → `orrery_body_fragment` in
`Shaders.metal` draws the surface on the sphere impostor.

Non-obvious sync points:
- **`PlanetSurfaceStyle` raw Int32 values MUST match the `style` switch in `orrery_body_fragment`** (0 rocky,1 banded=gas giant,2 icy,3 molten,4 ocean,5 desert,6 iceGiant). Gas giant (banded) and ice giant (iceGiant) are deliberately separate styles.
- **Per-planet variability is a stable seed**: `OrreryMapping.appearanceSeed(designation:rotationPeriodHours:)` (FNV hash → [0,1)) is passed in `surfaceParams.w` and drives band count/swirliness/hue-jitter/feature placement in the shader via `pr(seed,i)` — so a planet always looks the same. Spin longitude is a separate seed in `surfaceParams.z`.
- Planet surfaces use `fbm6`/`ridge` (6-octave) for resolution, NOT the 4-octave `fbm` (that stays for star granulation).
- Adding fields to `OrreryBodyUniform` (C struct in CShaderTypes/ShaderTypes.h) needs `rm -rf Modules/.build` before rebuild — see [[spm-stale-layout-crash]].
- **`estimated` is NOT in the enum** — it's the body's `typeEstimated` bool threaded separately (moons use `recon != .scanned`); renders duller + staticky.
- **Scan tags live on `physical.tags`** (only populated once a body is scanned; NOT a planet-root key). `PlanetMaterial.modifiers(tags:)` maps a curated set (cratered/no_atmosphere/volcanic/hellworld/ice_surface/frozen/cold/…) to intensity nudges; unknown tags ignored (type stays primary). Design choice: tags only modulate, never override the type's style.

Animated clouds + live tuning (added): terrestrial (non-giant) worlds get an animated cloud deck in `orrery_body_fragment` (post-style block, two drifting `fbm6` octaves for parallax; shader gate `style != 1 && != 6`). Coverage comes from `SurfaceModifiers.atmosphere` (`mods.y`), set AUTHORITATIVELY from the scanned `Atmosphere` ordinal via `PlanetMaterial.cloudAmount(for:)` (none/unknown→0 … crushing→1.3) — NOT from tags (atmosphere-blind); old ocean-only inline cloud line removed. KEY: atmosphere drives the coverage THRESHOLD not opacity — `density=saturate(mods.y*cloudAmount/1.3)`, `lo=mix(0.9,-0.2,density)` so crushing pulls the smoothstep floor below the noise → total overcast (scaling opacity alone could never fully cover — that was the first-cut bug). Clouds sample a separate `cloudDir` (computed in the fragment): a deck that rotates FASTER than the surface (`cloudDrift` added to the 0.06 spin) and is lifted by tangential view-parallax (`cloudHeight`) so it floats above the terrain. The atmosphere "eyeball" constants (cloud amount/scale/speed/softness/opacity/drift/height + halo extent/density/falloff/day-bias/intensity) are now BAKED as `constant float kCloud*`/`kHalo*` literals near the top of the orrery-surface section in `Shaders.metal` — read directly by `orrerySurface`/`orrery_body_fragment` (clouds) and `orrery_atmosphere_{vertex,fragment}` (halo). To retune, edit those `k*` constants. (History: these were once live-tuned via an `OrreryTuning` GPU struct on buffer(3) + an on-screen `OrreryTuningPanel` slider panel; that whole system — struct, panel, `@State atmosphereTuning`, `MetalStarView.tuning`, `Coordinator.applyTuning`, `StarFieldRenderer.orreryTuning` — was removed once the look was dialed in, and buffer(3) is now free in those passes.)

Atmosphere halo (added): terrestrial (non-giant) bodies get a soft glow shell bleeding beyond the limb. Driven by the backend `physical.atmosphere` ordinal (`none`/`thin`/`standard`/`dense`/`crushing`, empty until scanned) — a DEDICATED field, decoupled from type AND temperature (proof: SOL-2/Venus is a Desert World with `crushing` atmosphere; Desert Worlds also seen as `thin`). Parsed to `Atmosphere` enum (PlanetType.swift), mapped to `AtmosphereShell{tint,extent,density}` by `PlanetMaterial.atmosphereShell(for:atmosphere:tags:)` (giants + none/unknown → nil; methane_atmosphere tag → orange tint). Rendered in a SEPARATE pass: `OrreryAtmosphereUniform` → `orrery_atmosphere_{vertex,fragment}` on an enlarged quad, additive HDR + depth-READ (readDepthState, occluded by nearer bodies, no depth write), drawn after the opaque body pass. Placement shared via `StarFieldRenderer.PlacedBody`/`placedOrreryBodies` so halo registers exactly with the limb.

Shader constants (band freq, cloud/city thresholds, static intensity, frost, atmosphere extent/density/falloff) are eyeball-tuned — worth revisiting in the running app. See [[new-star-map-feature]], [[orrery-layout-tuning]], [[sqlite-db-location]] (query planets via `json_extract(systemJSON,'$.planets')`).
