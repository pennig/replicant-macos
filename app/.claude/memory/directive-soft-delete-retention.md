---
name: directive-soft-delete-retention
description: "Clearing finished runs marks them; a one-month purge on two triggers (the click and the hourly sweep) is what actually deletes rows. Terminal statuses only — that is a safety property, not a filter."
metadata:
  node_type: memory
  type: reference
---

# Directive soft delete + one-month retention

Clearing finished runs from the Directives list stops destroying them. Two
separate verbs now:

- **Mark** — `clearFinished` stamps `deletedAt` on every `.completed` /
  `.cancelled` row whose `deletedAt` is nil. Nothing is deleted; the list query
  (`DirectivesFeature.State.directives`) is the only reader that filters on the
  mark. Every engine query is status-scoped and still sees the row.
- **Purge** — `Directive.purgeFinished(before:in:)` (GameModels) hard-deletes
  terminal rows last touched over `Directive.purgeWindow` (30 days) ago,
  together with their `directiveLogEntries`.

## Terminal statuses only, and that is a safety property

`.running`, `.needsAttention` and `.paused` all still OWN physical devices
(`Brain.owningStatuses`). Marking one would hide a live carrier from the
operator's only view of it; purging one would strand that mission's whole fleet
with no local record of what it was doing.

So the terminal set is **not a parameter** of `purgeFinished` — a caller that
passed the wrong set would destroy a live mission's rows, and that must not be
expressible. `DirectiveStatus.finishedCases` is the single definition;
`DirectiveResolutionClient.finishedStatuses` (what the toolbar counts) is
derived from it.

## Two triggers, one primitive

| trigger | what it does |
| --- | --- |
| the Clear button (`DirectiveResolutionClient.clearFinished`) | mark, then purge |
| the hourly sweep (`DirectiveRetention.sweep`, off `DeadlineScheduler.run()`) | purge only |

The sweep exists because the button alone cannot bound the window: the toolbar
disables Clear on `finishedCount == 0`, counted over the already-filtered list,
so the state right after a Clear is exactly the state in which the purge is
unreachable. With the click alone, a month is a floor, not a bound.

**The sweep must never mark.** Hiding a run from the list is an operator action;
an unattended job that hid runs would decide for the operator what they have
finished looking at.

## Two ordering rules inside the purge

- **Timeline entries go BEFORE the rows they point at, in the same
  transaction.** Every timeline query is keyed by directive id, so an orphan
  entry is unreachable forever. The delete is scoped to the doomed ids so it
  cannot sweep up another directive's entries, or the device-scoped ones whose
  `directiveID` is NULL (built-in AMI history).
- **The clock is `updatedAt`, and marking must not re-stamp it.** Otherwise
  "finished over a month ago" silently becomes "cleared over a month ago", a
  different retention policy. Nothing else can move it either: every resolution
  verb refuses a terminal row.

`DirectiveLogRetention.window` (30 days, the `directiveLogEntries` sweep) is a
separate policy over a separate table that happens to carry the same number, so
a marked run's timeline and its row age out together. It exempts entries owned
by an open run; the directive purge exempts the run itself.

Related: [[operations-table-retention]],
[[directive-log-window-and-timeline]], [[directives-feature]].
