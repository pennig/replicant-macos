# System↔body drill: make the system rush away

**Date:** 2026-07-28
**Module:** `app/Modules/NewStarMapFeature`

> **Correction, 2026-07-28 (post-implementation).** Where this document says the scale
> composes into a layer's `(centre, scale, reveal)`, that is wrong and the first
> implementation shipped the bug: `OrreryLayout` places every anchor at `sceneRadius ·
> scale · reveal`, so pushing both squares the factor. It composes into `(centre,
> reveal)` — the factor rides `reveal` alone. This also removes the "radius unchanged"
> correction described below for bodies and pips: radii come off `scale`, which is no
> longer pushed, so they are true world size for free. See the k² section in
> `app/.claude/memory/body-drill-rush.md`.

## The problem

Drilling from the system view into a planet currently reads as the solar system
*receding slightly into the background*. Drilling from the galaxy into a system
reads much better — everything rushes far away from the focused star, which sells
the idea that the stars are genuinely far apart and are now just points in the
night sky. The goal is to bring the deeper transition up to the same standard.

### Why the deeper drill reads flat today

The system→body move is not really a dive. Working in units of the focused star's
rendered radius `R`:

- **System view.** `enterSystem` frames the star at `maxAngularSize` (0.05), so the
  camera sits at `dFinal = R / 0.05 ≈ 17R` from the star, with the whole orrery
  fitted to the frame — outer orbits land around `0.52 · 17R ≈ 9R`.
- **Body view.** `enterBody` rescales so the drilled planet renders at exactly `R`
  (star-sized), then frames the moon system — landing the camera at roughly `19R`
  from the planet.

The camera therefore **translates** from star to planet without meaningfully
changing its distance-to-target. The whole sense of zoom comes from
`bodyCentralStartRadius → fullRadius`, an artificial growth of the central body.
Everything else in the system keeps its true world position, at depths comparable
to the arriving moon system, so it can only slide sideways and fade.

The galaxy drill, by contrast, applies a real recession: `systemPush = 2.0` pushes
every non-focused star to 3× its distance from the focused star while `fieldShrink
= 0.4` collapses it toward a pinprick. There is no equivalent one level down.

## The design

While the system↔body cross-fade runs, apply a **uniform scale about the drilled
planet's live world position** to everything belonging to the *system* layer:

```
k     = 1 + bodyPush · bodyProgress          (bodyPush = 5 → k tops out at 6)
p'    = pivot + (p − pivot) · k
```

`pivot` is the drilled planet's live world position, which is already tracked every
frame (`trackBodyCentre` on the way in, `trackDepartingBodyCentre` on the way out).
That planet is already the one body **excluded** from the system layer — it is drawn
once as the continuous central body (`excludeID: bodyPlanetID`) — so it is the exact
fixed point of the transform, with nothing to reconcile.

Consequences, all of which are what the effect asks for:

- Orbit-ring radii **and** their spacing both scale by `k` → the rings visibly
  spread apart, centered on the selected planet.
- The sun (≈ 4R from the planet) and the siblings (up to ≈ 13R) sit *closer* to the
  pivot than the camera does (≈ 19R), so scaling them out flings them past the
  camera and shrinks them hard, instead of leaving them at comparable depth.
- Zoom-out is the exact mirror for free: `bodyProgress` 1→0 unwinds `k` to 1, so the
  system converges back in as it fades in.

Nothing about the existing fade changes. `orreryAlpha` is already decoupled from
`orreryReveal` (a documented invariant of the two-layer cross-fade), so the push is
purely geometric.

### Where it applies

**Scaffold — orbit rings, HZ band, belt — needs no shader change.** Those vertex
shaders already compute

```
world = orreryCenter + (baked − orreryBuildCenter) · orreryReveal
```

and a uniform scale about a pivot composes into exactly that form:

```
k · world + (1−k) · pivot
  = [k · orreryCenter + (1−k) · pivot] + local · (orreryReveal · k)
```

So the push is expressed entirely by writing `center' = k·center + (1−k)·pivot` and
`reveal' = reveal · k` into the per-layer `Uniforms` copy that `encodeOrreryLayer`
already builds. No new uniform fields, no buffer rebuild, no rebase change.

**Bodies** are placed on the CPU by `placedOrreryBodies`. Their `center` *and* their
`sun` (light source) take the same map — transforming both preserves every light
direction exactly, so lit faces do not swing as bodies fly out. **Radius is left
unchanged**, so bodies shrink purely by perspective; that is the "they are simply
far away now" reading, and it also keeps a sibling that sweeps near the camera as a
small disc rather than a full-frame smear. Ring and atmosphere-halo uniforms derive
from the same `PlacedBody`, so they follow automatically.

**Pips, ships, the selection ring, and the SwiftUI overlays** read the active layer
via `frameOrreryLayout`. This matters on the way *out*, where the arriving system
layer is the active one: without the same transform they would detach from the rings
for the whole pull-back. Because `OrreryLayout` is an affine map of scene
coordinates, the pushed layout is just `OrreryLayout(center: center', scale: k·scale)`
— one composition, and every consumer follows.

**The sun** is not an orrery body: `enterSystem` makes the focused *star field* star
the sun (uncapped, unfaded), and `enterBody` keeps it. So `star_vertex` gets the same
push for the focused star only. Because the push is radial from the planet, the star
stays exactly on the planet→sun lighting ray, so the lit face keeps pointing at the
visible sun with no extra work.

### Deliberately untouched

- **The background galaxy field.** Those stars are light-years away, already pushed
  3× by `systemPush` and dimmed to the `fieldFloor` (0.15) backdrop. Pivoting them on
  a planet would swing the entire sky; leaving them put is also what real parallax
  does at that distance.
- **`OrreryLayout` as used by `pickLocation`**, which builds its own copy from the
  true centre/scale. Picking keeps hit-testing real positions; the push lives only in
  the render path.
- **The fade curves**, the camera fly, the transition durations, and the central
  body's size morph — all unchanged.

### Tunables

Added beside `systemPush` / `fieldShrink` / `fieldFloor` in the `StarFieldRenderer`
tunables block:

- `bodyPush: Float = 5` — full-drill distance multiplier is `1 + bodyPush = 6`.

`k` is driven by the eased `bodyProgress`, matching how `systemPush` is driven by the
eased `orreryReveal`, so the rush peaks with the cross-fade rather than fighting it.

### Risk to check visually

The habitable-zone band is a large additive filled annulus. Expanding it past the
camera could briefly wash the lower frame (the camera sits ~25° above the orbital
plane, so the band sweeps beneath it). If that reads badly, the fix is to front-load
the scaffold's fade on a pushed layer — not to weaken the push.

## Testing

- **Unit** — the push transform is a pure function, tested for: identity at
  `bodyProgress = 0`; the pivot as an exact fixed point at any progress; the
  centre/reveal composition matching a direct point-wise scale (the algebraic
  identity the scaffold path relies on); and the scaling being linear in progress so
  the unwind is symmetric.
- **Visual** — run the app, drill into a planet and back out, and confirm the rings
  spread, the sun and siblings fly out and become points, and the HZ band does not
  flash.
