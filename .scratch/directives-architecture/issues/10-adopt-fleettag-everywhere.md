# 10 — Replace the six formatters / seven parsers with `FleetTag`; fleet refresh fetches scoped + unscoped

Type: task
Status: resolved
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

- [x] **Step 1: Formatters**

Replace each string literal/interpolation with the typed value; keep the public property NAMES so diffs stay small; change types to `FleetTag` and add `.string` at every `String` consumer the compiler flags. `MineRecipe.carrierTag = FleetTag(goal: .carrier)`; delete `EventRun.swift:54`'s duplicate and point at `MineRecipe.carrierTag`.

- [x] **Step 2: Parsers**

- `RepairFleet.answers(bot, owner)`: `owner` becomes `FleetTag?`; a bot answers when it wears no `auto:` tag at all, or `bot.carries(owner, policy: .exactOrUnscoped)` — NOTE this is still root-tolerant on purpose here; ticket 12 tightens it. Preserve today's truth table with a test before and after.
- `HaulRun.isFleetTagged(device, tag)`: `device.carries(tag, policy: .exact) || (tag.isScoped && device.scopedTag(for: .haul) == nil && device.carries(tag.unscoped, policy: .exact))` — identical semantics to `namesATheatre`.
- `Brain.isGeneralHaul(tag)`: `tag.goal == .haul`.
- `DirectiveGroup`: key = `device.scopedTag(for: goal) ?? unscoped` — the "most specific" rule, now by type.
- `DirectiveRow.fleetOwner`: same rule (this deletes the `min()` bare-tag trap for good).
- `DeviceListAttention.covers`: use `carries(_, policy: .exact)` — closes the un-normalised compare.

- [x] **Step 3: Fleet refresh fetches scoped + unscoped**

`resolveFleetRefresh(tag: String, …)` becomes `resolveFleetRefresh(tag: FleetTag, …)` (`MissionAction.refreshFleet(tag:)` payload type changes to `FleetTag`; update the machines that build it). Body: fetch `tag.string`; if `tag.isScoped` also fetch `tag.unscoped.string`; ingest both; one log line naming both counts. Test: a stubbed `devicesClient.fetchByTag` records the tags requested; a scoped refresh requests exactly two, an unscoped one exactly one.

- [x] **Step 4: Grep for stragglers**

`grep -rn '"auto:' app/Modules --include=*.swift | grep -v Tests` must return zero hits outside `FleetTag.swift`. Tests may keep literals.

- [x] **Step 5: Run all five targets + `DevicesFeatureTests`; commit**

`refactor(tags): FleetTag replaces every auto: literal, formatter and parser`.

## Comments

Resolved in `5f32e2c` (sweep) and `564c0b1` (review fixes).

Six targets green: DirectiveEngineTests 1602, GameServicesTests 324, GameSyncTests 81,
GameModelsTests 149, DirectivesFeatureTests 287, DevicesFeatureTests 166. Step 4's grep gate returns
one hit, `FleetTag.swift`'s own `prefix` constant. From-scratch `swift build --build-tests` clean.

**Four places the implementation deviated from this ticket, all reviewed and upheld:**

1. `HaulRun.isFleetTagged` keeps `tag.goal == .haul` on the fallback arm. The old code guarded
   `hasPrefix("auto:haul:")` — goal AND scope — and the ticket's expression drops the goal half, so a
   mine-ferry row (`auto:mine:<belt>`, a `.haulRun` row) would have claimed every bare-`auto:mine`
   recipe member. Not live-reachable (call sites short-circuit on `pinnedSource`), but a real
   semantics change.
2. `RepairFleet.answers` keeps a third arm (bot scoped, owner unscoped). The ticket's
   `.exactOrUnscoped`-only form fails the shipped `aTheatreTaggedBotStillAnswersToABareOwner`. The
   kept arm is truth-table identical to the old `owned.map(root).contains(normalizedOwner)`.
3. **This ticket's Interfaces line (`:19`) is wrong.** "Callers use `.unscoped.string`" contradicts
   Step 3 and the headline exception: `.unscoped` makes `tag.isScoped` false, so the second fetch can
   never fire. The five ex-`root(of:)` sites pass the row's own scoped tag.
4. `FleetTag(parsing:)` now trims whitespace. `Device.fleetTags` alone was normalising, while nine
   `directive.fleetTag` parse sites were not — and two of those (`Brain.isGeneralHaul`,
   `DirectiveGroup.automationKey`) normalised before this ticket, so a padded stored tag had started
   falling back to the default. Trimming in the parser cures all ten.

**A closed `Goal` enum means ungrammatical `auto:` tags (`auto:other`, `auto:haul-b`) are no longer
fleet tags anywhere** — grouping, row ownership, attention join. Unreachable on live data. Five shipped
tests encoded such tags as "another fleet" and were re-expressed with per-theatre tags; two of the
rewrites lost their discriminating power and were repaired in `564c0b1` by inverting the device codes
so the run's own bot sorts last, proven by deliberately breaking `RepairFleet.answers` and confirming
both assertions fail.

`BrainCarrierTagTests.carrierTagIsNormalised` was deleted: the type enforces normalisation by
construction, so the test could no longer fail.

**Note for later tickets:** an incremental `swift build` reported BUILT while `MineRun.swift` still
passed a `FleetTag` to `hasTag(String)`. A from-scratch build takes ~120 s and is now required before
any type-sweep ticket reports done.
