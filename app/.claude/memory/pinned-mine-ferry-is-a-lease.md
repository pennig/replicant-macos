---
name: pinned-mine-ferry-is-a-lease
description: "A per-belt haulRun does not haul — the server's `ferry` directive does. It exists to hold the lease on the ferry controller and to re-arm a drifted config, so it now HOLDS in `hauling` and writes nothing while the config stands"
metadata:
  node_type: memory
  type: reference
---

`Brain` makes two shapes of `haulRun` and they do unrelated jobs:

- **The general drainer** (`ensureHaul`, `isGeneralHaul`, `targets == []`), one per
  theatre. It ranks stockpiles and repoints `auto:haul`-tagged controllers —
  2,924 `set_directive` commands in three weeks. This is the one
  [[haul-run-design]] describes.
- **The pinned mine ferry** (`ensureMineFerries`, `targets == [belt]`), one per
  installed belt. **Zero dispatches, ever** — 18 rows, 11 days, measured
  2026-08-21.

## Why a pinned row exists at all

The `mineRun` arms the ferry at install time, so `assign`'s pinned branch finds
`isInForce` already true and never commands anything. What the row buys:

1. **The lease.** All `mineRun` rows go terminal after the install, so nothing
   else claims the ferry. `Ownership.resolve` claims `directive.deviceCode`, and
   its `.adoption` drag edge extends that to the `cargo_freighter` the controller
   adopted — 36 devices held across 18 rows. `Brain.mineFerryController` filters
   candidates by `reservedDevices`, so this is what stops the next mine install
   handing belt B a controller already ferrying belt A.
2. **Drift insurance.** `assign` compares the controller's live `ami_directive`
   block against the assignment it would issue (`ferry`, `collect == belt`,
   `deliver == depot`) and re-arms on any mismatch. Never yet exercised.

It buys nothing for reporting — `BrainReport` reads `isGeneralHaul` specifically.

The general drainer could not steal these controllers anyway: they carry
`auto:mine`, and its fleet query resolves `auto:haul:<depot>`. The lease protects
against the mine-install path, not against the drainer.

## Why `hauling` now holds

The old shape cycled `surveying → assigning → hauling` every
`HaulRun.pollInterval` (60s), and `DirectiveExecutor` writes a `.stepStarted` row
on every step change — three rows a lap, ~3,240 an hour across 18 runs,
**265,871 rows** accumulated. `survey` refreshes the stockpile census, which only
the drainer's ranking reads; a pinned row has one belt and never re-ranks.

`haul` now watches the config in place for a pinned row and returns `.wait`, the
only action that writes nothing at all. A settled ferry costs one dictionary
lookup per tick and zero rows.

**Drift must route through `assigning`, never back through `hauling`.**
`dispatchAttemptCount` walks the log backwards and its `default:` arm RETURNS on
any step outside `assigning`/`dispatching`/`confirming` — so a retry loop passing
through `hauling` would reset the budget every lap and make
`dispatchAttemptLimit` structurally unreachable. That is defect #2 from the
original build, recorded in [[haul-run-design]], and it is the reason `confirm`
returns to `assigning` rather than to `hauling`.

## The one consequence

A settled pinned row now stops touching `updatedAt` entirely, so the soft-stall
detector in [[dedup-window-soft-stall]] false-positives on all 18 forever. Its
query needs the pinned rows excluded:

```sql
select id, kind, step, stepStartedAt, updatedAt from directives
where status='running' and deletedAt is null
  and not (kind='haulRun' and json_array_length(targets)=1)
  and updatedAt < datetime('now','-20 minutes');
```

Nothing in code escalates on a stale directive `updatedAt`, and
`Directive.purgeFinished` filters on `status.in(finishedCases)`, so a running row
is never at risk however old its stamp. `DirectivesFeature` does not read the
column at all.
