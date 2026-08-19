A step that loops over a FLEET must dispatch each leg at its own step
(`confirmStep: nil`). A dispatch is a `return`, so naming a confirm step ends
the loop on the first subject that needs a command and every later one is
silently never ordered.

`EventRun.departing` had it both ways: the carrier's `TravelTo` passed
`confirmStep: nil` (the same-step loop, guarded by the tracked travel op) while
the freighter loop passed `confirmStep: Step.confirmingArrival.rawValue`. With
one freighter the two are indistinguishable — the sole hull is also the last —
so the shape survived until [[stall-triage-2026-08-19]] §4 made the lease a
list.

The failure is a permanent stall, not a slow one. `confirmArrival` requires
`[carrier] + freighters` ALL placed, so a hull that was never ordered can never
satisfy it, and the run spends `arrivalConfirmDeadline` and reports
`.vesselPositionUnconfirmed` — a reason naming no vessel, on a hull sitting at
the depot it started from. Retry re-enters the same confirm step and re-stalls;
cancelling relaunches into the same trap. The tell is the `operations` table:
one travel op per hull is expected, and the stalled run had orders for the
carrier and the lead freighter only.

Fixed by making the freighter loop match the carrier's leg, so the step ends
only at the loop's trailing `.advanceStep`. `EventRunMultiFreighterTests`
pins it by walking `departing` the way the executor does — dispatch, place that
hull, re-enter only while the dispatch still names this step — and asserting
every hull carries an order before `confirmingArrival`. A per-leg assertion
alone does not catch this; the walk is what models the hand-off.

`departing` is the only step in the engine that loops over hulls returning a
dispatch mid-loop. The other multi-hull steps are round-counted instead —
`staging` indexes `plan[rounds]` off `MissionLogBudget.dispatchRounds` and hands
to `confirmingStage`, which comes BACK to `staging`. That is the distinction
worth carrying: a confirm step is safe when the confirm returns to the dispatch
step, and fatal when it moves the run forward, because then the dispatch step
gets exactly one pass.
