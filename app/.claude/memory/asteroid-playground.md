# Asteroid playground

`AsteroidPlaygroundView` (NewStarMapFeature) — one captured asteroid, centred, orbitable,
re-rollable. Reachable from **Tools ▸ Asteroid Playground**, `#if DEBUG` only, and from a
`#Preview` at the bottom of `AsteroidPlayground.swift`. Added 2026-07-28 because judging the
irregular-body impostor in the orrery means drilling into the right planet and zooming onto
a body a few pixels across.

Non-obvious bits:

- **It draws through the PRODUCTION shaders** — `orrery_body_vertex` / `orrery_body_fragment`,
  fed an `OrreryBodyUniform` assembled the way `StarFieldRenderer.bodyUniform` assembles one
  (same `PlanetMaterial.surface`, same `irregularAxes`, same `BodySpin.renderSpinAxis`). This
  is deliberate: `FlarePlayground` has its own `FlarePlaygroundShaders.metal`, which can drift
  from production. This one cannot. A change to the body shader or to `PlanetMaterial` shows
  up here with no edit to the playground.
- **It reproduces the renderer's TWO-PASS setup** (HDR `rgba16Float` offscreen → real
  `tonemap_fragment` to a `bgra8Unorm` drawable) for that reason. Skipping the tone-map and
  rendering straight to the drawable makes the body read far darker than it does in the map,
  which would make the playground actively misleading. `u.exposure` feeds the tone-map;
  `u.orreryAlpha` must be 1 or the body is fully transparent.
- **Gestures mirror `MetalStarView`**: two-finger scroll orbits, pinch zooms, roll ignored.
  Camera state lives on the renderer, not in SwiftUI `@State`, so a drag doesn't re-evaluate
  the view tree per event.
- **Default camera distance is 6, not tighter.** Unit-product axes put the long one at up to
  1.54× the nominal radius; at distance 3.6 that subtends 0.40 rad against a 0.30 rad
  half-FOV and the rock is cropped on open.

See [[orrery-physical-fidelity]] for the impostor's invariants and [[flare-playground]] for
the older, self-contained playground pattern this one deliberately departs from.
