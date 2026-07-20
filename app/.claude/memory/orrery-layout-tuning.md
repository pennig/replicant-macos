---
name: orrery-layout-tuning
description: "Orrery sizing/orbit model — planets sun-relative, orbits spaced non-overlapping, fidelity over accuracy"
metadata: 
  node_type: memory
  type: project
  originSessionId: e9e492ce-4061-45e3-981a-3fa4b0a99190
---

The NewStarMapFeature orrery (OrreryMapping.swift) sizes and spaces bodies relative to the sun rather than to raw AU, and the user prefers **visual fidelity + comprehensibility over literal radial/size accuracy**.

**How it works:**
- `sunSceneFraction ≈ 0.096` — the star's rendered radius as a fraction of `frameScene`, derived from the renderer's `maxAngularSize`=0.05 / fovy=60° / fit=0.9. Everything anchors to this.
- Planet radius = `sunScene * sizeFraction(planet)` (0.16 terrestrial → 0.42 cap), so planets are always clearly sub-sun and consistent across systems (was frameScene-coupled `displayRadius*orreryScale`, which ballooned planets in compact systems).
- `spacedOrbits()` — greedy non-overlap pass: walk outward from the star (the innermost "body" of radius `sunScene`), each planet keeps its `7√au` radius when it has room else pushed out to clear the previous body + pad. Guarantees no orbit intersects the sun or a neighbor. Replaced the earlier hard `max(raw, sunScene*1.3+r)` floor, which stacked all crowded inner planets on ONE ring (SHERATANON's inner 3 collapsed together).
- Tradeoff accepted: crowded inner planets end up evenly spaced, not proportional to true distance. Deeper levers if ever revisited: the `7√au` compression curve or the sun's apparent size (`maxAngularSize`).
- Moons (`bodyModel`) are index-stepped so they don't stack; central planet = fixed `centralScene=2.6`, moons proportional to it.
- Orbit speed centralized in `orreryOrbitSpeed` (StarFieldRenderer, 1.2 = ~2× slower than old 0.6).

See [[new-star-map-feature]], [[flare-playground]].
