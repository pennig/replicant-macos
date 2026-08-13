The 2026-08-12 final-review fix: `HaulRun`'s own step machine (`preflight`/
`assign`/`plans`) resolved its controller pool via `HaulRun.controllers(in:
WorldSnapshot, tag:)`, which applies `isFleetTagged`'s un-migrated-bare-tag
fallback with no notion of WHICH theatre is asking. With two theatres both
still wearing the bare `auto:haul` tag (the natural state before an operator
re-tags either fleet), run A's per-theatre tag query (`auto:haul:<depotA>`)
and run B's (`auto:haul:<depotB>`) BOTH widen to match every bare-tagged
controller account-wide — so each run's `plans()` contains the other's
controller, `isInForce` reads the sibling's config as not-in-force, and each
repoints the other's cargo every tick with `dispatchAttemptCount` reset by the
ping-pong (never reaching `dispatchAttemptLimit`), an unbounded fight.

Unlike `Brain.haulReadiness` (which already scoped its own candidate pool via
`owningTheatre(of:)` at LAUNCH time, so the initial pick was always correct —
this is a purely ONGOING-evaluation bug), `HaulRun`'s step functions had no
theatre awareness at all. Fixed by adding an optional `theatreDepot:` filter
to the `WorldSnapshot` overload of `controllers(in:tag:)`, applied at all
three internal call sites via the directive's own `directive.theatreDepot`,
scoped through a new `WorldSnapshot.owningTheatre(of:)` (mirrors
`WorldView.owningTheatre(of:)`'s rule off the snapshot's own
`starPositions`/`components`/`theatres`, since a mission never holds a
`WorldView`). `theatreDepot: nil` (the default) preserves the old unscoped
read for every other caller and every pre-existing test.
