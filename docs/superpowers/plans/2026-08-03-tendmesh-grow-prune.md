# tendMesh Grow + Prune Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the automation brain online for the first time on its central capability — `tendMesh` grow+prune — so the app autonomously plants FTL relays toward discovered-but-unreached value and reclaims durably-useless relays, all as a pure selector over the existing directive rails.

**Architecture:** This is the **first brain build**; nothing of the brain exists in source (verified — only design memory under `app/.claude/memory/brain-*.md`). The plan therefore bootstraps the minimal shared brain scaffolding — a nonisolated ranking **plan loop** on the existing `DirectiveEngineCore` actor, a galaxy-wide `WorldView` snapshot, a derived **why-view**, and `DirectiveAttentionReason.brainDisposition` — and builds the `tendMesh` capability on top: one stateless **graph computation** (multi-source Dijkstra over a ≤7.5 ly relay-hop graph) read in two directions (grow = cheapest chain toward value; prune = the same paths read inversely), plus a new **Relay Run** `MissionStepMachine` (print → stow → travel → deploy → activate → confirm) registered against the reserved-but-inert `relayRun` kind. The brain **ranks and launches**, never enacts; every command still flows executor → `CommandGovernor` → engine.

**Tech Stack:** Swift 6 / SwiftUI, SPM package rooted at `app/Modules`, GRDB via SQLiteData (`@Table`), Point-Free `Dependencies` + `swift-composable-architecture` (feature tier only), Swift Testing (`@Test`/`#expect`) with the JSON event stream, `os.Logger`.

## Global Constraints

- **Additive only. No new SPM module.** All brain code lands in the existing **`DirectiveEngine`** module (new files beside `SalvageRun.swift`/`SalvageTargetPlanner.swift`); the one enum extension lands in **`GameModels`** (`Directive.swift`). No `.xcodeproj`/pbxproj edits (manual-link friction — see `pbxproj-link-is-manual` memory note).
- **The brain is a pure selector (robustness clause 1).** Its only writes are: create a directive (launch), `.cancelled` a directive (retire), and drive `DirectiveResolutionClient.{retry, cancel}` as an automated operator. It **never** hand-edits a running directive's step/target/status, and **never** issues a command outside `CommandGovernor`. `skipTarget`/`pause`/`resume` stay operator-only.
- **Stateless between ticks (clause 2).** A brain tick is a pure function of `(WorldView, running-directive rows)`. No lease, no cache, no committed-intent. The path-union *is* the state, recomputed each tick.
- **Confirm-fresh before every plant/reclaim (clause 4c).** Ranking runs on best-effort `WorldView`; every irreversible commitment (a print, an emplacement, a reclaim) is gated on a just-in-time `.high` confirm-read that repairs the row it reads. Staleness degrades efficiency, never safety.
- **Database migrations are append-only** (see `app/CLAUDE.md`). New columns = new `ALTER TABLE` `SchemaMigration` appended to `GameDatabase.manifest`; never edit a shipped `CREATE TABLE`. `SchemaManifestTests` freezes the identifier list; regenerate `GoldenSchemaTests` with `RC_REGENERATE_SCHEMA_FIXTURE=1` only when the change is intended.
- **`.simple(...)` verbs carry NO `Operation` row** — every `deploy`/`activate`/`launch`/`stow` dispatch MUST be split into a dispatch step and a separate poll step (see `same-step-dispatch-needs-tracked-op` memory note and `SalvageRun.swift:616-657`). Re-dispatching a `.simple` verb on its own step re-stamps `stepStartedAt` every tick and defeats the deadline.
- **Mesh reads go through device rows, never `ftlLinks`.** A just-activated relay produces no link rows yet; the meshed-system set is derived from `Device.features.contains("relay") && statusBase == "relaying"` (`SalvageTargetPlanner.meshSystems(in:)`, `SalvageTargetPlanner.swift:68-75`). System designation = leading hyphen segment (`SiteAssay.system(of:)`).
- **Monospace + design tokens** for any UI (the why-view): system/location names use a `.rcMono*` token; no hard-coded colors/spacing/fonts (`DesignSystem.swift`).
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = `Brain` for brain code.
- **LSP hygiene (per `app/CLAUDE.md`):** before signing off any task, `cd app/Modules && swift build --build-tests` then `./scripts/link-index-store.sh`, and query Swift-LSP for reference correctness — but treat an empty `findReferences` on same-session code as a cold index, not proof of no callers; fall back to a clean build.
- **Run tests via the event stream**, never by scraping console text — use the `swift-test-event-stream` skill's `--event-stream-output-path` + `jq` recipes.

## Two locked inputs that need build-time CONFIRMATION (not re-decision)

Per the design (`brain-tendmesh-worthiness.md`), these are settled decisions whose *only* open element is a concrete value to verify against the live API/schema. **Do not reopen the tier ordering or the ceiling shape.** Each is a numbered verification task below:

1. **Belt-class source field** (Task 9). The tier ordering `Event ▸ Rich belt ▸ Moderate belt ▸ salvage-by-units ▸ Sparse belt` is locked. Reconnaissance found **no field literally named Rich/Moderate/Sparse**: the candidates are `Belt.density: String?` (free-form; sample vocabulary `"sparse"`/`"dense"`) and `Belt.richness: [String: String]` (per-resource `"low"/"moderate"/"high"/"abundant"`), both in `UniverseModels/Sources/LocationModels.swift:518`, both arriving with survey/scan data (so pre-mesh-knowable, as the design assumes). Task 9 **probes the live API** to pin the real `density` value set and maps it onto the three locked classes. The mapping is a build detail; the ordering is not.
2. **The `R` / `N` spend-ceiling literals** (Task 20). Ticket 10 **retired `N`** (the idle-relay buffer cap) in favour of lazy/demand-driven reclaim — so this plan builds **no `N` cap**; confirming that retirement is itself the verification. `R` (the per-type reserve floor, the hard rail at the print step) keeps its shape; its literal is deferred to calibration. Task 20 confirms the six resource-type names against `/inventory` and lands `R` as a single named, calibratable constant surfaced in the why-view.

---

## File Structure

**New files (all in `DirectiveEngine/Sources/` unless noted):**

- `WorldView.swift` — the brain's galaxy-wide snapshot (`WorldView` value + `WorldView.read(from:now:)`). Sibling to the directive-scoped `WorldSnapshot.swift`; wider reads (all meshed systems, all census star positions, all non-depleted salvage, live events, hub).
- `MeshGraph.swift` — the pure pathfinding core: a ≤7.5 ly relay-hop graph over census systems with a uniform spatial grid for neighbour lookup, plus multi-source Dijkstra (`reach(targets:)`) rooted at the live mesh, returning per-target cheapest chains. One computation; grow and prune both read it.
- `MeshValue.swift` — the value model: `ValueTier`, `BeltClass`, `ValueTarget`, and `ValueCatalog.build(from:)` enumerating unmeshed value-bearing systems from `WorldView`.
- `GrowRanking.swift` — the lexicographic grow key over first-hop candidates (`GrowCandidate`, `GrowRanking.rank(...)`), producing the top grow `Goal`.
- `PrunePredicate.swift` — the inverse read: the pinned/reclaimable partition of deployed relays over the same path-union (`PruneAnalysis.analyse(...)`).
- `BrainGoal.swift` — the `Goal` model (`Goal(kind:target:rationale:)`), the `BrainDecision` output (dispatch / defer-idle / stall + reason), and the shared `Goal.Kind` (this plan populates `tendMesh` only).
- `Brain.swift` — the plan loop: `Brain.evaluateOnce()` (the stateless per-tick selector), the launch/retire/reclaim actions through the sanctioned seam, and the confirm-read gating. Ticks as a sibling `Task` on `DirectiveEngineCore`.
- `RelayRun.swift` — the new `MissionStepMachine` (`kind = .relayRun`): `acquire → printing → stowing → travelling → emplacing → activating → confirmingRelay → done`, cloning SalvageRun's proven emplace/activate/confirm shape and prepending print+stow (or reclaim-source) acquisition.
- `BrainWhyView.swift` (module `DirectivesFeature`) — the derived live "why" surface (ranked candidates, the gate on the top goal, limit pressure). UI only; no new table.

**Modified files:**

