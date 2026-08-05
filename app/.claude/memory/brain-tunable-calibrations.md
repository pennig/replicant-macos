---
name: brain-tunable-calibrations
description: "The arithmetic behind the automation brain's two hand-tuned constants — Brain.reclaimRangeLY (2 relay hops / 15 ly, the reclaim-vs-print detour cutoff, closing brain-tendmesh-worthiness's deferred 'build-time distance cutoff') and Brain.retryBudget (3 auto-retries per stall episode). Both were calibrated at build time against measured live figures and neither derivation was recorded anywhere but the source comments; this note is where a re-calibration starts. The third brain rail constant, BrainCeiling.aggregateSpendFloor, has its own note."
metadata:
  type: project
---

# The brain's tunable constants, and the arithmetic behind each

Two constants in `Brain.swift` are hand-tuned numbers rather than derivations of
something else. Their calibration arguments lived only in source comments until
this note; the comments now carry the *rules* the constants must satisfy, and
the *numbers* live here. See [[brain-relay-reserve-floor]] for the third
(`BrainCeiling.reserveRelays` — `K` = 5, the one knob on that type, marked
`// CALIBRATE`), which already has its own record. Note that
`BrainCeiling.aggregateSpendFloor` (35,078) is NOT a fourth hand-tuned constant:
it is DERIVED from `K` and the reference hub mix, and moves whenever `K` does.

## `Brain.reclaimRangeLY` = `2 * SalvageTargetPlanner.relayRangeLY` = 15 ly

**This closes the deferral at [[brain-tendmesh-worthiness]]**, whose PRUNE
section makes print the fallback when there is "no useless relay reachably close
(**build-time distance cutoff**)" and leaves the cutoff to the build. This is
that cutoff, and the reasoning it was chosen by.

How far off its road the brain will send a carrier to fetch a spare relay it
could otherwise print.

### Measured from the plant site, not the hub — the part that IS in source

Print flies `hub → target`; reclaim flies `hub → source → target`. The extra
distance is `d(hub,source) + d(source,target) − d(hub,target)`, which the
triangle inequality bounds by `2 · d(source,target)` **regardless of where the
hub happens to be**. One number about the source and the target therefore caps
the whole detour, where a cutoff measured from the hub would cap nothing. The
surviving comment on the constant states this; it is the rule a caller can
violate, so it stayed in the code.

### Why two hops and not some other number — the part that was ONLY in git

What a reclaim **buys** is fixed and known: the entire 370-unit relay bill
(`carbon 20, silicates 100, structural 80, rares 40, conductive 120,
volatiles 10` — 370 TOTAL across six types, never 370 per type) and the ~800 s
print that spends it. What it **costs** grows with distance: at most `2 · d` of
extra travel, plus a deactivate/stow round the print path does not pay.

**The time side.** The fastest read available on travel is the live one
([[travel-is-cheap-vs-survey]]): ETAs of 1–3 minutes, **467 s the worst
observed**, over a mesh whose own extent is ~16 ly — call it **~30 s/ly at the
pessimistic end**. At `d = 15` the detour bound is **30 ly ≈ 870 s**, the same
order as the **800 s print it replaces**. Past that the time cost keeps growing
while the saving stays fixed, so 15 ly is where the trade stops being clearly
favourable. The bound is pessimistic twice over: the factor of two is only
attained when the source lies directly *behind* the carrier.

**The resource side breaks the tie in reclaim's favour**, which is why 15 rather
than something tighter. `BrainCeiling.aggregateSpendFloor` sits at **~47% of the
live hub's total stock** ([[brain-relay-reserve-floor]]), so units are the
scarcer half of the bill by some margin; a reclaim costing a few extra minutes
and no units is a good trade almost everywhere inside this range.

**Stated in the graph's own unit** (`SalvageTargetPlanner.relayRangeLY` = 7.5)
rather than as a bare `15.0`, because one relay hop is the only length scale the
subsystem has — two hops is "in the same neighbourhood as the plant site" said
in the vocabulary the mesh is built from, and it keeps the cutoff meaningful if
the range ever changes.

**Sanity check against being dead code or effectively unbounded:** the live
15-relay mesh fits inside a ~16 ly ball, so 15 ly is roughly "anywhere on
today's mesh" — the cutoff bites only once the mesh outgrows that.

### If you re-calibrate

Re-measure travel first — [[travel-is-cheap-vs-survey]] explicitly warns against
extrapolating its ~20 ly evidence to 40+ ly hops, and `Device` carries no
speed/range column to fit a curve from. The two numbers this trade turns on are
the per-ly travel cost and the print duration; if either moves by more than
about a factor of two, the 15 ly answer moves with it. Pinned by
`BrainReclaimSourcingTests` (`== 15.0` and `== 2 * relayRangeLY`).

## `Brain.retryBudget` = 3

How many auto-retries the brain spends on ONE stall episode before leaving the
run for a human. The **upper** bound's argument survives in source (three
re-evaluations spread over `retryInterval` each is structural rather than
transient evidence, and retrying past that pays forever on a run that will never
self-correct while holding its carrier out of the fleet). The **lower** bound's
argument did not, and is recorded here:

- **Attempt 1** covers a genuine one-off — a lost write, a governor deferral, a
  row the sync had not reached.
- **Attempt 2** covers a slow-but-real recovery: a confirm-read landing, a
  census refresh arriving.
- **Why not 1:** escalation spends the operator's attention, the scarcest
  resource in the system, and a budget of one spends it on every transient the
  second attempt would have cleared silently.

Each attempt costs at most one API-driving evaluation (a `.high` confirm-read, a
census refresh, or a re-issued command), so the number is a direct budget of
live-API spend per stalled directive per episode. With `retryInterval` at 15
minutes the three attempts land at roughly t, t+15 and t+30 (the first is
unspaced — at the first stall there is no `.resolved` entry to measure from),
and escalation follows the third. **The fuse to escalation is therefore ~30
minutes, not ~45.** `Brain.stallResponse` tests `episode.attempts < retryBudget`
BEFORE the `retryInterval` wait, so once the third attempt is spent escalation
lands on the very next tick rather than one more interval later; `Brain.swift`'s
own doc on `retryInterval` agrees ("`retryBudget` attempts span ~30 minutes").
The easy way to get this wrong is to count the first attempt as spaced, which
inflates the fuse to ~45 min; [[brain-tendmesh-build]]'s clause-6 row made exactly
that error and is corrected. The clause's real point, that the fuse lengthens but
does not close the carrier hold, is unaffected either way.

Related: [[brain-tendmesh-worthiness]], [[brain-relay-reserve-floor]],
[[brain-tendmesh-build]], [[travel-is-cheap-vs-survey]], [[brain-executor-seam]].
