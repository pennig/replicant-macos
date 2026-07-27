# Orrery physical fidelity — design

2026-07-27

## Goal

Make the orrery read as a real system rather than a schematic. Three strands:

1. **Use the physical data we already fetch.** Rings, axial tilt, rotation period,
   orbital period, and the moon-specific block (`tidally_locked`,
   `orbital_distance_km`, `orbital_period_hours`, `has_atmosphere`,
   `has_subsurface_ocean`) all arrive from the backend. Most are decoded and then
   dropped on the floor.
2. **Fix the volcanic surface.** Three dark bands rotate around every volcanic body
   and converge at the poles — a beach-ball artifact. Volcanism is also overscaled;
   some bodies read as more lava than crust.
3. **Stop pausing the orrery in the planet view.** The body level freezes the orbit
   clock, which also freezes the drilled planet's moons. Remove the freeze and make
   the system↔body transition seamless by construction.

## Data reality

Probed live (`replicant raw GET locations/…`) and cross-checked against the app's
persisted system blobs (15 systems, 69 planets, 150 moons).

### Planets

Present on every scanned planet, at system-scan level (no per-body hydration needed):

| Field | Observed range |
| --- | --- |
| `axial_tilt_deg` | 3.13 … 177.4 |
| `rotation_period_hours` | −5832.5 … +998.5 (magnitude 9.92 … 5832.5) |
| `orbital_period_days` | 89.69 … 30589 |
| `rings` | `true` on SOL-6, SOL-7; `false` on all 69 stored planets |

### Moons

Present on every scanned moon:

| Field | Observed |
| --- | --- |
| `orbital_distance_km` | 174 287 … 1 221 870 |
| `orbital_period_hours` | 32.89 … 655.7 |
| `tidally_locked` | `true` on every scanned moon probed |
| `has_atmosphere` | `true` on SOL-6-1 (Titan) |
| `has_subsurface_ocean` | `true` on SOL-5-2, SOL-6-2 |

### Retrograde rotation

**Retrograde is carried by a negative `rotation_period_hours`, and independently by
an obliquity greater than 90°** — the standard astronomical convention. Tilt is
reported in `0…180` and never exceeds it (max observed 177.4).

| Body | `axial_tilt_deg` | `rotation_period_hours` |
| --- | --- | --- |
| SOL-2 (Venus) | 177.4 | −5832.5 |
| SOL-7 (Uranus) | 97.77 | −17.24 |
| SOL-5 (Jupiter) | 3.13 | +9.92 |
| SOL-6 (Saturn) | 26.73 | +10.66 |

This simplifies the renderer: apply the obliquity *geometrically* and retrograde
emerges on its own. A body at 177.4° points its north pole nearly straight down, so
spinning right-handed about that pole reads as backwards from above. Uranus at 97.77°
rolls on its side. No special case — the "> 90° means retrograde" rule *is* the
geometry, not a branch to write.

Only the explicit negative period needs handling in code, as an override for the case
where the backend calls a rotation retrograde without the obliquity implying it.

### The one genuine gap

`orbital_period_hours` is in the live moon payload but has no field on
`RawBodyPhysical`, so the decoder discards it. Moons carry no `orbital_period_days`
either — so **every moon orbit speed currently on screen is synthetic**
(`8 + index * 3` days, from `OrreryMapping.bodyModel`).

## Architecture

### Data plumbing (`UniverseModels`)

Add `orbitalPeriodHours: Double?` to `RawBodyPhysical`, `BodyPhysical`, and the
wire-DTO mapping in `LocationDTOs.swift`. This is the only decoding gap; every other
field is already decoded.

Persisted system blobs re-encode `BodyPhysical`, so no migration is required — the
new key is additive and optional, and absent blobs decode to `nil`.

### Model surface (`OrreryModels`)

Two small value types keep the new facts cohesive instead of scattering optionals
across `OrreryPlanet`:

