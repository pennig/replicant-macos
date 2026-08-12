# Theatres filter by component inward, rank by distance outward

`WorldView` resolves "which theatre serves this system" two ways, differing
only by one filter, both routed through one shared
`nearestTheatre(to:admits:)`:

- **`theatre(servicing:)`** — inward, a system asking who already owns it.
  Restricted to the SAME mesh component (`components[system] ==
  components[theatre.system]`) before ranking by distance. This is the
  eligibility gate: `HaulTargetPlanner.assignments` and `PrunePredicate` both
  filter candidates through it, since a controller can't ferry to a theatre
  its own component can't FTL-reach.
- **`theatre(nearest:)`** and **`TheatreSiteRanking.rank`** — outward,
  proposing where a NEW theatre should stand. No component filter at all;
  `distanceToNearestTheatre` is a pure score input with a redundancy ceiling
  (`2 × Brain.reclaimRangeLY`). A candidate site 300 ly away in an unreached
  pocket still scores — the ranking's job is to surface it, not hide it.

**The live mesh measured as a single component** (2026-08-11, 205
relaying-relay systems, one component at both 7.5 ly and 15 ly, spanning a
~60 ly ball). So the component filter rejects very little in practice — its
real job is refusing a physically impossible assignment (an unreached
pocket), not routine load-balancing between theatres. Any invariant that
assumes theatres stay disjoint is a bug in this design: the filter exists for
the day a second component appears, not because one exists today.
