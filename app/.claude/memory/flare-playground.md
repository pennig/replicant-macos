---
name: flare-playground
description: Solar-flare tuning playground in NewStarMapFeature; keep until user asks to remove.
metadata: 
  node_type: memory
  type: project
  originSessionId: 44a7c28b-a6ea-42ff-b763-e88628deac16
---

Stars in [[new-star-map-feature]] have animated solar flares at highest LOD: added in `star_fragment`/`starFlare` (Shaders.metal), living in the annulus beyond `kDiscEdge`, sampled in the star's rotating frame (locked to the disc granulation spin, now `time * 0.065`).

A live tuning tool ships alongside: `FlarePlayground.swift` (`FlarePlaygroundView` + sliders/color pickers + "Copy values"), `FlarePlaygroundShaders.metal` (self-contained single-star copy of the flare math driven by the `FlareParams` uniform in ShaderTypes.h). The playground shader is a PARALLEL copy of production — when tuned values are baked into Shaders.metal constants, update both to avoid drift.

**Why:** user wants to revisit flare tuning later.
**How to apply:** keep all three pieces (playground swift, playground metal, FlareParams struct) until the user explicitly says to remove them.
