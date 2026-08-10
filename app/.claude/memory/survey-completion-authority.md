# Survey completion authority: the controller's verdict, never the counts

The 2026-08-09 live stall: a roaming Survey Run's `awaiting` backstop polled the
target's scan counts on a 10-minute timer, the counts read fully scanned at
01:02, and the run walked its whole wrap-up (`confirming` → `recovering` →
`repairing` → `stowingBots` → next preflight) while the AMI survey controller
was still out — its own `directive.completed` / `device.stowed` arrived at
04:06, three hours later. Preflight for the next target then demanded a stowed
controller, truthfully found none, and stalled `noSurveyControllerAboard` —
which is **`.escalate`-class** (staging is the player's job), so the brain never
retried and the run sat 11.5 h until a manual Retry passed trivially against the
long-since-stowed row. The trap: "the engine has nothing left to dispatch" and
"the AMI is done and home" are different notions of *done*, and counts can read
complete while the controller still has hours of digests left.

Fixed in `04e7891`: `awaitCompletion`'s backstop now judges the claimed
controller's own row — re-stowed aboard the vessel on a row fresher than the
step start ends the wait (also the dropped-frame recovery); otherwise one
throttled controller read per `backstopInterval`. The `directive.completed` log
entry stays the fast path; counts only ever cross-check in `confirming`, which
now stalls `.surveyIncomplete` when the controller is home but counts disagree
(that widened check also closed a pre-existing miss: after the
`refreshSystem` transition re-stamps `stepStartedAt`, `completionSeen` can no
longer see the very event that triggered the transition).

Two reviewed-and-accepted residuals, both conservative halts: (1) a controller
row deleted from the fleet (or stowed in the *wrong* vessel) leaves `awaiting`
in a permanent silent `.wait` — no read, no stall; the operator must notice and
cancel. (2) A seconds-wide race on the freshness anchor
(`stepStartedAt − eventTimeSkewTolerance` vs launch execution) can, combined
with a *second* independent event loss, produce a false `.surveyIncomplete` —
clearable by Retry once any sync corrects the row.
