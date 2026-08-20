---
name: event-convoy-has-no-singular
description: EventRun has ONE convoy path — `freighterCodes` is the only lease, `Convoy` exposes no single freighter, and load/sweep share one divider. Restoring any singular form re-opens the drift.
---

# The event convoy has no singular form

`Directive.freighterCodes` is the whole lease. The `freighterCode` mirror, the
`leasedFreighters` accessor and `Convoy.freighter` are gone, and no step may
reintroduce a "lead hull" — a convoy of one is a list of one, walking the same
code as a convoy of three. The physical `freighterCode` COLUMN survives in the
table (append-only migrations) but nothing reads or writes it; treat it as
inert. `addFreighterCodes` already backfilled every row that had one.

Load and sweep share `divide(_:across:room:)`. They differ in exactly two
declared ways and no others:

- **room** — `wholeHold` outbound (capacity; the launch gate leases hulls empty,
  and a share cut from capacity does not move as collections land) versus
  `freeHold` homeward (remaining; a hull comes back carrying what the option did
  not ask for).
- **policy on `unplaced`** — loading stalls via `holdsCannotTake`, sweeping
  leaves the remainder for a Haul Run.

`staging` calls the same `holdsCannotTake` rather than improvising a berth on
`freighters[0]`, so one convoy cannot stall at the depot and improvise at the event.

**The bug this closed:** `depositing` bounded its loop with `laden.count`, which
SHRANK as hulls emptied, so a two-hull convoy ordered the first hold and then
retired the loop with the second still full — and `confirmDeposit` required
EVERY hull empty, so it never handed back and the run stalled `.commandRejected`.
The bound is now the whole convoy and the confirm judges only the hull it
ordered. A loop bound must be read off something that does not move as the loop
runs — the same lesson as [[convoy-legs-fly-abreast]].

Reward sweeping still fills ONE hull, the roomiest. Splitting a reward across
several is unbuilt on purpose: a round-indexed plan cut from free space is not
stable across ticks, since each collect changes the space the next cut reads.
