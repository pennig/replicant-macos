---
name: haul-depots-are-sinks
description: "The 2026-08-16 live loss: the AINALRAM haul run drained the operator's stock out of the newly-pinned SAGARMADHA-2-L4 depot, because `HaulTargetPlanner.assignments` excluded only its OWN delivery sink from the candidate piles. Every theatre's depot is now excluded — a depot is a sink, never a source."
metadata:
  type: project
---

`HaulTargetPlanner.assignments` filtered candidate piles on `units > 0`,
`location != delivery`, and same-mesh-component. The live mesh is a SINGLE
component ([[theatre-component-vs-distance]]), so the only pile any run refused
was its own delivery point. A second theatre's depot was therefore an ordinary
pile — and being a depot, the richest one in reach.

**Measured at the incident**: `theatrePins` held one row, `SAGARMADHA-2-L4`,
pinned 2026-08-16 01:46. Its footprint read `resources = 0` while
`AINALRAM-BELT-1` read 361,195, and the account's one general `haulRun`
(`fleetTag: auto:haul:AINALRAM-BELT-1`) delivers to AINALRAM. The operator had
placed that inventory deliberately; the run ranked it top and ferried it away.

Fixed by a `depots: Set<String>` parameter on `assignments`, defaulted to `[]`
so the pure-function tests are unaffected, with `HaulRun.plans` passing
`Set(world.theatres.map(\.depot))` — **every recognised theatre, not only the
operational ones**. A `.claimed` theatre's stock is still the operator's and may
recover; draining it while it is down is the same loss.

The guard that matters is the ENGINE one, not the planner one: a planner test
handed the right piles proves nothing about whether the run passes them
(the vacuous-regression trap [[haul-run-design]] already records). The first cut
of that engine test **passed against the broken code** — the local pile shared
the delivery SYSTEM, so `roundTripRank` returned `.infinity` and it won on the
same-system rule regardless of the depot filter. The pile must sit in a THIRD
system for the depot's richness to be what decides.

Deliberately not built: depot-to-depot rebalancing. No flow wants it, and
without the exclusion two theatres pull each other's stock back and forth.