- `GameModels/Sources/Directive.swift` — add `BrainDisposition` enum + `DirectiveAttentionReason.brainDisposition`; add nullable `sourceRelayCode: String?` column (append-only migration `addSourceRelayCode`) that the brain writes on a reclaim-sourced Relay Run (nil ⇒ print at hub).
- `DirectiveEngine/Sources/MissionRegistry.swift` — register `RelayRun()` (the one-line edit the file's own comment anticipates: "Relay Run joins in Stage 5").
- `DirectiveEngine/Sources/DirectiveEngine.swift` — start/stop a sibling `brain` `Task` on `DirectiveEngineCore` beside `supervisor`.
- `GameModels/Sources/Device.swift` — add `isPrintHub` / `isReclaimableRelay` helper predicates used by the hub and reclaim logic (thin, tested).

---

## Phase A — Brain scaffolding & the seam (the brain runs, ranks nothing, surfaces idle)

Deliverable at end of phase: `DirectiveEngineCore` runs a brain plan loop every 5s that reads a galaxy `WorldView`, produces an **idle** decision (no `tendMesh` logic yet), surfaces that idle in a why-view, and never writes. This is the "brain online, calm, inert" milestone that clears robustness clauses 1/2/6/8 in miniature before any grow logic exists.

### Task 1: `BrainDisposition` + `brainDisposition` classification

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (add enum + computed property near `DirectiveAttentionReason`, ~line 62-160)
- Test: `app/Modules/GameModels/Tests/BrainDispositionTests.swift`

**Interfaces:**
- Produces: `public enum BrainDisposition: String, Codable, Sendable, Equatable { case retry, escalate, decisionRequest }` and `public extension DirectiveAttentionReason { var brainDisposition: BrainDisposition }`. Consumed by `Brain.evaluateOnce` (Task 17) to classify a running directive's stall.

- [ ] **Step 1: Write the failing test.** Cover the full case-map so a future added reason forces a decision.

```swift
import Testing
@testable import GameModels

@Suite struct BrainDispositionTests {
    @Test func retryReasonsSelfCorrectOnReRead() {
        let retry: [DirectiveAttentionReason] = [
            .surveyIncomplete, .unreachableDevice, .vesselPositionUnconfirmed,
            .salvageSystemUnresolved, .salvageBodyNotDepleted, .commandRejected,
            .relayActivationFailed,
        ]
        for r in retry { #expect(r.brainDisposition == .retry, "\(r) should be retry") }
    }

    @Test func escalateReasonsNeedAPowerTheBrainLacks() {
        let escalate: [DirectiveAttentionReason] = [
            .noSurveyControllerAboard, .noSurveyDroneAboard, .noMiningControllerAboard,
            .noMiningDroneAboard, .noRelayCoLocated, .dronesNotRecovered,
            .launchDeployedNothing, .noHaulControllerTagged, .awaitingRelayRestock,
        ]
        for r in escalate { #expect(r.brainDisposition == .escalate, "\(r) should be escalate") }
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `swift test --filter BrainDispositionTests` → FAIL (`brainDisposition` undefined).
- [ ] **Step 3: Implement.** Add to `Directive.swift`:

```swift
/// How the brain (as an automated operator) responds to a directive that has
/// halted-and-surfaced. The mission layer's halt matrix is unchanged; this is
/// purely the brain's response classification (see brain-executor-seam.md).
public enum BrainDisposition: String, Codable, Sendable, Equatable {
    /// Self-corrects on a re-read — bounded auto-`retry`, budget timeline-derived, then escalate.
    case retry
    /// Needs a power the brain lacks (staging / adoption / replacement / tagging),
    /// or an executor exhausted something it can't self-compose — surface to operator.
    case escalate
    /// An expected operator choice (the HITL seam) — surface as a decision request.
    case decisionRequest
}

public extension DirectiveAttentionReason {
    /// The brain never invents a response; it classifies the reason and drives
    /// only `{retry, cancel}`. `skipTarget`/`pause`/`resume` stay operator-only.
    var brainDisposition: BrainDisposition {
        switch self {
        case .surveyIncomplete, .unreachableDevice, .vesselPositionUnconfirmed,
             .salvageSystemUnresolved, .salvageBodyNotDepleted, .commandRejected,
             .relayActivationFailed:
            return .retry
        case .noSurveyControllerAboard, .noSurveyDroneAboard, .noMiningControllerAboard,
             .noMiningDroneAboard, .noRelayCoLocated, .dronesNotRecovered,
             .launchDeployedNothing, .noHaulControllerTagged, .awaitingRelayRestock:
            return .escalate
        }
    }
}
```
> Note: `printStockShort` and `needsFulfilmentChoice` are NOT yet cases on `DirectiveAttentionReason` — they arrive in Task 15 and (future) location-event work respectively. This `switch` is exhaustive over today's 16 cases; adding a case will force a compile error here, which is the desired forcing function.

- [ ] **Step 4: Run to verify it passes.** `swift test --filter BrainDispositionTests` → PASS.
- [ ] **Step 5: Commit.**

```bash
git add app/Modules/GameModels/Sources/Directive.swift app/Modules/GameModels/Tests/BrainDispositionTests.swift
git commit -m "feat(brain): classify directive attention reasons by brain disposition"
```

### Task 2: `WorldView` — the galaxy-wide brain snapshot

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/WorldView.swift`
- Test: `app/Modules/DirectiveEngine/Tests/WorldViewTests.swift`

**Interfaces:**
- Consumes: `Device` (GameModels), `Star`/`SiteAssay` (UniverseModels), `LocationEvent` (GameModels), GRDB `Database`. `SalvageTargetPlanner.meshSystems(in:)` (existing).
- Produces:
```swift
public struct WorldView: Equatable, Sendable {
    public let devices: [String: Device]          // whole fleet
    public let starPositions: [String: Position]  // system designation → census position
    public let meshSystems: Set<String>           // currently meshed systems (relay+relaying → system)
    public let salvageUnits: [String: Double]     // system → summed non-depleted salvage units
    public let beltsBySystem: [String: [BeltInfo]]// system → surveyed belts (Task 8 fills class)
    public let eventSystems: Set<String>          // systems with a live location event
    public let hubLocation: String?               // the autofactory device's location, if meshed
    public let now: Date
    public static func read(from db: Database, now: Date) throws -> WorldView
}
```
This is the input every later brain task consumes. `BeltInfo` is defined in Task 8; until then `beltsBySystem` is populated empty (`[:]`).

- [ ] **Step 1: Write the failing test** against an in-memory DB seeded with one meshed relay, one census star with a position, and one non-depleted salvage assay.

```swift
import Testing
import GameModels
import UniverseModels
@testable import DirectiveEngine

@Suite struct WorldViewTests {
    @Test func readDerivesMeshFromRelayingRelays() async throws {
        let db = try GameDatabase.bootstrapInMemory()  // existing test helper; see GameDatabase
        try await db.write { db in
            try Device.seedRelay(db, code: "R1", location: "SOL-3-L4", status: "relaying")
            try Star.seed(db, designation: "SOL", x: 0, y: 0, z: 0)
            try SiteAssay.seed(db, id: "VEGA-2-SAL-1", system: "VEGA",
                               totals: ["metal": 1200, "silicon": 800], depleted: false)
        }
        let now = Date(timeIntervalSince1970: 1_000)
        let view = try await db.read { try WorldView.read(from: $0, now: now) }
        #expect(view.meshSystems == ["SOL"])
        #expect(view.starPositions["SOL"] == Position(x: 0, y: 0, z: 0))
        #expect(view.salvageUnits["VEGA"] == 2000)
        #expect(view.now == now)
    }

    @Test func depletedSalvageExcluded() async throws {
        let db = try GameDatabase.bootstrapInMemory()
        try await db.write { db in
            try SiteAssay.seed(db, id: "DEAD-1-SAL-1", system: "DEAD",
                               totals: ["metal": 500], depleted: true)
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.salvageUnits["DEAD"] == nil)
    }
}
```
> If `bootstrapInMemory` / `seed*` helpers don't exist, add minimal ones in a `TestSupport` file in this task (they are test-only fixtures; keep them beside the test). Confirm the exact `Star`/`SiteAssay`/`Device` column names against `UniverseModels/Sources/LocationRecords.swift` and `GameModels/Sources/Device.swift` before writing the seeds.

- [ ] **Step 2: Run to verify it fails.** `swift test --filter WorldViewTests` → FAIL (`WorldView` undefined).
- [ ] **Step 3: Implement `WorldView.read`.** Wider than `WorldSnapshot.read` (which scopes systems to a directive's `wanted` set) — the brain needs galaxy scope, but only the *cheap* tables (devices, `stars`, `siteAssays`, `locationEvents`, footprints). Belt data (blob-decode) is deferred to Task 8's `ValueCatalog`, so `beltsBySystem` is `[:]` here.

```swift
import Foundation
import GameModels
import UniverseModels
import GRDB   // via SQLiteData

public struct WorldView: Equatable, Sendable {
    public let devices: [String: Device]
    public let starPositions: [String: Position]
    public let meshSystems: Set<String>
    public let salvageUnits: [String: Double]
    public let beltsBySystem: [String: [BeltInfo]]   // filled by ValueCatalog integration (Task 8+)
    public let eventSystems: Set<String>
    public let hubLocation: String?
    public let now: Date

    public static func read(from db: Database, now: Date) throws -> WorldView {
        let allDevices = try Device.all.fetchAll(db)
        let devicesByCode = Dictionary(uniqueKeysWithValues: allDevices.map { ($0.deviceCode, $0) })

        let mesh = SalvageTargetPlanner.meshSystems(in: allDevices)

        let stars = try Star.all.fetchAll(db)
        var positions: [String: Position] = [:]
        for s in stars { positions[s.designation] = s.position }

        // Sum non-depleted salvage per system.
        let assays = try SiteAssay.where { !$0.depleted && $0.siteType == "salvage" }.fetchAll(db)
        var salvage: [String: Double] = [:]
        for a in assays {
            salvage[a.system, default: 0] += a.totals.values.reduce(0, +)
        }

        let events = try LocationEvent.where { $0.status == "active" }.fetchAll(db)
        let eventSystems = Set(events.map { SiteAssay.system(of: $0.location) })

        let hub = Self.hubLocation(in: allDevices, meshSystems: mesh)

        return WorldView(
            devices: devicesByCode,
            starPositions: positions,
            meshSystems: mesh,
            salvageUnits: salvage,
            beltsBySystem: [:],
            eventSystems: eventSystems,
            hubLocation: hub,
            now: now
        )
    }

    /// The single print hub this effort: the autofactory device's location, but
    /// only if that system is meshed (off-mesh hub → escalate/unsupported, 06).
    static func hubLocation(in devices: [Device], meshSystems: Set<String>) -> String? {
        guard let hub = devices.first(where: { $0.isPrintHub })?.location else { return nil }
        return meshSystems.contains(SiteAssay.system(of: hub)) ? hub : nil
    }
}
```
> `Device.isPrintHub` lands in Task 3. `Star.all` / `SiteAssay.where` / `LocationEvent.where` are StructuredQueries against the existing `@Table`s — confirm the query DSL against an existing planner (`SalvageTargetPlanner` reads `stars`/`siteAssays`).

- [ ] **Step 4: Run to verify it passes.** `swift test --filter WorldViewTests` → PASS (after Task 3's `isPrintHub`; if executing strictly in order, stub `isPrintHub` inline first, then Task 3 hardens it).
- [ ] **Step 5: Commit.**

```bash
git add app/Modules/DirectiveEngine/Sources/WorldView.swift app/Modules/DirectiveEngine/Tests/WorldViewTests.swift
git commit -m "feat(brain): galaxy-wide WorldView snapshot for brain ranking"
```

### Task 3: `Device` hub + reclaimable-relay predicates

**Files:**
- Modify: `app/Modules/GameModels/Sources/Device.swift` (add computed helpers near `inControlRange`, ~line 170-210)
- Test: `app/Modules/GameModels/Tests/DevicePredicatesTests.swift`

**Interfaces:**
- Produces: `var Device.isPrintHub: Bool` (an `availableCommands`-contains-`enqueue_print` autofactory), `var Device.isActiveRelay: Bool` (`features.contains("relay") && statusBase == "relaying"`). Consumed by `WorldView` (Task 2), `PrunePredicate` (Task 13), `RelayRun` (Task 14).

- [ ] **Step 1: Write the failing test.**

```swift
import Testing
@testable import GameModels

@Suite struct DevicePredicatesTests {
    @Test func printHubIsAnEnqueuePrintCapableDevice() {
        var hub = Device.fixture(code: "AF1", type: "autofactory", location: "SOL-3")
        hub.availableCommands = ["enqueue_print", "configure"]
        #expect(hub.isPrintHub)
        var vessel = Device.fixture(code: "V1", type: "heaven_vessel", location: "SOL-3")
        vessel.availableCommands = ["travel", "stow"]
        #expect(!vessel.isPrintHub)
    }

    @Test func activeRelayNeedsFeatureAndRelayingStatus() {
        var r = Device.fixture(code: "R1", type: "ftl_relay", location: "SOL-3-L4")
        r.features = ["relay"]; r.status = "relaying"
        #expect(r.isActiveRelay)
        r.status = "idle"
        #expect(!r.isActiveRelay)
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `swift test --filter DevicePredicatesTests` → FAIL.
- [ ] **Step 3: Implement.**

```swift
public extension Device {
    /// The print hub predicate (06): a device that can accept `enqueue_print`.
    /// Uses availableCommands (capability) rather than a deviceType string match,
    /// which a print-vessel would otherwise miss. `system_hub` (mesh device) is a
    /// DIFFERENT concept and is deliberately not matched here.
    var isPrintHub: Bool { availableCommands.contains("enqueue_print") }

    /// An FTL relay that is presently meshing its system. Capability, not type
    /// (includes an integrated system_hub relay); status matched via statusBase.
    var isActiveRelay: Bool { features.contains("relay") && statusBase == "relaying" }
}
```

- [ ] **Step 4: Run to verify it passes.** → PASS. (Add `Device.fixture` to test support if absent — a loud minimal builder, mirroring the `testValue`/`previewValue` discipline.)
- [ ] **Step 5: Commit.**

```bash
git add app/Modules/GameModels/Sources/Device.swift app/Modules/GameModels/Tests/DevicePredicatesTests.swift
git commit -m "feat(brain): Device.isPrintHub and isActiveRelay predicates"
```

### Task 4: The plan loop on `DirectiveEngineCore` (idle, non-writing)

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift` (add `brain` Task field + start/stop wiring, ~lines 60-100)
- Create: `app/Modules/DirectiveEngine/Sources/Brain.swift` (the loop entry; `evaluateOnce` returns idle for now)
- Test: `app/Modules/DirectiveEngine/Tests/BrainLoopTests.swift`

**Interfaces:**
- Consumes: `WorldView.read` (Task 2), `@Dependency(\.continuousClock)`, `@Dependency(\.defaultDatabase)`.
- Produces: `Brain` type with `func evaluateOnce() async -> BrainDecision` (Task 6 defines `BrainDecision`; for now return `.idle(reason:)`), and a `DirectiveEngineCore.brain: Task<Void, Never>?` ticking every 5s. This is the real seam every later task tests end-to-end through (clause 5).

- [ ] **Step 1: Write the failing test** — under `TestClock`, the loop ticks and writes nothing.

```swift
import Testing
import Dependencies
@testable import DirectiveEngine

@Suite struct BrainLoopTests {
    @Test func loopTicksAndWritesNothingWhenIdle() async throws {
        let clock = TestClock()
        try await withDependencies {
            $0.continuousClock = clock
            $0.defaultDatabase = try GameDatabase.bootstrapInMemory()
        } operation: {
            let engine = DirectiveEngine.live(tick: .seconds(5))
            await engine.start()
            await clock.advance(by: .seconds(5))   // one brain tick
            // No directives exist and none should be created by an idle brain.
            let count = try await engine.directiveCount()
            #expect(count == 0)
            await engine.stop()
        }
    }
}
```
> Confirm the real construction seam — the existing `DirectiveEngine.live`/`start`/`stop` façade at `DirectiveEngine.swift:30-100`. Add a tiny `directiveCount()` test affordance only if one doesn't already exist; prefer reading the table directly in-test.

- [ ] **Step 2: Run to verify it fails.** → FAIL (no `brain` task; `Brain` undefined).
- [ ] **Step 3: Implement.** In `DirectiveEngine.swift`, add a sibling task, mirroring `supervisor` exactly:

```swift
// in actor DirectiveEngineCore, beside `supervisor`/`executors`:
private var brain: Task<Void, Never>?

// in start(), after claiming supervisor (guarded by supervisor == nil):
brain = Task { [weak self] in
    while !Task.isCancelled {
        await self?.tickBrain()
        try? await clock.sleep(for: tick)
    }
}

// in stop(): brain?.cancel(); brain = nil   (alongside supervisor cancel)

private func tickBrain() async {
    let decision = await Brain(now: /* clock.now bridged to Date via date dependency */).evaluateOnce()
    // Phase A: idle only — nothing to enact. Later phases act on `decision`.
    _ = decision
}
```
And `Brain.swift`:

```swift
import Foundation
import Dependencies

struct Brain {
    let now: Date
    @Dependency(\.defaultDatabase) var database

    func evaluateOnce() async -> BrainDecision {
        // Phase A: read the world, decide nothing.
        guard let view = try? await database.read({ try WorldView.read(from: $0, now: now) }) else {
            return .idle(reason: "world unavailable")
        }
        return .idle(reason: view.meshSystems.isEmpty ? "no mesh yet" : "no grow or prune work")
    }
}
```
> `BrainDecision` is defined in Task 6; for strict in-order execution, define a placeholder `enum BrainDecision { case idle(reason: String) }` here and let Task 6 expand it. Bridge the clock's `now` to a `Date` using the existing `@Dependency(\.date)` the engine already uses at launch sites (see `NewDirectiveFeature.swift:236` `date.now`), so `TestClock` determinism is preserved.

- [ ] **Step 4: Run to verify it passes.** → PASS (loop ticks, no writes).
- [ ] **Step 5: Commit.**

```bash
git add app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift app/Modules/DirectiveEngine/Sources/Brain.swift app/Modules/DirectiveEngine/Tests/BrainLoopTests.swift
git commit -m "feat(brain): plan loop on DirectiveEngineCore, idle and non-writing"
```

### Task 5: The why-view surface (idle state)

**Files:**
- Create: `app/Modules/DirectivesFeature/Sources/BrainWhyView.swift`
- Create: `app/Modules/DirectivesFeature/Sources/BrainWhyRow.swift` (row struct in its own file — `list-row-preview-crash` rule)
- Test: `app/Modules/DirectivesFeature/Tests/BrainWhyViewTests.swift` (logic only)

**Interfaces:**
- Consumes: `BrainDecision` (Task 6) rendered as a derived view model `BrainWhy` (no new table — like `WorldView`, per clause 8).
- Produces: `struct BrainWhy: Equatable { var topGoalGate: String; var candidates: [BrainWhyRow]; var limitPressure: [String] }` and `BrainWhy.from(decision:view:)`. Later phases populate `candidates`.

- [ ] **Step 1: Write the failing test** — an idle decision renders a calm, surfaced (not escalated) why-view.

```swift
import Testing
@testable import DirectivesFeature
@testable import DirectiveEngine

@Suite struct BrainWhyViewTests {
    @Test func idleIsSurfacedButNotEscalated() {
        let why = BrainWhy.from(decision: .idle(reason: "no grow or prune work"), view: nil)
        #expect(why.topGoalGate == "idle — no grow or prune work")
        #expect(why.candidates.isEmpty)
        #expect(!why.isEscalated)   // idle-calm must NOT read as a stall (clause 6)
    }
}
```

- [ ] **Step 2: Run to verify it fails.** → FAIL.
- [ ] **Step 3: Implement** the derived view model + a minimal SwiftUI surface. System/location names in `.rcMono*`; no hard-coded tokens; `isEscalated` distinguishes idle-calm from stall.

```swift
public struct BrainWhy: Equatable, Sendable {
    public var topGoalGate: String
    public var candidates: [BrainWhyRow]
    public var limitPressure: [String]
    public var isEscalated: Bool

    public static func from(decision: BrainDecision, view: WorldView?) -> BrainWhy {
        switch decision {
        case let .idle(reason):
            return .init(topGoalGate: "idle — \(reason)", candidates: [], limitPressure: [], isEscalated: false)
        case let .stall(reason):
            return .init(topGoalGate: "stalled — \(reason.displayName)", candidates: [], limitPressure: [], isEscalated: true)
        case let .dispatch(goal, ranked):
            return .init(topGoalGate: "dispatching — \(goal.rationale)",
                         candidates: ranked.map(BrainWhyRow.init(candidate:)),
                         limitPressure: [], isEscalated: false)
        }
    }
}
```
> The SwiftUI view itself (a `List` reading `BrainWhy`) is scaffolding — wire it into the existing Directives surface under a "Brain" section. Keep the row struct (`BrainWhyRow`) in its own file. Actions (launch/retire) already ride the `DirectiveLogEntry` timeline, so the why-view is read-only.

- [ ] **Step 4: Run to verify it passes.** → PASS.
- [ ] **Step 5: Commit.**

```bash
git add app/Modules/DirectivesFeature/Sources/BrainWhyView.swift app/Modules/DirectivesFeature/Sources/BrainWhyRow.swift app/Modules/DirectivesFeature/Tests/BrainWhyViewTests.swift
git commit -m "feat(brain): derived why-view surface, idle state"
```

### Task 6: The `Goal` model + `BrainDecision`

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/BrainGoal.swift`
- Test: `app/Modules/DirectiveEngine/Tests/BrainGoalTests.swift`

**Interfaces:**
- Produces:
```swift
public struct Goal: Equatable, Sendable {
    public enum Kind: String, Sendable { case survey, tendMesh, mine, salvage, fulfillEvent }
    public let kind: Kind
    public let target: String        // grow: the first-hop system to plant; prune: the useless relay code
    public let rationale: String     // a graph fact, never a scalar (clause 8)
}
public enum BrainDecision: Equatable, Sendable {
    case idle(reason: String)
    case stall(DirectiveAttentionReason)
    case dispatch(Goal, ranked: [GrowCandidate])   // GrowCandidate from Task 12
}
```
This replaces the Task 4/5 placeholders; consumed everywhere downstream.

- [ ] **Step 1: Write the failing test** — a `Goal` carries a legible rationale; `BrainDecision` equatably distinguishes idle/stall/dispatch.

```swift
@Suite struct BrainGoalTests {
    @Test func decisionsAreDistinct() {
        let g = Goal(kind: .tendMesh, target: "POLARISUM", rationale: "meshing POLARISUM — 3,200 units at VEGA, 2 hops")
        #expect(BrainDecision.idle(reason: "x") != BrainDecision.stall(.relayActivationFailed))
        #expect(BrainDecision.dispatch(g, ranked: []) != .idle(reason: "x"))
    }
}
```

- [ ] **Step 2–5:** implement the two value types (replace placeholders in Tasks 4/5), run green, commit `feat(brain): Goal model and BrainDecision`.

---

## Phase B — The mesh graph & pathfinding (the stateless graph computation)

Deliverable at end of phase: a pure, tested multi-source Dijkstra over a ≤7.5 ly relay-hop graph that, from the live mesh, returns the cheapest relay chain to any target system — the single computation grow and prune both read. No brain wiring yet; this is the algorithmic keystone (the `OrreryLayout`-style pure resolver).

### Task 7: The spatial grid + hop adjacency

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/MeshGraph.swift` (grid + adjacency portion)
- Test: `app/Modules/DirectiveEngine/Tests/MeshGraphAdjacencyTests.swift`

**Interfaces:**
- Consumes: `Position` (UniverseModels), `Position.distance(to:)` (existing, `Position.swift:25`), `SalvageTargetPlanner.relayRangeLY` (existing `= 7.5`).
- Produces: `MeshGraph(positions:hopRange:)` and `func neighbours(of system: String) -> [String]` (systems within `hopRange`, via a uniform grid so it is not O(n²) per query).

- [ ] **Step 1: Write the failing test** — neighbours within 7.5 ly are found; beyond are excluded; the grid agrees with brute force on a small set.

```swift
@Suite struct MeshGraphAdjacencyTests {
    @Test func neighboursWithinHopRange() {
        let positions: [String: Position] = [
            "A": .init(x: 0, y: 0, z: 0),
            "B": .init(x: 5, y: 0, z: 0),   // 5 ly from A — neighbour
            "C": .init(x: 9, y: 0, z: 0),   // 9 ly from A — not a neighbour (but is of B)
        ]
        let g = MeshGraph(positions: positions, hopRange: 7.5)
        #expect(Set(g.neighbours(of: "A")) == ["B"])
        #expect(Set(g.neighbours(of: "B")) == ["A", "C"])
    }

    @Test func gridMatchesBruteForceOnRandomCloud() {
        var positions: [String: Position] = [:]
        for i in 0..<200 {
            // deterministic pseudo-cloud — no Math.random in tests
            positions["S\(i)"] = .init(x: Double(i % 17) * 2, y: Double((i * 7) % 13) * 2, z: Double((i * 3) % 11) * 2)
        }
        let g = MeshGraph(positions: positions, hopRange: 7.5)
        for (s, p) in positions {
            let brute = Set(positions.filter { $0.key != s && $0.value.distance(to: p) <= 7.5 }.keys)
            #expect(Set(g.neighbours(of: s)) == brute, "grid disagrees at \(s)")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails.** → FAIL.
- [ ] **Step 3: Implement** a uniform spatial grid keyed by `floor(coord / hopRange)`, scanning the 27 neighbour cells. This keeps per-query cost bounded even at ~14,000 census systems (the reconnaissance count), so a stateless per-tick rebuild stays within the 5s budget.

```swift
public struct MeshGraph: Sendable {
    private let positions: [String: Position]
    private let hopRange: Double
    private let cells: [Cell: [String]]

    struct Cell: Hashable { let x: Int; let y: Int; let z: Int }

    public init(positions: [String: Position], hopRange: Double = SalvageTargetPlanner.relayRangeLY) {
        self.positions = positions
        self.hopRange = hopRange
        var cells: [Cell: [String]] = [:]
        for (name, p) in positions {
            cells[Self.cell(for: p, hopRange: hopRange), default: []].append(name)
        }
        self.cells = cells
    }

    static func cell(for p: Position, hopRange: Double) -> Cell {
        Cell(x: Int((p.x / hopRange).rounded(.down)),
             y: Int((p.y / hopRange).rounded(.down)),
             z: Int((p.z / hopRange).rounded(.down)))
    }

    public func neighbours(of system: String) -> [String] {
        guard let p = positions[system] else { return [] }
        let base = Self.cell(for: p, hopRange: hopRange)
        var out: [String] = []
        for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
            let c = Cell(x: base.x + dx, y: base.y + dy, z: base.z + dz)
            for other in cells[c] ?? [] where other != system {
                if let q = positions[other], q.distance(to: p) <= hopRange { out.append(other) }
            }
        }}}
        return out
    }
}
```

- [ ] **Step 4: Run to verify it passes.** → PASS (both tests).
- [ ] **Step 5: Commit.** `feat(brain): spatial-grid hop adjacency for the mesh graph`.

### Task 8: Multi-source Dijkstra → cheapest relay chains

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MeshGraph.swift` (add `reach`)
- Test: `app/Modules/DirectiveEngine/Tests/MeshGraphReachTests.swift`

