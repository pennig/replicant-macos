# 11 — `Ownership.resolve` + one `owningTheatre`; delete the two `owningStatuses` copies

Type: task
Status: resolved
Blocked by: 10
Labels: directives-architecture, stage-1

Spec S1.2 / S1.3. `Brain.reservedDevices` (`Brain.swift` was `:1221-1271`) is the one lease derivation and takes no theatre input, so it is account-wide by construction; ~11 call sites recompute it per tick. `WorldSnapshot.owningTheatre` and `WorldView.owningTheatre` are hand-mirrored copies. Three copies of the owning-status set exist (`DirectiveStatus.openCases`, `Brain.owningStatuses`, `DirectiveRow.owningStatuses`) and the `Brain.swift:51` comment justifying it is stale.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/Ownership.swift`, `TheatreResolver.swift`
- Create: `app/Modules/DirectiveEngine/Tests/OwnershipTests.swift`
- Modify: `Brain.swift` (`reservedDevices` → view; `holdingDirective`, `unmigratedHold`, `carrierClause` → views; delete `owningStatuses`; `adoptTheatres` uses the resolver), `WorldSnapshot.swift` + `WorldView.swift` (hold a `TheatreResolver`; delete the duplicated `owningTheatre`/`theatre(servicing:)`/`theatre(nearest:)`/`nearestTheatre` bodies), `DirectiveRow.swift` (delete `owningStatuses`, `merge`'s owners via `Ownership`), `DirectiveGroup.swift` (`missionKeys`), `DevicesFeature/Sources/DeviceListAttention.swift` (`covers` via `Ownership`).

**Interfaces:**
- Produces:
  ```swift
  public struct Ownership: Sendable, Equatable {
      public enum Via: String, Sendable { case deviceCode, controllerCode, freighterCode, fleetTag, stow, attach, adoption }
      public struct Holder: Sendable, Equatable { public let directiveID: String; public let via: Via; public let theatreDepot: String? }
      /// Every device held by a directive in `DirectiveStatus.openCases`, with why.
      public static func resolve(directives: [Directive], devices: [Device], theatres: [Theatre]) -> Ownership
      public func holder(of deviceCode: String) -> Holder?
      /// All held device codes (today's `reservedDevices`).
      public var reserved: Set<String>
      /// Held codes that bind INSIDE `theatre`: a scoped-tag lease binds only its own theatre;
      /// an unscoped-tag lease binds everywhere; deviceCode/controllerCode/freighterCode/closure
      /// leases bind everywhere (a physical device is one place).
      public func reserved(in theatre: Theatre) -> Set<String>
      /// Rows whose fleetTag is unscoped and therefore reserve account-wide.
      public var accountWideLeases: [Directive]
  }
  public struct TheatreResolver: Sendable, Equatable {
      public init(theatres: [Theatre], starPositions: [String: Position], components: [String: String])
      /// Scoped tag outranks location; location decides only for a device wearing no scoped tag for `goal`.
      public func owningTheatre(of device: Device, goal: FleetTag.Goal?) -> Theatre?
      public func theatre(servicing system: String) -> Theatre?    // same component, nearest
      public func theatre(nearest system: String) -> Theatre?      // no component filter
  }
  ```
- Consumes: `FleetTag`, `Device.scopedTag(for:)` (09/10).

---

- [x] **Step 1: Failing tests (OwnershipTests)**

Port `Brain.reservedDevices`'s existing test cases (find them via LSP references in `BrainTestSupport`/`Brain*Tests`) onto `Ownership.resolve(...).reserved` — the set must be IDENTICAL for every existing fixture. Then add:
```swift
@Test func scopedTagLeaseBindsOnlyItsTheatre() {
    // row A: fleetTag auto:haul:depot-a, running; device H1 wears auto:haul:depot-a; theatres A, B
    #expect(ownership.reserved(in: A).contains("H1"))
    #expect(!ownership.reserved(in: B).contains("H1"))
    #expect(ownership.reserved.contains("H1"))
}
@Test func unscopedTagLeaseBindsEverywhereAndIsReported() { /* fleetTag auto:haul → in A and B; accountWideLeases == [row] */ }
@Test func deviceCodeLeaseBindsEverywhere() { /* deviceCode V1 → in A and B */ }
@Test func stowClosureFollowsTheCarrier() { /* V1 held; D1 stowedInDeviceCode V1 → D1 held via .stow */ }
```
`TheatreResolver` tests: `owningTheatre(of: vessel wearing auto:survey:depot-b standing near A, goal: .survey) == B`; unscoped vessel near A → A; stowed vessel → nil.

- [x] **Step 2: Implement `Ownership` and `TheatreResolver`**

`resolve`: seed per row from `deviceCode`/`controllerCode`/`freighterCode` (`.deviceCode` etc.), then for `fleetTag` parse it; every device with `carries(tag, policy: .exact)` → `.fleetTag` holder with `theatreDepot: row.theatreDepot`; then fixpoint over stow (both directions), controller/adopted, attach — copy the loops from `reservedDevices` verbatim, recording `via`. `reserved(in:)` filters `.fleetTag` holders whose tag is scoped to a different depot.

- [x] **Step 3: Brain becomes a consumer**

`Brain.reservedDevices(...)` body → `Ownership.resolve(...).reserved` (keep the function as a one-line shim this ticket; delete it when the last caller moves in tickets 12–13). Every readiness function that filters `!reserved.contains(code)` for a THEATRE now uses `ownership.reserved(in: theatre)`. `holdingDirective` → `ownership.holder(of:)`. Delete `Brain.owningStatuses` and `DirectiveRow.owningStatuses`; use `DirectiveStatus.openCases` (verify with a test that the three sets were equal — they are today: running/needsAttention/paused).

`WorldSnapshot`/`WorldView`: build one `TheatreResolver` in `read` and expose it as `theatreResolver`; keep `owningTheatre(of:)` as a one-line forwarder (`goal: nil` — location rule) so callers compile; ticket 12 passes goals.

- [x] **Step 4: Run all targets incl. `DevicesFeatureTests` and `DirectivesFeatureTests`; commit**

`refactor(engine): Ownership.resolve and TheatreResolver — one lease derivation, one theatre rule`.

## Comments

Resolved in `70fd770` (implementation) and `9381b92` (review fixes).

Six targets green: DirectiveEngineTests 1637, GameServicesTests 324, GameSyncTests 81,
GameModelsTests 149, DirectivesFeatureTests 287, DevicesFeatureTests 167. From-scratch
`swift build --build-tests` clean.

**The derivation did not move.** Thirteen ported cases assert
`Ownership.resolve(...).reserved == Brain.reservedDevices(...)` and were run against the OLD body
before the shim landed — 50/50. Review diffed `held(by:)` + `dragEdges(in:)` against the old body line
by line: same four seeds, same six `link` calls with the identical dangling guard, same worklist. The
port is per-row rather than one global closure, which is what makes `via` attributable; the union is
provably the same set.

The one intended derivation change is the fleetTag seed moving from `hasTag(String)` to
`FleetTag(parsing:)` + `carries(_:policy: .exact)`, so a row whose `fleetTag` is not `auto:` grammar
now sweeps nothing. That is what ticket 10's review required.

**`Brain.owningStatuses` and `DirectiveRow.owningStatuses` deleted** after a temporary cross-module
test proved all three sets equal `[.running, .needsAttention, .paused]`. A permanent freeze test
replaces it and fails in both directions — on a change to `openCases`, and on a new `DirectiveStatus`
case left unclassified.

**Three deviations from the ticket, all upheld on review:**

1. `DeviceListAttention.covers` now also matches `freighterCode`. The hand-written version seeded from
   three of the four claim sources with no comment or test suggesting the omission was deliberate.
   `EventRun` seeds the freighter as its own lease because no stow or attach edge reaches it, so the
   attention join is the only surface it can appear on. Covered now by `directiveJoinsOnFreighterCode`.
2. `holders(of:)` added beyond the stated interface, for `DirectiveRow.merge`'s "driven by" badge —
   `holder(of:)` returns the lowest-id claim across all seven `via`s and cannot serve it. This also
   surfaced a real defect: a pinned mine-ferry row names one device as both `deviceCode` and
   `controllerCode`, so each seed must record its own claim.
3. `resolve` takes `devices: [String: Device]` (the dangling-edge guard needs the dictionary) and
   `TheatreResolver` gained `owningTheatre(ofSystem:)` (public, with live callers).

**A live behaviour change ships with this ticket.** Step 3 moves five theatre-scoped readiness
functions onto `reserved(in: theatre)`. For `surveyReadiness`, `salvageReadiness` and `haulReadiness`
that is inert — a device must wear this theatre's tag to reach the filter. **`mineSiting` and
`eventReadiness` are not inert**: their only theatre narrowing is physical location, since
`MineRecipe.idleCarrier` requires just `carries(auto:carrier)` + location + idle, and `freeHull` is
called with `tag: nil` for the freighter and so applies no tag filter at all. A surge carrier idle at
depot B held by theatre A via any scoped tag, and a cargo freighter wearing `auto:haul:A` parked empty
at depot B, are both now allocatable by B. This is what S1.2 asks for and it is what Checkpoint B
exercises. Pinned by `aScopedLeaseElsewhereLeavesTheCarrierSpendable` and
`aScopedLeaseElsewhereLeavesTheFreighterSpendable`.

**`OwnershipTests.aBeltScopedLeaseFallsBackToItsRowStamp` could not fail as first written** — its
device wore no tags, so `binds` short-circuited on `.deviceCode` and `Ownership.swift`'s
`depots.contains(designation)` guard had zero coverage. Repaired by asserting on a device that actually
wears the belt tag, proven by three separate mutations of `leaseDepot`.

`DirectiveGroup.missionKeys` was left unchanged: it holds no lease derivation after tickets 09/10.
It does still hand-write the `.deviceCode` seed, but folding it would change behaviour — `missionKeys`
is first-wins in newest-first row order while `holders(of:)` is id-ordered. On the punch list.
