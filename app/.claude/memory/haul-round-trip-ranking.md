# Haul ranks by round-trip time, not raw units

`HaulTargetPlanner.roundTripRank(_:units:)` ranks candidate piles by
`units / (2 × distance(pile.system, deliverySystem) × secondsPerLy)` —
richest-per-round-trip-second first, designation breaking ties for a total
order. Same-system piles rank `.infinity` (always outrank an interstellar
pile, stay on the `shuttle` path). This replaced a flat raw-unit sort
(`lhs.value > rhs.value`) once a component/position filter made a pile's
distance from the delivery sink knowable at rank time.

`HaulTargetPlanner.secondsPerLy = 30` is **still uncalibrated** — a starting
figure, not a measurement. [[travel-is-cheap-vs-survey]]'s observations
(1–3 min typical, 467 s worst-case) are the nearest real data, but they were
never fit to this specific formula; measure against real ferry legs before
trusting the ranking's ordering near a tie.

**The raw-units order is the fallback**, not a separate mode: when either
system's position is missing from the census, `roundTripRank` returns
`Double(units)` directly for that one candidate — a per-candidate degrade so
a census hole never drops a real pile from the ranking, not a global switch
back to unit-only sorting.