**Interfaces:**
- Produces:
```swift
public struct Chain: Equatable, Sendable {
    public let target: String
    public let firstHop: String     // the first UNMESHED system to plant a relay at (== target if completesNow)
    public let relaysRemaining: Int // count of new relays to fully unlock target (incl. target)
    public let completesNow: Bool   // relaysRemaining == 1
    public let waypoints: [String]  // full ordered unmeshed path incl. target (for the path-union)
    public let hopDistance: Double  // total ly along the chain (minor sub-tiebreak)
}
public extension MeshGraph {
    /// Multi-source over the live mesh: cheapest new-relay chain to each target.
    /// Node cost = +1 per unmeshed system entered (a relay). Mesh systems are
    /// zero-cost sources. Ties on relay count broken by total hop distance.
    func reach(targets: Set<String>, meshSystems: Set<String>) -> [String: Chain]
}
```
- Consumes: Task 7's adjacency. Unreachable targets (no ≤7.5 chain from the mesh) are simply absent from the result.

- [ ] **Step 1: Write the failing test** — one-hop completes now; a two-hop chain reports the correct first hop and relay count; an out-of-range target is unreachable.

```swift
@Suite struct MeshGraphReachTests {
    // Line world: MESH(0) — W(6) — T(12).  hopRange 7.5.
    let positions: [String: Position] = [
        "MESH": .init(x: 0, y: 0, z: 0),
        "W":    .init(x: 6, y: 0, z: 0),
        "T":    .init(x: 12, y: 0, z: 0),
        "FAR":  .init(x: 40, y: 0, z: 0),
    ]

    @Test func oneHopCompletesNow() {
        let g = MeshGraph(positions: positions)
        let chains = g.reach(targets: ["W"], meshSystems: ["MESH"])
        let c = try! #require(chains["W"])
        #expect(c.firstHop == "W")
        #expect(c.relaysRemaining == 1)
        #expect(c.completesNow)
    }

    @Test func twoHopReportsFirstHopAndCount() {
        let g = MeshGraph(positions: positions)
        let chains = g.reach(targets: ["T"], meshSystems: ["MESH"])
        let c = try! #require(chains["T"])
        #expect(c.firstHop == "W")            // plant W first, not T
        #expect(c.relaysRemaining == 2)       // W then T
        #expect(!c.completesNow)
        #expect(c.waypoints == ["W", "T"])
    }

    @Test func outOfRangeTargetIsUnreachable() {
        let g = MeshGraph(positions: positions)
        #expect(g.reach(targets: ["FAR"], meshSystems: ["MESH"]).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails.** → FAIL.
- [ ] **Step 3: Implement** a Dijkstra where a mesh system has cost 0 and entering an unmeshed system costs +1 relay (ties broken by accumulated hop distance). Predecessor backtracking yields `waypoints`/`firstHop`.

```swift
public extension MeshGraph {
    func reach(targets: Set<String>, meshSystems: Set<String>) -> [String: Chain] {
        struct State { var relays: Int; var dist: Double; var pred: String? }
        var best: [String: State] = [:]
        // Priority frontier keyed lexicographically by (relays, dist).
        var frontier = Heap<Frontier>()  // min-heap on (relays, dist); see helper below
        for m in meshSystems where allSystems.contains(m) {
            best[m] = State(relays: 0, dist: 0, pred: nil)
            frontier.insert(.init(system: m, relays: 0, dist: 0))
        }
        var settled: Set<String> = []
        let wanted = targets
        var remaining = wanted
        while let node = frontier.popMin(), !remaining.isEmpty {
            if settled.contains(node.system) { continue }
            settled.insert(node.system)
            remaining.remove(node.system)
            for nb in neighbours(of: node.system) {
                let stepDist = (positions[node.system]!).distance(to: positions[nb]!)
                let addRelay = meshSystems.contains(nb) ? 0 : 1
                let cand = State(relays: node.relays + addRelay, dist: node.dist + stepDist, pred: node.system)
                if let cur = best[nb], (cur.relays, cur.dist) <= (cand.relays, cand.dist) { continue }
                best[nb] = cand
                frontier.insert(.init(system: nb, relays: cand.relays, dist: cand.dist))
            }
        }
        var out: [String: Chain] = [:]
        for t in wanted {
            guard let s = best[t], s.relays > 0 else { continue }  // relays==0 ⇒ already meshed, not a grow target
            let path = Self.backtrack(to: t, best: best)
            let unmeshedPath = path.filter { !meshSystems.contains($0) }
            guard let firstHop = unmeshedPath.first else { continue }
            out[t] = Chain(target: t, firstHop: firstHop, relaysRemaining: unmeshedPath.count,
                           completesNow: unmeshedPath.count == 1, waypoints: unmeshedPath, hopDistance: s.dist)
        }
        return out
    }
}
```
> Provide a tiny deterministic binary-heap helper (`Heap<Frontier>`) in the same file, or fall back to a sorted-array frontier if the target set is small — correctness first; the grid already bounds fan-out. `allSystems`/`positions` are `MeshGraph` internals; expose `backtrack` as a private static. `(a, b) <= (c, d)` uses tuple lexicographic comparison. **Comparison operator note:** Swift tuples are `Comparable` up to arity 6 — `(relays, dist)` is fine.

- [ ] **Step 4: Run to verify it passes.** → PASS (all three).
- [ ] **Step 5: Commit.** `feat(brain): multi-source Dijkstra for cheapest relay chains`.

---

## Phase C — The value model & the grow ranking

Deliverable at end of phase: given a `WorldView`, the brain enumerates unmeshed value-bearing systems, scores each candidate first-hop by the locked lexicographic key, and produces the top grow `Goal` — all pure, all tested, still not enacting.

### Task 9 (VERIFICATION): pin the belt-class source field, then build `BeltClass`

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/MeshValue.swift` (`BeltClass`, `BeltInfo`, classification)
- Test: `app/Modules/DirectiveEngine/Tests/BeltClassTests.swift`
- Doc: append findings to `app/.claude/memory/` (a new note or the belt/mining note)

