---
name: brain-stockpile-value
description: "Already-mined units awaiting a Haul Run are a brain value signal on both halves of tendMesh — prune pins the road to them, grow ranks them at ValueTier.stockpile"
metadata:
  node_type: memory
  type: project
---

`WorldView.stockpileUnits` (system → summed units, off `LocationFootprint`
bounded in SQL to `resources > 0`) makes already-extracted resources a value
signal the brain reads. Both halves of `tendMesh` consume it.

**Prune** takes it as a fifth source in `PrunePredicate.servedSystems`, so a
relay standing over a pile is pinned. **Grow** takes it as a sixth
`ValueTier`, `stockpile`, ordered `event ▸ richBelt ▸ moderateBelt ▸
stockpile ▸ salvage ▸ sparseBelt` — above salvage because no mining cycle
stands between the fleet and the units, below every belt because a pile is
finite and a belt never depletes. Magnitude within the tier is summed units,
matching `.salvage`'s definition.

**Why it was needed:** depletion is exactly what PRODUCES a pile, so the two
facts moved in opposite directions at the same instant — a site's assay
dropped out of `salvageUnits` as its units landed on the ground, and the
system went from "live value" to "worth nothing" while holding more
collectable resource than before. Prune then offered up the relay. That
strands the units rather than postponing them: `HaulTargetPlanner` only
issues a `ferry` while BOTH ends sit on the mesh.

**Two decisions worth not re-litigating.** Neither source is bounded to
meshed systems — `liveValueSystems` isn't either, and an unmeshed pile is now
a real grow target, so the hops planted along a chain toward one must not
read as spare mid-build. And there is **no minimum pile size**: a 20-unit
pile is a target even though a relay costs 370 units. Matt chose this
deliberately over a 370-unit floor on 2026-08-06; the ranking key's
cheapness fields (fewest relays, then distance) dominate field 3 entirely, so
a tiny distant pile loses on cost long before its tier is consulted. If
relays start chasing trivial piles, the floor is the knob — put it in
`ValueCatalog.build`, which is pre-pathfinding and so can only compare
against the one-relay bill, never the real chain cost.

See [[brain-tendmesh-worthiness]] for the tier ordering this amends and
[[haul-run-design]] for the `ferry` both-ends-meshed constraint.
