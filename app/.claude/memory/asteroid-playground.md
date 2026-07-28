# Asteroid playground (REMOVED 2026-07-28)

`AsteroidPlaygroundView` — one captured asteroid, centred, orbitable, re-rollable, reachable from
Tools ▸ Asteroid Playground under `#if DEBUG`. Added and removed the same day: it existed to get the
irregular-body impostor over the line (it is what made the spin-rigidity bugs findable) and came out
once that landed, on the same "tool, not a feature" principle as [[nebula-playground]].
`FlarePlayground` is still in the tree by contrast; it stays until asked.

Restore with `git show 54e4ff8 -- app/Modules/NewStarMapFeature/Sources/AsteroidPlayground.swift`;
the Tools-menu and `WindowID` wiring is in that same commit. Kept because rebuilding one is only
cheap if you already know these four things:

- **Drive the PRODUCTION shaders**, not a copy: `orrery_body_vertex` / `orrery_body_fragment` fed an
  `OrreryBodyUniform` assembled the way `StarFieldRenderer.bodyUniform` assembles one. This is the
  whole point — `FlarePlayground` owns a private `FlarePlaygroundShaders.metal` that can silently
  drift from what ships, so it can lie about the thing it exists to judge. Both stages take
  `Uniforms` at buffer 1 and `OrreryBodyUniform` at buffer 2.
- **Reproduce the renderer's TWO passes**: HDR `rgba16Float` offscreen → the real `tonemap_fragment`
  (texture 0, `Uniforms` at buffer 0) → `bgra8Unorm` drawable. Straight to the drawable and the body
  reads far darker than it does in the map, which makes the tool misleading rather than merely
  different.
- **`u.orreryAlpha` must be 1.** The body fragment multiplies coverage by it; at 0 you get a
  correctly-rendered, completely invisible asteroid.
- **Camera distance ≥ ~5.1 for a body of radius 1** at a 0.6 rad FOV. Unit-product axes put the long
  axis at up to 1.54× the radius, so a tighter default crops the rock the moment it opens.

See [[orrery-physical-fidelity]] for the impostor's invariants, and §5 of
`docs/superpowers/specs/2026-07-27-orrery-moon-swarm-visual-verification.md` for the three
non-rigid-motion signatures this tool was built to catch.
