# 09 — `FleetTag` value type + `Device.fleetTags` / `carries`

Type: task
Status: resolved
Blocked by: 01
Labels: directives-architecture, stage-1

Spec S1.1. The grammar `auto:<goal>[:<depot|belt>]` exists only in comments; six formatters and seven parsers exist (audit F3). One type in `GameModels`. Per D2 the canonical string may go on the wire as-is; the server lowercases, so the canonical form is lowercase throughout.

**Files:**
- Create: `app/Modules/GameModels/Sources/FleetTag.swift`
- Modify: `app/Modules/GameModels/Sources/Device.swift` (`fleetTags`, `carries`)
- Create: `app/Modules/GameModels/Tests/FleetTagTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct FleetTag: Hashable, Sendable, Codable, CustomStringConvertible {
      public enum Goal: String, CaseIterable, Sendable, Codable {
          case haul, survey, salvage, mine, carrier, event
          case tendMesh = "tendmesh"
      }
      public enum Scope: Hashable, Sendable, Codable {
          case theatre(depot: String)   // designation, stored lowercased, compared case-insensitively
          case belt(designation: String)
          /// The raw third segment; a theatre depot and a belt are both designations —
          /// the goal decides which one this is (`.mine` ferries → belt, everything else → theatre).
          public var designation: String { get }
      }
      public enum MatchPolicy: Sendable { case exact, exactOrUnscoped }

      public let goal: Goal
      public let scope: Scope?
      public init(goal: Goal, scope: Scope? = nil)
      public init?(parsing raw: String)        // "auto:haul", "auto:haul:AINALRAM-BELT-1", "AUTO:TendMesh" all parse
      public var string: String                // "auto:haul:ainalram-belt-1"
      public var unscoped: FleetTag
      public var isScoped: Bool
      public static let prefix = "auto:"
      public var description: String { string }
  }
  extension Device {
      public var fleetTags: [FleetTag]         // parsed from `tags`, non-auto tags skipped
      public func carries(_ tag: FleetTag, policy: FleetTag.MatchPolicy) -> Bool
      /// A device wearing any scoped tag for `goal` — nil when unscoped-only or absent.
      public func scopedTag(for goal: FleetTag.Goal) -> FleetTag?
  }
  ```
  Parsing rule for the third segment: `goal == .mine` → `.belt`; else → `.theatre`. (`Brain.mineFerryTag` uses `.belt`; `MineRecipe.fleetTag(forTheatre:)` for the INSTALL directive uses `.theatre` — that one becomes `FleetTag(goal: .mine, scope: .theatre(depot:))` and its `string` is indistinguishable from a belt tag; the consumer knows which by context. Document that in the type's header line, ≤ 6 lines.)

---

- [x] **Step 1: Failing tests**

```swift
@Test func parsesUnscopedAndScoped() {
    #expect(FleetTag(parsing: "auto:haul") == FleetTag(goal: .haul))
    #expect(FleetTag(parsing: "auto:haul:AINALRAM-BELT-1") == FleetTag(goal: .haul, scope: .theatre(depot: "ainalram-belt-1")))
    #expect(FleetTag(parsing: "auto:mine:TAU-BELT-2") == FleetTag(goal: .mine, scope: .belt(designation: "tau-belt-2")))
    #expect(FleetTag(parsing: "AUTO:TendMesh") == FleetTag(goal: .tendMesh))
    #expect(FleetTag(parsing: "auto:unknown") == nil)
    #expect(FleetTag(parsing: "manual:haul") == nil)
}
@Test func stringIsCanonicalLowercase() { #expect(FleetTag(goal: .survey, scope: .theatre(depot: "SOL-1")).string == "auto:survey:sol-1") }
@Test func carriesPolicies() {
    let d = device(tags: ["auto:survey"])
    let scoped = FleetTag(goal: .survey, scope: .theatre(depot: "SOL-1"))
    #expect(!d.carries(scoped, policy: .exact))
    #expect(d.carries(scoped, policy: .exactOrUnscoped))
    #expect(device(tags: ["auto:survey:sol-1"]).carries(scoped, policy: .exact))
}
@Test func scopedTagForGoal() { /* ["auto:survey","auto:survey:sol-1"] → scoped == sol-1; ["auto:survey"] → nil */ }
@Test func roundTripsThroughDeviceTags() { /* Device.normalizedTag(tag.string) == tag.string */ }
```

- [x] **Step 2: Implement; run `GameModelsTests`; commit**

`feat(models): FleetTag — one grammar for auto:<goal>[:<scope>]`.

## Comments

Resolved in `02207fa` (implementation) and `0846dbe` (review fixes).

All five targets green at `02207fa`: GameModelsTests 148/148, DirectiveEngineTests 1602/1602,
GameServicesTests 324/324, GameSyncTests 81/81, DirectivesFeatureTests 287/287.

**Controller ruling R2 — `FleetTag` equality ignores the scope case.** `Scope.theatre(depot:)` and
`Scope.belt(designation:)` render the same canonical string, and `init?(parsing:)` picks the case from
the goal. `MineRecipe.fleetTag(forTheatre:)` (live at `Brain.swift:551`) constructs goal `.mine` with a
`.theatre(depot:)` scope, which parses back as `.belt` — a synthesised `Hashable` would have made the
constructed and parsed tags unequal, and ticket 11's `Ownership.resolve` would have silently failed to
match a mineRun row's tag. `Equatable`/`Hashable` are therefore hand-written over `(goal,
scope?.designation)` on both `FleetTag` and `FleetTag.Scope`, covered by `scopeCaseDoesNotAffectEquality`.

Review found two things, both fixed in `0846dbe`: the file header shipped at 11 lines against the ≤ 6
budget, and a test comment pointed at an ephemeral SDD report file instead of the spec.

**Note for later tickets:** `check-comments.sh` has no line-count logic, so it cannot enforce the header
and `///` budgets — those need a manual count in review.