```swift
/// How a body turns. `tiltDeg` is obliquity (0…180 after normalization);
/// `rotationHours` is signed — negative means the backend explicitly calls the
/// rotation retrograde. `tidallyLocked` overrides both: spin phase tracks orbit.
struct BodySpin: Equatable, Sendable {
    var tiltDeg: Double?
    var rotationHours: Double?
    var tidallyLocked: Bool
}

/// A ring system's band, as multiples of the body's rendered radius.
struct RingSystem: Equatable, Sendable {
    var innerFrac: Float
    var outerFrac: Float
    var seed: Float
}
```

`BodySpin` derives:

- `obliquityDeg` — `tiltDeg` normalized into `0…180`. Defensive only; the backend
  already reports within that range.
- `pole` — `+Y` rotated by `obliquityDeg` about a stable per-body azimuth derived
  from the appearance seed, so two same-tilt worlds don't line up.
- `spinRate(anchor:)` — signed radians/second (see below).

`OrreryPlanet` and `CentralBody` each gain `spin: BodySpin` and `rings: RingSystem?`,
replacing the existing bare `hasRing: Bool`. Moons additionally carry
`hasSubsurfaceOcean: Bool` and `orbitalDistanceKm: Double?`.

### Spin rate compression

Rotation periods span 9.92h … 5832.5h — a 588× spread. Linear mapping either blurs
the fast rotators or freezes the slow ones. Mirror the approach `OrbitTiming` already
uses for orbits: anchor off the fastest rotator in the current layer and compress the
ratio with an exponent.

```
rate = baseRate * pow(fastestHours / |hours|, falloff)
```

with `baseRate` tuned so the fastest rotator lands near today's fixed `0.06` rad/s,
and `falloff ≈ 0.5`. A body with no `rotationPeriodHours` keeps today's default rate.

**Tidally locked** bodies ignore this entirely: spin phase equals orbit angle, so the
same face points at the parent. This is the visible truth for essentially every
scanned moon.

### Body-space texturing (`Orrery.metal`)

`OrreryBodyUniform` gains `simd_float4 spinAxis` — `xyz` = the body's pole in world
space, `w` = signed spin rate (rad/s).

`orrery_body_fragment` currently rotates the reconstructed sphere normal about world
`Y` and hands `dir` to `orrerySurface`, which reads latitude as `dir.y`. Instead,
build an orthonormal basis from the pole and transform `dir` into **body space**
before texturing. Every existing latitude feature — gas-giant bands and polar hoods,
ice-giant bands, icy caps, temperature-driven polar ice — then tilts correctly with no
change to its own code.

The cloud deck (`cloudDir`) goes through the same basis so weather stays aligned with
the surface.

### Sphere depth

`orrery_body_fragment` writes no depth today, so the depth buffer holds the flat
billboard-quad plane through the body centre. That is close enough for the current
passes but wrong for a ring, whose far half must be occluded by the near hemisphere
exactly at the silhouette.

Add `[[depth(less)]]` output: the reconstructed sphere surface is always nearer than
the quad plane, so `less` is the correct conservative qualifier. Side benefit — pips
and the atmosphere shell get correct occlusion at the limb.

### Rings

New pass `orrery_ring_vertex` / `orrery_ring_fragment` with `OrreryRingUniform`:

```c
typedef struct {
    simd_float4 centerRadius;   // xyz = body world centre, w = body radius
    simd_float4 poleInner;      // xyz = body pole (unit), w = inner radius (× body radius)
    simd_float4 sunOuter;       // xyz = sun world position, w = outer radius (× body radius)
    simd_float4 tintSeed;       // rgb = ring tint, w = band seed
} OrreryRingUniform;
```

Geometry: an annulus in the body's **equatorial plane** (perpendicular to the pole),
spanning 1.35× … 2.30× the body radius. Built once as a shared unit annulus and
transformed per body, like the existing shared quad.

