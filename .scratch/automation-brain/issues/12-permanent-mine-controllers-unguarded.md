# 12 — Permanent mine's belt controllers have no owner, so nothing guards Reconfigure/Clear

Type: task
Status: resolved

## Symptom (observed live 2026-08-10)

The installed mine at `ACHERNUR-BELT-1` runs on two AMI controllers with
directives in force — `C4A2FF23` (`gather_evenly`) and `189E4074`
(`belt_search`) — plus the armed ferry covered by ticket 11. Their built-in
rows in the Directives list are **not locked**: no "driven by …" badge, and the
Reconfigure/Clear refusals in `DirectivesFeature.swift:204`/`215` don't fire.
One Clear in the UI silently breaks the permanent mine; no run stalls, the
brain just sees an unhealthy belt later.

## Why this is a design gap, not a missed stamp

The lock model (`DirectiveOwner` / `drivenBy` in
`app/Modules/DirectivesFeature/Sources/DirectiveRow.swift`) assumes every
engine-owned built-in directive is held by a **live mission row** via
`controllerCode`. The permanent mine deliberately has none: `mineRun` finishes
after install, and the brain re-derives mine health statelessly
(`MineRecipe.installedBelts`, `Brain.mineHealth`) — the design records this as
"a dedicated PERSISTENT Haul Run per site; brain-derived statelessly". So
ticket 11's fix (stamp `controllerCode`) cannot cover these two devices: there
is no row to stamp. The pinned haul row owns the ferry only.

## Question to decide

What marks an in-force directive as brain-owned when no mission row holds it?
Options sketched, none chosen:

- A derived predicate in `DirectiveRow.merge`: a device wearing an `auto:`
  fleet tag whose directive is in force renders as engine-owned ("part of the
  mine at <belt>") and refuses Reconfigure/Clear. Cheap, no schema; makes the
  bare tag load-bearing for a guard, and operator un-tagging remains the
  documented take-back gesture (`HaulRun.controllers` comment).
- A standing owner row per installed mine (a `mineRun`-kept-alive or a new
  lightweight kind) so the existing `controllerCode` lock just works. Heavier;
  contradicts the shipped "mine is permanent, brain re-derives" disposition.
- Leave Clear possible but make it loud: confirm dialog naming the mine, and
  brain escalation when an installed belt loses its controller.

## Acceptance (once decided)

- The mine's belt controllers are either refused or loudly confirmed on
  Reconfigure/Clear, and their rows say who owns them.
- The operator take-back path (whatever it is) is documented in the row UI or
  the domain doc, not just in engine comments.

## Answer (2026-08-10) — option 1, the derived predicate

The operator chose the derived predicate on the `auto:` tag. The standing-owner
row was rejected (contradicts the locked "mine is permanent, brain re-derives"
disposition from ticket 06) and so was leave-Clear-possible-but-loud (a
mis-click still breaks the mine).

**The predicate, exactly.** A device is engine-owned when it (a) has an AMI
directive in force — i.e. already renders a built-in row, (b) is *not* already
owned via a live mission's `controllerCode`, and (c) carries a tag which, after
`Device.normalizedTag`, begins with `RepairFleet.fleetTagPrefix` (`auto:`). The
lowest-sorting such tag is the owner. Site is claimed for `auto:mine` only, and
only when the device's `location` is one of `MineRecipe.installedBelts(in:hub:)`
computed over devices *with a directive in force* — an idle mine fleet parked at
the hub is inventory, not a mine. Otherwise no site is claimed.

`DirectiveOwner` was reshaped around one notion of ownership
(`Holder.mission(id:)` / `Holder.fleetTag(_)`), so the badge, the subtitle and
both refusals at `DirectivesFeature.swift:204`/`215` read from a single source.
A built-in row's `headlineDesignation` is now its owner's designation, putting
the belt in the mono half of the headline rather than the caption.

**Take-back path documented** in `app/CONTEXT.md` (a new *Fleet tag* glossary
entry: the tag is both the opt-in and the lock) and in user-visible copy — the
detail pane's lock note reads "Remove the `auto:mine` tag from this device to
take it back."

### Corrections to the framing above

1. **The gap is 8 rows, not 2.** Beyond the two belt controllers the predicate
   newly locks **six service bots** running `service` — two each on the survey,
   salvage and mine fleets. These should not have stayed editable:
   `RepairFleet.isArmed` requires `currentDirective == "service" && status ==
   "active"`, so a Clear silently disarms repair. Ticket 12's bug in a second
   place it never named.
2. **The belt does not follow from the bare tag.** The mine's ferry wears
   `auto:mine` and stands at the delivery sink, not a belt. The belt is derived
   from the fleet (installed mining controllers actually running) and left
   unclaimed when the data doesn't establish it. The ferry reports "part of the
   mine" with no belt until ticket 11's `controllerCode` stamp makes it report
   "driven by Haul Run" instead.

**Blast radius, measured against the live DB.** 12 devices carry an `auto:` tag
*and* a directive in force. Three stay mission-owned and unchanged (`auto:haul`
ferry, `auto:salvage` gatherer, `auto:survey` controller — the mission wins, no
double-report). Eight are newly locked (2 belt controllers + 6 service bots).
One is the mine's ferry. Nothing else is caught: `auto:carrier` surge carriers,
the `auto:tendmesh` racing vessel and every tagged drone/freighter have no
directive in force, so there is no row to lock.

**Accepted cost of this option:** an operator who tags a device *and* hand-sets
its AMI directive locks their own row. Un-tagging is the way back.
