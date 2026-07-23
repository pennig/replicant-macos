---
name: starmap-main-thread-load
description: "Star map main-thread load: the four costs that jammed other windows + lagged ship icons, and the 2026-07-23 lightening (frame pacing, label throttle, shared layout, emission snapping, decode cache)"
metadata:
  type: project
---

The Metal star map draws on the MAIN thread (MTKView, continuous), so its costs are
taken from every window in the process — the user reported the Raw API console
scroll jamming while the map was up, and the SwiftUI ship icons falling behind
their GPU pips during auto-rotate (icon lag = the overlay's Core Animation commits
lagging the Metal presents under main-thread saturation; one root cause, two
symptoms). Fixed 2026-07-23 (`85fb932`); the four costs found and what now bounds
them:

1. **120 Hz always** → `StarFieldRenderer.updateFramePacing`: 120 Hz only while a
   gesture / eased framing / drill transition / relevance fade is live (gesture
   recency via `lastInteractionTime`, window 1.5 s), else 60 Hz for idle ambience
   and the slow auto-rotate. Knobs: `activeFramesPerSecond`/`idleFramesPerSecond`.
2. **Label pass projected + distance-sorted EVERY star every frame** → split: the
   membership/collision half (`refreshLabelLayout`) runs at `labelLayoutInterval`
   (0.05 s) or immediately on selection/symbols/terrain change; per-frame work
   re-anchors only the tracked ~20 labels (`cachedLabelPlacements` stores each
   label's collision offset FROM its anchor, so labels stay frame-locked to their
   stars between refreshes).
3. **Per-frame churn**: `frameOrreryLayout` is built once per `draw` and shared by
   ship heads, transit lines, and the three SwiftUI overlay emissions (was up to
   5 constructions/frame); emissions snap to the physical pixel grid BEFORE the
   `!=` publish guards (`snapToPixelGrid`), so sub-pixel auto-rotate drift no
   longer re-renders the ship/cluster/callout layers per frame.
4. **View body re-evals on every observed table change** (device roster refreshes
   every few seconds): `stars` recon merge is now a dictionary (was O(stars ×
   systemDetails) per row, run twice per eval); `stars`/`focusedModel`/
   `deviceClusters` are computed ONCE at the top of `body` and threaded through;
   `SystemDecodeCache` (@State, keyed designation+`hydratedAt`) memoizes the
   focused system's blob decode — the same stall class as
   [[starmap-hydrate-fly-hitch]].

Also: `updateTerrain` skips the RelevanceField rebuild AND the ~16k-puff
`NebulaField.generate` re-diffusion (O(puffs × stars), main thread) on flag-only
changes (star COUNT unchanged ⇒ positions unchanged, table is append-only); an
active data filter is still recomputed because it reads exactly those flags.

Verification note: couldn't confirm at runtime from a background session — a
scratch debug build (different DerivedData path) can't read the Keychain session
token, so it sits at the login screen; `screencapture`/System Events are
TCC-blocked. Verified by swift build (0 warnings) + all 102 module tests; the
user should confirm the scroll feel live. Related: [[metal-hud-glass-hitch]],
[[new-star-map-feature]].
