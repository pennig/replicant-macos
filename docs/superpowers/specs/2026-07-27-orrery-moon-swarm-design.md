# Orrery: many-moon rendering (swarm bands, size honesty, coupled orbital plane)

**Date:** 2026-07-27
**Status:** design approved, awaiting spec review
**Area:** `Modules/NewStarMapFeature` — body-level orrery

## Problem

At body level the orrery draws one orbit ring and one near-uniform lit sphere per
moon. Planets with 50+ moons — most of them tiny icy/rocky/captured bodies —
turn that into a dartboard of hairlines behind indistinguishable dots, and the
drilled planet shrinks to almost nothing. Every moon still needs *some*
representation, because devices, events, and salvage sites can exist at any of
them.

### Measured, from the live database

Five planets carry 20+ moons. The worst is POLARISON-6 with 59, then ASTELLIO-1
(55) and ALASII-4 (48). Four measurements frame the work:

**1. Physical data coverage is sparse and uneven.** `orbitalDistanceKm` is
present for 43/55 moons on ASTELLIO-1, **1 of 48** on ALASII-4, and **0 of 59**
on POLARISON-6. `recon` does not predict it — ASTELLIO-1 reports all 55
"scanned" yet 12 carry no physical block. So `rawMoonOrbits` in
`OrreryMapping.bodyModel` is a blend of real sqrt-compressed km and the
`base + i·step` index ladder, where `i` is a position in the *interest-first*
sort. The resulting layout is neither physical nor schematic.

The cause is upstream and known: moon physical data arrives in the
`scan.completed` event, which only fires for a survey drone that is **not**
adopted by an AMI controller (see the `ami-drones-are-event-silent` note). A
backend fix is filed. Until it lands — and for rosters already stored, after it
lands — coverage stays partial. **The design must therefore treat missing
physical data as the normal case, not an edge case.**

**2. The size mapping crushes a 1000× range into 1.5×.** `moonSizeFraction` is
`min(0.30, 0.10 + 0.08·√rₑ)`. SOL-5's real moon radii span 0.0004 → 0.413 R⊕;
on screen that becomes 0.264 → 0.394 scene units. The unscanned default (0.14 →
0.364 scene) lands *above* most known small moons, so an uncharted rock renders
larger than a real one. This is the specific cause of "the minimum size reads
spherical and larger than a captured asteroid".

**3. The non-overlap pass spends the whole radial budget.** With
`centralScene = 2.6` and `pad = 0.6`, each moon consumes ~1.33 scene units.
At the current `maxMoons: 24` cap the outermost orbit lands near 34 and
`frameScene` ≈ 38, putting the drilled planet at **6.7%** of the frame radius.
Uncapped at 59 moons it would reach ~91, or **2.9%**. So many-moon planets do
not merely look busy — the planet you drilled into becomes a dot.

**4. The cap silently hides places.** At 59 moons, 35 get no model entry at all.
The cap is also unstable: a moon acquiring salvage promotes past it, re-runs
`spacedLayout`, and shifts every other moon's orbit.

**Diagnosis.** One visual channel — a distinct ring plus a near-uniform sphere —
carries 59 items of near-zero individual importance, at a radial cost linear in
roster size against a fixed screen budget.

### A second, separate defect found during design

`orrery_ring_vertex` builds the ring plane from the body's **full** reported
obliquity, correctly placing rings in the equatorial plane. Regular satellites
occupy that *same* plane. Moon orbits are currently strictly planar
(`OrreryLayout.radial` returns y = 0). So a ringed, tilted planet asserts two
mutually exclusive things about one plane — visible on SOL-6 as rings at 26.7°
with moons flat around them.

This is not rare in the way rings are. Only 3 of 77 known planets have rings,
but **19 of 21 moon-hosting planets have a plane tilt over 10°**, and 21 of 21
have tilt data. Since the surface already tilts with the true pole (bands,
polar hoods, ice caps), a flat moon plane mismatches the *surface* on 19
planets, not just the rings on 2.

The two problems coincide at the worst case: POLARISON-6 has 59 moons **and**
66.1° of tilt.

| planet | tilt | moons | rings |
| --- | --- | --- | --- |
| POLARISON-6 | 66.1° | 59 | no |
| ALASII-4 | 20.7° | 48 | no |
| ABEEMIM-6 | 33.8° | 26 | no |
| ASTELLIO-2 | 27.4° | 24 | no |
| POLARISON-5 | 62.3° | 10 | no |
| SOL-6 | 26.73° | 7 | **yes** |
| SOL-7 | 97.77° | 3 | **yes** |