Drawn after the opaque bodies: alpha-blended, depth-**read**, no depth write, so the
planet's near hemisphere occludes the far half of the ring and the ring occludes
nothing.

Fragment:

- **Banding** — seeded ridged noise on the normalized radius gives stable Cassini-like
  gaps. Same `appearanceSeed`, so a body's rings are identical every viewing.
- **Illumination** — brightness scales with the sun's angle to the ring plane, so an
  edge-on ring nearly vanishes and an open one reads bright.
- **Planet shadow on the ring** — project the ring point along the sun direction; if
  it passes within one body radius of the axis, and on the far side, darken. Analytic
  and cheap. This is the detail that sells the effect.
- **Ring shadow on the planet** — in the body fragment, intersect the surface point's
  ray toward the sun with the ring plane; darken if the hit lands inside the band.
  A few lines. *Marked optional*: if it reads as noise at orrery scale, drop it and
  say so rather than shipping something muddy.

### Volcanic surface

The beach-ball is `Orrery.metal:118`:

```c
float pulse = 0.7 + 0.3 * sin(t * 1.5 + lon * 3.0 + sd * 6.283);
```

`lon` is `atan2(dir.z, dir.x)` — undefined at both poles and discontinuous at the
antimeridian. The `× 3.0` is exactly the three bands; `t` rotates them. The gas-giant,
ice-giant, and desert styles each already carry an explicit pole-safe fix with a
comment naming this artifact. Molten was missed.

Replace with a pulse driven by 3D noise in body space, so hot regions breathe
independently, nothing converges at a pole, and there is no seam:

```c
float pulse = 0.7 + 0.3 * sin(t * 1.5 + fbm6(dirBody * 2.3 + sd * 11.0) * 6.283);
```

Coverage comes down by raising the crack threshold band so peak lava occupies roughly
20–25% of the surface rather than over half, and `PlanetMaterial.lavaAmount`
recentres so a mid-temperature world reads as cracks in basalt rather than basalt
islands in lava. The hottest worlds still crack wide — the ceiling drops, the
temperature response stays.

### Moons made real

In `OrreryMapping.bodyModel`:

- **Period** — `orbitalPeriodHours / 24` replaces the synthetic `8 + i * 3` ladder.
- **Orbit radius** — `orbitalDistanceKm` mapped through a sqrt compression (matching
  the planets' AU treatment) and then through the **existing** `spacedLayout`
  non-overlap pass, which already guarantees no two orbits intersect and nothing
  falls inside the central body. Moons with no distance keep the index-step fallback
  so an unscanned roster still lays out sanely.
- **Atmosphere** — moons receive a `has_atmosphere` boolean, never the thickness
  string planets get, so `Atmosphere(apiValue:)` yields `.unknown` and moons always
  render airless today. Map `has_atmosphere == true` → `.thin` (upgraded by a
  `thick_atmosphere` tag, which Titan carries), giving them the faint halo they
  should have.
- **Subsurface ocean** — a new surface treatment: bluish cryo-fracture lineae over
  the icy/rocky base, deliberately unlike lava (cool tint, no pulsing, low emissive).
  Driven by a new `SurfaceModifiers` field so it composes with existing tags.

### Removing the pause

The freeze exists for exactly one reason: the body view's centre is a fixed world
point, so the drilled planet must not orbit out from under it. The fix is to remove
the reason, not to compensate for it.

- `StarFieldRenderer` retains `parentSystem { model, center, scale }` while at body
  level. Today the system model survives only as `departing`, for the duration of the
  cross-fade.
- Delete the freeze at `StarFieldRenderer.swift:643` — `orbitClock` always advances.
  **This alone starts the moons orbiting**, which is most of what reads as paused.
- Each frame at body level, recompute `orreryCenter` as the parent layout's live
  position for `bodyPlanetID`, and re-derive `orrerySunWorldPos` from it — so the
  sunlight direction on the planet shifts as it rounds its star.
- New `TurntableCamera.translate(by:)` shifts `target` **and** any in-flight framing
  endpoints by the frame's delta, so the camera rides along with no user-visible
  motion and a dive stays locked to a moving target.
- Scaffold buffers must not rebuild per frame (geometry generation plus buffer
  allocation on the render thread is exactly the hitch the codebase already defers
  transitions around). Add `Uniforms.orreryBuildCenter`; the line and point shaders
  become `world = orreryCenter + (pos − orreryBuildCenter) * reveal`. One uniform, no
  reallocation.
- **Zoom-out is then seamless by construction.** The body centre *is* the planet's
  live system position, so the arriving system layer already draws the planet exactly
  there. There is nothing to reconcile — which is why this beats animating the seam
  away. `exitToSystem` just eases the camera back to the star pose, which is static.
- `StarMapViewpoint` persists the parent system so a tab-switch restore still tracks.

### Dossier facts

`NewStarMapView.resolveLocation` gains facts, shown only when scanned:

- **Planet** — Rings · Day (rotation period) · Year (orbital period) · Tilt
  (with "retrograde" when obliquity > 90° or the period is negative).
- **Moon** — Orbit (km and period) · Tidally locked · Atmosphere · Subsurface ocean.

Design tokens throughout; designations stay in a mono token per the project rule.

## Error handling

Every new field is optional and every consumer degrades to today's behaviour:

- No `axialTiltDeg` → upright pole (current look).
- No `rotationPeriodHours` → current fixed spin rate.
- `rings != true` → no ring pass for that body.
- No `orbitalPeriodHours` → current synthetic moon ladder.
- No `orbitalDistanceKm` → current index-stepped moon orbits.
- Unscanned bodies keep the existing `estimated` staticky treatment.

Unscanned and partially-hydrated systems are the common case, so this is the main
path, not a fallback.

## Testing

Pure logic is unit-tested (`OrreryTests`, `UniverseModelsTests`):

- `orbital_period_hours` decodes, from the captured live fixtures already in the repo.
- Moon `orbitalDistanceKm` → compressed, non-overlapping orbit radii.
- `orbitalPeriodHours` → `periodDays`.
- `BodySpin`: obliquity normalization (including the past-180 fold), pole vector,
  retrograde sign from a negative period, tidal-lock phase equals orbit angle.
- Ring inner/outer radii and the equatorial-plane basis.
- Body-centre tracking: the parent-layout query returns the planet's live position,
  and `OrreryLayout` stays pure.

Shader work has no unit-test path, so it is verified by `xcodebuild` compile plus
screenshots of the running app, against the SOL cases the probe identified:

| Case | Body |
| --- | --- |
| Rings | SOL-6, SOL-7 |
| Extreme obliquity / retrograde | SOL-7 (97.77°), SOL-2 (177.4°) |
| Fast vs. slow rotation | SOL-5 (9.92h) vs. SOL-2 (5832.5h) |
| Volcanic surface | SOL-5-1 (Io) |
| Moon atmosphere | SOL-6-1 (Titan) |
| Subsurface ocean | SOL-5-2, SOL-6-2 |
| Tidal lock | SOL-3-1 (Luna) |

## Phases

Each phase is a reviewable commit on `main`.

1. Data plumbing (`orbitalPeriodHours`) + `BodySpin`/`RingSystem` model surface + tests
2. Volcanic beach-ball fix + volcanism scale-down
3. Axial tilt / rotation / tidal lock, including sphere-depth output
4. Rings
5. Moon orbits from real km/hours + subsurface-ocean and atmosphere cues
6. Removing the pause
7. Dossier facts

Phase 2 is deliberately early: it is the smallest change and the most visible.

## Out of scope

- Ring shadow *on the planet* may be dropped if it reads as noise (called out above).
- No changes to `OrbitTiming`'s existing planet-orbit compression — the recorded
  tuning decision is fidelity over accuracy, and this work does not revisit it.
- No SceneKit cutover; this stays in the raw-Metal renderer.
