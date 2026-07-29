# Continuous Survey Roam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Survey Run take a single starting star and survey outward indefinitely on its own, in expanding 5-light-year shells that keep the scanned region free of permanent holes.

**Architecture:** One nullable column (`Directive.roamCentre`) turns a run continuous. When the target queue empties, `SurveyRun.preflight` returns a new `MissionAction.extendQueue`, which `DirectiveEngineCore` resolves by reading the census, asking a pure `SurveyRoamPlanner` for the next system, appending it to `targets`, and re-asking the machine against the freshly-written row. The shell is *derived* from what is still unsurveyed rather than stored, so it self-heals; `targets` doubles as the run's append-only history, which is what stops an uncompletable system from wedging it.

**Tech Stack:** Swift 6, Swift Testing, The Composable Architecture, SQLiteData/GRDB, SwiftUI (macOS 26).

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-29-continuous-survey-roam-design.md`. Read it before Task 1.
- **Shell width is 5 ly**, a baked constant on `SurveyRoamPlanner`, never a user control.
- **The stall matrix is unchanged.** Do not add, remove, or re-route any `DirectiveAttentionReason`. Every stall still halts the run.
- **Migrations are append-only.** Never edit, rename, or reorder a shipped `SchemaMigration`. A new column means a new `ALTER TABLE` migration appended to the END of `GameDatabase.manifest`.
- **Mission machines stay pure:** no I/O, no clock reads (use `world.now`), no randomness. Every effect is the returned `MissionAction`.
- **No pure logic as a static on a SwiftUI `View`** — it traps with signal 5 under `swift test`. Use a plain enum namespace.
- **Any system/location designation renders in a mono token** (`.rcMonoSmall`, `.rcMono`, …). Never inline `design: .monospaced`.
- **Never hard-code colors, spacing, or font sizes.** Use `DesignSystem.swift` tokens.
- **Logging:** `os.Logger` only, subsystem `name.pennig.replicould`, category = module name.
- **Working directory for all commands:** `app/Modules` (where `Package.swift` lives).
- **Read test results from the JSON event stream, never console text.** Every run in this plan uses `--test-product` to avoid the multi-target truncation trap (each test target is its own binary under the `swiftbuild` backend, and they all truncate the same output file).
- **`--filter` matches the Swift TYPE name, not the `@Suite("display name")`.** A typo'd filter exits 0 with "No matching test cases were run", which reads as success. Always confirm the `testStarted` count is non-zero.

### The standard test command

```bash
cd app/Modules
swift test --test-product <Product> --filter '<TypeName>' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

### The standard result check

```bash
cd app/Modules
jq -s '
  map(select(.kind=="event").payload) as $e
  | ($e | map(select(.kind=="issueRecorded" and .issue.isFailure != false).testID) | unique) as $failed
  | { started: ($e | map(select(.kind=="testStarted")) | length),
      ended:   ($e | map(select(.kind=="testEnded")) | length),
      failed:  ($failed | length),
      completed: ($e | any(.kind=="runEnded")) }
' .build/events.jsonl
jq -s -r '
  (map(select(.kind=="test").payload) | INDEX(.id)) as $t
  | map(select(.kind=="event").payload)
  | map(select(.kind=="issueRecorded" and .issue.isFailure != false))[]
  | "\($t[.testID].displayName // $t[.testID].name)  \(.issue.sourceLocation.fileID):\(.issue.sourceLocation.line)\n    \(.messages[0].text)"
' .build/events.jsonl
```

A run is good only when `completed` is `true`, `started == ended` (a mismatch means a test crashed and produced no issue at all), `started` is the number you expected, and `failed` is 0.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `DirectiveEngine/Sources/SurveyRoamPlanner.swift` | **Create.** Pure shell-band target selection. The only place the algorithm lives. | 1 |
| `DirectiveEngine/Tests/SurveyRoamPlannerTests.swift` | **Create.** Unit matrix over fixtures. | 1 |
| `DirectiveEngine/Tests/SurveyRoamGrowthTests.swift` | **Create.** The hole-bound invariant, plus a greedy control that must violate it. | 2 |
| `GameModels/Sources/Directive.swift` | **Modify.** Add `roamCentre` + its migration. | 3 |
| `GameDatabase/Sources/GameDatabase.swift` | **Modify.** Append the migration to `manifest`. | 3 |
| `GameDatabase/Tests/SchemaManifestTests.swift` | **Modify.** Append the frozen identifier. | 3 |
| `GameDatabase/Tests/Fixtures/…` | **Modify.** Regenerated golden schema. | 3 |
| `DirectiveEngine/Sources/MissionStepMachine.swift` | **Modify.** Add `MissionAction.extendQueue`. | 4 |
| `DirectiveEngine/Sources/SurveyRun.swift` | **Modify.** Preflight's roam branch. | 4 |
| `DirectiveEngine/Sources/DirectiveExecutor.swift` | **Modify.** Exhaustive-switch case for the bypassed-resolution path. | 4 |
| `DirectiveEngine/Tests/SurveyRunTests.swift` | **Modify.** `run()` gains `roamCentre`; new preflight suite. | 4 |
| `DirectiveEngine/Sources/DirectiveEngine.swift` | **Modify.** `resolveExtendQueue` + carry the fresh row into `apply`. | 5 |
| `DirectiveEngine/Tests/DirectiveEngineTests.swift` | **Modify.** Resolution tests, incl. the append-rollback regression. | 5 |
| `DirectivesFeature/Sources/NewDirectiveFeature.swift` | **Modify.** `Mode`, `roamCentre`, `effectiveCentre`, mode-aware `canLaunch`/launch. | 6 |
| `DirectivesFeature/Sources/NewDirectiveSheet.swift` | **Modify.** Mode picker + centre picker. | 6 |
| `DirectivesFeature/Tests/NewDirectiveFeatureTests.swift` | **Modify.** Mode behaviour. | 6 |
| `DirectivesFeature/Sources/DirectiveRow.swift` | **Modify.** Move `subtitle` here; roam branch. | 7 |
| `DirectivesFeature/Sources/DirectiveRowView.swift` | **Modify.** Delegate to `DirectiveRow.subtitle`. | 7 |
| `DirectivesFeature/Tests/DirectiveRowTests.swift` | **Create or modify.** `subtitle` cases. | 7 |

---

## Task 1: `SurveyRoamPlanner`

The pure algorithm. Everything else in this plan is plumbing around it.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/SurveyRoamPlanner.swift`
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRoamPlannerTests.swift`