## Goals

- Body-level orrery reads clearly from 1 to 60+ moons.
- Every moon remains addressable; nothing is silently dropped.
- The drilled planet keeps visual presence regardless of roster size.
- Missing physical data degrades gracefully, and late-arriving data does not
  reshuffle the scene.
- Rings, surface, and moon orbits agree about the body's equatorial plane.

## Non-goals

- Mesh-based asteroid geometry. Irregularity is achieved analytically in the
  existing impostor pass.
- Physically accurate moon distances or inclinations. Consistent with
  `orrery-layout-tuning`, comprehensibility beats literal accuracy.
- Changing system-level planet layout, except as a consequence of the shared
  pole (below).
- A Preferences UI for the new knobs (deferred; see §5).

## Design

### 1. Tiering: promoted moons and the swarm

A moon is **promoted** — own orbit ring, lit impostor, label, pickable in 3D —
when any of:

- `moonIsInteresting` is true (device / live salvage / mining site / inventory).
  Rare: 2 of 59 on POLARISON-6.
- It is among the top **K = 4** by known `radiusEarth`, subject to a relative
  floor: a moon must be at least **0.5×** the largest known radius to qualify,
  so a roster of similarly-sized moons does not promote four arbitrarily.
- **The roster has ≤ 8 moons**, in which case every moon is promoted.

That last clause is the compatibility guarantee. Of 77 known planets, 56 have no
moons and all but five have ≤ 12, so the swarm is an exceptional mode. For a
roster of ≤ 8 the output must be **identical** to today's, which is asserted by
test.

With no radius data nothing is promoted on size — correct, because we genuinely
do not know which moons are major. POLARISON-6 promotes only its 2 interesting
moons and sends 57 to the swarm.

**Safety property.** Everything that needs an exact anchor is promoted by
construction: devices, sites, salvage, and inventory all flow through
`moonIsInteresting`. No swarm member can host something
`OrreryLayout.anchor(ofLocation:)` must resolve exactly. This is what makes the
swarm's coarser treatment safe, and it is asserted by test.

`maxMoons` is removed. Every moon gets a model entry.

### 2. The swarm: one annulus, emergent structure

