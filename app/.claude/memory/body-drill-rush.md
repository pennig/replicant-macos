# System→body drill rush (OrreryPush)

SHIPPED 2026-07-28. The system→body drill used to read as the solar system
*receding slightly*; it now flings the system away from the drilled planet, matching
what galaxy→system already did with `systemPush`.

## The non-obvious diagnosis: the deeper drill is not a dive

Working in units of the focused star's rendered radius `R`:

- `enterSystem` frames the star at `maxAngularSize` (0.05) → camera at `R / 0.05 ≈ 17R`.
- `enterBody` rescales so the planet renders at exactly `R` (star-sized), then frames
  the moon system → camera at roughly `19R`.

So the camera **translates** from star to planet without meaningfully changing its
distance-to-target. The entire sense of zoom comes from `bodyCentralStartRadius →
fullRadius` artificially growing the central body. Everything else keeps its true
world position at a depth comparable to the arriving moon system — which is why it
could only slide sideways and fade, no matter how the fade was tuned. **Do not try to
fix the feel of this transition by adjusting fades or camera timing; the geometry is
the problem.**

Corollary worth remembering: after the drill the sun sits ~4R from the planet and the
siblings up to ~13R, while the camera is ~19R out. They are *nearer the pivot than the
camera is*, so scaling them out from the planet flings them past the camera — which is
exactly why this works here and would not work if the camera actually sat on the pivot
(a uniform scale about a point the camera occupies is a no-op on screen).

## The design

`OrreryPush` (`Sources/OrreryPush.swift`) — a uniform scale `k = 1 + bodyPush ·
bodyProgress` about the drilled planet's live world position, applied to **system**
layers only. `bodyPush = 5` (so `k` tops out at 6) is a `StarFieldRenderer` tunable
beside `systemPush`; **the value is Matt's choice**, so retune only on request.

The drilled planet is already the one body a system layer excludes (`excludeID:
bodyPlanetID` — it is drawn once as the continuous central body), so it is the exact
fixed point, with nothing to reconcile between the two cross-fading layers. The
zoom-out is the mirror for free, since `bodyProgress` unwinds.

## The composition identity (why there is almost no new code)

The scaffold shaders compute `orreryCenter + (baked − orreryBuildCenter) · orreryReveal`,
and an `OrreryLayout` is an affine map of scene coordinates. A uniform scale about a
pivot therefore folds into a layer's frame:

```
k · world + (1−k) · pivot  ==  push(centre) + local · (reveal · k)
```

So `encodeOrreryLayer` just shadows `center`, `emergeReveal`, `scale` and `sun`, and
the recession carries through rings, HZ band, belt, bodies and pips with **no shader
change and no buffer rebuild**. `buildCenter` must NOT be pushed — it is the baked
origin the shaders subtract, and the identity depends on it staying put.
`OrreryPushTests.composesIntoCentreAndReveal` pins this; if it ever fails, the scaffold
path is silently wrong.

## Three places that must divide the factor back out

Positions spread; a body's own *radius* must not, or a planet grows by exactly the
factor it recedes and appears not to move at all:

1. `encodeOrreryLayer` divides each `PlacedBody.radius` by `push.factor` (rings and
   atmosphere halos derive from `PlacedBody`, so they follow).
2. `orreryPips` takes a separate `bodyScale` — the pip row hugs a planet's rim by
   projecting its world radius, so the spread scale would fling the dots off.
3. `pickLocation` builds its layout from the **pushed** frame (or a click during a
   zoom-out lands where the bodies used to be) while keeping true radii.

## The sun is a star-field star, not an orrery body

There is no sun body — `enterSystem` makes the focused star field star the sun and
`enterBody` keeps it — so `star_vertex` pushes it itself, via the new
`Uniforms.bodyPush` / `bodyPivot`. Because the push is **radial from the planet**, the
star stays exactly on the planet→sun lighting ray, so lit faces keep pointing at the
visible sun for free.

The background sky is deliberately NOT pushed from this pivot: those stars are
light-years out, already receded by `systemPush` and dimmed to `fieldFloor`, and
pivoting them on a planet would swing the whole sky.

## Not yet checked visually

Implemented, unit-tested and compiling (package + app target), but the effect itself
was never seen: a background job cannot run a scratch build (Keychain login wall — see
[[no-gui-verification-from-bg-jobs]]). The one thing flagged for a first look is the
**habitable-zone band**, a large additive filled annulus that the expanding layer
sweeps beneath the camera; if it washes the lower frame, front-load the scaffold's
fade on a pushed layer rather than weakening the push.

Related: [[orrery-physical-fidelity]], [[new-star-map-feature]].