**Interfaces:**
- Consumes: `UniverseModels.Star` (`designation`, `positionX/Y/Z`, `position`, `fullyScannedAt`), `UniverseModels.Position`.
- Produces: `SurveyRoamPlanner.shellWidthLY: Double` (== 5) and `SurveyRoamPlanner.nextTarget(centre:from:stars:attempted:shellWidth:) -> String?`. Tasks 5 and 6 call both.

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/DirectiveEngine/Tests/SurveyRoamPlannerTests.swift`:

```swift
//
//  SurveyRoamPlannerTests.swift
//  DirectiveEngineTests
//
//  The continuous run's target selection. Pure function over fixtures, the same
//  shape as SurveyRun's stall matrix and the launcher's suggestions.
//
//  Every fixture lies on the X axis and every distance below is exactly
//  representable in binary floating point, so the band-edge cases assert real
//  boundary behaviour rather than an ULP coin flip.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Survey roam planner")
struct SurveyRoamPlannerTests {
    /// A census row `x` light-years out along the X axis.
    private func star(_ designation: String, x: Double, scanned: Bool = false) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            firstVisitedAt: nil,
            fullyScannedAt: scanned ? Date(timeIntervalSince1970: 1) : nil
        )
    }

    private func pick(
        _ stars: [Star],
        vesselX: Double,
        centreX: Double = 0,
        attempted: Set<String> = []
    ) -> String? {
        SurveyRoamPlanner.nextTarget(
            centre: Position(x: centreX, y: 0, z: 0),
            from: Position(x: vesselX, y: 0, z: 0),
            stars: stars,
            attempted: attempted
        )
    }

    /// The test that distinguishes this design from greedy nearest-neighbour at
    /// all: a candidate sitting right next to the vessel is passed over because
    /// it is outside the band. Without this the planner could be a plain
    /// nearest-neighbour and every other test here would still pass.
    @Test func passesOverANearerCandidateOutsideTheBand() {
        let stars = [star("INNER", x: 1), star("EDGE", x: 5.5), star("FAR", x: 20)]
        // inner = 1, band = [0, 6]. FAR is 0 ly from the vessel but out of band.
        #expect(pick(stars, vesselX: 20) == "EDGE")
    }

    /// The band slides with the innermost remaining candidate rather than
    /// sitting on a fixed grid of annuli around the centre.
    @Test func slidesTheBandOntoTheInnermostCandidate() {
        let stars = [star("A", x: 10), star("B", x: 14), star("C", x: 20)]
        // inner = 10, band = [10, 15]. C is nearest the vessel but out of band.
        #expect(pick(stars, vesselX: 100) == "B")
    }

    @Test func includesACandidateExactlyOneBandWidthOut() {
        let stars = [star("INNER", x: 3), star("EDGE", x: 8)]
        // inner = 3, band top = 8 exactly. sqrt(9) == 3 and 8*8 == 64 are both
        // exact, so this is a true boundary assertion.
        #expect(pick(stars, vesselX: 1000) == "EDGE")
    }

    @Test func excludesACandidateJustBeyondTheBand() {
        let stars = [star("INNER", x: 3), star("EDGE", x: 8.001)]
        #expect(pick(stars, vesselX: 1000) == "INNER")
    }

    /// The centre is a geometric origin, not the vessel's position, so an
    /// unsurveyed centre is surveyed first — at zero travel.
    @Test func treatsTheCentreItselfAsACandidate() {
        let stars = [star("HOME", x: 0), star("A", x: 2)]
        #expect(pick(stars, vesselX: 0) == "HOME")
    }

    @Test func excludesFullyScannedSystems() {
        let stars = [star("DONE", x: 1, scanned: true), star("TODO", x: 2)]
        #expect(pick(stars, vesselX: 0) == "TODO")
    }

    /// The exclusion that stops an uncompletable system pinning the band and
    /// stops the user's Skip being undone on the next extend.
    @Test func excludesAlreadyAttemptedSystems() {
        let stars = [star("TRIED", x: 1), star("NEXT", x: 2)]
        #expect(pick(stars, vesselX: 0, attempted: ["TRIED"]) == "NEXT")
    }

    @Test func returnsNilWhenNothingIsLeftToSurvey() {
        let stars = [star("DONE", x: 1, scanned: true), star("TRIED", x: 2)]
        #expect(pick(stars, vesselX: 0, attempted: ["TRIED"]) == nil)
    }

    @Test func returnsNilForAnEmptyCensus() {
        #expect(pick([], vesselX: 0) == nil)
    }

    /// A total order is what makes the plan reproducible: two equidistant
    /// candidates must not swap between evaluations.
    @Test func breaksTiesOnDesignation() {
        let stars = [star("ZULU", x: 3), star("ALPHA", x: -3)]
        #expect(pick(stars, vesselX: 0) == "ALPHA")
    }

    @Test func measuresTheBandFromTheCentreNotTheVessel() {
        let stars = [star("NEARCENTRE", x: 2), star("NEARVESSEL", x: 40)]
        // Centre at 0: inner = 2, band = [0, 7]. The vessel sitting on top of
        // NEARVESSEL cannot pull it into the band.
        #expect(pick(stars, vesselX: 40, centreX: 0) == "NEARCENTRE")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules
swift test --test-product DirectiveEngineTests --filter 'SurveyRoamPlannerTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: a **compile** failure — `cannot find 'SurveyRoamPlanner' in scope`. The event stream will be absent or empty because nothing ran; that is the correct "fails" signal for a type that does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `app/Modules/DirectiveEngine/Sources/SurveyRoamPlanner.swift`:

```swift
//
//  SurveyRoamPlanner.swift
//  Replicould — DirectiveEngine
//
//  Where a continuous Survey Run goes next: the cheapest hop inside an
//  expanding band of unsurveyed systems around a fixed centre.
//
//  Why not simply the nearest unsurveyed system? Because that is greedy
//  nearest-neighbour, and measured over the real census it never recovers from
//  its first skip. From ATIANFU it passed a system 3.9 ly out, found a cheaper
//  hop, and in 120 systems and 483 ly of travel never came back — leaving gaps
//  22 ly deep behind the frontier. Banding costs ~35% more travel and holds the
//  worst gap to one band width, which is affordable because travel is not the
//  bottleneck: the server's own travel ETAs run 1–3 minutes against a survey
//  cycle of tens of minutes.
//
//  Pure by contract — no I/O, no clock, no randomness — so it tests as plain
//  function calls over fixtures. It must NOT be a static on a SwiftUI `View`:
//  pure logic in that position traps with signal 5 under `swift test` (see the
//  swiftui-view-statics-trap-in-tests note).
//

import Foundation
import UniverseModels

public enum SurveyRoamPlanner {
    /// The band thickness — the one dial between travel and density. Wider
    /// approaches greedy nearest-neighbour (cheapest, leaves permanent holes
    /// 22 ly deep); narrower approaches strict radial order (no holes, 3x the
    /// travel). Measured at 5 ly: +35% travel over greedy, buying a filled
    /// radius of 16.4 ly against greedy's 3.9.
    public static let shellWidthLY: Double = 5

    /// The next system a continuous run should survey, or nil when nothing is
    /// left.
    ///
    /// Two distances, deliberately measured from two different points:
    /// membership of the band is measured from `centre` (that is what bounds the
    /// holes), and the pick within the band is measured from `vessel` (that is
    /// what keeps the hop cheap). Collapsing them onto one point gives either
    /// greedy nearest-neighbour or strict radial order — the two things the band
    /// exists to sit between.
    ///
    /// The band SLIDES: its outer edge is `inner + shellWidth`, anchored on the
    /// innermost remaining candidate rather than on a fixed grid of annuli. A
    /// grid was measured within ~8% on travel at the same hole bound, and lost
    /// on specification — a candidate landing exactly on a grid line opens a
    /// double-width band, whereas a sliding band has no boundary case and makes
    /// the guarantee exactly true: nothing is ever left behind that is more than
    /// `shellWidth` closer to the centre than the system just picked.
    ///
    /// `attempted` must carry every system this run has already aimed at, not
    /// just the ones it finished. Two failures follow from omitting it, and both
    /// occur in practice: `StarSystem.isFullyScanned` requires
    /// `planetsTotal > 0`, so a planetless system can never be marked complete
    /// and would pin `inner` at its own radius forever; and the user's Skip
    /// would be undone, because the next extend would re-pick the system just
    /// skipped. `Directive.targets` is exactly that set.
    public static func nextTarget(
        centre: Position,
        from vessel: Position,
        stars: [Star],
        attempted: Set<String>,
        shellWidth: Double = shellWidthLY
    ) -> String? {
        // Pass 1: how far out the innermost unsurveyed system sits. The band is
        // anchored on it, so it has to be known before membership can be judged
        // — which is also why a bounding-box pre-filter cannot help here.
        var innerSquared = Double.infinity
        for star in stars where isCandidate(star, attempted) {
            innerSquared = min(innerSquared, squaredDistance(star, centre))
        }
        guard innerSquared.isFinite else { return nil }

        // The only `sqrt` in the function: the band's edge is a SUM of
        // distances, which squared distances cannot express.
        let shellTop = innerSquared.squareRoot() + shellWidth
        let shellTopSquared = shellTop * shellTop

        // Pass 2: inside the band, the cheapest hop from where the vessel is.
        var best: (distanceSquared: Double, designation: String)?
        for star in stars where isCandidate(star, attempted) {
            guard squaredDistance(star, centre) <= shellTopSquared else { continue }
            let candidate = (
                distanceSquared: squaredDistance(star, vessel),
                designation: star.designation
            )
            if let best, !isBetter(candidate, than: best) { continue }
            best = candidate
        }
        return best?.designation
    }

    /// Still worth surveying, and not something this run has already tried.
    private static func isCandidate(_ star: Star, _ attempted: Set<String>) -> Bool {
        star.fullyScannedAt == nil && !attempted.contains(star.designation)
    }

    private static func squaredDistance(_ star: Star, _ point: Position) -> Double {
        let dx = star.positionX - point.x
        let dy = star.positionY - point.y
        let dz = star.positionZ - point.z
        return dx * dx + dy * dy + dz * dz
    }

    /// Nearer wins; equal distance breaks on designation so the order is total
    /// and the plan is reproducible across evaluations.
    private static func isBetter(
        _ lhs: (distanceSquared: Double, designation: String),
        than rhs: (distanceSquared: Double, designation: String)
    ) -> Bool {
        lhs.distanceSquared == rhs.distanceSquared
            ? lhs.designation < rhs.designation
            : lhs.distanceSquared < rhs.distanceSquared
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd app/Modules
swift test --test-product DirectiveEngineTests --filter 'SurveyRoamPlannerTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Then run the standard result check. Expected: `started: 11`, `ended: 11`, `failed: 0`, `completed: true`.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/SurveyRoamPlanner.swift \
        app/Modules/DirectiveEngine/Tests/SurveyRoamPlannerTests.swift
git commit -m "Add the continuous survey roam planner

Greedy nearest-neighbour is the cheapest visit order and it leaves
permanent holes: measured over the real census from ATIANFU it passed a
system 3.9 ly out, took a cheaper hop, and in 120 systems never came
back, leaving gaps 22 ly deep. This picks the cheapest hop INSIDE a
5 ly band around a fixed centre instead, which holds the worst gap to
one band width for ~35% more travel.

Membership is measured from the centre and the pick from the vessel;
collapsing them onto one point degenerates to greedy or to strict radial
order, the two things the band sits between. The band slides with the
innermost remaining candidate rather than sitting on a grid of annuli,
which removes the boundary case where a candidate on a grid line opens a
double-width band."
```

---

## Task 2: The hole-bound invariant

Task 1's unit tests pin individual decisions. This pins the *property* the whole design is justified by, and proves the test is not vacuous by running a greedy control that must fail it.

**Files:**
- Create: `app/Modules/DirectiveEngine/Tests/SurveyRoamGrowthTests.swift`

**Interfaces:**
- Consumes: `SurveyRoamPlanner.nextTarget(centre:from:stars:attempted:shellWidth:)`, `SurveyRoamPlanner.shellWidthLY` (Task 1).
- Produces: nothing. Test-only.

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/SurveyRoamGrowthTests.swift`:

```swift
//
//  SurveyRoamGrowthTests.swift
//  DirectiveEngineTests
//
//  The property the roam planner exists for, rather than any single decision it
//  makes: surveying always stays within one band width of complete.
//
//  Stated precisely — at every moment, (the radius of the farthest system
//  surveyed) minus (the radius of the nearest system NOT surveyed) is at most
//  one band width. That is the bound greedy nearest-neighbour violates by 4x on
//  real data, and it is the entire justification for spending +35% travel.
//
//  Note what is deliberately NOT asserted: that the filled radius rises
//  monotonically. It does, but only trivially — the filled radius is a minimum
//  over the unsurveyed set, and removing elements from a set can only raise its
//  minimum. Asserting it would pass for any planner whatsoever, including one
//  that picks at random.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Survey roam growth")
struct SurveyRoamGrowthTests {
    private func star(_ designation: String, x: Double, y: Double, z: Double) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: y, positionZ: z, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            firstVisitedAt: nil, fullyScannedAt: nil
        )
    }

    /// A deterministic pseudo-random star field in a cube of side 60 centred on
    /// the origin. A fixed LCG rather than `SystemRandomNumberGenerator`: a
    /// property test that fails must fail identically on the next run, or the
    /// failure cannot be investigated.
    private func fixtureCensus(count: Int) -> [Star] {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func nextUnit() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<count).map { index in
            star(
                "S\(index)",
                x: nextUnit() * 60 - 30,
                y: nextUnit() * 60 - 30,
                z: nextUnit() * 60 - 30
            )
        }
    }

    private let centre = Position(x: 0, y: 0, z: 0)

    /// Run `steps` survey cycles and return the worst gap that ever opened
    /// behind the frontier.
    ///
    /// `pick` is the strategy under test, so the banded planner and a greedy
    /// control run through byte-identical simulation machinery — otherwise a
    /// difference in outcome could come from the harness rather than the
    /// strategy.
    private func worstHole(
        stars initial: [Star],
        steps: Int,
        pick: (_ vessel: Position, _ stars: [Star], _ attempted: Set<String>) -> String?
    ) -> Double {
        var stars = initial
        var attempted: Set<String> = []
        var vessel = centre
        var frontier = 0.0
        var worst = 0.0

        for _ in 0..<steps {
            guard let target = pick(vessel, stars, attempted),
                  let index = stars.firstIndex(where: { $0.designation == target })
            else { break }

            // Surveying it stamps the census row AND records the attempt, which
            // is exactly what the production path does (`SystemDetail.persist`
            // stamps `fullyScannedAt`; the engine appends to `targets`).
            stars[index].fullyScannedAt = Date(timeIntervalSince1970: 1)
            attempted.insert(target)
            vessel = stars[index].position
            frontier = max(frontier, stars[index].position.distance(to: centre))

            let filled = stars
                .filter { $0.fullyScannedAt == nil }
                .map { $0.position.distance(to: centre) }
                .min()
            guard let filled else { break }
            worst = max(worst, frontier - filled)
        }
        return worst
    }

    private func bandedPick(
        _ vessel: Position, _ stars: [Star], _ attempted: Set<String>
    ) -> String? {
        SurveyRoamPlanner.nextTarget(
            centre: centre, from: vessel, stars: stars, attempted: attempted
        )
    }

    /// Greedy nearest-neighbour: the same simulation with the band removed.
    private func greedyPick(
        _ vessel: Position, _ stars: [Star], _ attempted: Set<String>
    ) -> String? {
        stars
            .filter { $0.fullyScannedAt == nil && !attempted.contains($0.designation) }
            .min {
                let a = $0.position.distance(to: vessel), b = $1.position.distance(to: vessel)
                return a == b ? $0.designation < $1.designation : a < b
            }?
            .designation
    }

    @Test func neverLeavesAGapDeeperThanOneBandWidth() {
        let hole = worstHole(stars: fixtureCensus(count: 300), steps: 120, pick: bandedPick)
        // A hair of slack for the sqrt round-trip in the band-edge comparison.
        #expect(hole <= SurveyRoamPlanner.shellWidthLY + 1e-9)
    }

    /// The control. Without it `neverLeavesAGapDeeperThanOneBandWidth` could
    /// pass on a planner that never moves, or on a fixture too sparse for any
    /// gap to open — neither of which would be measuring anything.
    @Test func greedyNearestNeighbourViolatesTheBoundOnTheSameFixture() {
        let hole = worstHole(stars: fixtureCensus(count: 300), steps: 120, pick: greedyPick)
        #expect(hole > SurveyRoamPlanner.shellWidthLY)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

At this point Task 1 is already implemented, so these should **pass** on the first run rather than fail — the property is a consequence of Task 1, not new behaviour. Run them and confirm:

```bash
cd app/Modules
swift test --test-product DirectiveEngineTests --filter 'SurveyRoamGrowthTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: `started: 2`, `ended: 2`, `failed: 0`.

**If `neverLeavesAGapDeeperThanOneBandWidth` fails,** the planner is wrong — that is the invariant it is built to hold. Fix `SurveyRoamPlanner`, not the test.

**If `greedyNearestNeighbourViolatesTheBoundOnTheSameFixture` fails,** the fixture is too easy for the control to trip over: raise `count` to 600 and `steps` to 240 and re-run. Do not weaken the assertion — a control that cannot fail is not a control.

- [ ] **Step 3: Commit**

```bash
git add app/Modules/DirectiveEngine/Tests/SurveyRoamGrowthTests.swift
git commit -m "Pin the roam planner's hole bound with a greedy control

The +35% travel the band costs is justified by exactly one property: the
frontier never runs more than one band width ahead of complete coverage.
That deserves a test rather than a one-off simulation.

Paired with a greedy nearest-neighbour control through byte-identical
simulation machinery, which must VIOLATE the bound on the same fixture —
otherwise the invariant test could be passing vacuously on a fixture too
sparse for any gap to open. Deliberately does not assert that the filled
radius rises monotonically: it does, but only because a minimum over a
shrinking set can only rise, so that assertion would hold for a planner
picking at random."
```

---

## Task 3: The `roamCentre` column

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift`
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift`
- Modify: `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift`
- Modify: `app/Modules/GameDatabase/Tests/Fixtures/` (regenerated golden schema)

**Interfaces:**
- Produces: `Directive.roamCentre: String?` (defaulted to `nil` in `init`) and `Directive.addRoamCentre: SchemaMigration`. Tasks 4–7 all read `roamCentre`.

- [ ] **Step 1: Add the property**

In `app/Modules/GameModels/Sources/Directive.swift`, immediately after the `controllerCode` property and its doc comment, add:

```swift
    /// The centre of a CONTINUOUS run, or nil for a fixed queue.
    ///
    /// Non-nil is the whole switch: `SurveyRun.preflight` extends the queue
    /// instead of finishing when this is set, so the run surveys outward
    /// indefinitely in bands around this system (see `SurveyRoamPlanner`).
    ///
    /// A designation rather than a coordinate, because the census row is the
    /// authority on where a system is and copying its position here would let
    /// the two drift.
    public var roamCentre: String?
```

- [ ] **Step 2: Add the initializer parameter**

In the same file, in `Directive.init`, add the parameter directly after `controllerCode` **with a default**, and the matching assignment after `self.controllerCode`:

```swift
        controllerCode: String? = nil,
        roamCentre: String? = nil,
```

```swift
        self.controllerCode = controllerCode
        self.roamCentre = roamCentre
```

The default is what keeps this source-compatible: every existing call site labels its arguments, so a defaulted parameter inserted mid-list needs no call-site changes.

- [ ] **Step 3: Add the migration**

In the same file, in the `extension Directive` that holds `createDirectives` and `addControllerCode`, append after `addControllerCode`:

```swift
    /// A separate migration, not an edit to either above: both have shipped and
    /// are already recorded in real databases, so editing one means it silently
    /// never runs again.
    public static let addRoamCentre = SchemaMigration("Add 'roamCentre' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "roamCentre" TEXT
            """
        )
        .execute(db)
    }
```

- [ ] **Step 4: Append to the manifest**

In `app/Modules/GameDatabase/Sources/GameDatabase.swift`, append to the **very end** of the `manifest` array, after `Star.backfillFullyScannedAt,`:

```swift
        Directive.addRoamCentre,
```

Append-only means the end of the list, not next to the other `directives` migrations.

- [ ] **Step 5: Append to the frozen identifier list**

In `app/Modules/GameDatabase/Tests/SchemaManifestTests.swift`, append to the end of `frozenIdentifiers`, after `"Backfill 'fullyScannedAt' from systemDetails",`:

```swift
        "Add 'roamCentre' to 'directives'",
```

- [ ] **Step 6: Run the schema tests to see the golden snapshot fail**

```bash
cd app/Modules
swift test --test-product GameDatabaseTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: `SchemaManifestTests` passes (both lists now agree) and `GoldenSchemaTests` FAILS, because the `directives` table gained a column. That failure is the point — it proves the migration actually ran.

- [ ] **Step 7: Regenerate the golden snapshot and re-run**

```bash
cd app/Modules
RC_REGENERATE_SCHEMA_FIXTURE=1 swift test --test-product GameDatabaseTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
swift test --test-product GameDatabaseTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Then run the standard result check on the second run. Expected: `failed: 0`, `completed: true`.

Inspect the regenerated fixture with `git diff` before committing. The **only** change may be the added `"roamCentre" TEXT` column on `directives`. Anything else means an unintended schema change rode along — stop and investigate rather than committing it.

- [ ] **Step 8: Confirm the whole package still builds**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -5
```

Expected: `Build complete!`. This is what catches any `Directive.init` call site the default did not cover.

- [ ] **Step 9: Commit**

```bash
git add app/Modules/GameModels/Sources/Directive.swift \
        app/Modules/GameDatabase/Sources/GameDatabase.swift \
        app/Modules/GameDatabase/Tests/SchemaManifestTests.swift \
        app/Modules/GameDatabase/Tests/Fixtures
git commit -m "Add 'roamCentre' to directives

One nullable column is the whole switch between a fixed queue and a
continuous run. A designation rather than a coordinate, so the census row
stays the single authority on where a system is.

Appended as its own migration at the end of the manifest — both existing
'directives' migrations have shipped, so editing either would mean it
silently never runs again on databases that already recorded it. The
initializer parameter is defaulted, which is what keeps every existing
call site compiling."
```

---

## Task 4: `MissionAction.extendQueue` and preflight's roam branch

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/SurveyRun.swift:225-234` (the `preflight` guard)
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift`
- Test: `app/Modules/DirectiveEngine/Tests/SurveyRunTests.swift`

**Interfaces:**
- Consumes: `Directive.roamCentre` (Task 3).
- Produces: `MissionAction.extendQueue(centre: String)`. Task 5 resolves it.

- [ ] **Step 1: Add the action case**

In `app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift`, add to `MissionAction` immediately before `case advanceTarget`:

```swift
    /// The queue is empty and this is a CONTINUOUS run: pick the next system
    /// from the census, append it to `targets`, and carry on. The engine owns
    /// the read and the write; the machine sees the extended queue when it is
    /// re-asked.
    ///
    /// Resolved by `DirectiveEngineCore` rather than the executor, like
    /// `.refreshDevices`, because it needs I/O plus a second call into the
    /// machine.
    ///
    /// It differs from the refresh cases in one way that matters: they cannot
    /// change the directive ROW, so they re-ask with the same `Directive` value.
    /// This one appends to `targets`, so its re-asked action must be applied to
    /// the freshly-read row — applying it to the pre-write value rolls the
    /// append straight back (see `DirectiveEngineCore.Resolution`).
    ///
    /// Bounded to one round: a second `.extendQueue` from the re-ask means the
    /// planner found nothing left, which resolves to `.done`.
    case extendQueue(centre: String)
```

- [ ] **Step 2: Write the failing tests**

In `app/Modules/DirectiveEngine/Tests/SurveyRunTests.swift`, first add a `roamCentre` parameter to the shared `run(...)` helper (around line 164). Add it after `returnToOrigin` with a `nil` default, and pass it through:

```swift
private func run(
    step: String = SurveyRun.Step.preflight,
    targets: [String] = ["TAU"],
    targetIndex: Int = 0,
    controllerCode: String? = nil,
    returnToOrigin: Bool = false,
    roamCentre: String? = nil,
    origin: String? = "SOL",
    stepStartedAt: Date = Date(timeIntervalSince1970: 900)
) -> Directive {
    Directive(
        id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
        controllerCode: controllerCode, roamCentre: roamCentre,
        targets: targets, targetIndex: targetIndex,
        step: step, stepStartedAt: stepStartedAt, returnToOrigin: returnToOrigin,
        originDesignation: origin, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}
```

Then append this suite to the end of the file:

```swift
// MARK: - Continuous roam

@Suite("Survey Run — continuous roam")
struct SurveyRunRoamTests {
    /// An exhausted queue is not the end of a continuous run — it is the cue to
    /// extend it.
    @Test func exhaustedQueueExtendsWhenARoamCentreIsSet() {
        let action = SurveyRun().nextAction(
            directive: run(targets: ["TAU"], targetIndex: 1, roamCentre: "ATIANFU"),
            world: world(stagedFleet())
        )
        #expect(action == .extendQueue(centre: "ATIANFU"))
    }

    /// The fixed-queue regression. Without a centre an exhausted queue must
    /// still finish exactly as it does today.
    @Test func exhaustedQueueStillFinishesWithoutARoamCentre() {
        let action = SurveyRun().nextAction(
            directive: run(targets: ["TAU"], targetIndex: 1, roamCentre: nil),
            world: world(stagedFleet())
        )
        #expect(action == .done)
    }

    /// The other fixed-queue regression: the return leg is untouched.
    @Test func exhaustedQueueStillReturnsToOriginWhenAsked() {
        let action = SurveyRun().nextAction(
            directive: run(
                targets: ["TAU"], targetIndex: 1,
                returnToOrigin: true, roamCentre: nil, origin: "SOL"
            ),
            world: world(stagedFleet(vesselAt: "TAU-1"))
        )
        #expect(action == .advanceStep(nextStep: SurveyRun.Step.returning))
    }

    /// The roam branch is checked BEFORE the return leg, so a run carrying both
    /// keeps surveying rather than going home. Nothing sets both today; this
    /// pins the ordering so "roam, then come home" stays expressible later.
    @Test func roamTakesPrecedenceOverTheReturnLeg() {
        let action = SurveyRun().nextAction(
            directive: run(
                targets: ["TAU"], targetIndex: 1,
                returnToOrigin: true, roamCentre: "ATIANFU", origin: "SOL"
            ),
            world: world(stagedFleet(vesselAt: "TAU-1"))
        )
        #expect(action == .extendQueue(centre: "ATIANFU"))
    }

    /// A roam run still skips a target the census already says is done, without
    /// spending a trip on it — the existing preflight guard, unchanged.
    @Test func roamStillSkipsAnAlreadyScannedTarget() {
        let scanned = StarSystem(
            designation: "TAU", planetsTotal: 2, planetsScanned: 2,
            moonsTotal: nil, moonsScanned: nil
        )
        let action = SurveyRun().nextAction(
            directive: run(targets: ["TAU"], targetIndex: 0, roamCentre: "ATIANFU"),
            world: world(stagedFleet(), systems: ["TAU": scanned])
        )
        #expect(action == .advanceTarget)
    }
}
```

**Before running:** the `StarSystem(...)` initializer above is illustrative. Open `app/Modules/UniverseModels/Sources/` and find how existing tests in `SurveyRunTests.swift` build a fully-scanned `StarSystem` fixture (search the file for `planetsScanned`), and use that exact form. Likewise confirm `stagedFleet()`'s `vesselAt:` label by reading its definition near line 71.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd app/Modules
swift test --test-product DirectiveEngineTests --filter 'SurveyRunRoamTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: a compile failure first (`DirectiveExecutor.apply`'s switch is not exhaustive now that `MissionAction` has a new case). Fix that in Step 4, then expect `exhaustedQueueExtendsWhenARoamCentreIsSet` and `roamTakesPrecedenceOverTheReturnLeg` to FAIL while the two regressions pass.

- [ ] **Step 4: Handle the new case in the executor**

In `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift`, add to the `switch action` in `apply`, next to the `.refreshDevices` case:

```swift
        case .extendQueue:
            // The engine resolves this before it ever reaches the executor (it
            // needs a census read and a second call into the machine). Reaching
            // here means that resolution was bypassed, which is a programming
            // error rather than a world state — so say so loudly and leave the
            // row alone. The next tick re-evaluates and will say the same thing,
            // which is recoverable (the user can cancel) and visible in the log,
            // where silently returning `.done` would look like a finished run.
            logger.error("directive \(directive.id, privacy: .public): unresolved extendQueue reached the executor — leaving the row untouched")
            return true
```

- [ ] **Step 5: Add preflight's roam branch**

In `app/Modules/DirectiveEngine/Sources/SurveyRun.swift`, replace the opening guard of `preflight` (currently lines 226-234):

```swift
        guard let target = directive.currentTarget else {
            // Queue exhausted. The vessel stays put unless the run was created
            // with `returnToOrigin` — an unwanted return leg costs fuel and time.
            guard directive.returnToOrigin,
                  let origin = directive.originDesignation,
                  Self.system(of: vessel) != origin
            else { return .done }
            return .advanceStep(nextStep: Step.returning)
        }
```

with:

```swift
        guard let target = directive.currentTarget else {
            // A CONTINUOUS run never exhausts its queue — it extends it. Checked
            // before the return leg so the two stay independently expressible:
            // nothing sets both today, but "roam, then come home" should remain a
            // matter of setting both flags rather than needing new code.
            if let centre = directive.roamCentre {
                return .extendQueue(centre: centre)
            }
            // Queue exhausted. The vessel stays put unless the run was created
            // with `returnToOrigin` — an unwanted return leg costs fuel and time.
            guard directive.returnToOrigin,
                  let origin = directive.originDesignation,
                  Self.system(of: vessel) != origin
            else { return .done }
            return .advanceStep(nextStep: Step.returning)
        }
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd app/Modules
swift test --test-product DirectiveEngineTests --filter 'SurveyRunRoamTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: `started: 5`, `ended: 5`, `failed: 0`.

- [ ] **Step 7: Run the whole DirectiveEngine suite for regressions**

```bash
cd app/Modules
swift test --test-product DirectiveEngineTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Run the standard result check. Expected: `failed: 0`, `started == ended`, `completed: true`. The existing stall matrix and finishing suites must be untouched.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift \
        app/Modules/DirectiveEngine/Sources/SurveyRun.swift \
        app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift \
        app/Modules/DirectiveEngine/Tests/SurveyRunTests.swift
git commit -m "Extend the queue instead of finishing on a roam run

An exhausted queue is the end of a fixed run and the cue to extend a
continuous one, so preflight gains one branch and a new MissionAction
carries the request out to the engine.

The branch sits ahead of the return leg deliberately. Nothing sets both
returnToOrigin and roamCentre today, so the ordering is unobservable —
pinning it with a test keeps 'roam, then come home' a matter of setting
both flags rather than needing new code later.

The executor's case for .extendQueue logs loudly and leaves the row
alone: the engine always resolves this action first, so arriving here is
a programming error, and returning .done would dress it up as a finished
run."
```

---

## Task 5: `resolveExtendQueue`

The trap task. Read the "Interfaces" note twice.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift`
- Test: `app/Modules/DirectiveEngine/Tests/DirectiveEngineTests.swift`

**Interfaces:**
- Consumes: `SurveyRoamPlanner.nextTarget(centre:from:stars:attempted:shellWidth:)` (Task 1), `MissionAction.extendQueue(centre:)` (Task 4), `Directive.roamCentre` (Task 3), `UniverseModels.Star`, `UniverseModels.SiteAssay.system(of:)`.
- Produces: nothing consumed by later tasks.

**The trap:** `evaluateOnce` passes the *pre-resolution* `directive` value to `DirectiveExecutor.apply`, and every executor path builds its write as `var updated = directive`. So an action resolved *after* an append, applied to the *pre-append* value, writes `targets` back and **loses the appended target**. This is the ordinary happy path, not an edge case — the action after a successful extend is normally `.assignController`, which commits the whole row through `move()`. The fix is to carry the fresh row out of the resolver.

- [ ] **Step 1: Add the import**

In `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift`, add to the import block (keep it alphabetical):

```swift
import UniverseModels
```

- [ ] **Step 2: Write the failing tests**

Append to `app/Modules/DirectiveEngine/Tests/DirectiveEngineTests.swift`:

```swift
// MARK: - Continuous roam resolution

@Suite("DirectiveEngine roam resolution")
struct DirectiveEngineRoamTests {
    /// A census row `x` light-years out along the X axis.
    private func star(_ designation: String, x: Double, scanned: Bool = false) -> Star {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 3,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            firstVisitedAt: nil,
            fullyScannedAt: scanned ? Date(timeIntervalSince1970: 1) : nil
        )
    }

    /// A roam directive with an exhausted queue, ready to be extended.
    private func roamDirective(targets: [String] = [], targetIndex: Int = 0) -> Directive {
        Directive(
            id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
            controllerCode: nil, roamCentre: "CENTRE",
            targets: targets, targetIndex: targetIndex,
            step: SurveyRun().firstStep,
            stepStartedAt: Date(timeIntervalSince1970: 0),
            returnToOrigin: false, originDesignation: "CENTRE",
            attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func extendQueueAppendsThePlannersPick() async throws {
        let database = try GameDatabase.bootstrap()
        let directive = roamDirective()
        try await database.write { db in
            try Star.insert { self.star("CENTRE", x: 0, scanned: true) }.execute(db)
            try Star.insert { self.star("NEAR", x: 2) }.execute(db)
            try Star.insert { self.star("FAR", x: 40) }.execute(db)
            try Directive.insert { directive }.execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let core = DirectiveEngineCore(machines: [SurveyRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let row = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(row?.targets == ["NEAR"])
        }
    }

    /// The regression for the trap this task exists to avoid. The action the
    /// machine returns AFTER the append gets applied to a directive row, and if
    /// that row is the pre-append value, the append is rolled straight back —
    /// `targets` would come out `[]` and the run would extend forever without
    /// ever going anywhere.
    ///
    /// Driven through `evaluateOnce` rather than the resolver directly, because
    /// the bug lives in the hand-off between them and a resolver-level test
    /// cannot see it.
    @Test func theAppendSurvivesTheActionAppliedAfterIt() async throws {
        let database = try GameDatabase.bootstrap()
        let directive = roamDirective()
        try await database.write { db in
            try Star.insert { self.star("CENTRE", x: 0, scanned: true) }.execute(db)
            try Star.insert { self.star("NEAR", x: 2) }.execute(db)
            try Directive.insert { directive }.execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let core = DirectiveEngineCore(machines: [SurveyRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let row = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            // Whatever the machine decided next, the queue must still hold the
            // target that was just planned for it.
            #expect(row?.targets == ["NEAR"])
            #expect(row?.currentTarget == "NEAR")
        }
    }

    @Test func nothingLeftToSurveyCompletesTheRun() async throws {
        let database = try GameDatabase.bootstrap()
        let directive = roamDirective()
        try await database.write { db in
            try Star.insert { self.star("CENTRE", x: 0, scanned: true) }.execute(db)
            try Star.insert { self.star("DONE", x: 2, scanned: true) }.execute(db)
            try Directive.insert { directive }.execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let core = DirectiveEngineCore(machines: [SurveyRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let row = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(row?.status == .completed)
        }
    }

    /// A system this run has already aimed at is never offered again — the
    /// exclusion that stops an uncompletable system pinning the band and stops
    /// the user's Skip being undone.
    @Test func alreadyAttemptedSystemsAreNotOfferedAgain() async throws {
        let database = try GameDatabase.bootstrap()
        // Queue already holds NEAR and the index has moved past it: NEAR was
        // aimed at and left behind, exactly as Skip leaves it.
        let directive = roamDirective(targets: ["NEAR"], targetIndex: 1)
        try await database.write { db in
            try Star.insert { self.star("CENTRE", x: 0, scanned: true) }.execute(db)
            // Still unscanned — an uncompletable system looks exactly like this.
            try Star.insert { self.star("NEAR", x: 2) }.execute(db)
            try Star.insert { self.star("NEXT", x: 4) }.execute(db)
            try Directive.insert { directive }.execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let core = DirectiveEngineCore(machines: [SurveyRun()], tick: .seconds(5))
            await core.evaluateOnce(directiveID: "D1")

            let row = try await database.read { db in
                try Directive.where { $0.id.eq("D1") }.fetchOne(db)
            }
            #expect(row?.targets == ["NEAR", "NEXT"])
        }
    }
}
```

**Before running:** confirm the imports at the top of `DirectiveEngineTests.swift` include `UniverseModels` and `GameDatabase`; add whichever is missing. Also confirm `DirectiveEngineCore`'s initializer signature (`machines:tick:`) against `DirectiveEngine.swift:68` and how existing tests in this file construct it.

Note that these tests do **not** stage a fleet, so after the append the machine will ask for a device refresh and the run may stall — that is fine and deliberate. Every assertion here is about `targets` and `status`, never about the step reached.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd app/Modules
swift test --test-product DirectiveEngineTests --filter 'DirectiveEngineRoamTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: compile failure (`resolveExtendQueue` does not exist and `evaluateOnce`'s switch does not handle `.extendQueue`).

- [ ] **Step 4: Add the `Resolution` type and the resolver**

In `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift`, inside `actor DirectiveEngineCore`, add above `resolveRefresh`:

```swift
    /// A resolved action plus the directive row it must be applied to.
    ///
    /// Only `.extendQueue` needs the second half. `resolveRefresh` and
    /// `resolveSystemRefresh` re-ask with the SAME `Directive` value because a
    /// device read cannot change the directive row — but an extend appends to
    /// `targets`, and every executor path builds its write as
    /// `var updated = directive`. Applying a post-extend action to the
    /// pre-extend value therefore writes `targets` back and rolls the append
    /// away. That is not an edge case: the action after a successful extend is
    /// normally `.assignController`, which commits the whole row.
    private struct Resolution {
        let action: MissionAction
        let directive: Directive
    }

    /// Pick the next target for a continuous run, append it, and ask the machine
    /// again against the EXTENDED row.
    ///
    /// One census read per surveyed system — tens of minutes apart, not on the
    /// 5 s tick — so reading the whole table is affordable and the candidate
    /// filter stays in the planner, where it is unit-tested.
    ///
    /// A bounding box around the centre was considered and rejected: the band's
    /// outer edge is `inner + shellWidth`, and `inner` is only known after
    /// scanning the candidates, so bounding needs the very scan it would save.
    private func resolveExtendQueue(
        centre: String,
        directive: Directive,
        machine: any MissionStepMachine
    ) async -> Resolution {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        let vesselCode = directive.deviceCode
        let attempted = Set(directive.targets)

        let planned: String?
        do {
            planned = try await database.read { db -> String? in
                guard let centreStar = try Star
                    .where { $0.designation.eq(centre) }
                    .fetchOne(db)
                else { return nil }

                let vessel = try Device.where { $0.deviceCode.eq(vesselCode) }.fetchOne(db)
                let vesselSystem = vessel?.location.map { SiteAssay.system(of: $0) }
                let vesselStar = try vesselSystem.flatMap { designation in
                    try Star.where { $0.designation.eq(designation) }.fetchOne(db)
                }

                let candidates = try Star.all.fetchAll(db)
                return SurveyRoamPlanner.nextTarget(
                    centre: centreStar.position,
                    // A stowed or in-transit vessel reports no location at all,
                    // so measure the hop from the centre instead. Only WHICH
                    // member of the band is cheapest changes — the band itself
                    // is anchored on the centre either way, so the coverage
                    // guarantee is unaffected.
                    from: vesselStar?.position ?? centreStar.position,
                    stars: candidates,
                    attempted: attempted
                )
            }
        } catch {
            // The run is no worse off than before the attempt; wait and let the
            // next tick try again.
            logger.error("directive \(directive.id, privacy: .public): roam census read failed: \(error)")
            return Resolution(action: .wait, directive: directive)
        }

        guard let planned else {
            logger.info("directive \(directive.id, privacy: .public): nothing left to survey around \(centre, privacy: .public) — finishing")
            return Resolution(action: .done, directive: directive)
        }

        // `targetIndex` already equals `targets.count` (that is what made the
        // queue exhausted), so appending alone makes the new entry the current
        // target. No index arithmetic.
        var extended = directive
        extended.targets.append(planned)
        extended.updatedAt = date.now
        do {
            try await database.write { db in
                try Directive.upsert { extended }.execute(db)
            }
        } catch {
            logger.error("directive \(directive.id, privacy: .public): roam append failed: \(error)")
            return Resolution(action: .wait, directive: directive)
        }
        logger.info("directive \(directive.id, privacy: .public): roam picked \(planned, privacy: .public) (\(extended.targets.count) aimed at so far)")

        let world: WorldSnapshot
        do {
            world = try await WorldSnapshot.read(from: database, now: date.now, directive: extended)
        } catch {
            logger.error("world snapshot after roam extend failed: \(error)")
            return Resolution(action: .wait, directive: extended)
        }

        let action = machine.nextAction(directive: extended, world: world)
        if case .extendQueue = action {
            // A target was just appended and the machine still wants one. Not
            // reachable through preflight (it would have to skip the brand-new
            // target first, which is a fresh evaluation), so this is the
            // one-round loop guard rather than an expected path.
            logger.notice("directive \(directive.id, privacy: .public): roam extend did not settle — finishing")
            return Resolution(action: .done, directive: extended)
        }
        return Resolution(action: action, directive: extended)
    }
```

- [ ] **Step 5: Carry the fresh row through `evaluateOnce`**

In the same file, in `evaluateOnce`, replace the action-resolution block and the `apply` call. The existing code is:

```swift
        var action = machine.nextAction(directive: directive, world: world)
        switch action {
        case let .refreshDevices(deviceCodes, thenStall):
            action = await resolveRefresh(
                deviceCodes: deviceCodes, thenStall: thenStall,
                directive: directive, machine: machine
            )
        case let .refreshDevicesInSystem(designation, thenStall):
            action = await resolveSystemRefresh(
                designation: designation, thenStall: thenStall,
                directive: directive, machine: machine
            )
        default:
            break
        }
        let stillRunnable = await DirectiveExecutor.apply(action, to: directive, machine: machine)
```

Replace it with:

```swift
        var action = machine.nextAction(directive: directive, world: world)
        // The row the action gets applied to. Only `.extendQueue` moves it off
        // the value read at the top of this method — it is the one resolver that
        // WRITES the row, so applying its result to the pre-write value would
        // roll its append back (see `Resolution`).
        var current = directive
        switch action {
        case let .refreshDevices(deviceCodes, thenStall):
            action = await resolveRefresh(
                deviceCodes: deviceCodes, thenStall: thenStall,
                directive: directive, machine: machine
            )
        case let .refreshDevicesInSystem(designation, thenStall):
            action = await resolveSystemRefresh(
                designation: designation, thenStall: thenStall,
                directive: directive, machine: machine
            )
        case let .extendQueue(centre):
            let resolution = await resolveExtendQueue(
                centre: centre, directive: directive, machine: machine
            )
            action = resolution.action
            current = resolution.directive
        default:
            break
        }
        let stillRunnable = await DirectiveExecutor.apply(action, to: current, machine: machine)
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd app/Modules
swift test --test-product DirectiveEngineTests --filter 'DirectiveEngineRoamTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: `started: 4`, `ended: 4`, `failed: 0`.

- [ ] **Step 7: Run the whole DirectiveEngine suite for regressions**

```bash
cd app/Modules
swift test --test-product DirectiveEngineTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Run the standard result check. Expected `failed: 0`, `started == ended`, `completed: true`.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift \
        app/Modules/DirectiveEngine/Tests/DirectiveEngineTests.swift
git commit -m "Resolve a roam extend against the freshly-written row

The engine reads the census, asks SurveyRoamPlanner for the next system,
appends it, and re-asks the machine — the same do-the-IO-then-re-ask
shape as .refreshDevices.

With one difference that is a real trap rather than a signature detail.
The refresh resolvers re-ask with the same Directive value because a
device read cannot change that row; an extend appends to targets, and
every executor path builds its write as 'var updated = directive'. So
applying the post-extend action to the pre-extend value writes targets
back and loses the append. That is the happy path, not an edge case: the
action after a successful extend is normally .assignController, which
commits the whole row. The resolver therefore returns the fresh row
alongside the action, and evaluateOnce applies to that.

A vessel with no location (stowed or in transit) measures its hop from
the centre. Only which band member is cheapest changes; the band is
anchored on the centre regardless, so coverage is unaffected."
```

---

## Task 6: The launcher's mode toggle

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/NewDirectiveFeature.swift`
- Modify: `app/Modules/DirectivesFeature/Sources/NewDirectiveSheet.swift`
- Test: `app/Modules/DirectivesFeature/Tests/NewDirectiveFeatureTests.swift`

**Interfaces:**
- Consumes: `Directive.roamCentre` (Task 3), `SurveyRoamPlanner.shellWidthLY` (Task 1).
- Produces: `NewDirectiveFeature.State.Mode` (`.continuous`, `.fixedQueue`), `State.mode`, `State.roamCentre`, `State.effectiveCentre`, `Action.centrePicked(String)`.

- [ ] **Step 1: Write the failing tests**

Append to `app/Modules/DirectivesFeature/Tests/NewDirectiveFeatureTests.swift`. Read the existing tests in that file first and match how they build the store, seed `devices`, and drive it — the skeleton below shows the assertions, but the store construction must follow the file's existing pattern (`@FetchAll` state means the fleet is seeded through the database, not assigned directly).

```swift
// MARK: - Continuous mode

@Suite("New directive — continuous mode")
struct NewDirectiveContinuousModeTests {
    /// The default: a continuous run centred on the vessel's own system needs no
    /// queue built at all, so Launch is live as soon as a vessel is chosen.
    @Test func continuousModeLaunchesWithNoTargetsQueued() async throws {
        // …seed a staged vessel located at "ATIANFU-1" following this file's
        // existing pattern, select it, leave `mode` at its default…
        // #expect(store.state.mode == .continuous)
        // #expect(store.state.effectiveCentre == "ATIANFU")
        // #expect(store.state.canLaunch)
    }

    /// The written row is what the engine reads, so assert on it rather than on
    /// state: `roamCentre` set, and an EMPTY queue for the engine to extend.
    @Test func continuousLaunchWritesARoamCentreAndAnEmptyQueue() async throws {
        // …drive `.launchTapped`, then read the Directive row back…
        // #expect(row.roamCentre == "ATIANFU")
        // #expect(row.targets.isEmpty)
        // #expect(row.returnToOrigin == false)
    }

    @Test func anExplicitCentreOverridesTheVesselsSystem() async throws {
        // …send `.centrePicked("KRIOS")`…
        // #expect(store.state.effectiveCentre == "KRIOS")
    }

    /// A vessel with no location gives no centre to roam around, so Launch stays
    /// disabled rather than writing a run the engine cannot plan for.
    @Test func continuousModeCannotLaunchWithoutAKnownLocation() async throws {
        // …seed a staged vessel with `location: nil`, select it…
        // #expect(store.state.effectiveCentre == nil)
        // #expect(!store.state.canLaunch)
    }

    /// The fixed-queue regression: switching modes must leave the old path
    /// writing exactly what it writes today.
    @Test func fixedQueueModeStillWritesItsQueueAndNoRoamCentre() async throws {
        // …set `mode = .fixedQueue`, add two targets, launch…
        // #expect(row.roamCentre == nil)
        // #expect(row.targets == ["KRIOS", "SAFANA"])
    }
}
```

Fill in each body from the file's existing conventions before running. Do **not** leave the comment skeletons in place — a test that asserts nothing passes.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules
swift test --test-product DirectivesFeatureTests --filter 'NewDirectiveContinuousModeTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: compile failure — `Mode`, `mode`, `roamCentre`, `effectiveCentre`, `centrePicked` do not exist.

- [ ] **Step 3: Add the state**

In `app/Modules/DirectivesFeature/Sources/NewDirectiveFeature.swift`, add to `State`, after `returnToOrigin`:

```swift
        /// Whether the run picks its own targets forever, or works a queue the
        /// user built.
        public enum Mode: String, CaseIterable, Equatable, Sendable {
            case continuous
            case fixedQueue

            public var title: String {
                switch self {
                case .continuous: "Continuous"
                case .fixedQueue: "Fixed queue"
                }
            }
        }

        /// Continuous by default: picking targets by hand is the thing this mode
        /// exists to remove, and switching back is one click.
        public var mode: Mode = .continuous

        /// An explicitly chosen centre. Nil means "use the vessel's own system",
        /// which is what `effectiveCentre` resolves.
        public var roamCentre: String?
```

Then add, after `anchorSystem`:

```swift
        /// The centre a continuous run would actually use: an explicit pick, or
        /// the vessel's current system. Nil only when no vessel is chosen or it
        /// has no location — the same two cases `anchorSystem` covers, and the
        /// reason Launch is disabled for them.
        public var effectiveCentre: String? { roamCentre ?? anchorSystem }
```

- [ ] **Step 4: Make `canLaunch` mode-aware**

Replace `canLaunch`:

```swift
        public var canLaunch: Bool { vesselCode != nil && !targets.isEmpty }
```

with:

```swift
        public var canLaunch: Bool {
            guard vesselCode != nil else { return false }
            switch mode {
            // A continuous run has nothing to queue — the centre IS the input.
            case .continuous: return effectiveCentre != nil
            case .fixedQueue: return !targets.isEmpty
            }
        }
```

- [ ] **Step 5: Add the action**

Add to `Action`, after `case targetRemoved(Int)`:

```swift
        case centrePicked(String)
```

And handle it in the reducer, after the `.targetRemoved` case:

```swift
            case let .centrePicked(designation):
                state.roamCentre = designation
                state.search = ""
                return .none
```

- [ ] **Step 6: Write the mode into the new row**

In `launchTapped`, replace the guard and the three affected initializer arguments. The guard becomes:

```swift
            case .launchTapped:
                guard let vesselCode = state.vesselCode, state.canLaunch,
                      let vessel = state.devices.first(where: { $0.deviceCode == vesselCode })
                else { return .none }
                let isContinuous = state.mode == .continuous
```

and the initializer arguments:

```swift
                    controllerCode: nil,
                    // Non-nil is what makes the engine extend the queue rather
                    // than finish when it empties.
                    roamCentre: isContinuous ? state.effectiveCentre : nil,
                    // Empty on purpose: the engine plans the first target from
                    // the census on its first evaluation.
                    targets: isContinuous ? [] : state.targets,
```

and:

```swift
                    // A continuous run has no queue to empty, so a return leg
                    // would never fire; keep the column honest rather than
                    // recording an intent that cannot happen.
                    returnToOrigin: isContinuous ? false : state.returnToOrigin,
```

Update the log line to name the mode:

```swift
                logger.info("launching \(isContinuous ? "continuous" : "fixed", privacy: .public) survey run \(directive.id, privacy: .public) on \(vesselCode, privacy: .public)")
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd app/Modules
swift test --test-product DirectivesFeatureTests --filter 'NewDirectiveContinuousModeTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: `started: 5`, `ended: 5`, `failed: 0`.

- [ ] **Step 8: Build the UI**

In `app/Modules/DirectivesFeature/Sources/NewDirectiveSheet.swift`, add `import DirectiveEngine` to the import block (needed for `SurveyRoamPlanner.shellWidthLY`).

In `body`, replace:

```swift
                        vesselPicker
                        targetPicker
                        Toggle("Return to origin when the queue empties", isOn: $store.returnToOrigin)
                            .font(.rcBody)
                            .foregroundStyle(.rcTextSecondary)
```

with:

```swift
                        vesselPicker
                        modePicker
                        switch store.mode {
                        case .continuous:
                            centrePicker
                        case .fixedQueue:
                            targetPicker
                            Toggle("Return to origin when the queue empties", isOn: $store.returnToOrigin)
                                .font(.rcBody)
                                .foregroundStyle(.rcTextSecondary)
                        }
```

Add these two views beside `targetPicker`:

```swift
    private var modePicker: some View {
        Picker("Mode", selection: $store.mode) {
            ForEach(NewDirectiveFeature.State.Mode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// A continuous run's only input. Defaults to the vessel's own system, so
    /// the common case needs no interaction at all.
    private var centrePicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            RCSectionHeader("Centre")
            if let centre = store.effectiveCentre {
                HStack(spacing: Space.xs) {
                    Text(centre)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextPrimary)
                    if store.roamCentre == nil {
                        Text("the vessel's system")
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextTertiary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("Choose a vessel with a known location.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
            RCField("Search systems", text: $store.search)
            if !store.searchResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.searchResults) { star in
                            Button {
                                store.send(.centrePicked(star.designation))
                            } label: {
                                HStack {
                                    Text(star.designation)
                                        .font(.rcMonoSmall)
                                        .foregroundStyle(.rcTextPrimary)
                                    Spacer()
                                }
                                .padding(.vertical, Space.xxs)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            Text("Surveys outward in \(Int(SurveyRoamPlanner.shellWidthLY)) ly shells until you cancel it.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
        }
    }
```

- [ ] **Step 9: Verify the whole package builds and the feature suite is green**

```bash
cd app/Modules
swift build --build-tests 2>&1 | tail -5
swift test --test-product DirectivesFeatureTests \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Run the standard result check. Expected `Build complete!` and `failed: 0`.

- [ ] **Step 10: Commit**

```bash
git add app/Modules/DirectivesFeature/Sources/NewDirectiveFeature.swift \
        app/Modules/DirectivesFeature/Sources/NewDirectiveSheet.swift \
        app/Modules/DirectivesFeature/Tests/NewDirectiveFeatureTests.swift
git commit -m "Launch a continuous survey run from a centre, not a queue

The launcher gains a Continuous / Fixed queue toggle. Continuous mode
replaces the whole queue builder with one centre picker defaulting to the
vessel's own system, so the common case is pick a vessel and press
Launch.

Continuous is the default: picking targets by hand is exactly what this
mode removes, and switching back is one click. The written row carries an
EMPTY queue on purpose — the engine plans the first target from the
census on its first evaluation. returnToOrigin is forced off, since a
queue that never empties has no return leg to fire, and recording an
intent that cannot happen would only mislead."
```

---

## Task 7: The row's progress readout

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveRow.swift`
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveRowView.swift:70-81` (the `subtitle` computed property)
- Test: `app/Modules/DirectivesFeature/Tests/DirectiveRowTests.swift`

**Interfaces:**
- Consumes: `Directive.roamCentre` (Task 3).
- Produces: `DirectiveRow.subtitle: String?`.

A continuous run's `progress` is always "n/n" — `targetIndex == targets.count` for the whole window between finishing one system and planning the next — which renders as a finished run. The branch moves to `DirectiveRow`, the list's deliberately SwiftUI-free logic type, where it can be tested at all.

- [ ] **Step 1: Write the failing tests**

Create or append to `app/Modules/DirectivesFeature/Tests/DirectiveRowTests.swift`. If the file exists, add only the suite; if not, create it with this header:

```swift
//
//  DirectiveRowTests.swift
//  DirectivesFeatureTests
//
//  The unified list's row model.
//

import Foundation
import GameModels
import Testing

@testable import DirectivesFeature

@Suite("Directive row subtitle")
struct DirectiveRowSubtitleTests {
    private func directive(
        targets: [String], targetIndex: Int, roamCentre: String? = nil
    ) -> Directive {
        Directive(
            id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
            controllerCode: nil, roamCentre: roamCentre,
            targets: targets, targetIndex: targetIndex,
            step: "preflight", stepStartedAt: Date(timeIntervalSince1970: 0),
            returnToOrigin: false, originDesignation: "SOL",
            attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func aFixedQueueRunCountsAgainstItsTotal() {
        let row = DirectiveRow.custom(directive(targets: ["A", "B", "C"], targetIndex: 1))
        #expect(row.subtitle == "1/3")
    }

    /// The bug this branch exists for: a continuous run sits at
    /// `targetIndex == targets.count` between systems, so "n/n" would read as a
    /// finished run for most of its life.
    @Test func aContinuousRunCountsWhatItHasSurveyed() {
        let row = DirectiveRow.custom(
            directive(targets: ["A", "B"], targetIndex: 2, roamCentre: "ATIANFU")
        )
        #expect(row.subtitle == "2 surveyed")
    }

    @Test func aContinuousRunThatHasSurveyedNothingSaysSo() {
        let row = DirectiveRow.custom(
            directive(targets: [], targetIndex: 0, roamCentre: "ATIANFU")
        )
        #expect(row.subtitle == "0 surveyed")
    }

    @Test func aBuiltInRowCountsItsControlledDevices() {
        let row = DirectiveRow.builtIn(
            BuiltInDirective(
                deviceCode: "AMI1", deviceType: "ami_survey_controller",
                directive: "survey_system", config: nil,
                controlledDevices: [], drivenBy: nil
            )
        )
        #expect(row.subtitle == nil)
    }

    @Test func aDrivenBuiltInRowNamesTheMission() {
        let row = DirectiveRow.builtIn(
            BuiltInDirective(
                deviceCode: "AMI1", deviceType: "ami_survey_controller",
                directive: "survey_system", config: nil,
                controlledDevices: [],
                drivenBy: DirectiveOwner(directiveID: "D1", kindTitle: "Survey Run")
            )
        )
        #expect(row.subtitle == "driven by Survey Run")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules
swift test --test-product DirectivesFeatureTests --filter 'DirectiveRowSubtitleTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: compile failure — `DirectiveRow` has no `subtitle`.

- [ ] **Step 3: Add `subtitle` to `DirectiveRow`**

In `app/Modules/DirectivesFeature/Sources/DirectiveRow.swift`, add after `title`:

```swift
    /// The row's second line: progress for a mission, the controlled-drone
    /// count for a built-in — or, when the engine owns it, the mission driving
    /// it.
    ///
    /// Lives here rather than on `DirectiveRowView` because this type is the
    /// list's SwiftUI-free logic (pure logic hanging off a View traps under
    /// `swift test`), which is what makes the continuous-run branch below
    /// testable at all.
    public var subtitle: String? {
        switch self {
        case let .custom(directive):
            // A continuous run EXTENDS its queue instead of completing it, so
            // `targetIndex == targets.count` for the whole window between
            // finishing one system and planning the next — and "n/n" reads as a
            // finished run. Count what is done instead. The current target is
            // not repeated here; `headlineDesignation` already renders it.
            if directive.roamCentre != nil {
                return "\(directive.targetIndex) surveyed"
            }
            let progress = directive.progress
            return "\(progress.completed)/\(progress.total)"
        case let .builtIn(builtIn):
            if let owner = builtIn.drivenBy { return "driven by \(owner.kindTitle)" }
            let count = builtIn.controlledDevices.count
            return count > 0 ? "\(count) controlled" : nil
        }
    }
```

- [ ] **Step 4: Delegate from the view**

In `app/Modules/DirectivesFeature/Sources/DirectiveRowView.swift`, delete the whole `private var subtitle: String?` computed property (and its doc comment) and replace every use of `subtitle` in the view body with `row.subtitle`.

Find the uses first:

```bash
cd app/Modules && grep -n "subtitle" DirectivesFeature/Sources/DirectiveRowView.swift
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd app/Modules
swift test --test-product DirectivesFeatureTests --filter 'DirectiveRowSubtitleTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Expected: `started: 5`, `ended: 5`, `failed: 0`.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectivesFeature/Sources/DirectiveRow.swift \
        app/Modules/DirectivesFeature/Sources/DirectiveRowView.swift \
        app/Modules/DirectivesFeature/Tests/DirectiveRowTests.swift
git commit -m "Count what a continuous run has surveyed

A roam run sits at targetIndex == targets.count for the whole window
between finishing one system and planning the next, so the m/n readout
showed 'n/n' — a finished run — for most of its life. Show a plain count
instead; the current target is already on the row's first line via
headlineDesignation.

Moved subtitle off DirectiveRowView onto DirectiveRow on the way. It was
a private computed property on a SwiftUI View, which is untestable, and
DirectiveRow is the list's deliberately SwiftUI-free logic type that
already holds headline, headlineDesignation, and title."
```

---

## Task 8: Full verification

**Files:** none — this task only runs things.

- [ ] **Step 1: Build everything including tests**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -5
```

Expected: `Build complete!`.

- [ ] **Step 2: Run every affected test product into separate streams**

One file per product: they are separate binaries and would each truncate a shared path, silently leaving only the last product's results.

```bash
cd app/Modules
for p in DirectiveEngineTests DirectivesFeatureTests GameDatabaseTests UniverseModelsTests; do
  swift test --test-product "$p" --disable-xctest --event-stream-version 0 \
    --event-stream-output-path ".build/events-$p.jsonl"
done
cat .build/events-*.jsonl > .build/events.jsonl
```

- [ ] **Step 3: Check the combined results**

```bash
cd app/Modules
echo "products present:"
jq -r 'select(.kind=="test").payload.id | split(".")[0]' .build/events.jsonl | sort -u
echo "runs completed (must equal 4):"
jq -s '[.[] | select(.kind=="event" and .payload.kind=="runEnded")] | length' .build/events.jsonl
jq -s '
  map(select(.kind=="event").payload) as $e
  | ($e | map(select(.kind=="issueRecorded" and .issue.isFailure != false).testID) | unique) as $failed
  | { started: ($e | map(select(.kind=="testStarted")) | length),
      ended:   ($e | map(select(.kind=="testEnded")) | length),
      failed:  ($failed | length) }
' .build/events.jsonl
echo "crashed (started but never ended):"
jq -s -r '
  map(select(.kind=="event").payload) as $e
  | (($e | map(select(.kind=="testStarted").testID))
   - ($e | map(select(.kind=="testEnded" or .kind=="testSkipped").testID)))[]
' .build/events.jsonl
```

A pass requires: all four modules listed, `runEnded` count of 4, `failed: 0`, `started == ended`, and no crashed tests.

- [ ] **Step 4: Compile-check the app target**

The app shell in `app/Replicould.xcodeproj` is not covered by `swift build`. Confirm it still compiles:

```bash
cd app && xcodebuild -project Replicould.xcodeproj -scheme Replicould \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. Note that *running* the app from this worktree is blocked by the Keychain login wall — compiling is the check available here, and behavioural verification happens in the user's own checkout.

- [ ] **Step 5: Report**

Report the counts, the four products, and the app-target build result. Do **not** claim the feature works end to end — nothing in this plan exercises a live survey. State plainly that it is verified by unit and integration tests plus a clean build, and that a live continuous run is the user's to try.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| A1 `SurveyRoamPlanner`, `shellWidthLY` | 1 |
| A2 derived sliding band, centre-vs-vessel distances, squared ranking | 1 |
| A3 `attempted` exclusion, both deadlocks | 1 (unit), 5 (integration) |
| Measured hole bound | 2 |
| B1 `roamCentre` column + migration + frozen list + golden schema | 3 |
| B2 `MissionAction.extendQueue`, executor case | 4 |
| B3 preflight branch, ordering ahead of the return leg | 4 |
| B4 `resolveExtendQueue`, SQL candidate filter, locationless vessel | 5 |
| B5 fresh-row hand-off (`Resolution`) | 5 |
| C1 launcher mode toggle, centre picker, `canLaunch`, written row | 6 |
| C2 row subtitle, moved to `DirectiveRow` | 7 |
| "What does not change" — stall matrix, fixed-queue paths | 4 (regressions), 6 (regression), 8 |

No spec section is unimplemented. Decisions 2 (no radius leash) and 3 (stall matrix untouched) are satisfied by *absence* — Task 4's two regression tests are what hold decision 3 in place.

**Placeholder scan:** Task 6 Step 1 is the one place with comment skeletons rather than finished test bodies, because the existing `NewDirectiveFeatureTests.swift` seeds `@FetchAll` state through the database and inventing that setup blind would likely be wrong. The step says explicitly to fill each body from the file's conventions and not to leave the skeleton in place. Task 4 Step 2 similarly flags two fixture details (`StarSystem` construction, `stagedFleet`'s label) to confirm against the file rather than guessing.

**Type consistency:** `roamCentre` (not `roamCenter`) everywhere — model, migration SQL, launcher, row. `shellWidthLY` on `SurveyRoamPlanner` in Tasks 1, 2, 6. `nextTarget(centre:from:stars:attempted:shellWidth:)` matches between Task 1's definition and Task 5's call. `MissionAction.extendQueue(centre:)` matches between Tasks 4 and 5. `Mode.continuous`/`.fixedQueue` match between Tasks 6's state and its UI. `DirectiveRow.subtitle` matches between Task 7's definition and its view use. `Resolution` is private to `DirectiveEngineCore` and used only in Task 5.

Note the British spelling `centre` is used throughout for the new column and API, matching the spec. The codebase uses `designation`-style neutral naming elsewhere, so there is no existing convention this contradicts — but it must be spelled consistently or nothing compiles.
