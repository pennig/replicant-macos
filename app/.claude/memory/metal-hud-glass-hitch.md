---
name: metal-hud-glass-hitch
description: "Glass HUD cards (ultraThinMaterial + big shadow) hitch the Metal camera fly in NewStarMapFeature; drop the material/shadow, not the animation."
metadata: 
  node_type: memory
  type: project
  originSessionId: ed8bfcf0-a88f-41ad-b9fb-ddac9cd10f26
---

In NewStarMapFeature, `StarMTKView` is a continuous `MTKView` whose `draw(in:)` runs on the **main thread**, so any main-thread Core Animation work competes with the camera render loop. Re-aiming to a new star while the `SystemDossier` was visible made the camera fly hitchy.

Root cause (confirmed by the user's fix): the `hudGlass` recipe's `.ultraThinMaterial` backdrop-blur + `shadow(radius: 30)` forced an expensive offscreen recomposite **every animation frame**. The animated relayout of text/bars was NOT the problem.

**Bigger point — glass never actually rendered as glass here.** `.ultraThinMaterial`'s backdrop blur samples the SwiftUI/Core Animation compositing tree, but `MetalStarView` is a hosted `NSView` with its own `CAMetalLayer` that the material can't sample. So the card had nothing real to blur → fell back to a flat opaque dark panel over `.background(.black)`, and the shadow was invisible (black-on-black). A solid fill (e.g. `.rcSurfaceRaised`) is the CORRECT styling for HUD cards floating over the Metal view, not a perf concession.

**Why (perf):** backdrop-blur + large-radius shadow are per-frame offscreen passes; running them 120fps on the same main thread that drives the MTKView starves the render loop.

**How to apply:** for HUD cards over the Metal view, use a solid fill + no/small shadow instead of `.ultraThinMaterial` — it both looks right and keeps the camera fly smooth (you can keep the `.animation`/`.transition`). Also prefer a fixed `.frame(width:)` over `maxWidth:` so content swaps don't animate width. Do NOT reach for material glass over an MTKView/hosted-NSView backdrop expecting translucency.

Related: [[new-star-map-feature]], [[metal-spm-integration]].
