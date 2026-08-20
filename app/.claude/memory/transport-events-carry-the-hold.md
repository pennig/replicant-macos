---
name: transport-events-carry-the-hold
description: `transport.collected`/`transport.delivered` are the only events reporting a hold's contents, and until they patched the row a freighter re-ordered a collect it had already placed. Why the patch sits in applyDeviceEvent and why `resources` must never become `cargo`.
---

# Transport events carry the hold

`cargo_after` is the total aboard once the move settled — exactly what
`detail.cargo_used` means — and `transport.collected` / `transport.delivered`
are the ONLY two events that carry it. `Reconciler.cargoReportEvents` keys
them, and `applyDeviceEvent` folds the value into the device row in the same
transaction as the location/stow patch.

**The stall this closed.** `detail.cargo_used` otherwise had exactly one
writer — a full device read — and it is the only evidence that a
`collect_resources` landed. That verb opens no `Operation`, so
`EventRun.loading`'s duplicate guard is `Device.cargoUsed == 0` and nothing
else; `world.openOperation(for:)` beside it is structurally nil, the same shape
as [[same-step-dispatch-needs-tracked-op]]. Between a collect settling and the
next confirm-read the row still said "empty", so the step re-cut the same share
and re-sent it. The share is identical by construction: the outbound divider
measures `wholeHold` (capacity, not free space) precisely so a mid-load
recompute names the same number — see [[event-convoy-has-no-singular]]. The
server refused the second order, the run stalled `.commandRejected`, and it sat
there until the brain's 15-minute `retryInterval` outlived the staleness drain.
Four runs over three days, ~10% of event runs; the signature in the log is that
the amount requested exactly equals the amount already aboard.

Live evidence: the event arrived ~300ms after the collect, and **166 of 166**
`transport.collected` rows had matched no route. `deviceRoute` matches `.all`,
so these events always reached `applyDeviceEvent` — they just wrote nothing.

**`resources` is a delta and must never become `cargo`.** The payload's
`resources` block names what THIS move carried, not what the hold now holds.
Folding it into `detail.cargo` would put a delta where a total belongs. The
stacks stay the confirm-read's business; `cargo_used` alone answers "is there
room", and it is the only field the load guard reads.

**The patch sits BELOW the `!closed` tolerance guard**, deliberately. Catch-up
replays hundreds of events at launch, so a report can arrive long after a full
read settled the row — the newer read must win, or a replay walks the hold
backwards. Same lesson as [[confirm-steps-need-fresh-evidence]].

Pinned by `ReconcilerCargoEventTests`, all five proved by mutation.

## Still open: the duplicate order is narrowed, not closed

This patch shortens the blind window from "until the next full device read"
(15 minutes, observed) to "until the report arrives" (296ms, observed). It does
not make the duplicate impossible. A `transport.collected` delayed past the
tick interval — roughly 5s, the gap between `loading` re-entries in the live
log — and `EventRun.loading` re-orders exactly as before, because the row still
reads `cargoUsed == 0` and the second guard beside it is `world.openOperation(
for:)`, which is structurally nil.

**The structural fix is to give `collect_resources` a tracked `Operation`,** so
that guard becomes real and a dispatched-but-unconfirmed collect blocks the
next one on its own evidence rather than on a field the server has to tell us
about. Same remedy as [[same-step-dispatch-needs-tracked-op]] prescribes for
`.simple` verbs generally.

**Why it was not done in the same change.** `confirmLoad` is built on the
opposite premise, and says so: `attach` and `collect_resources` are immediate,
so no op is ever open and the loop's bound is a ROUND COUNT
(`MissionLogBudget.dispatchRounds`) rather than an op. Introducing an op means
re-deriving that bound and the `ConfirmRow` ladder beneath it, and `attach`
shares the shape, so it is one change to two verbs and three steps — not a
patch. Weigh it against the residual before starting: post-fix, the window is
sub-second and needs a stream stall to bite.

**How to know it recurred.** The signature is a `loading` stall whose requested
amount exactly EQUALS the amount already aboard — the outbound divider cuts
from capacity, so a recompute names the same number:

```sql
SELECT substr(directiveID,1,8), step, occurredAt, detail
FROM directiveLogEntries WHERE detail LIKE '%cargo capacity%'
ORDER BY occurredAt DESC;
```

`have N, requesting N` is this bug. `have 0, requesting M` where M exceeds the
convoy is the different, already-fixed payload-too-large case in
[[stall-triage-2026-08-19]]. If `have N, requesting N` appears again, check
first whether the `transport.collected` arrived at all (`eventLogs`, keyed on
the freighter) — a missing report is a routing regression in this note's fix,
while a report that arrived and was still too late is the case that finally
earns the tracked op.
