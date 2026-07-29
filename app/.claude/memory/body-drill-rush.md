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

So `encodeOrreryLayer` just shadows `center`, `emergeReveal` and `sun`, and the
recession carries through rings, HZ band, belt, bodies and pips with **no shader change
and no buffer rebuild**. `buildCenter` must NOT be pushed — it is the baked origin the
shaders subtract, and the identity depends on it staying put.
`OrreryPushTests.composesIntoCentreAndReveal` pins this; if it ever fails, the scaffold
path is silently wrong.

## APPLY THE FACTOR EXACTLY ONCE, THROUGH `reveal` — the k² trap

This shipped broken on the first pass and is the thing most likely to be reintroduced.
`OrreryLayout` places every anchor at `sceneRadius · scale · reveal`, so a layer pushed
through **both** `scale` and `reveal` gets `k²`. Every CPU consumer — `encodeOrreryLayer`
(bodies + pips), `frameOrreryLayout`, `pickLocation` — must push the CENTRE and multiply
`reveal` alone. The scaffold shaders have no `scale` at all, so they can only take it
through `orreryReveal`; that path was right from the start, which is exactly why the
mismatch showed up as **bodies detaching from their own rings**.

Why it was hard to read off the screen: the doubled form `push(centre) + (p − centre)·k²`
equals the correct `push(p)` plus an error term of `(p − centre)·k(k−1)` — a pure
radial-from-the-**sun** expansion, **30× the orbit radius** at k = 6. That term swamps
the real one, so the symptom is not "slightly too far": the whole system reads as
blowing up around the *star*, and an inner planet gets flung clean **past** the drilled
planet it should be receding from. (With one factor, `|p′ − pivot| = k · |p − pivot|`,
so nothing can ever cross the pivot. `OrreryPushTests.layerFactorAppliesExactlyOnce` and
`distanceFromPivotOnlyScales` pin both facts.)

Routing it through `reveal` alone has a second payoff: body radii come off `scale`, so
they stay at true world size for free and bodies shrink purely by perspective. An
earlier attempt pushed `scale` and then divided the factor back out of every radius in
three places (bodies, the pip row's rim anchor, picking) — all of that is gone.

One consumer still builds its own layout and must stay push-aware: `pickLocation` picks
against the **pushed** frame, or a click during a zoom-out lands where the bodies used
to be. Its candidate radii use the true `orreryScale`, which is already correct.

## The sun is a star-field star, not an orrery body

There is no sun body — `enterSystem` makes the focused star field star the sun and
`enterBody` keeps it — so `star_vertex` pushes it itself, via the new
`Uniforms.bodyPush` / `bodyPivot`. Because the push is **radial from the planet**, the
star stays exactly on the planet→sun lighting ray, so lit faces keep pointing at the
visible sun for free.

The background sky is deliberately NOT pushed from this pivot: those stars are
light-years out, already receded by `systemPush` and dimmed to `fieldFloor`, and
pivoting them on a planet would swing the whole sky.

## Verification history

A background job cannot run a scratch build (Keychain login wall — see
[[no-gui-verification-from-bg-jobs]]), so the effect can only be seen by Matt. That
gap is what let the k² bug ship: it passed unit tests, both builds, and a careful
diff read, because the transform was correct and only its *application* was doubled.
**For anything in this renderer, a green suite is not evidence the picture is right** —
ask for a look.

Still unchecked at the time of the k² fix: the **habitable-zone band**, a large additive
filled annulus that the expanding layer sweeps beneath the camera. If it washes the
lower frame, front-load the scaffold's fade on a pushed layer rather than weakening the
push.

Related: [[orrery-physical-fidelity]], [[new-star-map-feature]].
