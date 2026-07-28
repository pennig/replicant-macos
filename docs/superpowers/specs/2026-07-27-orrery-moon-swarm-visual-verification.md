# Orrery Many-Moon Rendering — Visual Verification Checklist

Everything in this feature that can be verified without a GPU has been: 220 tests pass and
`xcodebuild` compiles the app target and all five `.metal` shaders. Nothing GPU-side could be
verified in the environment the work was done in (a Keychain login wall blocks running the app),
so the items below are the ones that need eyes before this branch merges to `main`.

Branch: `worktree-orrery-moon-swarm`. Preference knobs are read via `@Shared(.appStorage(...))`,
so set them with `defaults write` and relaunch:

```
defaults write name.pennig.replicould orreryMoonPlaneTiltCapDeg -int 38     # default
defaults write name.pennig.replicould orreryDecoupleMoonPlane -bool NO      # default
```

## 1. Regression baseline — a small roster

Open a planet with ≤8 moons (e.g. `SOL-6`). All moons promote, no swarm band. Layout should look
as it did before **except** moon sizes: the largest moon should now read clearly bigger than the
small ones. The size range widened from 1.49× to ~10.5×, and the unscanned default dropped from
0.14 to 0.045 so an unsurveyed rock no longer out-sizes known moons.

## 2. The headline case — a large roster

Open a planet with 50+ moons (`PETORA-6` has 67 and is the most demanding case in the game;
`POLARISON-6` has 59). Expect a handful of moons carrying their own orbit ring, plus a band of
smaller lit bodies sharing one ring-less band, with the planet still substantial — computed at
~11% of frame radius against 2.9% before this work.

**Swarm members are real sphere impostors, not points.** They are drawn at their honest relative
size scaled down, so a large swarm moon reads large and a captured asteroid reads tiny, and they
grow when you zoom like any other body. Tier is communicated by *having an orbit ring or not*, not
by size — so on PETORA-6 several swarm moons legitimately render larger than promoted
`PETORA-6-22`, which promotes on prebiotic life rather than size.

The scale **ramps with size** rather than being flat: `swarmSizeScaleSmall` (0.5) for asteroid-ish
bodies down to `swarmSizeScaleLarge` (0.3) for the largest, interpolated over the body's own size
fraction. Small bodies were already reading correctly at 0.5, so the ramp leaves them nearly
untouched and pulls the big ones in by roughly a third. The endpoints are absolute constants, never
roster-relative — a moon's drawn size must not change because a *different* moon got scanned.

**Watch for crowding, and note the scatter may now be over-corrected.** Making swarm members visible
surfaced a crowding problem that dimensionless points hid, so `swarmInclinationSpread` was raised
0.12 → 0.30 to push members off the shared plane (regular members reach ~7.2° inclination, captured
ones ~15°). The size ramp then shrank the largest members by about a third, which improved crowding
again on its own: members with an overlap-capable neighbour are now ~39% and the median nearest pair
sits at 1.22× the radius sum — comfortably clear rather than touching.

0.30 turned out to be more off-plane spread than the band needed once the ramp landed, and the
value was tuned down to **0.22** on inspection. If it ever reads as too puffy or diffuse — more
shell than band — go lower; if it reads as a jumble, go higher. Scatter costs ~0.15% of frame
radius per step, where widening the band instead would cost ~17%, so this is the cheap lever. Do
not exceed ~0.40.

**Watch the drill-in specifically.** The band should grow out of the planet in step with the moons
and orbit rings. If it stays bunched near the planet while the moons are already halfway out and
then snaps outward at the end, the reveal is being applied twice. That bug was found and fixed, but
it is invisible at rest and only shows during the transition, so it is worth confirming.

## 3. Rosters with little or no scanned physical data

Now that survey-digest hydration has landed, this should be rarer — but where a roster reports no
moon radii at all, promotion falls back to the innermost `topBySize` moons in roster order (index
order is orbital order in generated systems). Confirm such a planet shows a few ringed moons rather
than an undifferentiated band. Note this fallback also changes those moons' period values, so the
layer's animation speed may differ from before on that roster shape.

Unmeasured swarm members fall back to a default size, so a roster with no radii will render a band
of uniformly-sized bodies — that is the honest presentation of "we do not know", not a bug.

