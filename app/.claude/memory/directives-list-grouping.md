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

## The theatre filter exempted every built-in (2026-08-21)

`DirectiveRow.theatreDepot` returned nil for every `.builtIn` row — "no theatre
concept applies" — and `DirectivesFeature.visibleRows` keeps a row when
`theatreDepot == nil || theatreDepot == theatreFilter`. That exemption was meant
for a mission never assigned a theatre; it swallowed every built-in as well.

With two theatres recognised, filtering to `TIANEFU-9-L4` therefore hid the 19
`AINALRAM-BELT-1` mission rows and kept all of AINALRAM's built-in ferries on
screen. **The grouping symptom follows from the filter symptom**, which is why
they looked like two bugs: with the mission rows gone, `missionKeys` no longer
holds their ids or device codes, so `key(for:)`'s built-in branch falls through
both mission lookups to `siteBearingTag` — the bare `auto:mine` — and the
orphaned ferries collect into a group of their own.

A built-in now inherits its driving mission's theatre. `DirectiveRow.missionTheatres`
maps each driven device to its mission's depot by **both** handles `missionKeys`
uses — `directive.deviceCode` and `directive.controllerCode` — because a pinned
row can leave `controllerCode` unset. An undriven built-in (a permanent mine's
belt controller, a service bot an armed fleet left standing) still resolves nil
and still survives every filter, which is the exemption's real purpose.

Visible side effect: a driven built-in's row caption now reads its depot rather
than "unassigned".

**The engine change that made this visible changed none of it.** The pinned haul
rows had just stopped writing per-tick ([[pinned-mine-ferry-is-a-lease]]), so the
timing invited blaming that; the rows were present in the query the whole time
and the filter was dropping them. The live log settled it in one query — those
runs were still cycling under the old build at the moment of the report.

