# The evaluation writes only the columns it decided

`DirectiveExecutor` holds a `Directive` value read at TICK time and writes it
back much later, outside any transaction that re-reads the row. Anything else
that changed the row in between — an operator's Pause, Cancel or Skip — is in
that value's stale copy of every column it does not own. A whole-row
`Directive.upsert` therefore did not delay a pause, it destroyed it: the
operator had to apply it twice before it stuck, with nothing on screen saying
why.

The operator's own write path (`DirectiveResolutionClient.apply`) has never had
this problem: it fetches, mutates and writes inside ONE transaction, so it is a
real read-modify-write. Only the evaluation side carries a stale value across a
transaction boundary, and only it needs this rule.

## The column sets

Disjoint apart from `updatedAt`, and exhaustive — every `updated.<column> =` in
the engine and executor is in one of them:

| Set | Columns | Written by |
| --- | --- | --- |
| progress | `step`, `stepStartedAt`, `targetIndex`, `controllerCode`, `claimedRelayCode`, `botCodes`, `updatedAt` | `DirectiveExecutor.commit` |
| lifecycle | `status`, `attentionReason`, `updatedAt` | `DirectiveExecutor.commitLifecycle` |
| queue | `targets`, `updatedAt` | `DirectiveEngine.resolveExtendQueue` |

Adding a column an action mutates means adding it to the matching set. A column
the executor never assigns must NOT be listed: `targets`, `freighterCodes`,
`deletedAt`, `theatreDepot`, `roamCentre`, `fleetTag`, `sourceRelayCode`,
`deviceCode`, `kind`, `returnToOrigin`, `originDesignation`, `createdAt` are all
owned by someone else, and the old whole-row upsert was clobbering them too.

## Progress is unconditional, lifecycle is compare-and-set

A progress write must land even on a paused row, and this is the part that looks
wrong until you follow it through. By the time `commit` runs, the dispatch has
already reached the server — `commandGovernor.dispatchOwned` returned
`.accepted(operationID)`. The step advance is not a plan, it is the record of
something that HAPPENED. Refuse it and the local row still names the old step,
so a resumed run re-dispatches; for the four `nonRetryableKinds` (`print`,
`dequeuePrint`, `collectResources`, `depositResources`) that is a duplicate
print or a double withdrawal. Recording reality on a paused row is strictly
safer than refusing it, and the pause still holds because `status` was never in
the statement.

`botCodes` is progress for the same reason: an enrolment records that a bot is
about to leave the hull, and losing it on a paused row would leave the run owing
a recovery it has no record of ([[bot-roster-departure-gate]]).

`commitLifecycle` is the opposite case and takes `WHERE status = 'running'`.
`.needsAttention` and `.completed` are decisions ABOUT the run, made from a row
that said `running`; if the operator has since said otherwise, the decision is
moot and the row is theirs. Both refusals self-heal: the executor retires, and a
resumed run re-evaluates and reaches the same action from the same world.

## A refused lifecycle write takes its log entries with it

The whole transaction is abandoned, `.stalled` and `.directiveCompleted` rows
included. Not a nicety — `SurveyRun.completionSeen` and `SalvageRun` decide a
step is finished by looking for a `.directiveCompleted` entry inside the current
step window. A completion entry landing without the row transition behind it
would let a resumed run treat a step as complete on evidence the engine itself
refused to write. The diagnostic value is not lost either: the re-evaluation
after a resume writes the entry then, against a row that accepts it.

The progress path needs no such rule because it is never refused; its entries
land with it always.
