---
name: haul-retag-is-the-handover
description: "The 2026-08-16 finding that re-tagging a haul controller `auto:haul:<depot>` did nothing: three independent gates each ignored the new tag — the bare-tag fallback still claimed it, the theatre filter judged it by LOCATION, and the old run's deviceCode/controllerCode reserved it for good. An explicit per-theatre tag is now authoritative at all three."
metadata:
  type: project
---

`Brain.unmigratedNote` tells the operator to *"re-tag it `auto:haul:<depot>` to
protect its fleet from other theatres"*. Doing exactly that had no effect at all.
Three gates, each of which alone was sufficient to defeat it:

**1. The bare-tag fallback outranked the explicit tag.** `HaulRun.isFleetTagged`
matched a per-theatre query against a device wearing the bare `auto:haul`, which
is the right migration behaviour for a device that names NO theatre — but it
applied to one wearing `auto:haul:<other-depot>` too, since operators add the new
tag rather than replacing the old. So the old theatre's query kept claiming it.
Now the fallback is skipped for any device wearing an `auto:haul:` tag of its
own: it has migrated, and its own tag decides.

**2. The theatre filter read LOCATION, not tag.** `haul-run-theatre-scoped-controllers`
scoped both `HaulRun.controllers(in:tag:theatreDepot:)` and `Brain.haulReadiness`
through `owningTheatre(of:)`, which resolves the nearest operational theatre to
the device's own `location`. **Measured**: the retagged controller stood at
`ATIANFU-1-L4` — 5.3 ly from AINALRAM, 20.1 ly from SAGARMADHA — so it resolved
to AINALRAM no matter what its tag said, and no controller could ever be moved
between theatres by tagging. The location rule exists to disambiguate BARE tags,
which carry no theatre; it must never overrule one that does. Both call sites now
go through `HaulRun.belongs`, which admits an exact tag match wherever it stands
and falls back to the location rule only for the bare case.

**3. Both device columns on the live row reserve for good.** `reservedDevices`
sweeps `directive.deviceCode` and `directive.controllerCode` account-wide, and
**nothing rewrote either after launch** — the general drainer's `deviceCode` was
stamped once by `haulReadiness` at launch. So even with (1) and (2) fixed, the
new theatre's `haulReadiness` found its only candidate reserved and idled with
the unhelpful `no free auto:haul controller offering ferry`. `Brain.rehomedHaulRuns`
+ `rehomeHaulRuns` now re-home a general drainer onto a real fleet member and
clear a `controllerCode` that left the fleet, in the same pre-goal position as
`adoptTheatreStamps`. **`controllerCode` needed closing separately**: `assigning`
re-stamps it only on a repoint, so a run already in force would have held the
departed controller indefinitely.

An empty fleet yields NO re-home — the row keeps its stale code and stalls on its
own `noHaulControllerTagged` path. Blanking `deviceCode` (NOT NULL, default `''`)
would strand the run instead.

Pinned mine-ferry rows are excluded twice over (`isGeneralHaul` is false for
`auto:mine:<belt>`, and `HaulRun.pinnedSource` is non-nil) — such a row drives
exactly its own `deviceCode`, so re-homing one would point it at a controller
that is not its belt's.

Generalised 2026-08-17: the rule is now `FleetMembership.belongs` and every fleet obeys it, not haul alone — see `.scratch/directives-architecture/issues/12-scoped-tag-outranks-location.md`.
