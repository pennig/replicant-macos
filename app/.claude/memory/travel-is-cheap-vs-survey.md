---
name: travel-is-cheap-vs-survey
description: "Measured 2026-07-29: inter-system travel costs 1-3 min (max 467s observed) against survey cycles of tens of minutes, so travel is NOT the bottleneck in survey automation — optimise for coverage, not for route length"
metadata:
  type: reference
---

Measured from the live `operations` table on 2026-07-29, over **826 completed travel operations**:

- Travel ETAs (`completesAt - startedAt`, the server's own estimate) cluster hard: **744 of 826 fall
  in the 1–3 minute band**, 62 under a minute, 26 between 3 and 10 minutes. The **longest observed is
  467 s (~8 min)**.
- `survey_scan` averages **160 s per body** (n=36), and a full-system survey means every planet *and*
  every moon plus the post-survey recall wait.

So a survey cycle runs to **tens of minutes of scanning against a few minutes of flight**. Travel is a
small fraction of the cycle.

**Why this matters:** it inverts the intuition that a routing automation should minimise travel. It
should not — it should maximise *coverage quality*, because the travel it spends doing so is nearly
free. This is the fact that made [[directives-feature]]'s continuous roam affordable: sliding 5-ly
bands cost ~35% more travel than greedy nearest-neighbour (about 1.4 extra ly, ~1 extra minute, per
system surveyed) and in exchange raise the hole-free surveyed radius from 3.9 ly to 16.4 ly.

**Caveat on the ceiling — do not over-extrapolate.** Every hop with evidence behind it is inside the
~20 ly region the fleet has actually been operating. It is NOT established that a 40+ ly hop stays
under 10 minutes, or that ETA is even linear in distance. `Device` carries no speed/range column
(`operationalCapacity` is unrelated), and the travel op's `detail` blob is empty (`{}`), so distance
cannot be recovered from the ledger to fit a curve. If a long-range automation starts feeling slow,
re-measure before assuming this still holds.

Do not read travel duration off `lastConfirmedAt - startedAt`: that is the reconciler's stamp for when
we last *looked*, not when the op closed, and it overstates badly (it put the max at 1227 s). Use
`completesAt`. See [[operations-table-retention]] for what prunes this table (terminal ops older than
7 days), which bounds how far back a re-measurement can reach.
