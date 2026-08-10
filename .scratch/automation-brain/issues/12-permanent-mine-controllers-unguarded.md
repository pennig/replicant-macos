# 12 — Permanent mine's belt controllers have no owner, so nothing guards Reconfigure/Clear

Type: task
Status: needs-triage

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
