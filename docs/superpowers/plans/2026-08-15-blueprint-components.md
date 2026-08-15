# Blueprint Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the app that some blueprints require other printed devices, so the
brain prices an event option through its whole component tree, refuses options it
cannot build, and prints prerequisites before the device that consumes them.

**Architecture:** One additive column on `blueprints` carries the wire's
`components` map. A new pure `BlueprintClosure` walks that map to produce a rolled-up
`ResourceCost`, a dependency-ordered job list, and the set of device types with no
blueprint. The two existing pricing sites call it instead of doing a single flat
lookup; `EventPlan` gains a `.blocked` resolution so an unbuildable option never
reaches ranking; `EventRun.printing` dispatches the job list deepest-first and
arms its already-declared-but-unused deadline. Three read-only surfaces stop
misreporting a component blockage.

**Tech Stack:** Swift 6, SwiftUI, Point-Free Composable Architecture,
SQLiteData/GRDB, swift-openapi-generator, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-15-blueprint-components-design.md`

## Global Constraints

- **Database migrations are append-only.** A schema change appends a new
  `SchemaMigration` to `GameDatabase.manifest`. Never edit a shipped
  `CREATE TABLE`. Adding a column means a new `ALTER TABLE` migration.
  `SchemaManifestTests.frozenIdentifiers` must gain the new identifier;
  `GoldenSchemaTests` is regenerated with `RC_REGENERATE_SCHEMA_FIXTURE=1`.
- **Comment budget is hard:** file header ≤ 6 lines, `///` doc ≤ 3 lines,
  inline `//` ≤ 2 lines. No dated history, no rejected alternatives, no
  rationale — those go to `app/.claude/memory/`.
- **Never hard-code colours, spacing or font sizes.** Use `DesignSystem.swift`
  tokens (`.rcTextPrimary`, `Space.m`, `Radius.card`, `Font.rcCaption`, …).
- **System and location names always render in a monospace token**
  (`.rcMono`, `.rcMonoSmall`, …). Device type names are not location names and
  render in normal type.
- **Read test results from the JSON event stream**, never by grepping console
  text. Use the `swift-test-event-stream` skill.
- **Commits go to the current branch** (`worktree-blueprint-components`). No PRs,
  no pushes, no `origin`.
- **Six resource types, always:** `carbon`, `silicates`, `structural`, `rares`,
  `conductive`, `volatiles`.
- **Name collision to avoid:** `WorldSnapshot.components` already exists and is
  the FTL **mesh** component map (`[String: String]`, system → component label).
  Blueprint components must be named `blueprintComponents` everywhere on both
  `WorldSnapshot` and `WorldView`. Never shadow the mesh one.

## Working directory and one-time setup

All paths are relative to the worktree root
`/Users/matt/Developer/replicant-macos/.claude/worktrees/blueprint-components`.
Do not `cd` to the main checkout.

This has already been done once and only needs repeating if `.build` is wiped:

```bash
cd app/Modules && swift build --build-tests && ./scripts/link-index-store.sh
```

Without `link-index-store.sh` every SourceKit-LSP reference query silently
returns zero results. The index is exactly as fresh as your last build: build,
then query.

Run tests from `app/Modules`.

---

### Task 1: `Blueprint.components` — the column

The wire and the generated client already carry `components`;
`Blueprint.init(schema:)` drops it. This task stops dropping it.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Blueprint.swift` (struct at `:23-75`, mapping at `:209-225`, schema section at `:230-255`)
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift:47` (the `manifest` array)
- Modify: `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift:26` (`frozenIdentifiers`)
- Test: `app/Modules/GameModels/Tests/BlueprintComponentsTests.swift` (create)
- Regenerate: `app/Modules/GameDatabase/Tests/Fixtures/schema.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: `Blueprint.components: [String: Int]` (empty when the payload omits
  it); `Blueprint.addComponents: SchemaMigration` with identifier
  `"Add 'components' to blueprints"`; the memberwise `init` gains
  `components: [String: Int] = [:]` as its **last** parameter.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/GameModels/Tests/BlueprintComponentsTests.swift`:

```swift
import Foundation
import Testing
@testable import GameModels

@Suite("Blueprint components")
struct BlueprintComponentsTests {
    @Test("a blueprint with no components decodes to an empty map")
    func absentComponents() {
        let blueprint = Blueprint(
            deviceType: "mining_drone", shortDescription: "", fullDescription: "",
            printTime: 200, features: [], directives: [],
            resources: ResourceCost(carbon: 25), stowCapacity: 0, cargoCapacity: 0,
            attachCapacity: 0, queueSize: 0, strength: 0, currentHubs: nil
        )
        #expect(blueprint.components.isEmpty)
    }

    @Test("a blueprint carries its component bill")
    func presentComponents() {
        let blueprint = Blueprint(
            deviceType: "atmospheric_regulator", shortDescription: "", fullDescription: "",
            printTime: 3600, features: [], directives: [],
            resources: ResourceCost(silicates: 200, structural: 200, conductive: 300, volatiles: 150),
            stowCapacity: 0, cargoCapacity: 0, attachCapacity: 0, queueSize: 0,
            strength: 0, currentHubs: nil,
            components: ["filtration_array": 1, "atmo_processor": 2]
        )
        #expect(blueprint.components == ["filtration_array": 1, "atmo_processor": 2])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter "Blueprint components"`
Expected: FAIL — `value of type 'Blueprint' has no member 'components'`, and the
second test fails to compile on the unknown `components:` argument.

- [ ] **Step 3: Add the stored property**

In `app/Modules/GameModels/Sources/Blueprint.swift`, after `currentHubs` at `:42`:

```swift
    /// Other printed devices this blueprint consumes, on top of `resources`.
    /// Empty for most blueprints; the wire omits the key entirely.
    @Column(as: [String: Int].JSONRepresentation.self) public var components: [String: Int]
```

Add the parameter to the memberwise `init` as the **last** parameter, with a
default so existing construction sites keep compiling:

```swift
        currentHubs: Int?,
        components: [String: Int] = [:]
    ) {
```

and the assignment as the last line of the body:

```swift
        self.components = components
```

If `[String: Int].JSONRepresentation` does not resolve, SQLiteData does not
vend a representation for `Dictionary`. Fall back to a tiny wrapper mirroring
`ResourceCost`'s shape — `public struct ComponentBill: Codable, Equatable,
Sendable { public var bill: [String: Int] }` — and use
`@Column(as: ComponentBill.JSONRepresentation.self)`. Everything downstream
reads `blueprint.components` either way, so only this file changes.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app/Modules && swift test --filter "Blueprint components"`
Expected: PASS

- [ ] **Step 5: Map the field from the wire**

In `Blueprint.init(schema:)` at `:209-225`, add as the last argument:

```swift
            currentHubs: schema.currentHubs,
            components: schema.components?.additionalProperties ?? [:]
        )
```

- [ ] **Step 6: Add the migration**

At the end of the `// MARK: - Schema` extension in `Blueprint.swift`, after
`createBlueprints`:

```swift
    /// Adds the `components` column — the other printed devices a blueprint
    /// consumes, beyond its raw `resources`.
    public static let addComponents = SchemaMigration("Add 'components' to blueprints") { db in
        try #sql(
            """
            ALTER TABLE "blueprints" ADD COLUMN "components" TEXT NOT NULL DEFAULT '{}'
            """
        ).execute(db)
    }
```

- [ ] **Step 7: Register it in the manifest**

In `app/Modules/GameDatabase/Sources/GameDatabase.swift`, append
`Blueprint.addComponents` to the **end** of the `manifest` array. Do not insert
it next to `Blueprint.createBlueprints` — the manifest is append-only and
ordering by arrival is what keeps `grdb_migrations` correct.

In `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift`, append
`"Add 'components' to blueprints"` to the **end** of `frozenIdentifiers`.

- [ ] **Step 8: Regenerate the golden schema**

Run: `cd app/Modules && RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --filter GoldenSchema`
Then run without the variable to confirm it passes:
`cd app/Modules && swift test --filter "GoldenSchema|SchemaManifest"`
Expected: PASS. Confirm `Tests/Fixtures/schema.sql` now shows
`"components" TEXT NOT NULL DEFAULT '{}'` on the `blueprints` table.

- [ ] **Step 9: Full model + database suite**

Run: `cd app/Modules && swift test --filter "GameModelsTests|GameDatabaseTests"`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add app/Modules/GameModels/Sources/Blueprint.swift \
        app/Modules/GameModels/Tests/BlueprintComponentsTests.swift \
        app/Modules/GameDatabase/Sources/GameDatabase.swift \
        app/Modules/GameDatabase/Tests/SchemaManifestTests.swift \
        app/Modules/GameDatabase/Tests/Fixtures/schema.sql
git commit -m "feat(blueprints): carry the components bill from the wire"
```

---

### Task 2: `BlueprintClosure` — the recursive expansion

The codebase has no transitive cost expansion. This adds one, pure and
testable, with a cycle guard and an explicit unprintable set.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/BlueprintClosure.swift`
- Modify: `app/Modules/GameModels/Sources/Blueprint.swift` (add `ResourceCost.scaled(by:)` after `add(_:)` at `:188`)
- Test: `app/Modules/DirectiveEngine/Tests/BlueprintClosureTests.swift` (create)

**Interfaces:**
- Consumes: `Blueprint.components` (Task 1), `ResourceCost` from `GameModels`.
- Produces:
  - `ResourceCost.scaled(by factor: Int) -> ResourceCost`
  - `BlueprintClosure.Job` — `deviceType: String`, `quantity: Int`, `depth: Int`
  - `BlueprintClosure.Expansion` — `resources: ResourceCost`, `jobs: [Job]`,
    `printSeconds: Int`, `unprintable: Set<String>`
  - `BlueprintClosure.expand(_ wanted: [String: Int], bills: [String: ResourceCost], components: [String: [String: Int]], printTimes: [String: Int] = [:]) -> Expansion`

