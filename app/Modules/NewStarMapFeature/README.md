# Star Map — Slice 1

A raw-Metal instanced star field: 10,000 stars in one draw call, a turntable
camera, and the relevance field wired through the terrain shader from day one.

## Xcode setup

1. New project → **macOS → App**, interface **SwiftUI**, language **Swift**.
2. Drop in all the files from this folder.
3. Bridging header (so Swift sees the shared C structs):
   - Add a header `StarMap-Bridging-Header.h` containing `#include "ShaderTypes.h"`.
   - Build Settings → **Objective-C Bridging Header** → set to that path.
   - (Xcode also offers to create one automatically the first time you reference
     a C type from Swift.)
4. `Shaders.metal` compiles into the default library automatically — no extra
   steps.

That's it; build and run.

## Controls

| Gesture | Action |
|---|---|
| Two-finger drag | Orbit (azimuth free, elevation clamped) |
| Shift + two-finger drag | Pan the pivot |
| Pinch | Logarithmic dolly |
| Click a star | Re-aim at it (tilt-only if near, zoom-toward if far); relevance falls off around it |
| Double-click a star | Dive in — always repositions to a fixed close distance |
| Esc | Clear focus (back to full terrain) |
| H | Home / overview |
| M | Toggle the FTL comms mesh (relay links + markers) |
| F | Cycle data filters (life / minerals / gas / rare / unexplored / off) |
| G | Toggle status symbols under labels (exploration / life / $ / inventory, SF Symbols) |

Click a star and watch the rest of the field ease down to the near-invisible
floor, then Esc to bring it back. That easing *is* the architecture — the same
write-the-relevance-field operation every overlay will use later.

## Where the knobs live

- **Sizing band / atmospheric dimming / exposure** — `StarFieldRenderer`
  tunables block. Size encodes depth within `[minAngularSize, maxAngularSize]`;
  outside it, depth is carried by atmospheric dimming and (once you move the
  camera) parallax.
- **Focus falloff / floor / easing rate** — `RelevanceField`.
- **Galaxy shape / spectral colors** — `Galaxy.generate`.

## What this slice proves

- Fill-rate, not star count, is the cost. Dolly into the core: if it blows out,
  that's the tone-map/exposure to tune, not a geometry problem. The HDR pass is
  already there to catch it.
- The relevance buffer→shader path works end to end before any real overlay
  exists.

## Honest gaps (next slices, roughly in order)

- **Eased camera moves.** *Done* — refocus is an eased re-aim (single click) /
  dive (double click), smoothstep over a change-scaled 300–750 ms. Still to come:
  framing a bounding volume for routes.
- **Sphere→disc LOD.** *Done* — stars cross-fade from a glow sprite to a
  limb-darkened, granulated luminous disc by on-screen angular size
  (`lodStart`/`lodFull`). Resolved discs are **opaque and depth-occluding** (a
  separate pass; the dense field stays additive/depth-less), the surface **spins**
  and is **view-coupled** (world-space granulation → sphere parallax). Ship head
  markers never occlude. Still to come: real surface texture (spots), on-surface
  lit planets post-dive.
- **System data readout.** *Done* — a compact row of white SF Symbols under each
  label (exploration circle, life leaf, a variable-fill resource $ gauge, inventory
  box), toggle with G. Replaced the noisier on-surface glyph experiment. Still to
  come: per-resource marks, a legend.
- **Overlays.** FTL mesh *done* (toggle M) — first relevance writer, max-combined
  with focus. State overlay *done* — player + ships (comet head / fading tail /
  dashed remainder), always on, with the state-tier clamp so their systems never
  dim. Labels *done* — curated names (selected + nearest) with screen-space
  collision avoidance, over the tone-mapped image. Data filters *done* (cycle F) —
  life / resources / scan as relevance-writing overlays. Still to come: trade
  routes, on-surface encoding (halos/glyphs) once bodies resolve, search.
- **Battery.** Continuous 120fps is wasteful for a mostly-static map — switch to
  `enableSetNeedsDisplay` + redraw-on-input, keeping continuous frames only
  while relevance is easing (`RelevanceField.step()` already returns that flag).
- **Bloom.** A small bloom on the HDR target before tone-map will do a lot for
  the "field of light" feel.