Non-promoted moons render as small specks inside a **single** annulus — not one
band per group. Its inner edge clears the outermost promoted moon (or the
planet's ring clearance when nothing is promoted); its outer edge is a fixed
fraction of the frame budget.

**The band's radial extent is derived from roster size and frame budget, never
from its members' positions.** This is the rule that makes late-arriving data
harmless: the band never moves, and individual moons settle into their true
radius within it as scans land. Scanning visibly resolves the cloud instead of
reshuffling the scene.

Placement within the band:

- **Radius** — real `orbitalDistanceKm`, sqrt-compressed and mapped into the
  band's range, when known. Otherwise a stable FNV-1a hash of the designation,
  anchored to the moon's index fraction — so index order still shows through on
  generated systems, where index *is* orbital order (verified: ASTELLIO-1 and
  ABEEMIM-6 are strictly monotonic; SOL-5, being hand-authored real data, is
  grouped by family instead, which the compression handles anyway).
- **Phase** — the existing `OrreryMapping.phaseDeg(designation)`.
- **Inclination** — a seeded scatter off the equatorial plane. Promoted moons sit
  exactly in the plane; swarm members scatter, and captured asteroids scatter
  widest. This is the strongest "cloud of rocks" cue, is physically right for
  irregular satellites, and doubles as visual de-overlap. It is a departure from
  the strictly planar orrery, so the spread is a single constant that can be
  zeroed.

Real structure emerges for free. SOL-5's genuine two-family gap
(128,000–1,882,700 km, then 7,154,000–23,624,000) falls out of the compression
with no clustering code; missing data degrades to an even scatter. One
mechanism, both ends.

**Rendering.** Swarm members go through the **existing belt point pass** —
cheap, additive, already built — tinted by `moonColor(type:)`. No per-moon
rings. One very faint annulus fill defines the region, reusing
`OrreryGeometry.habitableZoneFill`'s triangle-annulus construction.

**Motion.** Real `orbitalPeriodHours` where known, else a Kepler-ish period from
the band radius, so the band shows differential rotation rather than turning
rigidly.

### 3. Size and shape honesty

- Widen `moonSizeFraction` to span roughly **0.03 … 0.30**, so a 0.0004 R⊕ rock
  is a mote and a 0.4 R⊕ moon is a world.
- **Move the unscanned default to the low end** of that range. It currently sits
  mid-range and out-sizes most known moons.
- Legibility moves to overlays with a minimum *screen* size (via the existing
  `LabelEngine`), not to inflated bodies. Promoted moons get labels and pips;
  swarm members get none — they are texture.
- **Irregular impostor**, in the body fragment shader, applied to bodies whose
  `type` is `Captured Asteroid` (and optionally to very small radii): one 3D
  noise sample in body space used twice — displacing the hit radius for the
  shading normal, and alpha-cutting the silhouette against the same field at the
  grazing direction. Because both come from one sample, the lumpy outline and
  the lumpy terminator agree, which is what sells it. No loop. Combined with
  **normal quantization** to ~20 icosahedral axes for a faceted read, which is
  the strongest cue at small sizes.
- **Tumble.** Captured asteroids use a seed-derived tumble axis rather than
  `BodySpin`'s pole; irregular satellites are largely non-principal-axis
  rotators, and these moons report no pole anyway. Motion sells "captured rock"
  harder than silhouette does.

The impostor applies to the body pass only. Swarm specks stay on the belt point
pass until they cross a screen-size threshold on zoom-in, which bounds the
shader cost.

### 4. Coupled orbital plane, with compressed obliquity

Rings, surface, and regular moons must share one plane. The requirement is
**coupling**, not tilt — once coupled, the dissonance disappears at any tilt
value, leaving the choice of value as a pure usability question.

`TurntableCamera` defaults to 0.5 rad (~29°) elevation and clamps at ±80°.
Against SOL-7's 97.77° obliquity the shared plane sits near-perpendicular to the
orbital plane, so at default framing every orbit collapses toward a line. So the
range is compressed, exactly as `BodySpin.spinRate` already compresses a 588×
rotation-period spread:

```
m  = min(θ, 180 − θ)          // true plane-tilt magnitude, 0…90
m' = saturate(m)              // identity below ~30°, asymptotic to moonPlaneTiltCap
θ' = θ ≤ 90 ? m' : 180 − m'
```

| body | θ | θ' | plane reads |
| --- | --- | --- | --- |
| SOL-5 Jupiter | 3.13° | 3.13° | unchanged |
| SOL-6 Saturn | 26.73° | 26.73° | **unchanged** |
| SOL-2 Venus | 177.4° | 177.4° | **unchanged** |
| SOL-7 Uranus | 97.77° | 142.2° | 38° rather than 82° |

Only extremes move; Saturn, the case that prompted this, is untouched.

**The `θ ≤ 90` branch is load-bearing.** The `orrery-physical-fidelity` note is
explicit that retrograde falls out of the pole tipping below the orbital plane
and that `BodySpin.sign` must not also flip, or the two cancel. Folding Venus's
177.4° down to 2.6° would put its pole back above the plane and silently make it
prograde — that exact bug. This formulation **never crosses 90°**, so the
hemisphere is preserved structurally and no paired sign flip is needed. Any
future edit here must preserve that property.

**One pole, not two.** The compression lives inside `BodySpin` as the single
pole every consumer reads — surface texturing frame, ring plane, moon plane.
Keeping the true pole for the surface while compressing rings and moons would
merely relocate the dissonance to bands-vs-rings on the same body, which is more
visible. One source of truth makes two planes disagreeing structurally
impossible. `isRetrograde` and the dossier label continue to read the true
reported values.

This is the one part of the design that reaches beyond body level: the shared
pole also affects system-level ringed and tilted planets.

### 5. Two knobs

Distinct, and not interchangeable:

- **`moonPlaneTiltCap`** — degrees, default **38**. How much obliquity the
  coupled plane expresses. 0 flattens rings *too*, since everything reads one
  pole; 90 is fully physical.
- **`decoupleMoonPlane`** — bool, default **off**. Moons ignore the pole and
  stay in the orbital plane while rings keep it. This reproduces today's look
  and is the requested escape hatch.

Both are `@Shared(.appStorage(...))` values, following the pattern already used
for `activeReplicantCode` in `NewStarMapFeature`. They are read at the mapping
layer and passed *into* `BodySpin` as parameters, so `BodySpin` itself stays a
pure value with no dependency on storage — which is what keeps the compression
unit-testable against the §4 table.

**No Preferences UI initially** — `decoupleMoonPlane` is promoted into the
AccountFeature Settings sheet only if it turns out to be toggled in practice.

### 6. The Moons roster becomes the interaction surface

Swarm members are deliberately **not** individually pickable in 3D: at a few
pixels, clicking the right one of 57 near-identical bodies is frustrating even
when it works, and a list can carry names, types, and scan state that a speck
cannot.

`bodiesCard` at body level is today a plain `ForEach(model.planets)` — no
scroll, no height cap, and rows are static (the drill-in `Button` is
`isBody`-gated off). At 59 moons it overflows the window and offers no way to
select a moon. It becomes:

- Scrollable, with a capped max height.
- Rows selectable, driving the existing `pickedLocation` → location dossier,
  which already resolves moons.
- Grouped promoted-then-swarm, with counts in the section headers.
- Selecting a swarm row places a highlight reticle at that moon's live
  `OrreryLayout` position.

Selection flows list → 3D. That is what makes "not individually pickable"
a design choice rather than a gap.

## Components and boundaries

| Unit | Change |
| --- | --- |
| `OrreryMapping.bodyModel` | Tiering split, band placement; `maxMoons` removed |
| `OrreryMapping.moonSizeFraction` | Widened range, low unscanned default |
| `SystemModel` | Gains a separate `swarm` collection (see below) |
| `OrreryLayout` | Swarm position lookup; timing anchor folds in the swarm |
| `BodySpin` | Obliquity compression + the two knobs; single shared pole |
| `OrreryGeometry` | Swarm point vertices; faint annulus fill |
| `Orrery.metal` | Irregular impostor branch in the body fragment shader |
| `NewStarMapView.bodiesCard` | Scrollable, grouped, selectable roster |

**Why a separate `swarm` collection rather than a tier flag on `OrreryPlanet`.**
It makes the exclusions structural instead of conditional: `scaffoldLines`
iterates `planets` to emit rings, so swarm members get no ring automatically;
picking iterates `planets`, so they are excluded automatically. A flag would
require every consumer to remember to check it.

**The one thing this breaks.** `OrreryLayout.minPeriodDays` anchors on-screen
timing over `model.planets`. With the swarm split out it must fold the swarm in,
or swarm speeds are computed against a different anchor than promoted moons and
the two populations visibly disagree.

## Testing

`OrreryTests` covers the pure layout well. The crisp regression:

- **`frameScene` is O(1) in moon count.** 59 moons must frame comparably to 8;
  today 59 would push it to ~91 scene units and the drilled planet to 2.9% of
  the frame radius.
- **Small rosters are unchanged.** A ≤ 8-moon roster produces byte-identical
  output to the current implementation.
- **Promotion rules.** Interesting moons always promote; size promotion honors
  K and the relative floor; no radius data promotes nothing on size.
- **Anchor safety.** No swarm member satisfies `moonIsInteresting`.
- **Band stability.** A moon gaining `orbitalDistanceKm` moves only itself —
  the band's edges and every other moon's position are unchanged.
- **Obliquity compression.** The table in §4 reproduced exactly, plus the
  invariant that `θ'` never crosses 90° when `θ` does not, so retrograde
  survives (mirrors the existing `bodyFrameIsRightHanded` approach of asserting
  a geometric property on the CPU).

## Risks

- **Shader work cannot be visually verified from a background job.** The
  Keychain login wall blocks launching a scratch build (see
  `no-gui-verification-from-bg-jobs`). Two defects slipped through this gap
  during the physical-fidelity work. The irregular impostor, the tumble, and the
  inclination scatter all need the user's eyes.
- **Inclination scatter** is a departure from the planar orrery. Mitigated by
  keeping the spread a single zeroable constant.
- **The shared pole reaches system level**, affecting ringed and tilted planets
  outside the body view. Intended, but wider than "the moon situation".
- **The obliquity fold is the kind of change that silently double-counts
  retrograde.** The `θ ≤ 90` invariant is the guard, and it is asserted by test.

## Phasing

1. **Tiering, band layout, roster card.** Pure Swift, fully testable, no shader
   risk. Delivers most of the readability win.
2. **Size honesty.** Small and pure.
3. **Coupled plane + compressed obliquity + both knobs.** Touches `BodySpin`,
   rings, and the surface frame; needs a visual pass.
4. **Irregular impostor + tumble.** Shader work; needs a visual pass.

Phases 1–2 are independently shippable and carry no visual-verification risk.
