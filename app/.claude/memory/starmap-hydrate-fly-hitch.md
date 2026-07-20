---
name: starmap-hydrate-fly-hitch
description: Star map drill-in fly hitched because a mid-fly hydrate DB write forced a StarSystem blob re-decode on the main thread; fix = defer the hydrate until the transition lands.
metadata: 
  node_type: memory
  type: project
  originSessionId: a3ca651b-02c3-4ed6-a19c-0fed43d091c6
---

The NewStarMapFeature drill-into-body fly (`enterBody`, 1.15s) dropped a frame or two at variable times. Root cause: `drillIntoBodyRequested` merged `hydrateBody` (network fetch + DB persist) concurrently with the fly. When the write landed, `@FetchAll systemDetails` fired → `NewStarMapView.focusedModel` re-decoded the persisted `StarSystem` JSON blob (`persistedSystem` → `$0.system()`) on the main thread, stalling the render loop mid-fly.

The renderer's own work was NOT the culprit — deferring `setOrreryModel`/`updateOrrery` in `StarFieldRenderer` did nothing. The stall was upstream in the SwiftUI/TCA re-render (blob decode + view diff), which the renderer never sees.

**Fix (shipped):** defer the hydrate dispatch until the fly settles via `.concatenate(sleep(drillInBaseMs), hydrateBody(...))` in the reducer. During the fly nothing writes to the DB, so no re-render; the decode stall lands on the settled/static camera where a single hitch is imperceptible. `drillInBaseMs` (reducer) == `drillDurationBase` (renderer) == 1150ms.

**Diagnosis method that worked:** the decisive test was an A/B — temporarily drop `hydrateBody` from the drill effect; hitch vanished → confirmed it was the hydrate re-render, not the fly math or GPU.

Same pattern likely applies to `enterSystem`'s `hydrateSystem` (galaxy→system fly) — not yet changed. A deeper fix would cache the decoded `StarSystem` so `focusedModel` doesn't re-decode the blob on every body-level `body` re-eval. Related: [[metal-hud-glass-hitch]] (other main-thread work stalling the same MTKView fly), [[new-star-map-feature]].
