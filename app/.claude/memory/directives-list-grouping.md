---
name: directives-list-grouping
description: "The Directives list groups by the auto:<name>[:<site>] fleet tag. Two traps: grouping must take the device's MOST SPECIFIC tag (fleetOwner's min() picks the bare one and splits every migrated fleet from its own run), and a mission-driven built-in row joins its MISSION, since a pinned ferry stands at the delivery sink rather than its belt."
metadata:
  type: project
---

`DirectiveGroup` collects the unified list into collapsible sections. The key is the
`auto:<name>[:<site>]` fleet tag; `.mesh`, `.unassigned` and `.finished` are the buckets no
fleet tag names. Sections sort attention-first with `.finished` pinned last, and
`DirectivesFeature.expandedGroups` seeds once per session from whatever carries attention.

Measured before building (live fleet, 2026-08-13): **73 rows → 11 groups**, 28 of the rows
finished `relayRun`s from a single carrier accumulating at roughly one per half hour against
a one-month retention. Five mines at six rows each were 30 of the remaining 45.

**Grouping must read the device's most specific fleet tag.** `DirectiveRow.fleetOwner` picks
with `min()` over the `auto:` tags, which is right for *naming* the automation (`auto:mine`
and `auto:mine:GRAZ-BELT-1` both title as "mine") and wrong for *placing* it: a device
migrated to per-theatre tags wears **both** forms, so `min()` returns the bare one, which
names no site. That put every salvage and survey bot in a siteless group while its own run
— whose `fleetTag` carries the site — sat in the per-site one. `DirectiveGroup.siteBearingTag`
prefers the most colon-parts and breaks ties lexicographically smallest. This is why
`BuiltInDirective` carries `tags` at all; `drivenBy` cannot answer the question.

**A built-in row a mission drives joins that mission's group, not the one its own tag names.**
The case that forces it is the pinned mine ferry: it stands at the delivery sink, so its bare
`auto:mine` tag plus `MineRecipe.installedBelts` yields no belt (the sink has no tagged mining
controller and so is not an installed belt). The run knows — its `fleetTag` is
`auto:mine:<belt>`. Reached two ways, and both are needed: by `DirectiveOwner.holder`'s
`.mission(id:)` when `controllerCode` is stamped, and by `directive.deviceCode` when it is not
(a pinned row can carry a null `controllerCode` — see [[brain-mine-build]]). The design's
original "look up `HaulRun.pinnedSource`" step turned out unnecessary; the run's own fleet tag
already carries the belt, and keying off the mission generalises to the survey and salvage
controllers for free.

**The fixtures could not have found the tag-specificity bug** — it needs a device wearing both
tag forms, which is a fact about the un-migrated live fleet
([[theatre-aware-readiness-build]] records that the operator migration is still not done).
Replaying the real key derivation over the live SQLite rows is what surfaced it, and is worth
redoing for any future change to the grouping rules.

Deliberately not built: a group header is not selectable, so there is no per-mine detail pane.
Related: [[directives-feature]], [[directive-soft-delete-retention]].
