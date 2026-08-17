# 12 — Survey / Salvage / RepairFleet adopt "scoped tag outranks location"

Type: task
Status: resolved
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

- [x] **Step 1: Failing tests**

For each of survey/salvage/haul: a device wearing `auto:<goal>:depot-b` standing 1 ly from A and 20 ly from B is a member of B and not A; an unscoped device near A is A's; a device wearing BOTH belongs to B only. For `RepairFleet.answers`: a bot wearing `auto:survey` + `auto:survey:depot-b` does NOT answer a run whose owner tag is `auto:survey:depot-a`; a bot wearing only `auto:survey` answers both (unmigrated); a bot with no `auto:` tag answers anyone (unchanged policy).

- [x] **Step 2: Implement**

`FleetMembership.belongs` as in Interfaces; `HaulRun.belongs`, `SurveyRun.isFleetTagged`, `SalvageRun.isFleetTagged` all forward to it (keep names, change bodies). Brain's two AND-filters drop their `owningTheatre` clause because `belongs` already decided. `RepairFleet.answers(bot, owner: FleetTag?)`: bot with no auto tag → true; owner nil → bot has no auto tag; else `bot.scopedTag(for: owner.goal).map { $0 == owner } ?? bot.carries(owner.unscoped, policy: .exact)`.

`Brain.adoptTheatres`: use `resolver.theatre(servicing:) ?? resolver.theatre(nearest:)` on `originDesignation` — the launcher rule — so a row launched outside every component still gets stamped (today it stays nil unless exactly one theatre exists).

- [x] **Step 3: Delete `Brain.reservedDevices` if no callers remain; run all targets; commit**

`fix(theatres): a scoped tag outranks location for every fleet, not only haul`. Update memory notes `haul-retag-is-the-handover.md` and `survey-repair-fleet-tag.md` with one line each pointing here.

## Comments

Resolved in `6277230` (rule) and `8550c64` (review fixes).

DirectiveEngineTests 1650, GameServices 324, GameSync 81, GameModels 149, DirectivesFeature 287,
DevicesFeature 167 — 0 failed. From-scratch `swift build --build-tests` clean. Ten mutation runs:
both `belongs` branches, all three `answers` arms, and both new readiness tests each have a case that
fails when that logic alone is removed.

**A second guard was needed that this ticket did not anticipate.** Dropping the `owningTheatre`
AND-clause removed a *theatre* comparison, which was the intent — but that clause's left conjunct was
also the only **placeability** requirement on the candidate pools, so a stowed or mid-cruise
scoped-tagged vessel became launchable. `ensureSurvey`/`ensureSalvage` count `.needsAttention` as live
(`Brain.swift:432-436`), so a run launched on such a vessel that then faults parks the theatre's single
survey/salvage slot until an operator clears it — strictly worse than idling one tick.

The guard is `FleetMembership.isDeployable`, `resolver.owningTheatre(of:goal: nil) != nil`, and all
three fleets forward to it. It is deliberately NOT `location != nil`: that would leave a hole for a
device located in a system absent from `starPositions`, and would lose the existing "not placeable —
stowed or mid-cruise" diagnostic, which is the message the operator needs. `surveyCarrierBlocker`'s
`hulls` pool needed the conjunct explicitly because it hand-rolls its filter instead of routing
through `SurveyRun.isFleetTagged`; salvage's pool routes through the membership rule and did not.

**`Brain.reservedDevices` was NOT deleted.** Four production callers remain plus eight test files, so
deletion was never available. Note the ticket's premise was slightly wrong: three of the four DO have a
theatre in scope (`ensureOne` takes one and scopes `owns` with it; `mineFerryController` and
`commitBlocker` each had one a frame up, flattened to strings). They stay account-wide because each
intersects the reserved set with `location == hub` immediately, making the difference inert, and
because `ensureOne` re-reads inside its write transaction with no fresh `WorldView` to scope against.

**`isFreeCarrier`/`freeHull` got no goal threaded, correctly, but not for the reason first given.**
`isFreeCarrier` closes over `Brain.carrierTag`, which is `FleetTag(goal: .tendMesh)` (`Brain.swift:38`)
— not `.carrier`. The conclusion holds independently: the only `.carrier` construction is the unscoped
`MineRecipe.carrierTag`, `rg "auto:carrier:"` and `rg "auto:tendmesh:"` both return zero hits anywhere,
and both pools filter on location regardless. Threading `.haul` into `freeHull` would break
`aScopedLeaseElsewhereLeavesTheFreighterSpendable` by construction.

`RepairFleet.answers` is now one-directionally root-tolerant, per this ticket's rule: a scoped-tagged
bot no longer answers a bare-tagged legacy row. The degradation is silent (`deployBots` returns
`.advanceStep`, no stall, no log). On the punch list.

`WorldSnapshot.owningTheatre(of:goal:)` was deleted — dead on arrival, zero callers. The S1.3 seam is
the shared `TheatreResolver` both world reads hold, which is intact.
