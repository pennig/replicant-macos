# Directive soft delete + one-month retention

Clearing finished runs stops destroying them. The Clear button hides them; a
separate one-month clock is what actually removes rows.

## Why

A finished run's row and timeline are the only local record of what the engine
did — the material every incident write-up in `.claude/memory/` was
reconstructed from. Today `clearFinished` destroys both, so the operator's only
way to reduce list noise also destroys the diagnostics. Splitting the two verbs
keeps the quiet list and keeps a month of history.

## What changes

### Schema

One appended migration on `directives`:

    ALTER TABLE "directives" ADD COLUMN "deletedAt" TEXT

registered at the END of `GameDatabase.manifest` (append-only — never folded
into an existing migration). `Directive` gains `deletedAt: Date?`, nil meaning
"visible".

`SchemaManifestTests`'s frozen identifier list grows by exactly one entry, and
the `GoldenSchemaTests` fixture is regenerated with
`RC_REGENERATE_SCHEMA_FIXTURE=1`.

### `DirectiveResolutionClient.clearFinished`

Two operations, one transaction, in this order:

1. **Mark.** `deletedAt = now` on every row whose status is in
   `finishedStatuses` and whose `deletedAt` is null. Log entries untouched.
2. **Purge.** Hard-delete every row whose status is in `finishedStatuses` and
   whose `updatedAt` is older than `purgeWindow` (30 days), together with those
   rows' `directiveLogEntries` — entries first, then the rows, exactly as the
   current implementation orders them, so a half-applied purge cannot leave
   orphan log rows that no query can ever reach.

Both halves stay restricted to `.completed` and `.cancelled`. That is a safety
property, not a filter: `.running`, `.needsAttention` and `.paused` all still
own devices (`Brain.owningStatuses`), so touching one would release its carrier
to the brain mid-flight.

The purge clock ignores the delete mark. A terminal row that finished five
weeks ago is purged on the next Clear whether or not anyone marked it.

**The mark must not write `updatedAt`.** Doing so would restart the purge clock
at delete time, turning "finished over a month ago" into "deleted over a month
ago" — a different retention policy than the one chosen. A test pins this;
a comment would not.

`clearFinished` keeps returning `Int` — the number of rows it *marked*, which is
what the button's label promised. The purge count goes to the log on its own
line. The closure needs `@Dependency(\.date)` for `now`, which it does not
currently resolve.

Its doc comment stops saying the verb deletes.

### UI

`DirectivesFeature.State.directives` becomes:

    @FetchAll(Directive.where { $0.deletedAt.is(nil) }.order { $0.createdAt.desc() }, animation: .default)

`finishedCount` already counts over that array, so the toolbar label follows
with no change. The selection-drop in `clearFinishedTapped` is unchanged: the
row still vanishes from a live query the moment the write commits.

The toolbar button's `help` text changes — it currently promises "Delete
completed and cancelled runs and their timelines", which is no longer what
happens.

No affordance is added for viewing marked rows. Diagnostics come from the
database directly (`.claude/memory/sqlite-db-location.md`).

### Retention

`DirectiveLogRetention.window` goes from 7 days to 30, so a marked run's
timeline and its row age out on the same clock. Its doc comment currently
claims the window matches `OperationRetention.window`; that stops being true.
`OperationRetention` stays at 7 days.

The sweep's open-directive exemption is unchanged. A marked row is terminal, so
its entries are prunable — which is the intent.

## What does not change

Every production reader of `directives` filters to non-terminal statuses
(`Brain.owningStatuses`, `WorldSnapshot`'s `peers`, `DirectiveEngine`'s
`.running` scan, `SidebarView`'s `.needsAttention` count). A marked row is
inert to all of them, exactly as an uncleared completed row is today.

## Tests

- Marking sets `deletedAt` and deletes nothing — the row and its log entries
  are both still readable afterwards.
- Marking leaves `updatedAt` untouched.
- The purge removes a terminal row older than 30 days and its log entries.
- The purge leaves an open row alone however old it is.
- The purge leaves a terminal row younger than 30 days alone.
- A second Clear does not re-stamp an already-marked row's `deletedAt`.
- The list query excludes marked rows while a status-scoped engine query still
  finds them.
- `DirectiveLogRetention` keeps a 10-day-old entry belonging to a finished run
  and drops a 40-day-old one.
