An `Operation` row records one dispatched COMMAND, and one `enqueue_print`
carries `quantity: N`. So a bench working a batch has N jobs and exactly one op.
`PrintScheduler` encodes this on both sides — `onOrder`'s `printedQuantity ?? 1`
counts one op as N units, and `depth(of:ops:)` takes `max(snapshot jobs, op
count)` because the snapshot's job count is expected to EXCEED the op count.
Treat "one op per job" as false anywhere it matters.

**What that cost, before 2026-08-20.** The batch's op closes on the first
`print.completed`. When job 2 reaches the platen, `Reconciler.apply` finds no
live print op to promote, so the `else if matchingOp == nil` branch adopts a
fresh row from the device snapshot — and adoption wrote `directiveID: nil`.
Every job after the first was therefore ownerless, and `PrintQueueOwners` (which
selects open print ops and drops any with a nil `directiveID`) could not name
the run behind the job on the platen. The live symptom was an "Ordered by" line
that appeared for a print dispatched onto an idle bench and vanished for one
that had waited in the queue.

Confirmed against the live DB, not inferred: bench `E9F509DE` held an `event`-
sourced op with `directiveID` and `params.quantity = 2` for an `atmo_processor`
completing at 14:05:54, and a `poll`-sourced `active` op with no `directiveID`
for an `atmo_processor` starting at 14:05:55.

**`Reconciler.batchOwner` closes it** by carrying the batch's `directiveID` and
`step` onto the adopted row, and stopping once the bench has run as many jobs as
the batch asked for units. Its four guards each have a test: the batch must be
owned, must have asked for more than one unit, must name the type now on the
platen, and must have started no later than this job.

**The adopted row stays untyped on purpose** — `detail: {}`, no `paramsDigest`.
Two things depend on that and would break if the batch's params were copied
across wholesale: `selectCompletableOp`'s untyped fallback (`Reconciler.swift`)
closes adopted ops that name no device type, and `CommandGovernor`'s de-dup key
includes `paramsDigest`, so a copied digest could suppress a legitimate
re-dispatch.

**An untyped row is not a free zero, and reading it as one over-printed.** This
note used to claim `PrintScheduler.onOrder`'s `printedDeviceType` guard left the
"already on order" tally right. It did not: jobs 2…N read as nothing on order
while `EventRun.missingTree` counts only what STANDS at the depot, so the step
re-ordered its whole shortfall the moment the batch head completed. The signature
is a re-order landing one print-time after the last —
`MAHOSATI-2-EVT-006` wanted four `orbital_farm` and drew orders of 4, then 3,
then 1, at 22:43, 22:58 and 23:13 against a 900 s print. `onOrder` now takes, per
bench, the greater of what its own ops claim and what the bench's own snapshot
reports working — and trusts that snapshot only when every live op there is the
same owner's, because neither the platen block nor a `print_queue` entry names
one.

**Still open: `PrintQueueOwners` answers by bench, not by job.** It returns
every open print op's run title for a device code, and both Print Queue views
render that list as the label for the ACTIVE job. On a bench where a queued job
is owned by a different run, that run's title is attributed to the job on the
platen. The queue snapshot carries no per-job id, so fixing this needs a
different handle than the ops table currently offers.