**Interfaces:**
- Produces: `public enum BeltClass: Int, Comparable, Sendable { case sparse, moderate, rich }` (Comparable by rawValue) and `struct BeltInfo { let designation: String; let beltClass: BeltClass }`, plus `BeltClass.classify(density:richness:) -> BeltClass?`.

- [ ] **Step 1 (verify, don't re-decide): probe the live API for the real `density` value set.** Use the `probe-api` skill (GET-only, safe):

```bash
# Find a surveyed system with an asteroid belt, then read its location detail:
replicant raw GET locations/<SYSTEM-WITH-BELT>
```
Inspect the belt objects' `density` (and `resources`/`richness`) fields. Record the exact string vocabulary observed. **The tier ordering `Rich ▸ Moderate ▸ Sparse` is locked — you are only mapping observed strings onto it.** If `density` is truly free-form/absent, fall back to folding `richness` (max per-resource qualifier). Write the confirmed mapping into a memory note so later capability plans inherit it.

- [ ] **Step 2: Write the failing test** encoding the confirmed mapping (example assumes `density ∈ {sparse, moderate, dense}` — **replace with the verified vocabulary from Step 1**):

```swift
@Suite struct BeltClassTests {
    @Test func densityMapsToLockedClasses() {
        #expect(BeltClass.classify(density: "dense", richness: [:]) == .rich)
        #expect(BeltClass.classify(density: "moderate", richness: [:]) == .moderate)
        #expect(BeltClass.classify(density: "sparse", richness: [:]) == .sparse)
    }
    @Test func fallsBackToRichnessWhenDensityMissing() {
        #expect(BeltClass.classify(density: nil, richness: ["metal": "abundant"]) == .rich)
        #expect(BeltClass.classify(density: nil, richness: ["metal": "low"]) == .sparse)
    }
    @Test func classIsOrdered() {
        #expect(BeltClass.sparse < BeltClass.moderate)
        #expect(BeltClass.moderate < BeltClass.rich)
    }
}
```

- [ ] **Step 3: Implement** `classify` per the verified mapping (adjust the string arms to Step 1's findings — do not invent classes beyond the three locked ones):

```swift
public enum BeltClass: Int, Comparable, Sendable {
    case sparse = 0, moderate = 1, rich = 2
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

    /// Maps the observed `density` string (VERIFIED in Task 9 Step 1) onto the
    /// three locked classes; folds the per-resource `richness` map as fallback.
    public static func classify(density: String?, richness: [String: String]) -> BeltClass? {
        switch density?.lowercased() {
        case "dense", "rich", "abundant": return .rich
        case "moderate", "medium":        return .moderate
        case "sparse", "low", "thin":     return .sparse
        default: break
        }
        let ranks = richness.values.map { qualifier -> Int in
            switch qualifier.lowercased() {
            case "abundant", "high": return 2
            case "moderate":         return 1
            default:                 return 0
            }
        }
        guard let top = ranks.max() else { return nil }
        return BeltClass(rawValue: top)
    }
}
```

- [ ] **Step 4: Run to verify it passes.** → PASS.
- [ ] **Step 5: Commit.** `feat(brain): BeltClass (verified density mapping) + ordered tiers` — include the memory-note update in the same commit.

### Task 10: `ValueTier` + `ValueTarget` + `ValueCatalog.build`

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MeshValue.swift`
- Test: `app/Modules/DirectiveEngine/Tests/ValueCatalogTests.swift`

**Interfaces:**
- Consumes: `WorldView` (salvageUnits/eventSystems/beltsBySystem), `BeltClass`.
- Produces:
```swift
public enum ValueTier: Int, Comparable, Sendable {   // the locked hard ordering
    case sparseBelt = 0, salvage = 1, moderateBelt = 2, richBelt = 3, event = 4
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}
public struct ValueTarget: Equatable, Sendable {
    public let system: String
    public let bestTier: ValueTier
    public let salvageUnits: Double          // magnitude within the salvage tier
    public let beltCount: [BeltClass: Int]   // magnitude within a belt tier (served belts at that class)
    public let hasEvent: Bool
}
public enum ValueCatalog {
    /// Unmeshed systems holding value (salvage + mine belts + events). Survey EXCLUDED.
    public static func build(from view: WorldView) -> [ValueTarget]
}
```
> Note the enum's raw order encodes `Event(4) ▸ RichBelt(3) ▸ ModerateBelt(2) ▸ salvage(1) ▸ SparseBelt(0)`, exactly the locked tier ordering with salvage sitting between moderate and sparse belts.

- [ ] **Step 1: Write the failing test** — a system's `bestTier` is the max tier it holds; survey-only systems produce no target; already-meshed systems are excluded.

```swift
@Suite struct ValueCatalogTests {
    @Test func bestTierIsTheMaxHeld() {
        var view = WorldView.empty(meshSystems: ["SOL"])
        view = view.with(salvageUnits: ["VEGA": 3200], eventSystems: ["VEGA"])  // event beats salvage
        let targets = ValueCatalog.build(from: view)
        let vega = try! #require(targets.first { $0.system == "VEGA" })
        #expect(vega.bestTier == .event)
        #expect(vega.salvageUnits == 3200)
        #expect(vega.hasEvent)
    }

    @Test func meshedSystemsAreNotTargets() {
        let view = WorldView.empty(meshSystems: ["SOL"]).with(salvageUnits: ["SOL": 999])
        #expect(ValueCatalog.build(from: view).allSatisfy { $0.system != "SOL" })
    }

    @Test func surveyFrontierIsExcluded() {
        // A system with a position but no salvage/belt/event yields no target.
        let view = WorldView.empty(meshSystems: ["SOL"]).with(starPositions: ["DARK": .init(x: 3, y: 0, z: 0)])
        #expect(ValueCatalog.build(from: view).isEmpty)
    }
}
```
> Add small `WorldView.empty(...)` / `.with(...)` test builders (test-only) for ergonomic fixtures.

- [ ] **Step 2: Run to verify it fails.** → FAIL.
- [ ] **Step 3: Implement** `build`: union the systems appearing in `salvageUnits`, `beltsBySystem`, `eventSystems`; drop meshed systems; compute `bestTier` and per-tier magnitude.
- [ ] **Step 4: Run to verify it passes.** → PASS.
- [ ] **Step 5: Commit.** `feat(brain): value catalog over salvage/belts/events (survey excluded)`.

### Task 11: Wire belt data into `WorldView` (the blob-decode boundary)

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/WorldView.swift` (populate `beltsBySystem`)
- Test: `app/Modules/DirectiveEngine/Tests/WorldViewBeltsTests.swift`

**Interfaces:**
- Consumes: the persisted `StarSystem` blobs / belt decode (`Belt` in `UniverseModels/Sources/LocationModels.swift:518`; decoded via `RawBelt.domain()`), `BeltClass.classify`.
- Produces: `WorldView.beltsBySystem` filled for **surveyed, unmeshed** systems only (bounded set — meshed systems don't need grow-scoring, and belt richness is only known post-survey).

- [ ] **Step 1: Write the failing test** — a surveyed unmeshed system with a decoded belt appears in `beltsBySystem` with the right class; a meshed system is skipped (cost control).

```swift
@Suite struct WorldViewBeltsTests {
    @Test func surveyedUnmeshedBeltsAreClassified() async throws {
        let db = try GameDatabase.bootstrapInMemory()
        try await db.write { db in
            try Star.seed(db, designation: "CERES", x: 4, y: 0, z: 0)
            try StarSystem.seedWithBelt(db, system: "CERES", beltDesignation: "CERES-2-BELT", density: "dense")
        }
        let view = try await db.read { try WorldView.read(from: $0, now: Date()) }
        #expect(view.beltsBySystem["CERES"]?.first?.beltClass == .rich)
    }
}
```

- [ ] **Step 2: Run to verify it fails.** → FAIL.
- [ ] **Step 3: Implement** a bounded belt read: enumerate systems that are surveyed (in `stars`, `fullyScannedAt != nil` or `recon == scanned`) and NOT in `meshSystems`, decode their `StarSystem` blob's belts, and classify. **Performance guard:** cap/log the decode set size; if it proves costly at scale, a follow-up `belts` index table is the escape hatch (note in code + memory) — do not build it now. Fold this into `WorldView.read`.
- [ ] **Step 4: Run to verify it passes.** → PASS.
- [ ] **Step 5: Commit.** `feat(brain): classify surveyed-unmeshed belts into WorldView`.

### Task 12: The grow ranking key

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/GrowRanking.swift`
- Test: `app/Modules/DirectiveEngine/Tests/GrowRankingTests.swift`

**Interfaces:**
- Consumes: `MeshGraph.reach` (Task 8), `ValueCatalog` (Task 10), `WorldView`.
- Produces:
```swift
public struct GrowCandidate: Equatable, Sendable {
    public let firstHop: String            // system to plant a relay at (the grow target)
    public let completesNow: Bool
    public let relaysRemaining: Int
    public let bestTier: ValueTier         // best tier over ALL targets this hop serves
    public let magnitudeAtTier: Double     // salvage units OR served-belt-count at bestTier
    public let hopDistance: Double
    public let servedTargets: [String]     // for the why-view rationale
    public let designation: String         // == firstHop; the stable tiebreak
}
public enum GrowRanking {
    /// The locked lexicographic key:
    /// 1 completesNow (true first) · 2 fewest relaysRemaining (then hopDistance) ·
    /// 3 value = (bestTier, magnitudeAtTier) · 4 resource cost (inert, 370×6) · 5 designation.
    public static func rank(view: WorldView, graph: MeshGraph) -> [GrowCandidate]
}
```

- [ ] **Step 1: Write the failing tests** — each key field decides in isolation:

```swift
@Suite struct GrowRankingTests {
    // Two targets, both one hop from the mesh: an event system outranks a salvage system.
    @Test func tierBeatsMagnitude() {
        let view = WorldView.empty(meshSystems: ["MESH"])
            .with(starPositions: ["MESH": .zero, "EV": .init(x: 5, y: 0, z: 0), "SV": .init(x: 5, y: 3, z: 0)],
                  salvageUnits: ["SV": 999_999], eventSystems: ["EV"])
        let graph = MeshGraph(positions: view.starPositions)
        let ranked = GrowRanking.rank(view: view, graph: graph)
        #expect(ranked.first?.firstHop == "EV")   // event tier out-ranks a huge salvage pile
    }

    @Test func completesNowBeatsCheaperDistantChain() {
        // A one-hop salvage completes now; a one-hop-but-two-relays richer target does not.
        // completesNow (field 1) dominates before value (field 3).
        // ...construct and assert ranked.first.completesNow == true
    }

    @Test func fewerRelaysBeatsMoreRelays() { /* two targets, same tier, 1 vs 2 relays → 1 wins */ }
    @Test func designationBreaksExactTies() { /* identical everything → lexicographic designation */ }
}
```

- [ ] **Step 2: Run to verify it fails.** → FAIL.
- [ ] **Step 3: Implement** — build the target set from `ValueCatalog`, run `graph.reach`, group chains by `firstHop`, aggregate each group's `(bestTier, magnitudeAtTier)` and min `relaysRemaining`/`completesNow`, then sort by the lexicographic key. Encode the sort as an explicit tuple comparison so it reads as the locked key (no scalar utility).

```swift
public static func rank(view: WorldView, graph: MeshGraph) -> [GrowCandidate] {
    let targets = ValueCatalog.build(from: view)
    let chains = graph.reach(targets: Set(targets.map(\.system)), meshSystems: view.meshSystems)
    var byHop: [String: [ (Chain, ValueTarget) ]] = [:]
    for t in targets { if let c = chains[t.system] { byHop[c.firstHop, default: []].append((c, t)) } }

    let candidates = byHop.map { (hop, pairs) -> GrowCandidate in
        let completesNow = pairs.contains { $0.0.completesNow }
        let minRelays = pairs.map { $0.0.relaysRemaining }.min() ?? .max
        let minDist = pairs.filter { $0.0.relaysRemaining == minRelays }.map { $0.0.hopDistance }.min() ?? 0
        let bestTier = pairs.map { $0.1.bestTier }.max() ?? .sparseBelt
        let magnitude = Self.magnitude(at: bestTier, over: pairs.map(\.1))
        return GrowCandidate(firstHop: hop, completesNow: completesNow, relaysRemaining: minRelays,
                             bestTier: bestTier, magnitudeAtTier: magnitude, hopDistance: minDist,
                             servedTargets: pairs.map { $0.1.system }.sorted(), designation: hop)
    }
    return candidates.sorted { a, b in
        // Lexicographic, highest priority first. Higher completesNow/tier/magnitude = better.
        if a.completesNow != b.completesNow { return a.completesNow }
        if a.relaysRemaining != b.relaysRemaining { return a.relaysRemaining < b.relaysRemaining }
        if a.hopDistance != b.hopDistance { return a.hopDistance < b.hopDistance }
        if a.bestTier != b.bestTier { return a.bestTier > b.bestTier }
        if a.magnitudeAtTier != b.magnitudeAtTier { return a.magnitudeAtTier > b.magnitudeAtTier }
        // field 4 (resource cost) is inert (fixed 370×6) — skipped.
        return a.designation < b.designation
    }
}
```

- [ ] **Step 4: Run to verify it passes.** → PASS (all key-field tests).
- [ ] **Step 5: Commit.** `feat(brain): lexicographic grow ranking over first-hop candidates`.

---

## Phase D — The Relay Run executor & grow enactment (the brain grows the mesh)

Deliverable at end of phase: the brain launches a **Relay Run** directive for the top grow candidate; the executor prints a relay at the hub, stows it, flies to the plant system, deploys and activates it in-situ, and confirms the mesh — through the real `CommandGovernor` seam. Grow is live (print-sourced only; reclaim sourcing is Phase E).

### Task 13: The `printStockShort` attention reason (the `R` rail)

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (add `.printStockShort` case + `displayName`/`guidance`; extend `brainDisposition` switch to classify it `.retry`)
- Test: extend `BrainDispositionTests`

**Interfaces:**
- Produces: `DirectiveAttentionReason.printStockShort` (disposition `.retry` — self-supply refills the hub, so it idles rather than escalates, per 05).

- [ ] **Step 1: Write the failing test** — `printStockShort.brainDisposition == .retry`.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the new case + `displayName`/`guidance` strings + the `.retry` arm. This is an append-only enum case (a `String` raw enum; place it after `awaitingRelayRestock` to keep persisted values stable).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit.** `feat(brain): printStockShort attention reason (R rail veto, retry disposition)`.

### Task 14: `RelayRun` machine — print → stow → travel → emplace → activate → confirm

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/RelayRun.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/MissionRegistry.swift` (add `RelayRun()`)
- Test: `app/Modules/DirectiveEngine/Tests/RelayRunTests.swift`

**Interfaces:**
- Consumes: `MissionStepMachine` protocol (`MissionStepMachine.swift:252`), `MissionAction` (explicit-`deviceCode` `.dispatch`), the proven SalvageRun shape (`SalvageRun.swift:579-725` emplace/activate/confirmRelay), `CommandClient+Printing` (`enqueue_print`, deviceType only), print completion via `print.completed`/`new_device_code`.
- Produces: `struct RelayRun: MissionStepMachine { var kind = .relayRun; var firstStep = Step.acquire ... }` registered in `MissionRegistry.machines`.

Step vocabulary (all plain `String` constants in a nested `enum Step`):
`acquire` → `printing` → `stowing` → `travelling` → `emplacing` → `activating` → `confirmingRelay` → `settling` → (done). Every `.simple` verb (`deploy`, `activate`, `stow`) is split dispatch-step/poll-step per the global constraint.

- [ ] **Step 1: Write the failing test** — the machine, given a fresh `relayRun` directive whose target is an unmeshed system and whose vessel is at the hub, first dispatches `enqueue_print` with the relay `device_type` only.

```swift
@Suite struct RelayRunTests {
    @Test func acquireStepEnqueuesAPrintAtTheHub() {
        let run = RelayRun()
        let directive = Directive.relayRunFixture(vessel: "V1", target: "VEGA", step: RelayRun.Step.acquire, sourceRelayCode: nil)
        let world = WorldSnapshot.fixture(
            devices: [.hub("AF1", location: "SOL-3", coLocatedVessel: "V1")],
            now: Date())
        let action = run.nextAction(directive: directive, world: world)
        guard case let .dispatch(kind, deviceCode, params, next) = action else {
            return #expect(Bool(false), "expected a print dispatch, got \(action)")
        }
        #expect(kind == .print)
        #expect(deviceCode == "V1")               // carrier prints where it already is (a print-vessel) OR at AF1 (autofactory)
        #expect(params.deviceType == "ftl_relay")
        #expect(params.destination == nil)        // no location, no resource bill rides the call
        #expect(next == RelayRun.Step.printing)
    }

    @Test func confirmRelaySettlesWhenRelaying() {
        // A relay device at the target's L4 with statusBase == "relaying" → advance to settling/done.
    }

    @Test func printStockShortStallsRetry() {
        // The printing preflight's .high inventory read shows a type below R → .stall(.printStockShort)
    }
}
```
> Confirm the relay's real `device_type` string ("ftl_relay") and the hub vs print-vessel carrier choice against the live API / `salvage-run-design` (SalvageRun stages relays aboard a vessel). The autofactory-carrier composition (06) auto-stows a printed relay via a co-located HEAVEN vessel; a print-vessel collapses printer==carrier. Pick one for v1 and note it.

- [ ] **Step 2: Run to verify it fails.** → FAIL (`RelayRun` undefined).
- [ ] **Step 3: Implement** the machine. `acquire` branches on `directive.sourceRelayCode` (nil ⇒ print; Phase E adds the reclaim branch). Clone `emplace`/`activate`/`confirmRelay` verbatim in shape from `SalvageRun.swift:579-725` — travel the vessel to the target's L4 (`lagrangePoint(in:)`), `deploy` the stowed relay against the *relay's* `deviceCode`, then `activate` in-situ, then poll `statusBase == "relaying"` with the same `activationDeadline` backstop. `printing` does a `.refreshDevices` on the hub + an `.high` inventory check for the `R` rail (short ⇒ `.stall(.printStockShort)`), and completes on the printed clone's appearance (`print.completed`/`new_device_code` folds it into the fleet — see `GameSync.swift:332`). `stowing` issues `stow` (target = carrier) then polls the relay's `stowedInDeviceCode`. Register `RelayRun()` in `MissionRegistry`.
- [ ] **Step 4: Run to verify it passes.** → PASS.
- [ ] **Step 5: Commit.** `feat(brain): Relay Run mission machine (print→stow→emplace→activate→confirm)`.

### Task 15: The `sourceRelayCode` column (append-only migration)

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift` (add column + `addSourceRelayCode` migration)
- Modify: `app/Modules/GameDatabase/...` manifest registration (append the migration identifier)
- Test: `app/Modules/GameModels/Tests/...` (schema manifest + golden schema)

**Interfaces:**
- Produces: `Directive.sourceRelayCode: String?` — nil ⇒ print at hub; non-nil ⇒ reclaim this relay as the source (Phase E). A deliberate, minimal plan-hint column, distinct from the rejected "committed-devices" lease field (04/05): it is not a lease, it carries no ownership, and the executor still leases only the carrier `deviceCode`.

- [ ] **Step 1: Write the failing test** — `SchemaManifestTests` expects the new identifier `addSourceRelayCode` in order; a round-trip preserves `sourceRelayCode`.
- [ ] **Step 2: Run → FAIL** (manifest frozen without it).
- [ ] **Step 3: Implement** — add the property to the `@Table struct Directive`, append `SchemaMigration(id: "addSourceRelayCode") { ALTER TABLE directives ADD COLUMN sourceRelayCode TEXT }` to `GameDatabase.manifest` (append-only — never edit `createDirectives`), and update the frozen manifest list. Regenerate the golden schema with `RC_REGENERATE_SCHEMA_FIXTURE=1` (intended change).
- [ ] **Step 4: Run → PASS** (`SchemaManifestTests`, `GoldenSchemaTests`).
- [ ] **Step 5: Commit.** `feat(brain): Directive.sourceRelayCode plan-hint column (append-only migration)`.

### Task 16: Brain launches a grow directive (the greedy pass, grow-only)

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift` (turn the idle stub into a grow-launching selector)
- Test: `app/Modules/DirectiveEngine/Tests/BrainGrowTests.swift`

**Interfaces:**
- Consumes: `GrowRanking.rank` (Task 12), the directive-row reservation rules (04: exclude each owning-status directive's `deviceCode` + transitively-stowed + `controllerCode` + `fleetTag`), a free `heaven_vessel` carrier, `Directive.insert` (the launcher shape from `NewDirectiveFeature.swift:202-236`).
- Produces: `Brain.evaluateOnce` now returns `.dispatch(goal, ranked:)` and, on that decision, **launches** a `relayRun` directive (`kind: .relayRun`, `deviceCode: carrier`, `targets: [firstHop]`, `sourceRelayCode: nil`, `step: RelayRun().firstStep`, `status: .running`).

- [ ] **Step 1: Write the failing test — END-TO-END THROUGH THE REAL SEAM (clause 5).** Seed a world with a meshed hub, a free carrier, and a one-hop salvage target; run one brain tick under `TestClock`; assert a `.running` `relayRun` row now exists targeting the value system, and that a second tick does **not** double-launch (the running row reserves the carrier).

```swift
@Suite struct BrainGrowTests {
    @Test func brainLaunchesRelayRunForTopGrowCandidate() async throws {
        let clock = TestClock()
        try await withDependencies {
            $0.continuousClock = clock
            $0.defaultDatabase = try GameDatabase.bootstrapInMemory()
        } operation: {
            try await seedGrowableWorld()   // meshed SOL hub + carrier V1 + one-hop salvage at VEGA
            let engine = DirectiveEngine.live(tick: .seconds(5))
            await engine.start()
            await clock.advance(by: .seconds(5))
            let relays = try await fetchDirectives(kind: .relayRun, status: .running)
            #expect(relays.count == 1)
            #expect(relays.first?.targets == ["VEGA"])
            #expect(relays.first?.sourceRelayCode == nil)   // print-sourced
            await clock.advance(by: .seconds(5))            // second tick
            #expect(try await fetchDirectives(kind: .relayRun, status: .running).count == 1)  // no double-launch
            await engine.stop()
        }
    }

    @Test func idleWhenNoValueOrNoCarrier() async throws {
        // No unmeshed value → .idle, zero directives created.
    }
}
```

- [ ] **Step 2: Run to verify it fails.** → FAIL.
- [ ] **Step 3: Implement** the greedy pass (grow-only for now): read `WorldView`; compute reserved device sets from running directives (04 rules); if a `heaven_vessel` carrier is free and `GrowRanking.rank` yields a top candidate whose `firstHop`'s chain the carrier can service, build a `Goal` + a legible rationale (a graph fact — "meshing VEGA — 3,200 units, 1 hop"), and `database.write` the `relayRun` row via the launcher shape. Otherwise `.idle`. **Reserve in-tick** so one pass can't double-allocate the carrier. Confirm-read is Task 18.
- [ ] **Step 4: Run to verify it passes.** → PASS.
- [ ] **Step 5: Commit.** `feat(brain): brain launches Relay Run for the top grow candidate`.

### Task 17: Brain drives `retry`/`cancel` on a stalled Relay Run

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift` (add the stall-response layer)
- Test: `app/Modules/DirectiveEngine/Tests/BrainStallResponseTests.swift`

**Interfaces:**
- Consumes: `DirectiveResolutionClient` (`@Dependency(\.directiveResolution)`, `DirectiveResolutionClient.swift:25` — `retry`/`cancel` only), `DirectiveAttentionReason.brainDisposition` (Task 1), the `DirectiveLogEntry` timeline (for the timeline-derived retry budget).
- Produces: brain behaviour — a `relayRun` in `.needsAttention` with a `.retry` reason gets a bounded auto-`retry` (budget = count of prior retry→re-stall cycles in the log), then escalates; an `.escalate` reason is left surfaced (no auto-action); the why-view marks it escalated.

- [ ] **Step 1: Write the failing tests** — (a) a `relayActivationFailed` stall (disposition `.retry`) is auto-retried once then, after N re-stalls, left escalated; (b) a `noPrinterAtSite`-class `.escalate` reason is never auto-retried; (c) neither path ever calls `skipTarget`/`pause`/`resume` (assert via an `unimplemented` resolution client for those verbs — a loud failure if touched).

```swift
@Suite struct BrainStallResponseTests {
    @Test func retryDispositionAutoRetriesThenEscalates() async throws {
        // Stub directiveResolution.retry to record calls; feed a directive that
        // re-stalls .relayActivationFailed; assert bounded retries then escalate.
    }
    @Test func escalateDispositionIsNeverAutoResolved() async throws { /* ... */ }
    @Test func brainNeverDrivesOperatorOnlyVerbs() async throws {
        // directiveResolution.skipTarget/pause/resume = unimplemented → any call fails the test loudly.
    }
}
```

- [ ] **Step 2–5:** implement, run green, commit `feat(brain): bounded timeline-derived retry / escalate for stalled Relay Runs`.

### Task 18: Confirm-fresh gate before launch (clause 4c)

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift`
- Test: `app/Modules/DirectiveEngine/Tests/BrainConfirmFreshTests.swift`

**Interfaces:**
- Consumes: `@Dependency(\.deviceRefresher)` (the shared `.high` confirm-read over `PollCoordinator`, `device-refresher-dependency` note) — reused, no new poller (clause 4a / ticket 01).
- Produces: before writing a grow directive, the brain `.high`-confirms the carrier's freshness (and, when relevant, the target's value row); a stale/failed confirm **defers** (writes nothing, `.idle`-with-reason), never guesses. Ranking still runs on best-effort `WorldView`; only the commitment is gated.

- [ ] **Step 1: Write the failing test** — a candidate whose confirm-read reveals the carrier is no longer free is deferred (no directive written), and the why-view shows "deferred — carrier unavailable on confirm".
- [ ] **Step 2–5:** implement (the confirm-read only proceeds or defers — never re-ranks, clause 3), run green, commit `feat(brain): confirm-fresh gate before launching a grow directive`.

### Task 19: Populate the why-view with ranked grow candidates

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/BrainWhyView.swift`, `BrainWhyRow.swift`
- Test: extend `BrainWhyViewTests`

**Interfaces:**
- Consumes: `[GrowCandidate]` + the top `Goal`.
- Produces: the why-view lists ranked candidates (each a graph fact: served systems, tier, hop count), the gate on the top goal (dispatching/deferred/idle/stalled), and limit pressure (governor headroom, `R` ceiling headroom, any recent 429). Every row renders system names in `.rcMono*`.

- [ ] **Step 1: Write the failing test** — a dispatch decision renders the top candidate's rationale as the gate and lists the runners-up as rows; a 429 in the recent window surfaces distinctly from self-throttling (clause 8 "limits are signals").
- [ ] **Step 2–5:** implement, run green, commit `feat(brain): why-view shows ranked grow candidates + limit pressure`.

---

## Phase E — Prune & lazy reclaim (the brain reclaims useless relays)

Deliverable at end of phase: the brain identifies durably-useless deployed relays (off the path-union), and when a grow needs a relay, sources the nearest useless one (reclaim→redeploy) in preference to printing — gated on a `.high` confirm-read. Prune never escalates.

### Task 20 (VERIFICATION): confirm `N` is retired; land `R` as a calibratable constant

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/RelayRun.swift` (or a small `BrainCeiling.swift`)
- Test: `app/Modules/DirectiveEngine/Tests/BrainCeilingTests.swift`
- Doc: memory-note confirmation

- [ ] **Step 1 (verify, don't re-decide): confirm the ceiling shape from the locked design.** Ticket 10 **retired the `N` idle-relay buffer cap** (reclaim is lazy/demand-driven) — so **build no `N` cap**, and no idle-relay pool management. Confirm this against `brain-tendmesh-worthiness.md` (§ "Reclaim is LAZY/demand-driven ... retires 06's N buffer cap"). The only ceiling is `R`, the per-type reserve floor at the print step.
- [ ] **Step 2: probe `/inventory` for the six resource-type names** (probe-api, GET-only):

```bash
replicant raw GET devices/<AUTOFACTORY-CODE>   # or the hub location inventory
```
Record the exact six type keys (metal, silicon, … — confirm real names). These are the keys the `R` rail checks.

- [ ] **Step 3: Write the failing test** — a hub inventory with one type below `relayReserveFloor` fails the rail; all-above passes.

```swift
@Suite struct BrainCeilingTests {
    @Test func rRailVetoesWhenAnyTypeBelowFloor() {
        let stock = ["metal": 500.0, "silicon": 500, "rares": 50, "volatiles": 500, "carbon": 500, "silicates": 500]
        #expect(!BrainCeiling.printPermitted(hubStock: stock))   // rares below floor
    }
    @Test func rRailPermitsWhenAllAboveFloor() {
        let stock = Dictionary(uniqueKeysWithValues: BrainCeiling.resourceTypes.map { ($0, 10_000.0) })
        #expect(BrainCeiling.printPermitted(hubStock: stock))
    }
}
```

- [ ] **Step 4: Implement** `BrainCeiling` with `static let resourceTypes: [String]` (the verified six), `static let relayReserveFloor: Double` (a single calibratable literal — pick a conservative starting value, e.g. one relay's bill `370`, and mark it `// CALIBRATE: surfaced in why-view`), and `printPermitted(hubStock:)`. Wire it as the `printStockShort` veto in `RelayRun`'s `printing` step. Surface `R` headroom in the why-view (Task 19). Note the `N`-retirement in a memory update.
- [ ] **Step 5: Commit.** `feat(brain): R reserve-floor rail (verified six types); confirm N retired`.

### Task 21: The path-union & prune partition

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/PrunePredicate.swift`
- Test: `app/Modules/DirectiveEngine/Tests/PruneTests.swift`

**Interfaces:**
- Consumes: `MeshGraph` (the same one grow uses — one computation), the live-value target set (reached **and** grow-wanted), deployed relays from `WorldView.devices` (`isActiveRelay`).
- Produces:
```swift
public struct PruneAnalysis: Equatable, Sendable {
    public let pinned: Set<String>       // relay device codes on the path-union
    public let reclaimable: [ReclaimableRelay]  // useless relays, with location for nearest-source
}
public struct ReclaimableRelay: Equatable, Sendable { public let deviceCode: String; public let system: String }
public enum PrunePredicate {
    /// A deployed relay is USELESS iff its system lies on the cheapest
    /// anchor→live-target path-union for NO live-value target (reached or
    /// grow-wanted). On the union → pinned; off it → reclaimable.
    public static func analyse(view: WorldView, graph: MeshGraph) -> PruneAnalysis
}
```

- [ ] **Step 1: Write the failing tests** — the three unified conditions, each as a case:

```swift
@Suite struct PruneTests {
    @Test func loadBearingRelayIsPinned() {
        // Live salvage at T routes through relay-system W → W pinned, not reclaimable.
    }
    @Test func brandNewHopTowardUnreachedValueIsPinnedByConstruction() {
        // A just-planted relay W on the cheapest anchor→V path (V not yet reached) → pinned.
        // This is the thrash guard: a fresh hop can never be useless.
    }
    @Test func durablyUselessRelayIsReclaimable() {
        // V's salvage depleted (sticky) → V drops from targets → its relay W falls off the
        // union → reclaimable.
    }
    @Test func perpetualMineBeltRelayIsNeverPrunable() {
        // A mine belt never depletes → its target persists → its relay always pinned.
    }
}
```

- [ ] **Step 2: Run to verify it fails.** → FAIL.
- [ ] **Step 3: Implement** — build the live-value target set (salvage non-depleted + mine belts + events, reached and grow-wanted); run `graph.reach` over the **full** graph (meshed + candidate) to collect every target's cheapest-path systems; union them; map each deployed active relay to its system; `pinned` = relays whose system is in the union, `reclaimable` = the rest. **Prune reads the same `MeshGraph` grow uses** — this is the single stateless computation read inversely.
- [ ] **Step 4: Run to verify it passes.** → PASS (all four).
- [ ] **Step 5: Commit.** `feat(brain): path-union prune predicate (load-bearing / in-progress / durable-useless unified)`.

### Task 22: Reclaim-source branch in `RelayRun` (`acquire`)

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/RelayRun.swift` (the `acquire` step's reclaim branch)
- Test: extend `RelayRunTests` with a reclaim path

**Interfaces:**
- Consumes: `directive.sourceRelayCode` (non-nil ⇒ reclaim), the relay's `Device.location`, `deactivate`/`stow`/`travel`/`deploy`/`activate` verbs.
- Produces: when `sourceRelayCode != nil`, `acquire` routes into a reclaim sub-sequence: `.high`-confirm the source relay's system (evidence-before-reclaim, ticket 01), then `deactivate` → `stow` (aboard carrier) → the shared `travelling`→`emplacing`→`activating`→`confirmingRelay` tail at the plant target. No print, no `R` spend.

- [ ] **Step 1: Write the failing test** — a `relayRun` with `sourceRelayCode = "R9"` first `.high`-confirms R9's system, then dispatches `deactivate` against R9 (not `enqueue_print`).

```swift
@Test func reclaimSourceConfirmsThenDeactivates() {
    let run = RelayRun()
    let directive = Directive.relayRunFixture(vessel: "V1", target: "VEGA",
                                              step: RelayRun.Step.acquire, sourceRelayCode: "R9")
    let world = WorldSnapshot.fixture(devices: [.relay("R9", location: "DEAD-1-L4", relaying: true),
                                                .vessel("V1", location: "SOL-3")], now: Date())
    // First action must be the confirm-read of R9's system, then a deactivate dispatch.
    // ...assert .refreshDevices([R9]) then, once fresh, .dispatch(.simple("deactivate"), deviceCode: "R9", ...)
}
```
> Confirm `deactivate` is the correct verb (SalvageRun uses `deploy`/`activate`; the reverse for reclaim is `deactivate`→`stow`). Verify against the device command taxonomy (`device-command-taxonomy` note) / a probe. `decommission` is NOT the path (it destroys for the blueprint, no refund — ticket 10).

- [ ] **Step 2–5:** implement, run green, commit `feat(brain): Relay Run reclaim-source branch (deactivate→stow→redeploy)`.

### Task 23: Brain prefers reclaim over print when sourcing a grow

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift`
- Test: `app/Modules/DirectiveEngine/Tests/BrainReclaimSourcingTests.swift`

**Interfaces:**
- Consumes: `PrunePredicate.analyse` (Task 21), the build-time reclaim distance cutoff.
- Produces: when the brain decides to launch a grow, it checks for the **nearest reclaimable relay within the cutoff**; if found, it launches the `relayRun` with `sourceRelayCode` set to that relay (reclaim→redeploy); else `sourceRelayCode = nil` (print). This *is* 06's "prefer redeploy over print," realised as demand-time sourcing (no `N` pool).

- [ ] **Step 1: Write the failing test — END-TO-END.** Seed a world with a growable target **and** a reclaimable relay near the plant site; run a brain tick; assert the launched `relayRun` has `sourceRelayCode` set to the reclaimable relay (not nil). A second scenario with no reclaimable relay in range launches with `sourceRelayCode == nil`.

```swift
@Suite struct BrainReclaimSourcingTests {
    @Test func nearestReclaimableRelayIsPreferredOverPrint() async throws {
        // ... seed growable VEGA + reclaimable R9 within cutoff; tick; assert sourceRelayCode == "R9"
    }
    @Test func printFallbackWhenNoReclaimableInRange() async throws {
        // ... reclaimable R9 far beyond cutoff → sourceRelayCode == nil
    }
}
```

- [ ] **Step 2–5:** implement (nearest-useless within cutoff; the confirm-before-reclaim is Task 22's executor-side `.high` read — the brain only *selects* the source), run green, commit `feat(brain): prefer nearest reclaimable relay over printing when sourcing grow`.

### Task 24: Prune never escalates; reclaimed-away churn is adaptation

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/BrainWhyView.swift` (prune facts in the why-view)
- Test: extend `BrainWhyViewTests`

**Interfaces:**
- Produces: the why-view shows reclaim as a graph fact ("reclaiming R9→VEGA — R9 dark since depletion, VEGA holds a Rich belt"); a useless relay left in place is **surfaced-calm, never escalated** (prune has no stall path). Confirms clause 6.

- [ ] **Step 1: Write the failing test** — a reclaim decision renders a non-escalated fact; an unreclaimed useless relay is idle-calm, not a stall.
- [ ] **Step 2–5:** implement, run green, commit `feat(brain): prune surfaced-calm in why-view (never escalates)`.

---

## Phase F — Robustness closure & end-to-end verification

Deliverable at end of phase: the eight-clause robustness bar is answered with **evidence** (real end-to-end tests through the dispatch-to-rails seam under `TestClock`), and the capability is signed off.

### Task 25: End-to-end grow lifecycle through the real seam (clause 5)

**Files:**
- Test: `app/Modules/DirectiveEngine/Tests/BrainGrowLifecycleE2ETests.swift`

**Interfaces:**
- Consumes: the whole stack — `DirectiveEngineCore` (real supervisor + brain loop + per-directive executor), faked below the `CommandGovernor`/`CommandClient` seam (scripted command outcomes + world mutations), `TestClock`.
- Produces: a scripted run proving: brain launches Relay Run → executor prints → stows → travels → emplaces → activates → the world reflects `statusBase == "relaying"` → the target system enters `meshSystems` → the brain, next tick, no longer ranks that target and goes idle (or moves to the next). This is the salvage lesson made a gate (`SalvageTargetPlanner` was unit-green with zero callers) — a pure-unit ranker test does **not** satisfy the bar.

- [ ] **Step 1: Write the failing end-to-end test** driving the full lifecycle with a scripted command seam (accept each dispatch, mutate the faked world to reflect the effect, advance the clock). Assert the mesh grows and the brain converges to idle.
- [ ] **Step 2: Run → FAIL/iterate** until the lifecycle passes.
- [ ] **Step 3–5:** stabilise, run green, commit `test(brain): end-to-end grow lifecycle through the real dispatch seam`.

### Task 26: Safe-degradation & bounded-blast-radius tests (clauses 6, 7)

**Files:**
- Test: `app/Modules/DirectiveEngine/Tests/BrainDegradationTests.swift`

**Interfaces:**
- Produces evidence for: (6) transient → defer with backoff (no thrash, no budget burn — a deferred tick writes nothing); unknown → left alone (`isFullyScanned(nil) == false` analog: a system with no value data yields no target); persistent → escalate; **idle surfaced-not-escalated vs stall surfaced-and-escalated** are distinguishable. (7) worst case of any single decision = a wasted trip or an operator-resolvable stall — reclaim never strands live value (re-assert via `PruneTests`' load-bearing case), grow spend bounded by the `R` rail, all writes additive.

- [ ] **Step 1: Write the failing tests** — (a) a persistently `R`-blocked print idles, never thrashes or burns budget; (b) a reclaim is never proposed for a load-bearing relay even under stale `WorldView` (the `.high` confirm is the guard); (c) idle and stall render distinctly in the why-view.
- [ ] **Step 2–5:** implement/verify, run green, commit `test(brain): safe degradation + bounded blast radius evidence`.

### Task 27: The Robustness section + full suite green

**Files:**
- Doc: append a **Robustness** section to this plan / the capability's design record mapping each of the 8 clauses to the test(s) that prove it.
- Modify: `app/.claude/memory/brain-tendmesh-worthiness.md` (or a new `brain-tendmesh-build.md`) — record what shipped, any deviations, and the two verified inputs (belt-class mapping, `R` literal + `N` retirement).

- [ ] **Step 1: Run the entire DirectiveEngine + GameModels + DirectivesFeature suites via the event stream.** Confirm zero failures and no crashed targets (`swift-test-event-stream` skill; watch the multi-target truncation trap).
- [ ] **Step 2: `cd app/Modules && swift build --build-tests && ./scripts/link-index-store.sh`**, then LSP-verify no unresolved references / no orphaned symbols (the `SalvageTargetPlanner`-zero-callers lesson: confirm `Brain` is actually reached from `DirectiveEngineCore`, `RelayRun` from `MissionRegistry`).
- [ ] **Step 3: Write the Robustness mapping** (one row per clause → evidence).
- [ ] **Step 4: Commit** the docs + any final fixes. `docs(brain): tendMesh grow+prune robustness section + build record`.

---

## Robustness — how tendMesh clears the eight-clause bar (evidence map)

| Clause | How it's cleared | Proven by |
| --- | --- | --- |
| 1 Selector, not enactor | Brain only launches (`Directive.insert`), retires (`.cancelled`), and drives `DirectiveResolutionClient.{retry,cancel}`; every command flows executor → `CommandGovernor`. `skipTarget`/`pause`/`resume` never called. | Task 17 (`brainNeverDrivesOperatorOnlyVerbs`), Task 25 (all commands via the seam) |
| 2 Stateless between ticks | A tick is a pure function of `(WorldView, running rows)`; the path-union is recomputed each tick; no lease/cache. `sourceRelayCode` is a plan hint on the row, not brain memory. | Tasks 4, 16, 21 |
| 3 Pure selection; API vetoes | Ranking is pure over `WorldView`; the `.high` confirm and the `R` rail only proceed/defer/veto — never re-rank. | Tasks 18, 20 |
| 4 Snapshot fidelity | (a) rides the SSE drain + `deviceRefresher`, no new poller; (b) sticky `depleted`/mesh; (c) confirm-fresh before every plant/reclaim. | Tasks 2, 18, 22 |
| 5 Determinism / e2e | Exercised under `TestClock` end-to-end through the real dispatch-to-rails seam; a pure ranker test alone is explicitly insufficient. | Task 25 |
| 6 Safe degradation | No value/no carrier → idle (surfaced-calm); un-completable grow → stall (escalated); prune never escalates; idle vs stall distinguishable in the why-view. | Tasks 5, 24, 26 |
| 7 Bounded blast radius | Reclaim load-bearing-safe by the path-union predicate; grow spend bounded by the `R` rail; all writes additive. | Tasks 20, 21, 26 |
| 8 Live why-view | Derived surface (no new table): ranked candidates as graph facts, the top-goal gate, limit pressure incl. a distinct recent-429. | Tasks 5, 19 |

---

## Self-Review (author's check against the locked design)

**Spec coverage.** Structural pivot (tendMesh sole authority) → this plan only *adds* the Relay Run + brain; relay-emplacement removal from SalvageRun is explicitly a **different** build session (noted, not done here). Grow pathfinding + the five-field lexicographic key → Tasks 7–12. Tier ordering `Event ▸ Rich ▸ Moderate ▸ salvage ▸ Sparse` → `ValueTier` raw order (Task 10). Prune as the same computation inverted (load-bearing / in-progress / durable-useless unified) → Task 21. Lazy demand-driven reclaim, prefer-redeploy-over-print → Tasks 22–23. No `N` cap, `R` rail only → Task 20. Confirm-before-reclaim `.high` → Task 22. No `critical` flag (disjoint device sets) → the greedy pass launches tendMesh without cross-goal promotion (Task 16). Robustness section → present. The two flagged inputs are verification tasks (9, 20), not re-decisions.

**Placeholder scan.** The genuinely novel pure logic (WorldView read, grid adjacency, Dijkstra, value catalog, grow key, prune predicate, BeltClass) carries complete implementations and concrete assertions. Executor tasks (14, 22) and the later brain-wiring/why-view tasks (17–19, 23–26) give the exact interfaces, the proven shape to clone (`SalvageRun.swift:579-725`) with file:line anchors, concrete first-assertion tests, and named dependencies — a few carry test *sketches* (commented scenarios) rather than fully-spelled bodies where the world-seed fixtures depend on helpers built earlier in the same plan; the executing subagent has the pattern and the exact seam. Flag for the executor: prefer filling those sketch bodies before implementing.

**Type consistency.** `Goal`/`BrainDecision` (Task 6) supersede the Task 4/5 placeholders — noted inline at both sites. `GrowCandidate` is defined in Task 12 and forward-referenced by `BrainDecision` (Task 6) and the why-view (Task 5/19) — the executor should build Task 6/12's types before wiring Task 5's why-view fully. `BeltInfo`/`BeltClass` (Tasks 8/9) are consumed by `WorldView` (Task 2, empty until Task 11) and `ValueCatalog` (Task 10). `MeshGraph.reach` returns `Chain` (Task 8), consumed by `GrowRanking` (Task 12) and `PrunePredicate` (Task 21). `sourceRelayCode` column (Task 15) is read by `RelayRun` (Task 22) and written by `Brain` (Task 23).

**Known build risks to watch (surface early, don't silently absorb):**
- *Belt data cost (Task 11)* — galaxy-wide blob decode is bounded to surveyed-unmeshed systems, but if it's still costly at the 5s tick, a `belts` index table is the documented escape hatch (not built now).
- *Dijkstra fan-out* — the grid bounds it; verify the per-tick cost against a realistic ~14k-system census before sign-off, and move the ranking off-actor (nonisolated) as the design specifies.
- *Carrier auto-stow after print (Task 14)* — the one-tick un-held window between `print.completed` and `stow` is a known build edge (05); the carrier prints where it already is and stows next step. Confirm the HEAVEN-vessel co-location assumption against the live hub.
