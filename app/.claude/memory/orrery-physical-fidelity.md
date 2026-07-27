---
name: orrery-physical-fidelity
description: "Orrery uses the real physical block (rings/tilt/rotation/moon fields); retrograde is geometric, not a branch; the longitude beach-ball trap; the body-level orbit freeze is gone"
metadata:
  type: project
---

Shipped 2026-07-27. The orrery now consumes the physical data the backend was
already sending, and the body view no longer pauses. Four things here were
non-obvious enough to be worth keeping.

## Retrograde rotation is geometry, not a branch

The backend signals it **two** ways: a **negative `rotation_period_hours`**, and
an **obliquity > 90°** (the standard astronomical convention). `axial_tilt_deg`
is reported in 0…180 and never exceeds it — max observed 177.4 (SOL-2).

Live SOL values, worth reusing as test data:

| Body | `axial_tilt_deg` | `rotation_period_hours` | `rings` |
| --- | --- | --- | --- |
| SOL-2 (Venus) | 177.4 | −5832.5 | false |
| SOL-5 (Jupiter) | 3.13 | +9.92 | false |
| SOL-6 (Saturn) | 26.73 | +10.66 | **true** |
| SOL-7 (Uranus) | 97.77 | −17.24 | **true** |

**Only the negative period needs code.** Obliquity is handled by pointing the pole
where it says: past 90° the pole tips below the orbital plane, so a body spinning
right-handed about it reads backwards from above, for free. `BodySpin.sign`
therefore deliberately ignores obliquity — flipping there *as well* would
double-count and cancel a retrograde world back to prograde. `isRetrograde`
exists only for the dossier label; the renderer never consults it.

Rotation periods span 9.92h…5832.5h (588×), so `BodySpin.spinRate` compresses
against a **global 24-hour reference** (`BodySpin.referenceHours`) and clamps into a
perceptible band (`minRate`/`maxRate`).

It first shipped anchored on the fastest rotator *in the current layer*, which was
wrong twice over: only that one body got the base rate, so every other planet came
out slower than the flat speed they all span at before rotation was wired in (the
orrery read sluggish); and since the anchor counts only *scanned* bodies, surveying
one fast world silently slowed every other planet in that system. **Never anchor a
per-body visual on an aggregate of its neighbours** — it makes a body's appearance
depend on survey progress. Fixed 2026-07-27.

## The longitude beach-ball trap

`orrerySurface` gets a 3D direction. **Never derive `lon = atan2(dir.z, dir.x)`
from it.** Longitude is undefined at both poles and discontinuous at the
antimeridian, so any feature driven by it converges into a rotating beach-ball
pinch at the poles and seams down one meridian.

This bit the codebase twice. The banded / iceGiant / desert styles each carry
their own fix with a comment naming the artifact; the molten style was missed and
shipped `sin(t * 1.5 + lon * 3.0 + …)` — literally three rotating dark wedges.
The `lon` declaration is now deleted with a note against reintroducing it. Use
3D noise over `dir` instead.

Bodies are also textured in **body space** now (a frame whose +Y is the tilted
pole), which is what makes axial tilt work for every style at once — they all read
latitude as `dir.y`, so one transform tilts bands, polar hoods and ice caps
together.

### That frame MUST be right-handed

Building it as `bz = cross(pole, bx)` gives determinant **−1** — a reflection, not a
rotation. It mirrors the sphere and makes **every** planet appear to spin backwards,
tilted or not. It must be `cross(bx, pole)`.

This shipped and had to be fixed the same day. `BodySpin.frame(seed:)` now mirrors
the shader's construction on the CPU purely so `BodySpinTests.bodyFrameIsRightHanded`
can assert `det == +1`; the shader carries a SYNC POINT comment pointing at it. The
general lesson: an orthonormal basis assembled by hand from two cross products has a
50% chance of being a reflection, and a reflection is invisible in a static frame —
it only shows up as motion running the wrong way.

## `orbital_period_hours` was silently dropped

Moons report `orbital_period_hours` and **never** `orbital_period_days`. It had
no field on `RawBodyPhysical`, so the decoder discarded it and *every* moon orbit
speed on screen was synthetic (`8 + index * 3` days at index-stepped radii). Moon
orbits now come from `orbital_distance_km` + `orbital_period_hours`.

Related: moons report `has_atmosphere` as a **boolean**, never the thickness
*string* planets get — so `Atmosphere(apiValue:)` alone left every moon
`.unknown` and no moon ever drew a halo. `OrreryMapping.moonAtmosphere` maps the
boolean, and distinguishes a scanned-and-airless moon (`.none`) from an unscanned
one (`.unknown`), which is what decides whether a halo is drawn at all.

## The body-level orbit freeze is gone

`orbitClock` used to stop at body level so the drilled planet held still beneath
a fixed centre — which also froze its **moons**, the thing that actually read as
"paused". The centre now tracks the planet's live orbital position each frame
(`StarFieldRenderer.trackBodyCentre`), with the lighting sun and camera riding the
same delta, so nothing appears to move while nothing is stopped.

The payoff: **zoom-out is seamless by construction, not by reconciliation** — the
body centre *is* the planet's system position, so the arriving system layer already
draws it exactly there. Two supporting pieces make it free:

- `Uniforms.orreryBuildCenter` rebases scaffold/belt vertices on the GPU, so a
  moving centre never triggers a per-frame buffer rebuild (that allocation on the
  render thread is the hitch [[starmap-hydrate-fly-hitch]] is about).
- `Uniforms.fieldCenter` splits the background field's recession pivot off
  `orreryCenter`, pinned to the focused star. They used to be the same value —
  and at body level `orreryCenter` is now a *moving* point, so sharing it would
  have slid the entire star field.

A departing body layer tracks too, or it separates from the arriving system's copy
mid-cross-fade and reintroduces the exact seam this removes.

## Also worth knowing

- Bodies write **true sphere depth** (`[[depth(less)]]`) instead of the billboard
  quad's flat plane. The ring pass needs it to occlude at the real silhouette.
- `spacedLayout` sorts occupants by raw radius **internally** and returns them in
  input order, so callers may pass any ordering — the moon path relies on this
  (its roster is ordered interest-first for the cap).
- Ring shadow *on the planet* was scoped and deliberately **not** shipped, pending
  a visual check of the base ring effect.

See [[planet-texturing]] for the surface/style pipeline this extends and
[[orrery-layout-tuning]] for the sizing/spacing model the moon orbits now reuse.

**Shader work is compile-verified only** — a background job can build the app but
cannot launch it past the Keychain wall. Two defects (backwards rotation, sluggish
spin) got through that gap and were caught by the user on first look, which is the
honest cost of shipping renderer changes without a visual pass.