`printTimes` is defaulted because no production caller supplies it yet — only
the tests do. Wiring a `blueprintPrintTimes` map through `WorldView` is
deliberately out of scope; `printSeconds` reads 0 in production and the type is
ready when a caller needs it.

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/DirectiveEngine/Tests/BlueprintClosureTests.swift`:

```swift
import Foundation
import GameModels
import Testing
@testable import DirectiveEngine

@Suite("BlueprintClosure")
struct BlueprintClosureTests {
    /// The live catalogue's component-bearing blueprints and their leaves. The
    /// four blueprints the account cannot print are deliberately absent.
    private let bills: [String: ResourceCost] = [
        "climate_processor": ResourceCost(
            carbon: 250, structural: 200, rares: 100, conductive: 250, volatiles: 200
        ),
        "atmospheric_regulator": ResourceCost(
            silicates: 200, structural: 200, conductive: 300, volatiles: 150
        ),
        "biosphere_cultivator": ResourceCost(
            carbon: 300, structural: 100, conductive: 150, volatiles: 200
        ),
        "atmo_processor": ResourceCost(
            carbon: 150, structural: 200, conductive: 100, volatiles: 100
        ),
        "filtration_array": ResourceCost(
            carbon: 260, structural: 140, conductive: 110, volatiles: 60
        ),
        "orbital_farm": ResourceCost(
            carbon: 30, silicates: 20, structural: 400, rares: 50, conductive: 20, volatiles: 120
        ),
        "compute_core": ResourceCost(
            carbon: 2, silicates: 55, structural: 8, rares: 15, conductive: 35
        ),
        "processing_array": ResourceCost(conductive: 200),
        "mining_drone": ResourceCost(carbon: 25, silicates: 25, structural: 100, conductive: 50),
    ]

    private let components: [String: [String: Int]] = [
        "atmospheric_regulator": ["filtration_array": 1, "atmo_processor": 2],
        "biosphere_cultivator": ["hydroponic_bay": 2, "nutrient_synthesizer": 1, "orbital_farm": 1],
        "climate_processor": ["orbital_mirror": 1, "terraform_controller": 1, "atmo_processor": 2],
        "processing_array": ["compute_core": 5],
    ]

    @Test("a blueprint with no components expands to itself")
    func flat() {
        let out = BlueprintClosure.expand(["mining_drone": 2], bills: bills, components: components)
        #expect(out.resources.total == 400)
        #expect(out.jobs == [BlueprintClosure.Job(deviceType: "mining_drone", quantity: 2, depth: 0)])
        #expect(out.unprintable.isEmpty)
    }

    @Test("one level expands components before the parent")
    func oneLevel() {
        let out = BlueprintClosure.expand(
            ["processing_array": 1], bills: bills, components: components
        )
        #expect(out.jobs.map(\.deviceType) == ["compute_core", "processing_array"])
        #expect(out.jobs.first?.quantity == 5)
        // 200 for the array + 5 × 115 for the cores.
        #expect(out.resources.total == 775)
        #expect(out.unprintable.isEmpty)
    }

    @Test("a component reached twice merges into one job")
    func sharedComponent() {
        let out = BlueprintClosure.expand(
            ["atmospheric_regulator": 1, "climate_processor": 1],
            bills: bills, components: components
        )
        let atmo = out.jobs.first { $0.deviceType == "atmo_processor" }
        #expect(atmo?.quantity == 4)
        #expect(out.jobs.filter { $0.deviceType == "atmo_processor" }.count == 1)
    }

    @Test("an unknown blueprint is named and contributes nothing")
    func unknownLeaf() {
        let out = BlueprintClosure.expand(
            ["climate_processor": 2], bills: bills, components: components
        )
        #expect(out.unprintable == ["orbital_mirror", "terraform_controller"])
        // 2 × 1000 for the processors + 4 × 550 for the atmo processors. The two
        // unknown blueprints contribute nothing, so this is a lower bound.
        #expect(out.resources.total == 4200)
    }

    @Test("a cycle is refused rather than followed")
    func cycle() {
        let out = BlueprintClosure.expand(
            ["a": 1],
            bills: ["a": ResourceCost(carbon: 1), "b": ResourceCost(carbon: 1)],
            components: ["a": ["b": 1], "b": ["a": 1]]
        )
        #expect(out.unprintable.contains("a"))
    }

    @Test("deeper components sort ahead of shallower ones")
    func depthOrder() {
        let out = BlueprintClosure.expand(
            ["top": 1],
            bills: ["top": ResourceCost(), "mid": ResourceCost(), "leaf": ResourceCost()],
            components: ["top": ["mid": 1], "mid": ["leaf": 1]]
        )
        #expect(out.jobs.map(\.deviceType) == ["leaf", "mid", "top"])
    }

    @Test("print seconds sum over the whole tree")
    func printSeconds() {
        let out = BlueprintClosure.expand(
            ["processing_array": 1], bills: bills, components: components,
            printTimes: ["processing_array": 400, "compute_core": 200]
        )
        #expect(out.printSeconds == 1400)
    }

