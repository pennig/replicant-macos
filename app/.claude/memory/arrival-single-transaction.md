Directives-architecture ticket 04, 2026-08-16: closed two long-standing defects
in the arrival path, both previously recorded in
[[confirm-steps-need-fresh-evidence]]'s "still unfixed" door.

**Defect 1 — two transactions, one fact.** `GameSync.deviceRoute` used to close
the op (`Reconciler.applyOperationEvent`) and patch `device.location`
(`Reconciler.applyEventFields`) as two separate `database.write`s with an
`await` between them (the print.completed clone read). A directive tick landing
in that gap read "op closed, old location" and re-commanded travel — five
recorded incidents (`582d10b`, `5a4fd77`). Fixed by `Reconciler.applyDeviceEvent`,
which closes the op and patches the row inside ONE `database.write`; `deviceRoute`
now calls it once, and the print.completed clone read + post-close `.high` read
sit after it, unchanged.

**Why the op-closing patch is unconditional.** When the event closed an
operation, its envelope location is authoritative for the action that just
finished, regardless of how `device.updatedAt` compares — that ordering-vs-truth
conflict is exactly defect 1. Only the NON-closing path (no op to vouch for the
event) keeps the last-writer-wins tolerance guard; the two branches are
deliberately different rules, not one rule applied twice.

**Defect 2 — the same-second drop.** `applyEventFields`'s old guard,
`eventTime >= device.updatedAt`, compared a second-granular server `createdAt`
against a sub-second local `updatedAt`: a read issued later in the same wall-clock
second as the arrival stamped a `updatedAt` the arrival's own `eventTime` could
never beat, so the location write was silently dropped even though the op still
closed (row reads "fresh but wrong"). Fixed by widening the non-closing guard to
`eventTime + 1s >= device.updatedAt`. Applied identically inside `applyEventFields`
itself, so the poll path and the stream path use the same tolerance.

**The stamp is the client clock.** Every successful patch — closing or not —
now sets `device.updatedAt = date.now`, never `eventTime`: an event is an
observation, not authoritative time, and every other mission watermark in this
system (`stepStartedAt`, `lastConfirmedAt`) is already client-clock. This also
retires the old `min(eventTime, date.now)` future-clock clamp in
`applyEventFields` — stamping `date.now` directly can never land in the future
relative to itself.

**The classification is shared, not copied.** Both `applyOperationEvent` (poll
path unaffected) and `applyDeviceEvent` resolve which op kinds an event may
close through one private `Reconciler.completionPlan(for:)`, so the taxonomy in
`completionEvents` has exactly one reader-facing entry point.

See [[confirm-steps-need-fresh-evidence]]'s half three for the incident that
first exposed defect 1, and [[haul-run-design]] / [[salvage-run-design]] for the
missions it stalled.
