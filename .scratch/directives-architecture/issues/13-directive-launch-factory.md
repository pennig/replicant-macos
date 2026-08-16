# 13 — `Directive.launch` factory; thirteen sites; launchers stamp theatre; theatre picker; retire the `AINALRAM-BELT-1` UI literal

Type: task
Status: open
Blocked by: 11
Labels: directives-architecture, stage-1

Spec S1.4 / S1.8. Thirteen sites call the 20-parameter `Directive.init` and hand-write the invariants (audit: 5 UI + 8 Brain). The three sheet launchers do not stamp `theatreDepot` (so with ≥ 2 theatres `ensureOne.owns` treats the nil row as blocking every theatre's launch of that kind); Print Mine Fleet stamps unscoped `auto:mine` (reserving every theatre's ferries while it runs); `mineFleetSite`/`courierSite` pick the alphabetically first theatre; `HaulRun.deliveryLocation = "AINALRAM-BELT-1"` reaches the UI through `DirectiveRow.merge`/`DirectiveTargetsSection`.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/DirectiveLaunch.swift`, `Tests/DirectiveLaunchTests.swift`
- Modify: `Brain.swift` (8 sites: `:329, :447, :477, :512, :544, :589, :623, :2199`), `DirectivesFeature.swift` (`:353-364`, `:397-408`, `mineFleetSite :613`, `courierSite :581`), `NewDirectiveFeature.swift` (`:231-255`, `:216-230`), `NewSalvageRunFeature.swift` (`:196-222`, `:181-195`), `NewHaulRunFeature.swift` (`:117-142`, `:102-116`), `DirectiveRow.swift` (`merge`, `:153, :204, :271-294`), `DirectiveTargetsSection.swift` (`:75, :118-135`), `HaulRun.swift` (`deliveryLocation :51` → delete; `deliverySink` requires a depot), the two dialog launchers' sheets (theatre picker).
- Test: `NewDirectiveFeatureTests`, `NewSalvageRunFeatureTests`, `NewHaulRunFeatureTests`, `DirectivesFeatureTests`, `DirectiveRowTests`, `DirectiveTargetsSectionTests`, `Brain*Tests` — extend.

**Interfaces:**
- Produces:
  ```swift
  extension Directive {
      public struct Launch: Sendable, Equatable {
          public var kind: DirectiveKind
          public var deviceCode: String
          public var theatre: Theatre?                 // nil only when no theatre is operational
          public var targets: [String] = []
          public var roamCentre: String? = nil
          public var returnToOrigin: Bool = false
          public var originDesignation: String? = nil
          public var controllerCode: String? = nil
          public var freighterCode: String? = nil
          public var sourceRelayCode: String? = nil
          public var belt: String? = nil               // mine ferry rows: overrides the tag scope
      }
      /// The ONE constructor for a running row. Owns id/status/step/stamps/theatreDepot/fleetTag.
      public static func launch(_ l: Launch, id: String, now: Date) -> Directive
  }
  ```
  `fleetTag` rule inside `launch`: `.surveyRun/.salvageRun/.haulRun/.eventRun` → `FleetTag(goal:, scope: theatre.map { .theatre(depot: $0.depot) })`; `.mineRun/.mineFleetPrint` → `.mine` scoped to the theatre; `.haulRun` with `belt` set → `.haul` scoped `.belt(belt)`; `.relayRun/.restockRun/.eventCourierPrint` → nil (unchanged). `step` = `MissionRegistry.firstStep(for: kind)` (make that non-optional: every registered kind has one; a missing kind is a programmer error → `precondition`).
- Consumes: `Theatre`, `FleetTag`, `MissionRegistry`.

---

- [ ] **Step 1: Failing tests (DirectiveLaunchTests)**

One test per kind asserting the invariants: `status == .running`, `targetIndex == 0`, `step == <Kind>().firstStep`, `stepStartedAt == createdAt == updatedAt == now`, `attentionReason == nil`, `theatreDepot == theatre.depot`, `fleetTag == expected.string`. Plus: `haulRun` with `belt` → `auto:haul:<belt>`; `relayRun` → `fleetTag == nil`.

- [ ] **Step 2: Implement; migrate the eight Brain sites**

Each Brain `Directive(` becomes `Directive.launch(.init(kind:…), id: uuid().uuidString, now: now)`. `Brain*Tests` fixtures that assert exact rows must still pass — the factory produces the same values; if a test breaks, the factory found a drift (e.g. a site that forgot `theatreDepot`); fix the test's expectation to the factory's value and record which site drifted in `## Comments`.

- [ ] **Step 3: Migrate the five launcher sites; stamp the theatre**

The three sheet launchers already resolve a theatre for the tag (the duplicated ~15-line block); pass it into `Launch.theatre` and delete the block in favour of one helper `LauncherTheatre.resolve(for deviceCode:) async -> Theatre?` in `DirectivesFeature` (uses `WorldView.read` + `theatreResolver.owningTheatre(of:goal:)`). Print Mine Fleet / Print Event Courier: replace `mineFleetSite`/`courierSite`'s alphabetical pick with a theatre picker when `theatres.filter(\.isOperational).count > 1` — a `ConfirmationDialogState` listing depots in mono (`.rcMono`), default = the theatre owning the active replicant's host location; the row then launches with that theatre and Print Mine Fleet's tag is `auto:mine:<depot>`.

- [ ] **Step 4: Retire the UI literal**

Delete `HaulRun.deliveryLocation`; `deliverySink(in:for:)` requires `directive.theatreDepot` (nil → returns nil, callers show "no theatre"). `DirectiveRow.merge` and `DirectiveTargetsSection.assignments` pass `delivery: directive.theatreDepot`. Update `DirectiveRowTests`/`DirectiveTargetsSectionTests` fixtures to stamp `theatreDepot`.

- [ ] **Step 5: `grep -rn "Directive(" app/Modules --include=*.swift | grep -v Tests | grep -v "Directive.launch"` → only `Directive.swift`'s own init and `DirectiveLaunch.swift`. Run all targets; commit**

`refactor(directives): one Directive.launch factory; launchers stamp their theatre`.
