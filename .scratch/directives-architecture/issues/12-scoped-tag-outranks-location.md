# 12 — Survey / Salvage / RepairFleet adopt "scoped tag outranks location"

Type: task
Status: open
Blocked by: 11
Labels: directives-architecture, stage-1

Spec S1.3. `HaulRun.belongs` (tag > location, bare fallback retires once a device names a theatre) is the rule the 08-16 "retag is the handover" fix installed. `SurveyRun.isFleetTagged`/`SalvageRun.isFleetTagged` accept the unscoped tag forever and the brain then ANDs `owningTheatre(of:)?.depot == theatre.depot` (`Brain.swift` was `:1491, :1959`) — location outranks tag, so re-tagging a survey vessel `auto:survey:<B>` while it stands near A does nothing. `RepairFleet.answers` is root-tolerant, so a bot wearing unscoped + scoped-B answers A. `Brain.adoptTheatres` uses servicing-only where launchers use servicing-then-nearest.

**Files:**
- Modify: `SurveyRun.swift` (`isFleetTagged`), `SalvageRun.swift` (`isFleetTagged`), `RepairFleet.swift` (`answers`), `Brain.swift` (`salvageReadiness` candidates `:1489-1492`, `surveyCarrier` `:1956-1960`, `adoptTheatres` `:817-830`, and the mine/event pools `isFreeCarrier`/`freeHull` where a goal is known), `HaulRun.swift` (`belongs` → delegate to the resolver so there is one implementation).
- Test: `BrainSurveyTests`, `BrainSalvageTests`, `SurveyRunRepairTests`, `SalvageRunRepairTests`, `HaulRunTests` — extend.

**Interfaces:**
- Produces: `static func belongs(_ device: Device, to theatre: Theatre, goal: FleetTag.Goal, resolver: TheatreResolver) -> Bool` on a new `FleetMembership` enum in `DirectiveEngine`: `device.scopedTag(for: goal).map { $0.scope?.designation == theatre.depot.lowercased() } ?? (device.carries(FleetTag(goal: goal), policy: .exact) && resolver.owningTheatre(of: device, goal: goal)?.depot == theatre.depot)`.
- Consumes: 11.

---

- [ ] **Step 1: Failing tests**

For each of survey/salvage/haul: a device wearing `auto:<goal>:depot-b` standing 1 ly from A and 20 ly from B is a member of B and not A; an unscoped device near A is A's; a device wearing BOTH belongs to B only. For `RepairFleet.answers`: a bot wearing `auto:survey` + `auto:survey:depot-b` does NOT answer a run whose owner tag is `auto:survey:depot-a`; a bot wearing only `auto:survey` answers both (unmigrated); a bot with no `auto:` tag answers anyone (unchanged policy).

- [ ] **Step 2: Implement**

`FleetMembership.belongs` as in Interfaces; `HaulRun.belongs`, `SurveyRun.isFleetTagged`, `SalvageRun.isFleetTagged` all forward to it (keep names, change bodies). Brain's two AND-filters drop their `owningTheatre` clause because `belongs` already decided. `RepairFleet.answers(bot, owner: FleetTag?)`: bot with no auto tag → true; owner nil → bot has no auto tag; else `bot.scopedTag(for: owner.goal).map { $0 == owner } ?? bot.carries(owner.unscoped, policy: .exact)`.

`Brain.adoptTheatres`: use `resolver.theatre(servicing:) ?? resolver.theatre(nearest:)` on `originDesignation` — the launcher rule — so a row launched outside every component still gets stamped (today it stays nil unless exactly one theatre exists).

- [ ] **Step 3: Delete `Brain.reservedDevices` if no callers remain; run all targets; commit**

`fix(theatres): a scoped tag outranks location for every fleet, not only haul`. Update memory notes `haul-retag-is-the-handover.md` and `survey-repair-fleet-tag.md` with one line each pointing here.
