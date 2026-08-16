# 10 — Replace the six formatters / seven parsers with `FleetTag`; fleet refresh fetches scoped + unscoped

Type: task
Status: open
Blocked by: 09
Labels: directives-architecture, stage-1

Spec S1.1 / D2. Mechanical adoption of `FleetTag`. Behaviour must be identical after this ticket EXCEPT: `EventRun.fleetTag(forTheatre:)`'s lowercasing becomes universal (the server lowercases anyway), and `.refreshFleet(tag:)` reads BOTH the scoped and unscoped tag from the server so a half-migrated fleet is fully refreshed.

**Files:**
- Modify (formatters → `FleetTag(goal:scope:).string`): `SurveyRun.swift` (`defaultFleetTag`, `fleetTag(forTheatre:)`, was `:70, :580`), `SalvageRun.swift` (`:65, :916`), `HaulRun.swift` (`:47, :128`), `MineRecipe.swift` (`:15, :20, :21`), `EventRun.swift` (`:52, :54, :68-70`), `Brain.swift` (`mineFerryTag :1749`, `"auto:tendmesh" :38`).
- Modify (parsers → `FleetTag(parsing:)` / `Device.fleetTags` / `carries`): `RepairFleet.root(of:)` and `RepairFleet.answers` (`:24-40`), `HaulRun.isFleetTagged`/`namesATheatre` (`:133-143`), `Brain.isGeneralHaul` (`:1563-1566`), `DirectiveGroup.automationKey`/`siteBearingTag` (`:156-175`), `DirectiveRow.automationTitle` (`:339-342`), `DirectiveRow.fleetOwner` (`:321-335`), `DeviceListAttention.covers` (DevicesFeature, `:69-74`).
- Modify: `DirectiveEngine.swift` `resolveFleetRefresh` (`:600-630`).
- Modify: `Directive.swift:259, :273` guidance strings, `NewHaulRunSheet.swift:69,81`, `NewSalvageRunSheet.swift:76,92` (copy that names the tag) — build the shown string from `FleetTag(goal:).string`.
- Test: every touched module's existing tests must stay green; add `DirectiveEngineTests` case for the two-fetch refresh.

**Interfaces:**
- Produces: `SurveyRun.defaultFleetTag: FleetTag` (type changes from `String`; `String` call sites use `.string`); same for `SalvageRun`, `HaulRun`, `EventRun.rootTag`, `MineRecipe.fleetTag`, `MineRecipe.carrierTag` (the ONE `auto:carrier` definition; `EventRun` reuses it). `X.fleetTag(forTheatre depot: String) -> FleetTag`.
- Produces: `RepairFleet.root(of:)` deleted; callers use `.unscoped.string`.
- Consumes: ticket 09.

---

- [ ] **Step 1: Formatters**

Replace each string literal/interpolation with the typed value; keep the public property NAMES so diffs stay small; change types to `FleetTag` and add `.string` at every `String` consumer the compiler flags. `MineRecipe.carrierTag = FleetTag(goal: .carrier)`; delete `EventRun.swift:54`'s duplicate and point at `MineRecipe.carrierTag`.

- [ ] **Step 2: Parsers**

- `RepairFleet.answers(bot, owner)`: `owner` becomes `FleetTag?`; a bot answers when it wears no `auto:` tag at all, or `bot.carries(owner, policy: .exactOrUnscoped)` — NOTE this is still root-tolerant on purpose here; ticket 12 tightens it. Preserve today's truth table with a test before and after.
- `HaulRun.isFleetTagged(device, tag)`: `device.carries(tag, policy: .exact) || (tag.isScoped && device.scopedTag(for: .haul) == nil && device.carries(tag.unscoped, policy: .exact))` — identical semantics to `namesATheatre`.
- `Brain.isGeneralHaul(tag)`: `tag.goal == .haul`.
- `DirectiveGroup`: key = `device.scopedTag(for: goal) ?? unscoped` — the "most specific" rule, now by type.
- `DirectiveRow.fleetOwner`: same rule (this deletes the `min()` bare-tag trap for good).
- `DeviceListAttention.covers`: use `carries(_, policy: .exact)` — closes the un-normalised compare.

- [ ] **Step 3: Fleet refresh fetches scoped + unscoped**

`resolveFleetRefresh(tag: String, …)` becomes `resolveFleetRefresh(tag: FleetTag, …)` (`MissionAction.refreshFleet(tag:)` payload type changes to `FleetTag`; update the machines that build it). Body: fetch `tag.string`; if `tag.isScoped` also fetch `tag.unscoped.string`; ingest both; one log line naming both counts. Test: a stubbed `devicesClient.fetchByTag` records the tags requested; a scoped refresh requests exactly two, an unscoped one exactly one.

- [ ] **Step 4: Grep for stragglers**

`grep -rn '"auto:' app/Modules --include=*.swift | grep -v Tests` must return zero hits outside `FleetTag.swift`. Tests may keep literals.

- [ ] **Step 5: Run all five targets + `DevicesFeatureTests`; commit**

`refactor(tags): FleetTag replaces every auto: literal, formatter and parser`.