    @Test("the TABAT-4-EVT-007 options reverse order once components are counted")
    func liveEventOptions() {
        let biosphere = BlueprintClosure.expand(
            ["climate_processor": 2, "biosphere_cultivator": 1], bills: bills, components: components
        )
        let atmospheric = BlueprintClosure.expand(
            ["climate_processor": 2, "atmospheric_regulator": 1], bills: bills, components: components
        )
        // Naive (top-level bills only) makes atmospheric cheaper: 3,350 vs 3,450
        // once the event's own resources are added. Expanded, it is dearer.
        #expect(biosphere.resources.total + 700 == 6290)
        #expect(atmospheric.resources.total + 500 == 7220)
        #expect(biosphere.resources.total < atmospheric.resources.total)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter BlueprintClosure`
Expected: FAIL — `cannot find 'BlueprintClosure' in scope`.

- [ ] **Step 3: Add `ResourceCost.scaled(by:)`**

In `app/Modules/GameModels/Sources/Blueprint.swift`, immediately after
`add(_:)` at `:185-188`:

```swift
    /// Every field multiplied by `factor`, for costing a quantity in one step.
    public func scaled(by factor: Int) -> ResourceCost {
        ResourceCost(
            carbon: carbon * factor, silicates: silicates * factor,
            structural: structural * factor, rares: rares * factor,
            conductive: conductive * factor, volatiles: volatiles * factor
        )
    }
```

- [ ] **Step 4: Write the expansion**

Create `app/Modules/DirectiveEngine/Sources/BlueprintClosure.swift`:

```swift
//
//  BlueprintClosure.swift
//  Replicould — DirectiveEngine
//
//  What a set of devices really costs: raw material rolled up through the
//  blueprint components each one consumes, and the prints that build them.
//

import Foundation
import GameModels

public enum BlueprintClosure {
    /// One print in a build order. `depth` is 0 for a requested device and rises
    /// by one per component level, so a higher depth must print first.
    public struct Job: Equatable, Sendable {
        public let deviceType: String
        public let quantity: Int
        public let depth: Int

        public init(deviceType: String, quantity: Int, depth: Int) {
            self.deviceType = deviceType
            self.quantity = quantity
            self.depth = depth
        }
    }

    /// A device set costed through its whole component tree. `resources` is a
    /// LOWER BOUND whenever `unprintable` is non-empty — callers must branch on
    /// the set, never on the number.
    public struct Expansion: Equatable, Sendable {
        public let resources: ResourceCost
        public let jobs: [Job]
        public let printSeconds: Int
        public let unprintable: Set<String>

        public init(
            resources: ResourceCost, jobs: [Job], printSeconds: Int, unprintable: Set<String>
        ) {
            self.resources = resources
            self.jobs = jobs
            self.printSeconds = printSeconds
            self.unprintable = unprintable
        }
    }

    /// Expand `wanted` through `components`, costing each node from `bills`. A
    /// device with no bill, and a device already on the current path, are both
    /// recorded in `unprintable` and their subtrees abandoned.
    public static func expand(
        _ wanted: [String: Int],
        bills: [String: ResourceCost],
        components: [String: [String: Int]],
        printTimes: [String: Int] = [:]
    ) -> Expansion {
        var resources = ResourceCost()
        var quantities: [String: Int] = [:]
        var depths: [String: Int] = [:]
        var unprintable: Set<String> = []

        func visit(_ type: String, _ quantity: Int, _ depth: Int, _ path: Set<String>) {
            guard !path.contains(type) else { unprintable.insert(type); return }
            guard let bill = bills[type] else { unprintable.insert(type); return }
            resources.add(bill.scaled(by: quantity))
            quantities[type, default: 0] += quantity
            depths[type] = max(depths[type] ?? 0, depth)
            let onward = path.union([type])
            for (child, count) in components[type] ?? [:] {
                visit(child, quantity * count, depth + 1, onward)
            }
        }

        for (type, quantity) in wanted where quantity > 0 {
            visit(type, quantity, 0, [])
        }

        let jobs = quantities
            .map { Job(deviceType: $0.key, quantity: $0.value, depth: depths[$0.key] ?? 0) }
            .sorted { lhs, rhs in
                lhs.depth == rhs.depth ? lhs.deviceType < rhs.deviceType : lhs.depth > rhs.depth
            }
        let seconds = jobs.reduce(0) { $0 + (printTimes[$1.deviceType] ?? 0) * $1.quantity }
        return Expansion(
            resources: resources, jobs: jobs, printSeconds: seconds, unprintable: unprintable
        )
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter BlueprintClosure`
Expected: PASS, all 8 tests.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/BlueprintClosure.swift \
        app/Modules/DirectiveEngine/Tests/BlueprintClosureTests.swift \
        app/Modules/GameModels/Sources/Blueprint.swift
git commit -m "feat(engine): expand a device set through its blueprint components"
```

---

### Task 3: `EventPlan` prices through the tree and refuses what it cannot build

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/EventPlan.swift` (whole file, 69 lines)
- Test: `app/Modules/DirectiveEngine/Tests/EventPlanTests.swift` (extend; the suite already seeds `climate_processor` and `atmospheric_regulator` costs)

**Interfaces:**
- Consumes: `BlueprintClosure.expand`, `BlueprintClosure.Job` (Task 2).
- Produces:
  - `EventPlan.Option` gains `unprintable: Set<String>` and `jobs: [BlueprintClosure.Job]`
  - `EventPlan.Resolution` gains `case blocked([Option])`
  - `EventPlan.resolve(_:chosenOption:bills:components:)` — `components` defaults
    to `[:]`, so the four `EventRun` call sites passing `bills: [:]` keep compiling

- [ ] **Step 1: Write the failing tests**

Append to `EventPlanTests.swift`, inside the existing `struct EventPlanTests`:

```swift
    private let componentBills: [String: [String: Int]] = [
        "climate_processor": ["orbital_mirror": 1, "terraform_controller": 1, "atmo_processor": 2],
        "atmospheric_regulator": ["filtration_array": 1, "atmo_processor": 2],
    ]

    @Test("device units count the whole component tree")
    func pricesComponents() throws {
        var withAtmo = costs
        withAtmo["atmo_processor"] = ResourceCost(
            carbon: 150, structural: 200, conductive: 100, volatiles: 100
        )
        withAtmo["filtration_array"] = ResourceCost(
            carbon: 260, structural: 140, conductive: 110, volatiles: 60
        )
        let row = event(.array([
            option("only", devices: [(1, "atmospheric_regulator")], resources: [:])
        ]))
        guard case .decided(let plan) = EventPlan.resolve(
            row, chosenOption: nil, bills: withAtmo, components: componentBills
        ) else { Issue.record("expected .decided"); return }
        // 850 for the regulator, 570 for the filtration array, 2 × 550 for the
        // atmo processors.
        #expect(plan.deviceUnits == 2520)
        #expect(plan.jobs.map(\.deviceType) == ["atmo_processor", "filtration_array", "atmospheric_regulator"])
    }

    @Test("an option needing an unknown blueprint is blocked, not decided")
    func blockedOption() throws {
        let row = event(.array([
            option("only", devices: [(2, "climate_processor")], resources: ["volatiles": 500])
        ]))
        guard case .blocked(let options) = EventPlan.resolve(
            row, chosenOption: nil, bills: costs, components: componentBills
        ) else { Issue.record("expected .blocked"); return }
        #expect(options.first?.unprintable == ["orbital_mirror", "terraform_controller", "atmo_processor"])
    }

    @Test("one printable option among several decides without asking")
    func onePrintableDecides() throws {
        var withAtmo = costs
        withAtmo["atmo_processor"] = ResourceCost(carbon: 150, structural: 200, conductive: 100, volatiles: 100)
        withAtmo["filtration_array"] = ResourceCost(carbon: 260, structural: 140, conductive: 110, volatiles: 60)
        let row = event(.array([
            option("blocked", devices: [(2, "climate_processor")], resources: [:]),
            option("buildable", devices: [(1, "atmospheric_regulator")], resources: [:]),
        ]))
        guard case .decided(let plan) = EventPlan.resolve(
            row, chosenOption: nil, bills: withAtmo, components: componentBills
        ) else { Issue.record("expected .decided"); return }
        #expect(plan.name == "buildable")
    }

    @Test("a choice lists only the printable options")
    func choiceHidesBlocked() throws {
        let row = event(.array([
            option("blocked", devices: [(2, "climate_processor")], resources: [:]),
            option("cheap", devices: [(1, "mesh_relay")], resources: [:]),
            option("dear", devices: [(1, "signal_booster")], resources: [:]),
        ]))
        guard case .needsChoice(let offered) = EventPlan.resolve(
            row, chosenOption: nil, bills: costs, components: componentBills
        ) else { Issue.record("expected .needsChoice"); return }
        #expect(offered.map(\.name) == ["cheap", "dear"])
    }

    @Test("a pick naming a now-unprintable option falls back to a choice")
    func stalePickOnBlockedOption() throws {
        let row = event(.array([
            option("blocked", devices: [(2, "climate_processor")], resources: [:]),
            option("cheap", devices: [(1, "mesh_relay")], resources: [:]),
            option("dear", devices: [(1, "signal_booster")], resources: [:]),
        ]))
        guard case .needsChoice = EventPlan.resolve(
            row, chosenOption: "blocked", bills: costs, components: componentBills
        ) else { Issue.record("expected .needsChoice"); return }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter EventPlan`
Expected: FAIL — no `components:` argument, no `.blocked` case, no `jobs` or
`unprintable` members.

- [ ] **Step 3: Rewrite `EventPlan`**

Replace the body of `app/Modules/DirectiveEngine/Sources/EventPlan.swift` from
`public struct Option` through the end of `price`:

```swift
    /// One way to satisfy an event, priced through its whole component tree.
    public struct Option: Equatable, Sendable {
        public let name: String
        public let devices: [String: Int]
        public let resources: [String: Int]
        /// The build cost of every device in `devices` AND everything they
        /// consume. A lower bound when `unprintable` is non-empty.
        public let deviceUnits: Int
        /// Units of raw resource the event consumes.
        public let resourceUnits: Int
        /// Device types in the tree with no blueprint. Non-empty ⇒ unbuildable.
        public let unprintable: Set<String>
        /// The prints this option needs, prerequisites first.
        public let jobs: [BlueprintClosure.Job]

        public var exceedsOneFreighterLoad: Bool {
            resourceUnits > EventPlan.freighterCargoCapacity
        }
    }

    /// Whether an event can be worked without asking the operator.
    public enum Resolution: Equatable, Sendable {
        case decided(Option)
        case needsChoice([Option])
        /// Every option needs a blueprint the account does not have.
        case blocked([Option])
        /// The blob carries no readable option — never treat this as free.
        case undecodable
    }

    /// Resolve `event` against an optional recorded pick, over the printable
    /// options only. A pick naming no printable option is ignored, so a stale
    /// choice re-asks rather than misfires.
    public static func resolve(
        _ event: LocationEvent,
        chosenOption: String?,
        bills: [String: ResourceCost],
        components: [String: [String: Int]] = [:]
    ) -> Resolution {
        guard let detail = LocationEventDetail(event.detail), !detail.options.isEmpty else {
            return .undecodable
        }
        let priced = detail.options.map { price($0, bills, components) }
        let printable = priced.filter(\.unprintable.isEmpty)
        if printable.isEmpty { return .blocked(priced) }
        if printable.count == 1, let only = printable.first { return .decided(only) }
        if let name = chosenOption, let picked = printable.first(where: { $0.name == name }) {
            return .decided(picked)
        }
        return .needsChoice(printable)
    }

    private static func price(
        _ option: LocationEventDetail.Option,
        _ bills: [String: ResourceCost],
        _ components: [String: [String: Int]]
    ) -> Option {
        let devices = option.devices.reduce(into: [String: Int]()) { $0[$1.deviceType] = $1.required }
        let resources = option.resources.reduce(into: [String: Int]()) { $0[$1.resourceType] = $1.required }
        let expansion = BlueprintClosure.expand(devices, bills: bills, components: components)
        return Option(
            name: option.name,
            devices: devices,
            resources: resources,
            deviceUnits: expansion.resources.total,
            resourceUnits: resources.values.reduce(0, +),
            unprintable: expansion.unprintable,
            jobs: expansion.jobs
        )
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter EventPlan`
Expected: PASS. Older tests in the suite still pass because `components`
defaults to `[:]`, which makes every device a leaf — today's behaviour.

- [ ] **Step 5: Check nothing else broke**

Run: `cd app/Modules && swift build --build-tests`
Expected: SUCCESS. Any switch over `Resolution` that is now non-exhaustive
fails here; add a `.blocked` arm that behaves exactly as its `.needsChoice`
arm does, except where a later task changes it.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/EventPlan.swift \
        app/Modules/DirectiveEngine/Tests/EventPlanTests.swift
git commit -m "feat(events): price an option through its component tree and refuse unbuildable ones"
```

---

### Task 4: Surface blocked events in the why-view

`EventRanking.rank` already drops anything that is not `.decided`, so `.blocked`
never reaches ranking without further change. This task makes the operator able
to see why.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/EventRanking.swift` (`pendingChoices` at `:60-74`)
- Modify: `app/Modules/DirectiveEngine/Sources/BrainReport.swift` (`BrainEventChoice` at `:282-326`, `eventChoices` at `:431-465`)
- Test: `app/Modules/DirectiveEngine/Tests/EventRankingTests.swift`, `app/Modules/DirectiveEngine/Tests/BrainReportEventTests.swift`

**Interfaces:**
- Consumes: `EventPlan.Resolution.blocked` (Task 3).
- Produces:
  - `EventRanking.pendingChoices(events:chosenOptions:bills:components:)` — new
    `components` parameter, defaulted `[:]`
  - `EventRanking.blockedEvents(events:bills:components:) -> [(LocationEvent, [EventPlan.Option])]`
  - `BrainEventChoice.Option` gains `unprintable: [String]` (sorted; empty means
    printable)
  - `BrainEventChoice` gains `isBlocked: Bool`
  - `BrainReport.eventChoices(events:bills:components:devices:)` — new
    `components` parameter, defaulted `[:]`; returns pending choices followed by
    blocked events, each sorted by designation

- [ ] **Step 1: Write the failing tests**

Append to `EventRankingTests.swift`:

```swift
    @Test("an event whose every option needs an unknown blueprint is not ranked")
    func blockedIsNotRanked() {
        let row = eventNeeding(devices: [(2, "climate_processor")])
        let ranked = EventRanking.rank(
            events: [row], chosenOptions: [:], bills: [:],
            components: ["climate_processor": ["orbital_mirror": 1]],
            positions: [:], depot: "HUB-1", excluding: []
        )
        #expect(ranked.isEmpty)
    }

    @Test("a blocked event is reported with the blueprints it lacks")
    func blockedIsReported() {
        let row = eventNeeding(devices: [(2, "climate_processor")])
        let blocked = EventRanking.blockedEvents(
            events: [row],
            bills: ["climate_processor": ResourceCost(structural: 200)],
            components: ["climate_processor": ["orbital_mirror": 1, "terraform_controller": 1]]
        )
        #expect(blocked.count == 1)
        #expect(blocked.first?.1.first?.unprintable == ["orbital_mirror", "terraform_controller"])
    }
```

Add the helper to that suite if it does not already have an equivalent:

```swift
    private func eventNeeding(devices: [(Int, String)]) -> LocationEvent {
        LocationEvent(
            designation: "TABAT-4-EVT-007", location: "TABAT-4", tier: 4, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("only"),
                    "devices": .array(devices.map {
                        .object(["count": .number(Double($0.0)), "device_type": .string($0.1)])
                    }),
                    "resources": .object([:]),
                ])])
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }
```

Append to `BrainReportEventTests.swift`:

```swift
    @Test("a blocked event reaches the why-view flagged, with its missing blueprints")
    func blockedReachesTheReport() {
        let row = LocationEvent(
            designation: "TABAT-4-EVT-007", location: "TABAT-4", tier: 4, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("only"),
                    "devices": .array([.object([
                        "count": .number(2), "device_type": .string("climate_processor"),
                    ])]),
                    "resources": .object([:]),
                ])])
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        let choices = BrainReport.eventChoices(
            events: [row],
            bills: ["climate_processor": ResourceCost(structural: 200)],
            components: ["climate_processor": ["orbital_mirror": 1, "terraform_controller": 1]],
            devices: [:]
        )
        #expect(choices.count == 1)
        #expect(choices.first?.isBlocked == true)
        #expect(choices.first?.options.first?.unprintable == ["orbital_mirror", "terraform_controller"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter "EventRanking|BrainReportEvent"`
Expected: FAIL — no `components:` argument, no `blockedEvents`, no
`isBlocked`, no `unprintable`.

- [ ] **Step 3: Thread `components` through `EventRanking`**

In `EventRanking.swift`, add `components: [String: [String: Int]] = [:]` to
`rank` (after `bills:`) and pass it to `EventPlan.resolve`. Do the same for
`pendingChoices`. Then add, after `pendingChoices`:

```swift
    /// The events no option can build, with every option priced so the operator
    /// can see what each would need.
    public static func blockedEvents(
        events: [LocationEvent],
        bills: [String: ResourceCost],
        components: [String: [String: Int]] = [:]
    ) -> [(LocationEvent, [EventPlan.Option])] {
        events
            .filter(\.isActive)
            .compactMap { event in
                guard case .blocked(let offered) = EventPlan.resolve(
                    event, chosenOption: nil, bills: bills, components: components
                ) else { return nil }
                return (event, offered)
            }
            .sorted { $0.0.designation < $1.0.designation }
    }
```

- [ ] **Step 4: Extend `BrainEventChoice`**

In `BrainReport.swift`, add to `BrainEventChoice.Option` (and to its `init`,
as the last parameter with a `[]` default):

```swift
        /// Blueprints this option's component tree needs that the account does
        /// not have. Non-empty means the option cannot be built at any price.
        public let unprintable: [String]
```

Add to `BrainEventChoice` (and to its `init`, last, defaulting `false`):

```swift
    /// Whether every option is unbuildable — a report, not a decision.
    public let isBlocked: Bool
```

Rewrite `eventChoices` to take `components:` and append blocked events:

```swift
    /// The pending event choices and the blocked events, each option priced
    /// against what the fleet already holds. Ordered by designation.
    public static func eventChoices(
        events: [LocationEvent],
        bills: [String: ResourceCost],
        components: [String: [String: Int]] = [:],
        devices: [String: Device]
    ) -> [BrainEventChoice] {
        let held = devices.values.reduce(into: [String: Int]()) { counts, device in
            counts[device.deviceType, default: 0] += 1
        }
        let chosen = events.reduce(into: [String: String]()) { picks, event in
            picks[event.designation] = event.chosenOption
        }
        func choice(
            _ event: LocationEvent, _ options: [EventPlan.Option], blocked: Bool
        ) -> BrainEventChoice {
            BrainEventChoice(
                designation: event.designation,
                location: event.location,
                tier: event.tier,
                options: options.map { option in
                    BrainEventChoice.Option(
                        name: option.name,
                        deviceUnits: option.deviceUnits,
                        resourceUnits: option.resourceUnits,
                        exceedsOneFreighterLoad: option.exceedsOneFreighterLoad,
                        requiredDevices: option.devices.keys.sorted(),
                        missingDevices: option.devices
                            .filter { (held[$0.key] ?? 0) < $0.value }
                            .keys.sorted(),
                        unprintable: option.unprintable.sorted()
                    )
                },
                isBlocked: blocked
            )
        }
        let pending = EventRanking
            .pendingChoices(events: events, chosenOptions: chosen, bills: bills, components: components)
            .map { choice($0, $1, blocked: false) }
        let blocked = EventRanking
            .blockedEvents(events: events, bills: bills, components: components)
            .map { choice($0, $1, blocked: true) }
        return pending + blocked
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter "EventRanking|BrainReportEvent"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/EventRanking.swift \
        app/Modules/DirectiveEngine/Sources/BrainReport.swift \
        app/Modules/DirectiveEngine/Tests/EventRankingTests.swift \
        app/Modules/DirectiveEngine/Tests/BrainReportEventTests.swift
git commit -m "feat(brain): report an event no option can build, naming the missing blueprints"
```

---

### Task 5: `ResourceDemand` prices the tree

Mine siting weights belts by each open event's cheapest option. With components
uncounted, the cheapest option is the wrong one.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/ResourceDemand.swift` (`compute` at `:38-58`, `price` at `:61-79`)
- Test: `app/Modules/DirectiveEngine/Tests/ResourceDemandTests.swift`

**Interfaces:**
- Consumes: `BlueprintClosure.expand` (Task 2).
- Produces: `ResourceDemand.compute(events:bills:components:reserveFloors:)` —
  new `components` parameter, defaulted `[:]`.

- [ ] **Step 1: Write the failing test**

Append to `ResourceDemandTests.swift`:

```swift
    @Test("the cheapest option changes once components are counted")
    func componentsChangeTheCheapestOption() {
        let bills: [String: ResourceCost] = [
            "cheap_shell": ResourceCost(structural: 100),
            "dear_shell": ResourceCost(structural: 150),
            "hidden_core": ResourceCost(structural: 500),
        ]
        let components = ["cheap_shell": ["hidden_core": 1]]
        let row = twoOptionEvent(
            first: ("shell", [(1, "cheap_shell")]),
            second: ("plain", [(1, "dear_shell")])
        )
        let flat = ResourceDemand.compute(events: [row], bills: bills, reserveFloors: [:])
        #expect(flat.pricedEvents[row.designation]?.first?.name == "shell")

        let deep = ResourceDemand.compute(
            events: [row], bills: bills, components: components, reserveFloors: [:]
        )
        #expect(deep.pricedEvents[row.designation]?.first?.name == "plain")
        #expect(deep.total["structural"] == 150)
    }

    @Test("an option needing an unknown blueprint anywhere in its tree is dropped")
    func unknownInTreeDropsTheOption() {
        let bills: [String: ResourceCost] = ["shell": ResourceCost(structural: 100)]
        let components = ["shell": ["mystery": 1]]
        let row = twoOptionEvent(
            first: ("only", [(1, "shell")]),
            second: ("only2", [(1, "shell")])
        )
        let demand = ResourceDemand.compute(
            events: [row], bills: bills, components: components, reserveFloors: [:]
        )
        #expect(demand.pricedEvents[row.designation] == nil)
    }
```

Add the helper if the suite lacks one:

```swift
    private func twoOptionEvent(
        first: (String, [(Int, String)]), second: (String, [(Int, String)])
    ) -> LocationEvent {
        func opt(_ pair: (String, [(Int, String)])) -> JSONValue {
            .object([
                "name": .string(pair.0),
                "devices": .array(pair.1.map {
                    .object(["count": .number(Double($0.0)), "device_type": .string($0.1)])
                }),
                "resources": .object([:]),
            ])
        }
        return LocationEvent(
            designation: "D-1-EVT-001", location: "D-1", tier: 2, status: "active",
            detail: .object(["criteria": .array([opt(first), opt(second)])]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter ResourceDemand`
Expected: FAIL — no `components:` argument.

- [ ] **Step 3: Expand in `price`**

Add `components: [String: [String: Int]] = [:]` to `compute` (after `bills:`)
and thread it into the `price` call at `:49`. Replace the device loop in
`price` (`:70-77`) with an expansion:

```swift
    /// One option's unmet remainder, or nil when its tree needs a blueprint the
    /// account does not have.
    private static func price(
        _ option: LocationEventDetail.Option,
        bills: [String: ResourceCost],
        components: [String: [String: Int]]
    ) -> PricedOption? {
        var cost: [String: Double] = [:]
        for line in option.resources {
            let remaining = max(0, line.required - line.current)
            guard remaining > 0 else { continue }
            cost[line.resourceType.lowercased(), default: 0] += Double(remaining)
        }
        var outstanding: [String: Int] = [:]
        for line in option.devices {
            let remaining = max(0, line.required - line.current)
            guard remaining > 0 else { continue }
            outstanding[line.deviceType, default: 0] += remaining
        }
        let expansion = BlueprintClosure.expand(outstanding, bills: bills, components: components)
        guard expansion.unprintable.isEmpty else { return nil }
        for (type, amount) in expansion.resources.wireDictionary where amount > 0 {
            cost[type, default: 0] += Double(amount)
        }
        return PricedOption(name: option.name, cost: cost)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter ResourceDemand`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/ResourceDemand.swift \
        app/Modules/DirectiveEngine/Tests/ResourceDemandTests.swift
git commit -m "feat(engine): price fleet demand through blueprint components"
```

---

### Task 6: Carry the component map on both world views

`WorldView` feeds the brain's ranking; `WorldSnapshot` feeds a running mission.
Both need the map, under a name that does not collide with the mesh one.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldView.swift` (field beside `:91`, load at `:171-173`, construction at `:239`)
- Modify: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift` (field beside `:80`, `read` at `:327-342`, `init`)
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift` (`:1970`, `:1971`, `:1514-1534`, `:189-191`)
- Test: `app/Modules/DirectiveEngine/Tests/BrainEventTests.swift`

**Interfaces:**
- Consumes: `Blueprint.components` (Task 1); the `components:` parameters from
  Tasks 3–5.
- Produces:
  - `WorldView.blueprintComponents: [String: [String: Int]]`
  - `WorldSnapshot.blueprintBills: [String: ResourceCost]` and
    `WorldSnapshot.blueprintComponents: [String: [String: Int]]`, both defaulting
    to `[:]` in the init so every existing fixture keeps compiling

- [ ] **Step 1: Write the failing test**

Append to `BrainEventTests.swift`:

```swift
    @Test("the brain will not launch a run for an event it cannot build")
    func blockedEventNeverLaunches() throws {
        let event = LocationEvent(
            designation: "TABAT-4-EVT-007", location: "TABAT-4", tier: 4, status: "active",
            detail: .object([
                "criteria": .array([.object([
                    "name": .string("only"),
                    "devices": .array([.object([
                        "count": .number(2), "device_type": .string("climate_processor"),
                    ])]),
                    "resources": .object([:]),
                ])])
            ]),
            firstSeenAt: .distantPast, updatedAt: .distantPast
        )
        let view = BrainTestSupport.eventView(
            events: [event],
            bills: ["climate_processor": ResourceCost(structural: 200)],
            blueprintComponents: ["climate_processor": ["orbital_mirror": 1]]
        )
        guard case .idle = Brain.eventReadiness(view: view, directives: [], theatre: view.theatres[0])
        else { Issue.record("expected .idle for an unbuildable event"); return }
    }
```

If `BrainTestSupport` has no `eventView` helper with those parameters, add one
mirroring the existing view builder in that file and give
`blueprintComponents` a `[:]` default.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter BrainEvent`
Expected: FAIL — `blueprintComponents` is not a member of the view.

- [ ] **Step 3: Add the field to `WorldView`**

In `WorldView.swift`, after `blueprintBills` at `:91`:

```swift
    /// Device type → the other printed devices its blueprint consumes. Empty
    /// until the catalog is fetched, which makes every device read as a leaf.
    public let blueprintComponents: [String: [String: Int]]
```

Change the select at `:172` to take a third column and build both maps:

```swift
        let billRows = try Blueprint.all
            .select { ($0.deviceType, $0.resources, $0.components) }
            .fetchAll(db)
        let bills = Dictionary(
            billRows.map { ($0.0, $0.1) }, uniquingKeysWith: { _, last in last }
        )
        let blueprintComponents = Dictionary(
            billRows.map { ($0.0, $0.2) }, uniquingKeysWith: { _, last in last }
        )
```

Pass `blueprintComponents: blueprintComponents` in the constructor at `:239`,
and add the parameter to `WorldView`'s `init` with a `[:]` default.

- [ ] **Step 4: Add both fields to `WorldSnapshot`**

In `WorldSnapshot.swift`, after `components` at `:80` — and named so the two
never read alike:

```swift
    /// Device type → its blueprint's build cost, mirroring `WorldView`. Distinct
    /// from `components` above, which is the FTL mesh.
    public let blueprintBills: [String: ResourceCost]
    /// Device type → the printed devices its blueprint consumes.
    public let blueprintComponents: [String: [String: Int]]
```

Both take `= [:]` defaults in the `init` at `:124`. In `read` (`:300-342`),
alongside the existing reads:

```swift
            let blueprintRows = try Blueprint.all
                .select { ($0.deviceType, $0.resources, $0.components) }
                .fetchAll(db)
            let blueprintBills = Dictionary(
                blueprintRows.map { ($0.0, $0.1) }, uniquingKeysWith: { _, last in last }
            )
            let blueprintComponents = Dictionary(
                blueprintRows.map { ($0.0, $0.2) }, uniquingKeysWith: { _, last in last }
            )
```

and pass both in the `WorldSnapshot(` construction at `:327`.

- [ ] **Step 5: Pass the map at the brain's call sites**

In `Brain.swift`:
- `:1970` — `EventRanking.rank(..., bills: view.blueprintBills, components: view.blueprintComponents, ...)`
- `:1514-1534` — `ResourceDemand.compute(events:..., bills: view.blueprintBills, components: view.blueprintComponents, reserveFloors: BrainCeiling.reserveFloors)`
- `:189-191` — `BrainReport.eventChoices(events:..., bills:..., components: view.blueprintComponents, devices:...)`

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter "BrainEvent|WorldView|WorldSnapshot"`
Expected: PASS

- [ ] **Step 7: Full engine suite**

Run: `cd app/Modules && swift test --filter DirectiveEngineTests`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/WorldView.swift \
        app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift \
        app/Modules/DirectiveEngine/Sources/Brain.swift \
        app/Modules/DirectiveEngine/Tests/BrainEventTests.swift
git commit -m "feat(engine): carry the blueprint component map on both world views"
```

---

### Task 7: `EventRun.printing` builds prerequisites first, and stops spinning

The step that has been parked for eight hours. Three changes: print the tree
deepest-first, prefer a printer that is not already blocked, and arm the
deadline that has been declared and unused since the run shipped.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (add the reason after `:177`; `displayName` at `:204`; `brainDisposition` at `:288`)
- Modify: `app/Modules/DirectiveEngine/Sources/EventRun.swift` (`missingDevices` at `:160-171`, `printing` at `:180-229`)
- Test: `app/Modules/DirectiveEngine/Tests/EventRunTests.swift`

**Interfaces:**
- Consumes: `BlueprintClosure` (Task 2), `WorldSnapshot.blueprintBills` and
  `.blueprintComponents` (Task 6), `Device.waitingForComponents` — **which does
  not exist until Task 8.** Until then this task reads the blob inline via the
  helper defined in Step 4 below; Task 8 replaces that helper's body with a call
  to `Device.waitingForComponents` and the tests here keep passing.
- Produces:
  - `DirectiveAttentionReason.printBlockedOnComponents`
  - `EventRun.missingTree(for:at:in:tag:) -> [BlueprintClosure.Job]`

- [ ] **Step 1: Write the failing tests**

Append to `EventRunTests.swift`:

```swift
    @Test("printing dispatches a component before the device that consumes it")
    func componentsPrintFirst() {
        let now = Date()
        let world = EventRunFixtures.world(
            devices: [
                EventRunFixtures.carrier("CARRIER"),
                EventRunFixtures.courier(),
                EventRunFixtures.device("FACTORY", type: "autofactory"),
            ],
            event: EventRunFixtures.event(devices: [(1, "atmospheric_regulator")]),
            now: now,
            blueprintBills: [
                "atmospheric_regulator": ResourceCost(structural: 200),
                "filtration_array": ResourceCost(structural: 140),
                "atmo_processor": ResourceCost(structural: 200),
                "ftl_beacon": ResourceCost(structural: 50),
            ],
            blueprintComponents: [
                "atmospheric_regulator": ["filtration_array": 1, "atmo_processor": 2]
            ]
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: "printing", stepStartedAt: now),
            world: world
        )
        guard case .dispatch(_, _, let params, _) = action else {
            Issue.record("expected a dispatch, got \(action)"); return
        }
        #expect(params.deviceType == "atmo_processor")
        #expect(params.quantity == 2)
    }

    @Test("a component already standing under the run's tag is not reprinted")
    func standingComponentIsNetted() {
        let now = Date()
        let tag = EventRun.fleetTag(forTheatre: "HUB-1")
        let world = EventRunFixtures.world(
            devices: [
                EventRunFixtures.carrier("CARRIER"),
                EventRunFixtures.courier(),
                EventRunFixtures.device("FACTORY", type: "autofactory"),
                EventRunFixtures.device("AP1", type: "atmo_processor", tags: [tag]),
                EventRunFixtures.device("AP2", type: "atmo_processor", tags: [tag]),
            ],
            event: EventRunFixtures.event(devices: [(1, "atmospheric_regulator")]),
            now: now,
            blueprintBills: [
                "atmospheric_regulator": ResourceCost(structural: 200),
                "filtration_array": ResourceCost(structural: 140),
                "atmo_processor": ResourceCost(structural: 200),
                "ftl_beacon": ResourceCost(structural: 50),
            ],
            blueprintComponents: [
                "atmospheric_regulator": ["filtration_array": 1, "atmo_processor": 2]
            ]
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: "printing", stepStartedAt: now),
            world: world
        )
        guard case .dispatch(_, _, let params, _) = action else {
            Issue.record("expected a dispatch, got \(action)"); return
        }
        #expect(params.deviceType == "filtration_array")
    }

    @Test("an untagged component of the standing fleet is never scavenged")
    func untaggedComponentIsNotNetted() {
        let now = Date()
        let world = EventRunFixtures.world(
            devices: [
                EventRunFixtures.carrier("CARRIER"),
                EventRunFixtures.courier(),
                EventRunFixtures.device("FACTORY", type: "autofactory"),
                EventRunFixtures.device("AP1", type: "atmo_processor", tags: []),
                EventRunFixtures.device("AP2", type: "atmo_processor", tags: []),
            ],
            event: EventRunFixtures.event(devices: [(1, "atmospheric_regulator")]),
            now: now,
            blueprintBills: [
                "atmospheric_regulator": ResourceCost(structural: 200),
                "filtration_array": ResourceCost(structural: 140),
                "atmo_processor": ResourceCost(structural: 200),
                "ftl_beacon": ResourceCost(structural: 50),
            ],
            blueprintComponents: [
                "atmospheric_regulator": ["filtration_array": 1, "atmo_processor": 2]
            ]
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: "printing", stepStartedAt: now),
            world: world
        )
        guard case .dispatch(_, _, let params, _) = action else {
            Issue.record("expected a dispatch, got \(action)"); return
        }
        #expect(params.deviceType == "atmo_processor")
    }

    @Test("a print blocked past the deadline stalls instead of waiting forever")
    func blockedPrintStalls() {
        let now = Date()
        let started = now.addingTimeInterval(-EventRun.printDeadline - 60)
        var factory = EventRunFixtures.device("FACTORY", type: "autofactory")
        factory.detail = .object([
            "waiting_for": .object([
                "components": .object([
                    "atmo_processor": .object(["have": .number(0), "need": .number(2)])
                ])
            ])
        ])
        let world = EventRunFixtures.world(
            devices: [EventRunFixtures.carrier("CARRIER"), EventRunFixtures.courier(), factory],
            event: EventRunFixtures.event(devices: [(1, "atmospheric_regulator")]),
            now: now,
            openOperations: ["FACTORY": EventRunFixtures.openPrint("FACTORY", at: started)],
            blueprintBills: [
                "atmospheric_regulator": ResourceCost(structural: 200),
                "atmo_processor": ResourceCost(structural: 200),
                "filtration_array": ResourceCost(structural: 140),
                "ftl_beacon": ResourceCost(structural: 50),
            ],
            blueprintComponents: [
                "atmospheric_regulator": ["filtration_array": 1, "atmo_processor": 2]
            ]
        )
        let action = EventRun().nextAction(
            directive: EventRunFixtures.directive(step: "printing", stepStartedAt: started),
            world: world
        )
        guard case .stall(let reason, _) = action else {
            Issue.record("expected a stall, got \(action)"); return
        }
        #expect(reason == .printBlockedOnComponents)
    }
```

Extend `EventRunFixtures` with the parameters these tests use: `world(...)`
gains `blueprintBills: [String: ResourceCost] = [:]` and
`blueprintComponents: [String: [String: Int]] = [:]`, passed straight into
`WorldSnapshot`; add `event(devices:)` and `openPrint(_:at:)` helpers if the
file lacks them, following the existing `device` / `courier` shape.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter EventRun`
Expected: FAIL — no `blueprintComponents:` on the fixture, no
`.printBlockedOnComponents`.

- [ ] **Step 3: Add the stall reason**

In `app/Modules/GameModels/Sources/Directive.swift`, after
`case awaitingCourierReplication` at `:177`:

```swift
    /// A queued print is blocked on component devices it does not have. The run
    /// prints them itself; this fires only when the block outlives the deadline.
    case printBlockedOnComponents
```

In `displayName` (`:180-210`), add:

```swift
        case .printBlockedOnComponents: "Print blocked on components"
```

In `brainDisposition` (`:286-300`), add `.printBlockedOnComponents` to the
**`.retry`** list — the components are printable, so the bounded auto-retry
should run before the operator is asked.

- [ ] **Step 4: Expand the wanted tree in `EventRun`**

In `EventRun.swift`, after `missingDevices` at `:171`:

```swift
    /// Every print the option still needs, prerequisites first: its device tree
    /// expanded through blueprint components, netted against what already
    /// stands free at `depot` under this run's own tag.
    static func missingTree(
        for option: EventPlan.Option, at depot: String, in world: WorldSnapshot, tag: String
    ) -> [BlueprintClosure.Job] {
        let expansion = BlueprintClosure.expand(
            option.devices, bills: world.blueprintBills, components: world.blueprintComponents
        )
        var held: [String: Int] = [:]
        for device in world.devices.values
        where device.location == depot && device.hasTag(tag) {
            held[device.deviceType, default: 0] += 1
        }
        return expansion.jobs.compactMap { job in
            let outstanding = job.quantity - (held[job.deviceType] ?? 0)
            guard outstanding > 0 else { return nil }
            return BlueprintClosure.Job(
                deviceType: job.deviceType, quantity: outstanding, depth: job.depth
            )
        }
    }

    /// What a printer at `depot` says a queued job is still missing. The
    /// server's own count, which outranks the local expansion.
    static func blockedComponents(at depot: String, in world: WorldSnapshot) -> [String: Int] {
        var missing: [String: Int] = [:]
        for device in world.devices.values where device.location == depot {
            guard case let .object(waiting)? = device.detail["waiting_for"],
                  case let .object(rows)? = waiting["components"]
            else { continue }
            for (type, amounts) in rows {
                let need = Int(amounts["need"]?.numberValue ?? 0)
                let have = Int(amounts["have"]?.numberValue ?? 0)
                if need > have { missing[type] = max(missing[type] ?? 0, need - have) }
            }
        }
        return missing
    }
```

- [ ] **Step 5: Rewrite `printing`**

Replace `printing` (`:180-229`) with:

```swift
    private func printing(
        _ directive: Directive, _ convoy: Convoy, _ event: LocationEvent, _ world: WorldSnapshot
    ) -> MissionAction {
        guard let depot = world.theatreDepot(for: directive),
              case .decided(let option) = EventPlan.resolve(
                  event, chosenOption: event.chosenOption, bills: [:]
              )
        else { return .stall(.unreachableDevice) }

        let tag = Self.fleetTag(forTheatre: depot)
        var wanted: [String: Int] = [:]
        var order: [String] = []
        for job in Self.missingTree(for: option, at: depot, in: world, tag: tag) {
            wanted[job.deviceType] = job.quantity
            order.append(job.deviceType)
        }
        // The server's own shortfall outranks the local expansion.
        for (type, count) in Self.blockedComponents(at: depot, in: world) {
            if wanted[type] == nil { order.insert(type, at: 0) }
            wanted[type] = max(wanted[type] ?? 0, count)
        }
        if !Self.beaconStands(at: event.location, in: world),
           !world.devices.values.contains(where: {
               $0.deviceType == EventPlan.beaconDeviceType && $0.location == depot && $0.hasTag(tag)
           })
        {
            wanted[EventPlan.beaconDeviceType] = 1
            order.append(EventPlan.beaconDeviceType)
        }
        if wanted.isEmpty { return .advanceStep(nextStep: Step.loading) }

        let rail = RelayRun(reserveFloor: reserveFloor)
        if rail.footprintCensusIsStale(world) {
            return .refreshFootprint(nextStep: Step.printing, thenStall: nil)
        }
        if rail.printStockIsShort(at: depot, world) { return .wait }
        if MineFleetPrint.fleetEvidenceIsStale(directive, at: depot, in: world) {
            return .refreshDevicesInSystem(designation: depot, thenStall: .unreachableDevice)
        }

        // Sorted before `first`: two printers at one depot must not alternate.
        let printers = world.devices.values
            .filter { $0.location == depot && $0.deviceType == "autofactory" }
            .sorted { $0.deviceCode < $1.deviceCode }
        guard !printers.isEmpty else { return .stall(.unreachableDevice) }

        guard let free = printers.first(where: { world.openOperation(for: $0.deviceCode) == nil })
        else {
            let stuck = world.now.timeIntervalSince(directive.stepStartedAt) > Self.printDeadline
            return stuck ? .stall(.printBlockedOnComponents, detail: depot) : .wait
        }

        guard let type = order.first(where: { wanted[$0] != nil }),
              let quantity = wanted[type]
        else { return .wait }

        return .dispatch(
            kind: .print, deviceCode: free.deviceCode,
            params: CommandParams(deviceType: type, quantity: quantity, printTags: [tag]),
            nextStep: Step.printing
        )
    }
```

`order` preserves the expansion's deepest-first ordering and appends the beacon
last, which is what the old `option.devices.keys.sorted() + [beacon]` line did.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter EventRun`
Expected: PASS

- [ ] **Step 7: Drive it through the real engine**

Add to `app/Modules/DirectiveEngine/Tests/EventRunEngineTests.swift` a test that
runs a component-bearing option through `DirectiveEngineCore` (not a fixture
table) and asserts the run reaches `loading` after the component and parent
prints land. Follow the existing engine-test shape in that file. A pure-function
table missed exactly this class of stall in `RelayRun`.

Run: `cd app/Modules && swift test --filter EventRunEngine`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add app/Modules/GameModels/Sources/Directive.swift \
        app/Modules/DirectiveEngine/Sources/EventRun.swift \
        app/Modules/DirectiveEngine/Tests/EventRunTests.swift \
        app/Modules/DirectiveEngine/Tests/EventRunFixtures.swift \
        app/Modules/DirectiveEngine/Tests/EventRunEngineTests.swift
git commit -m "fix(events): print an option's components before the device that consumes them"
```

---

### Task 8: Parse the nested `waiting_for`, and stop calling a blockage met

`Device.waitingForResources` maps the top level of `waiting_for` as
`{resource: {need, have}}`. Against `{"components": {"atmo_processor": {…}}}`
it yields one row named `components` with nil amounts, whose `isMet` is
`0 >= 0` — true. The Print Queue draws a green tick on the blockage.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Printing.swift` (`WaitingResource` at `:91-108`, `waitingForResources` at `:143-157`)
- Modify: `app/Modules/DirectiveEngine/Sources/EventRun.swift` (`blockedComponents` from Task 7 — replace its body)
- Modify: `app/Modules/PrintQueueFeature/Sources/PrintQueueDetailView.swift` (`waitingFor(_:)` at `:182-208`)
- Test: `app/Modules/GameServices/Tests/PrintingSnapshotTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `WaitingResource.Kind` — `.resource` / `.component`
  - `WaitingResource.kind: Kind` (init parameter defaults to `.resource`)
  - `Device.waitingForComponents: [WaitingResource]`

- [ ] **Step 1: Write the failing tests**

Append to `PrintingSnapshotTests.swift`:

```swift
    @Test("a component blockage parses as component rows, not one nil row")
    func nestedComponents() {
        var device = PrintingFixtures.printer()
        device.detail = .object([
            "waiting_for": .object([
                "components": .object([
                    "filtration_array": .object(["have": .number(0), "need": .number(1)]),
                    "atmo_processor": .object(["have": .number(1), "need": .number(2)]),
                ])
            ])
        ])
        let rows = device.waitingForResources
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.kind == .component })
        #expect(rows.first?.resource == "atmo_processor")
        #expect(rows.first?.need == 2)
        #expect(rows.first?.have == 1)
        #expect(rows.allSatisfy { !$0.isMet })
    }

    @Test("a row with neither need nor have is unmet, never met")
    func unparseableRowIsUnmet() {
        let row = WaitingResource(resource: "components", need: nil, have: nil)
        #expect(!row.isMet)
    }

    @Test("the flat resource shape still parses")
    func flatResources() {
        var device = PrintingFixtures.printer()
        device.detail = .object([
            "waiting_for": .object([
                "structural": .object(["have": .number(10), "need": .number(80)])
            ])
        ])
        let rows = device.waitingForResources
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .resource)
        #expect(rows.first?.need == 80)
    }

    @Test("a nested resources block parses as resource rows")
    func nestedResources() {
        var device = PrintingFixtures.printer()
        device.detail = .object([
            "waiting_for": .object([
                "resources": .object([
                    "structural": .object(["have": .number(10), "need": .number(80)])
                ])
            ])
        ])
        let rows = device.waitingForResources
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .resource)
        #expect(rows.first?.resource == "structural")
    }
```

Use whatever printer fixture that suite already defines instead of
`PrintingFixtures.printer()` if the name differs.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --filter PrintingSnapshot`
Expected: FAIL — no `kind` member; the nested payload yields one row named
`components` whose `isMet` is true.

- [ ] **Step 3: Add the kind and reparse**

In `Printing.swift`, replace `WaitingResource` (`:91-108`) and
`waitingForResources` (`:143-157`):

```swift
/// A requirement a queued print still needs before it can start, parsed from a
/// `waiting_for` entry. Raw material and component devices arrive in the same
/// `{need, have}` shape under different keys.
public struct WaitingResource: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case resource
        case component
    }

    public var resource: String
    public var kind: Kind
    public var need: Double?
    public var have: Double?

    public var id: String { "\(kind.rawValue)>\(resource)" }

    /// Whether the location already holds enough. A row carrying neither figure
    /// could not be parsed and reads as unmet, never as satisfied.
    public var isMet: Bool {
        guard need != nil || have != nil else { return false }
        return (have ?? 0) >= (need ?? 0)
    }

    public init(
        resource: String, kind: Kind = .resource, need: Double? = nil, have: Double? = nil
    ) {
        self.resource = resource
        self.kind = kind
        self.need = need
        self.have = have
    }
}
```

and:

```swift
    /// What a queued print is still waiting on, parsed from `waiting_for`. The
    /// server nests rows under `components`/`resources`; a flat payload is read
    /// as raw material. Sorted by name within kind for a stable readout.
    public var waitingForResources: [WaitingResource] {
        guard case let .object(dict)? = detail["waiting_for"] else { return [] }
        var rows: [WaitingResource] = []
        for (key, value) in dict {
            guard case let .object(inner) = value else { continue }
            if let kind = WaitingResource.Kind(rawValue: key) ?? nestedKind(key) {
                for (name, amounts) in inner {
                    guard case let .object(figures) = amounts else { continue }
                    rows.append(
                        WaitingResource(
                            resource: name, kind: kind,
                            need: figures["need"]?.numberValue,
                            have: figures["have"]?.numberValue
                        )
                    )
                }
            } else {
                rows.append(
                    WaitingResource(
                        resource: key, kind: .resource,
                        need: inner["need"]?.numberValue,
                        have: inner["have"]?.numberValue
                    )
                )
            }
        }
        return rows.sorted {
            $0.kind == $1.kind ? $0.resource < $1.resource : $0.kind.rawValue < $1.kind.rawValue
        }
    }

    /// Component rows only — what a blocked print needs built before it starts.
    public var waitingForComponents: [WaitingResource] {
        waitingForResources.filter { $0.kind == .component }
    }
```

with this file-private helper beside them:

```swift
/// `components` / `resources` name a nested block; anything else is a flat
/// resource row in the legacy shape.
private func nestedKind(_ key: String) -> WaitingResource.Kind? {
    key == "components" ? .component : (key == "resources" ? .resource : nil)
}
```

`WaitingResource.Kind(rawValue: key)` already matches both names, so the
helper only needs to exist if you prefer the explicit form; drop the
`?? nestedKind(key)` and the helper if you do not.

- [ ] **Step 4: Point `EventRun.blockedComponents` at the parser**

Replace the body added in Task 7 Step 4:

```swift
    /// What a printer at `depot` says a queued job is still missing. The
    /// server's own count, which outranks the local expansion.
    static func blockedComponents(at depot: String, in world: WorldSnapshot) -> [String: Int] {
        var missing: [String: Int] = [:]
        for device in world.devices.values where device.location == depot {
            for row in device.waitingForComponents where !row.isMet {
                let shortfall = Int((row.need ?? 0) - (row.have ?? 0))
                if shortfall > 0 { missing[row.resource] = max(missing[row.resource] ?? 0, shortfall) }
            }
        }
        return missing
    }
```

- [ ] **Step 5: Render both kinds in the Print Queue**

In `PrintQueueDetailView.swift`, in `waitingFor(_:)` at `:193`, replace the
name lookup so a component row reads as a device:

```swift
                        Text(
                            resource.kind == .component
                                ? BlueprintPresentation.displayName(resource.resource)
                                : PrintQueuePresentation.displayName(resource.resource)
                        )
```

Add `import GameModels` to the file if it is not already there.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd app/Modules && swift test --filter "PrintingSnapshot|EventRun"`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add app/Modules/GameModels/Sources/Printing.swift \
        app/Modules/DirectiveEngine/Sources/EventRun.swift \
        app/Modules/PrintQueueFeature/Sources/PrintQueueDetailView.swift \
        app/Modules/GameServices/Tests/PrintingSnapshotTests.swift
git commit -m "fix(printing): parse the nested waiting_for and stop reading a blockage as met"
```

---

### Task 9: The print preview counts components

`PrintRequirements` models resource lines only, so the confirmation sheet
under-reports a composite blueprint exactly as the engine did.

**Files:**
- Modify: `app/Modules/GameModels/Sources/PrintRequirements.swift` (whole file, 115 lines)
- Modify: `app/Modules/GameServices/Sources/LocationsClient.swift` (`printRequirements` at `:112-135`)
- Modify: `app/Modules/PrintQueueFeature/Sources/PrintQueueDetailView.swift` (`requiredLines(for:)` at `:329-341`, and its `printPreviewRequested` call site)
- Modify: `app/Modules/DevicesFeature/Sources/CommandGrid.swift` (`requiredLines(for:)` at `:548-560`, and its call site)
- Modify: `app/Modules/PrintingUI/Sources/PrintPlanSheet.swift` (row rendering at `:139`)
- Test: `app/Modules/GameModels/Tests/PrintRequirementsTests.swift`

**Interfaces:**
- Consumes: `Blueprint.components` (Task 1).
- Produces:
  - `PrintComponentLine` — `deviceType: String`, `label: String`,
    `required: Int`, `available: Int?`, `isMet: Bool`, `id: String`
  - `PrintRequirements.components: [PrintComponentLine]`
  - `PrintRequirements.resolve(deviceType:locationName:required:requiredComponents:available:heldComponents:)`
  - `LocationsClient.printRequirements(deviceType:location:locationName:required:requiredComponents:heldComponents:)`

- [ ] **Step 1: Write the failing test**

Create `app/Modules/GameModels/Tests/PrintRequirementsTests.swift`:

```swift
import Foundation
import Testing
@testable import GameModels

@Suite("PrintRequirements components")
struct PrintRequirementsTests {
    @Test("a component the location lacks makes the print unmet")
    func missingComponent() {
        let requirements = PrintRequirements.resolve(
            deviceType: "atmospheric_regulator",
            locationName: "AINALRAM-BELT-1",
            required: [PrintResourceLine(resource: "structural", label: "Structural", required: 200)],
            requiredComponents: [
                PrintComponentLine(deviceType: "atmo_processor", label: "Atmo Processor", required: 2)
            ],
            available: ["structural": 5000],
            heldComponents: ["atmo_processor": 1]
        )
        #expect(requirements.components.first?.available == 1)
        #expect(requirements.components.first?.isMet == false)
        #expect(requirements.allMet == false)
    }

    @Test("every component present makes the print met")
    func componentsSatisfied() {
        let requirements = PrintRequirements.resolve(
            deviceType: "atmospheric_regulator",
            locationName: nil,
            required: [PrintResourceLine(resource: "structural", label: "Structural", required: 200)],
            requiredComponents: [
                PrintComponentLine(deviceType: "atmo_processor", label: "Atmo Processor", required: 2)
            ],
            available: ["structural": 5000],
            heldComponents: ["atmo_processor": 2]
        )
        #expect(requirements.allMet)
    }

    @Test("a blueprint with no components behaves exactly as before")
    func noComponents() {
        let requirements = PrintRequirements.resolve(
            deviceType: "mining_drone", locationName: nil,
            required: [PrintResourceLine(resource: "structural", label: "Structural", required: 100)],
            requiredComponents: [],
            available: ["structural": 5000],
            heldComponents: [:]
        )
        #expect(requirements.components.isEmpty)
        #expect(requirements.allMet)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/Modules && swift test --filter "PrintRequirements components"`
Expected: FAIL — `cannot find 'PrintComponentLine' in scope`.

- [ ] **Step 3: Add the component line**

In `PrintRequirements.swift`, after `PrintResourceLine` at `:40`:

```swift
/// One component line in the print confirmation: a device the blueprint
/// consumes, and how many stand where the print will run. `available` is nil
/// when the location's devices couldn't be read.
public struct PrintComponentLine: Equatable, Sendable, Identifiable {
    public var deviceType: String
    public var label: String
    public var required: Int
    public var available: Int?

    public var id: String { deviceType }

    /// Unknown availability reads as unmet so the sheet doesn't imply readiness.
    public var isMet: Bool { (available ?? 0) >= required }

    public init(deviceType: String, label: String, required: Int, available: Int? = nil) {
        self.deviceType = deviceType
        self.label = label
        self.required = required
        self.available = available
    }
}
```

Add to `PrintRequirements` after `lines` at `:51`:

```swift
    /// Component devices the blueprint consumes. Empty for most blueprints.
    public var components: [PrintComponentLine]
```

with `components: [PrintComponentLine] = []` as the last `init` parameter,
assigned in the body. Extend `allMet` and `resolve`:

```swift
    /// Whether the location stocks enough of every resource AND component.
    public var allMet: Bool {
        inventoryAvailable && lines.allSatisfy(\.isMet) && components.allSatisfy(\.isMet)
    }

    /// Fill in each line's availability from a resolved inventory lookup and a
    /// count of the devices standing where the print will run. A nil inventory
    /// means it couldn't be read, leaving every resource line unknown.
    public static func resolve(
        deviceType: String,
        locationName: String?,
        required: [PrintResourceLine],
        requiredComponents: [PrintComponentLine] = [],
        available: [String: Double]?,
        heldComponents: [String: Int] = [:]
    ) -> PrintRequirements {
        let lines = required.map { line in
            PrintResourceLine(
                resource: line.resource, label: line.label,
                required: line.required, available: available?[line.resource]
            )
        }
        let components = requiredComponents.map { line in
            PrintComponentLine(
                deviceType: line.deviceType, label: line.label,
                required: line.required, available: heldComponents[line.deviceType] ?? 0
            )
        }
        return PrintRequirements(
            deviceType: deviceType, locationName: locationName,
            inventoryAvailable: available != nil, lines: lines, components: components
        )
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app/Modules && swift test --filter "PrintRequirements components"`
Expected: PASS

- [ ] **Step 5: Thread it through the client**

In `LocationsClient.printRequirements` (`:112-135`), add two parameters and
pass them on:

```swift
    public func printRequirements(
        deviceType: String,
        location: String?,
        locationName: String?,
        required: [PrintResourceLine],
        requiredComponents: [PrintComponentLine] = [],
        heldComponents: [String: Int] = [:]
    ) async -> PrintRequirements {
        var available: [String: Double]?
        if let location, let items = try? await inventory(at: location) {
            available = Dictionary(
                items.map { ($0.resourceType.lowercased(), $0.quantity) },
                uniquingKeysWith: +
            )
        }
        return PrintRequirements.resolve(
            deviceType: deviceType,
            locationName: locationName,
            required: required,
            requiredComponents: requiredComponents,
            available: available,
            heldComponents: heldComponents
        )
    }
```

- [ ] **Step 6: Build the component lines in both views**

In **both** `PrintQueueDetailView.swift` (`:329-341`) and `CommandGrid.swift`
(`:548-560`) — the two copies are byte-identical today and must stay so — add
beside `requiredLines(for:)`:

```swift
    /// The component devices a blueprint consumes, as confirmation lines.
    /// Empty when the blueprint is unknown or consumes none.
    private func requiredComponents(for deviceType: String) -> [PrintComponentLine] {
        guard let blueprint = blueprints.first(where: { $0.deviceType == deviceType }) else { return [] }
        return blueprint.components
            .sorted { $0.key < $1.key }
            .map { type, count in
                PrintComponentLine(
                    deviceType: type,
                    label: BlueprintPresentation.displayName(type),
                    required: count
                )
            }
    }
```

Pass `requiredComponents(for:)` and a count of co-located devices into the
`printPreviewRequested` action each view sends, and thread both through the
reducer's effect into `LocationsClient.printRequirements`. The device count is
built from the rows the feature already holds:

```swift
        let held = devices
            .filter { $0.location == printer.location }
            .reduce(into: [String: Int]()) { $0[$1.deviceType, default: 0] += 1 }
```

- [ ] **Step 7: Render the component rows**

In `app/Modules/PrintingUI/Sources/PrintPlanSheet.swift`, add a Components
section below the resource rows, shown only when
`requirements.components.isEmpty == false`, using the same row treatment as the
resource lines — `checkmark.circle.fill` in `.rcStatusReady` when met,
`hourglass` in `.rcWarning` when not, amounts in `.rcMonoSmall`. Do not
introduce new tokens.

- [ ] **Step 8: Run the affected suites**

Run: `cd app/Modules && swift test --filter "PrintRequirements|PrintQueue|Devices"`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add app/Modules/GameModels/Sources/PrintRequirements.swift \
        app/Modules/GameModels/Tests/PrintRequirementsTests.swift \
        app/Modules/GameServices/Sources/LocationsClient.swift \
        app/Modules/PrintQueueFeature/Sources/PrintQueueDetailView.swift \
        app/Modules/DevicesFeature/Sources/CommandGrid.swift \
        app/Modules/PrintingUI/Sources/PrintPlanSheet.swift
git commit -m "feat(printing): count component devices in the print confirmation"
```

---

### Task 10: Show a blueprint's components in its detail view

**Files:**
- Modify: `app/Modules/BlueprintsFeature/Sources/BlueprintDetailView.swift` (after `costAndTime` at `:100-127`)
- Create: `app/Modules/BlueprintsFeature/Sources/BlueprintComponentsSection.swift`
- Test: manual, via the existing preview

A row struct lives in its own file — the Xcode 26 preview JIT crashes when a row
struct sits beside a `#Preview`.

**Interfaces:**
- Consumes: `Blueprint.components` (Task 1), `BlueprintPresentation.displayName`.
- Produces: `BlueprintComponentsSection(components:)` — a `View`.

- [ ] **Step 1: Create the section view**

Create `app/Modules/BlueprintsFeature/Sources/BlueprintComponentsSection.swift`:

```swift
//
//  BlueprintComponentsSection.swift
//  Replicould — BlueprintsFeature
//
//  The printed devices a blueprint consumes, beyond its raw resource cost.
//

import GameModels
import SwiftUI
import UI

struct BlueprintComponentsSection: View {
    let components: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader("Components")
            ForEach(components.sorted(by: { $0.key < $1.key }), id: \.key) { type, count in
                HStack(spacing: Space.m) {
                    Text(BlueprintPresentation.displayName(type))
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextSecondary)
                    Spacer(minLength: 0)
                    Text("×\(count)")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 2: Show it in the detail view**

In `BlueprintDetailView.swift`, in the body where `costAndTime(blueprint)` is
placed, add immediately after it:

```swift
                if !blueprint.components.isEmpty {
                    BlueprintComponentsSection(components: blueprint.components)
                }
```

- [ ] **Step 3: Build and check both colour schemes**

Run: `cd app/Modules && swift build`
Expected: SUCCESS

Then confirm the section reads correctly in light and dark. If checking from a
background session, use the headless render probe recorded in
`app/.claude/memory/headless-swiftui-render-probe.md` — an explicit surface
background is required or dark mode renders white-on-white.

- [ ] **Step 4: Commit**

```bash
git add app/Modules/BlueprintsFeature/Sources/BlueprintComponentsSection.swift \
        app/Modules/BlueprintsFeature/Sources/BlueprintDetailView.swift
git commit -m "feat(blueprints): show a blueprint's component requirements"
```

---

### Task 11: Full suite, comment pass, memory note

**Files:**
- Create: `app/.claude/memory/blueprint-components.md`
- Modify: `app/.claude/memory/MEMORY.md`

- [ ] **Step 1: Run the whole suite**

Run: `cd app/Modules && swift test`
Expected: PASS. `theSupervisorAdoptsTheRowTheBrainLaunched` is a known
pre-existing failure under `--build-system native` (all tests in one process) —
see `app/.claude/memory/supervisor-adopts-row-whole-package-failure.md`. Do not
attribute it to this work; verify it fails at `d082e6a` too before dismissing.

- [ ] **Step 2: Comment pass**

Run: `./app/scripts/check-comments.sh` from the repo root (its paths are
repo-root relative). Exit 0 is a floor, not proof — it is eleven regexes with no
notion of prose. Hand-check every file this branch touched against the budget:
file header ≤ 6 lines, `///` ≤ 3, inline `//` ≤ 2. Move any rationale, history,
or live-fleet detail into the memory note below.

- [ ] **Step 3: Write the memory note**

Create `app/.claude/memory/blueprint-components.md` recording what the build
found that the code cannot carry: that `components` shipped in `openapi.json`
and the generated client but was dropped at `Blueprint.init(schema:)`; the live
`waiting_for` nesting and the `isMet` bug it caused; that `EventPlan` scored an
unbillable device as 0 units so an unbuildable option ranked *first*; that
`EventRun.printDeadline` was declared and unused, which is how one run sat in
`printing` for eight hours with no stall; the four blueprints that carry
components and the four component types with no blueprint; and that `printSeconds`
is computed but unwired because no production caller supplies print times.

Add a one-line index entry to `app/.claude/memory/MEMORY.md`.

- [ ] **Step 4: Commit**

```bash
git add app/.claude/memory/blueprint-components.md app/.claude/memory/MEMORY.md
git commit -m "docs(memory): record the blueprint components build"
```

---

## Self-review

**Spec coverage.** §4.1 → Task 1. §4.2 → Task 2. §4.3 → Tasks 3, 5, 6. §4.4 →
Tasks 3, 4. §4.5 → Task 7. §4.6 → Task 8. §4.7 → Tasks 8, 9, 10. §7 testing is
distributed across every task; the engine-level `EventRun` test the spec asks
for is Task 7 Step 7. §8 robustness needs no task — it is a property of the
design, checked at review.

**Deliberate narrowings**, both recorded above where they occur:
- `Expansion.printSeconds` exists but no production caller supplies `printTimes`,
  so it reads 0 outside tests. Wiring a `blueprintPrintTimes` map through
  `WorldView` would be a fourth parallel dictionary for no current consumer.
- `WorldSnapshot` gains `blueprintBills` as well as `blueprintComponents`,
  which the spec does not mention. `EventRun` needs both to expand, and it had
  neither — the four `bills: [:]` call sites are why.

**Type consistency.** `blueprintComponents` is the name on both `WorldView` and
`WorldSnapshot` and in every parameter list; `WorldSnapshot.components` remains
the FTL mesh map and is never touched. `BlueprintClosure.Job` and
`.Expansion` are used with the same member names in Tasks 3, 5 and 7.
`EventPlan.Option.unprintable` is a `Set<String>`;
`BrainEventChoice.Option.unprintable` is a sorted `[String]` — the conversion
happens once, in Task 4 Step 4.

**Ordering constraint.** Task 7 references `Device.waitingForComponents`, which
Task 8 creates. Task 7 Step 4 therefore defines `blockedComponents` reading the
blob directly, and Task 8 Step 4 replaces that body. Running the tasks in order
leaves no broken intermediate state.