## 4. Zoom back out

The departing orrery layer deliberately draws no swarm, so the band disappears while the moons fade.
This is a documented tradeoff (two layers in one frame would each need their own per-frame-rewritten
buffer). Confirm it does not visibly pop.

## 5. Captured asteroids

Open a planet with captured-asteroid moons (e.g. `SOL-4`, `SOL-8` — both have small rosters, so all
moons promote to impostors). Three things:

- **Orbit the camera and watch one asteroid's outline, not its shading.** The silhouette should keep
  its shape as the camera moves. If the lumps slide or the outline re-cuts, the carve field is being
  sampled in the wrong frame.
- **With the camera still**, the outline should slowly change as the rock tumbles. If the tumble now
  reads as per-frame flicker at these sizes (3–20 px), the amplitude or spin rate wants tuning —
  the shape is inward-only carving, so it should read as chipped rather than jittery.
- **Watch the limb** as a ring annulus or another body passes behind it, for occlusion oddities.
  Depth is written from the geometric normal, not the perturbed one, so this should be stable.

Also confirm the faceted *shading* still looks right — the lighting normal is deliberately still
perturbed, and that is the thing most easily broken by accident.

## 6. The one-plane goal

Open a ringed, tilted planet (e.g. `SOL-6`). Rings, surface banding, and moon orbits should all sit
in **one** plane at the same tilt. This is the change's most visible win and the thing that
originally prompted it — rings at Saturn's tilt with the moons flat around it.

## 7. The tilt cap

**Rendering is fully physical by default** (`orreryMoonPlaneTiltCapDeg = 90`). A planet leans at its
real obliquity: `SOL-7` (Uranus, 97.77°) renders nearly on its side, and its rings and moon plane
follow, because all three share one pole.

The cap remains as an opt-in knob for anyone who finds a high-obliquity system unreadable. At
Uranus's tilt the shared plane sits near-perpendicular to the orbital plane, so from some camera
angles the moon orbits collapse toward a line — that is the tradeoff the compression exists to
soften, and it is now yours to invoke rather than imposed. Sweep it, relaunching each time:

- **90** (default) — fully physical.
- **38** — the old default. Uranus renders at ~142° instead of 97.77°; Saturn's 26.73° is untouched
  either way, since it sits below the compression knee.
- **0** — fully planar. Note this flattens rings too, since they share the pole.

At any setting, orbits **must never reverse direction**. The compression provably never crosses 90°
at any cap, which is what keeps retrograde bodies retrograde, so a reversal would mean something is
wrong. The cap applies at both system and body level, so a planet must not change tilt as you drill
into it.

## 8. The escape hatch

`defaults write name.pennig.replicould orreryDecoupleMoonPlane -bool YES`, then open a tilted ringed
planet: rings stay tilted, moon orbits go flat. This is the hatch for keeping moons planar
regardless of planet tilt.

On a planet with near-zero tilt, toggling this rotates the whole moon system 90° in phase rather
than doing nothing. That is expected and harmless — `phase0Deg` is an arbitrary seed, so no real
orientation information is lost.

## 9. Picking and the roster

Swarm members are deliberately not 3D-pickable — clicking the right one of 60 near-identical bodies
sharing a band is frustrating even when it works. The HUD roster is the interaction surface. Note
that now they render as real bodies at real sizes, this is worth re-judging: a large, clearly
visible swarm moon that cannot be clicked may read as broken rather than as a deliberate tier.
Tell me if it does and I will make them pickable.

- Click a "Minor bodies" roster row and confirm a dossier appears. It shows orbital distance and
  period only when the scan actually reported them, rather than showing a synthesized value as fact.
- Try clicking a *small promoted* moon while it crosses in front of the planet's disc. Widened sizes
  make the smallest promoted moons ~1–2 px, and disc-hit picking resolves frontmost-first, so it may
  not be selectable in 3D. The roster row is the designed fallback — confirm it works.

## 10. Life-bearing moons

A moon with a life stage always promotes out of the swarm, so its `.life` pip can render. The
promotion gate and the pip share one predicate (`OrreryMapping.hasDetectedLife`) specifically so
they cannot disagree. If you can find or arrange a life-bearing moon on a large roster, confirm it
appears as a lit moon with a life pip rather than as an anonymous dot.
