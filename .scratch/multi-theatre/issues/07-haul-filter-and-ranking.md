# 07 — Haul component filter and round-trip ranking

Type: task
Status: open
Blocked by: 04
Labels: multi-theatre

The two changes to `HaulTargetPlanner` land together because the ranking test needs the filter in place to have two theatres to rank between. This is the ticket that kills the 316 ly ferry.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/HaulTargetPlanner.swift`
- Modify: `app/Modules/DirectiveEngine/Sources/HaulRun.swift` (`:145`, the `meshSystems:` call site)
- Test: `app/Modules/DirectiveEngine/Tests/MultiTheatreHaulTests.swift` (create)

**Interfaces:**
- Consumes: `WorldView.components` (04), `WorldView.starPositions`.
- Produces:
  ```swift
  public static func assignments(
      controllers: [Device],
      footprints: [String: Int],
      components: [String: String],
      positions: [String: Position],
      delivery: String,
      secondsPerLy: Double = HaulTargetPlanner.secondsPerLy
  ) -> [Assignment]

  /// Travel seconds per light-year, for the round-trip ranking. UNCALIBRATED —
  /// see the residual in the spec.
  public static let secondsPerLy: Double = 30
  ```
  The `meshSystems: Set<String>` parameter is replaced by `components` and `positions`. Same-system piles still bypass the check entirely and remain `shuttle`.

**Ranking.** `rank = units / (2 · d(pile, delivery) · secondsPerLy)`, richest-per-round-trip first, designation as tie-break so the order stays total and the run does not re-issue `set_directive` forever (the property the current sort exists for, `HaulTargetPlanner.swift:80-84`). A same-system `shuttle` has `d == 0`; give it a rank of `.infinity` so in-system piles always outrank interstellar ones, which is both correct and what happens today.

**Fallback.** If `positions` cannot place either end, fall back to raw units for that candidate rather than dropping it. A wrong or missing distance must degrade to today's behaviour, never to no haulage.

---

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/MultiTheatreHaulTests.swift`:

```swift
//
//  MultiTheatreHaulTests.swift
//  Replicould — DirectiveEngine
//
//  Haul assignment across theatres: a pile in another mesh component is never
//  a candidate, and within one component distance beats raw size.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

private let positions: [String: Position] = [
    "AINALRAM": Position(x: -11.25, y: -37.09, z: -7.68),
    "GRAZ": Position(x: -14.0, y: -30.0, z: -5.0),
    "SOL": Position(x: 0, y: 0, z: 0),
    "OMEROPE": Position(x: -291.87, y: -125.98, z: 106.32),
]

private let components: [String: String] = [
    "AINALRAM": "AINALRAM", "GRAZ": "AINALRAM", "SOL": "AINALRAM",
    "OMEROPE": "OMEROPE",
]

private func controller(_ code: String) -> Device {
    Device.fixture(deviceCode: code, deviceType: "transport_hauler", location: "AINALRAM-BELT-1")
}

@Suite("Multi-theatre haul")
struct MultiTheatreHaulTests {
    @Test("A pile in another component is never assigned — the 316 ly regression")
    func refusesOtherComponent() {
        let assignments = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["OMEROPE-BELT-1": 50_000],
            components: components, positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(assignments.isEmpty)
    }

    @Test("Two theatres in ONE component each drain their own nearer piles")
    func sharedComponentSplitsByDistance() {
        let near = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["GRAZ-1-L4": 1_000, "SOL-3-1": 1_000],
            components: components, positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(near.first?.location == "GRAZ-1-L4")
    }

    @Test("A rich distant pile loses to a modest near one")
    func distanceBeatsRawSize() {
        let assignments = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["SOL-3-1": 1_200, "GRAZ-1-L4": 300],
            components: components, positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(assignments.first?.location == "GRAZ-1-L4")
    }

    @Test("A pile large enough to pay for the trip still wins")
    func sizeStillWinsWhenItPays() {
        let assignments = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["SOL-3-1": 500_000, "GRAZ-1-L4": 300],
            components: components, positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(assignments.first?.location == "SOL-3-1")
    }

    @Test("An in-system pile outranks every interstellar one and stays a shuttle")
    func shuttleOutranksFerry() {
        let assignments = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["AINALRAM-BELT-2": 10, "SOL-3-1": 500_000],
            components: components, positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(assignments.first?.location == "AINALRAM-BELT-2")
        #expect(assignments.first?.directive == HaulTargetPlanner.shuttle)
    }

    @Test("An unplaceable pile falls back to raw units rather than vanishing")
    func unplaceableFallsBack() {
        let assignments = HaulTargetPlanner.assignments(
            controllers: [controller("T1")],
            footprints: ["GHOST-1-L4": 9_000],
            components: components.merging(["GHOST": "AINALRAM"]) { a, _ in a },
            positions: positions,
            delivery: "AINALRAM-BELT-1"
        )

        #expect(assignments.first?.location == "GHOST-1-L4")
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
cd app/Modules && swift test --filter MultiTheatreHaulTests --event-stream-output-path /tmp/t07.json
```

Expected: compile failure on the unknown `components:` / `positions:` labels.

- [ ] **Step 3: Replace the filter and the sort**

In `HaulTargetPlanner.assignments`, swap the `meshSystems` parameter for `components` and `positions`, and replace the candidate filter (`HaulTargetPlanner.swift:70-79`) and sort (`:80-84`):

```swift
        let deliverySystem = SiteAssay.system(of: delivery)
        let deliveryComponent = components[deliverySystem]

        func roundTripRank(_ location: String, units: Int) -> Double {
            let system = SiteAssay.system(of: location)
            guard system != deliverySystem else { return .infinity }
            guard let from = positions[system], let to = positions[deliverySystem] else {
                // Unplaceable: degrade to raw units rather than dropping a real
                // pile because the census has a hole.
                return Double(units)
            }
            let seconds = 2 * from.distance(to: to) * secondsPerLy
            return seconds > 0 ? Double(units) / seconds : .infinity
        }

        let candidates = footprints
            .filter { location, units in
                guard units > 0, location != delivery else { return false }
                let system = SiteAssay.system(of: location)
                // Same system: `shuttle`, and connectivity is irrelevant because
                // nothing crosses a star. Different system: `ferry`, which needs
                // both ends in the DELIVERING theatre's component.
                if system == deliverySystem { return true }
                return components[system] != nil && components[system] == deliveryComponent
            }
            .sorted { lhs, rhs in
                let (l, r) = (roundTripRank(lhs.key, units: lhs.value), roundTripRank(rhs.key, units: rhs.value))
                return l != r ? l > r : lhs.key < rhs.key
            }
```

- [ ] **Step 4: Update the call site in `HaulRun`**

At `HaulRun.swift:145`, replace the `meshSystems: SalvageTargetPlanner.meshSystems(...)` argument with the world's `components` and `starPositions`. Use Swift-LSP `findReferences` on `assignments` to confirm there is no other caller.

- [ ] **Step 5: Run the tests and confirm they pass**

```bash
cd app/Modules && swift test --filter MultiTheatreHaulTests --event-stream-output-path /tmp/t07.json
cd app/Modules && swift test --event-stream-output-path /tmp/t07-all.json
```

Expected: 6 new tests pass. Existing `HaulTargetPlanner` tests may need their fixtures updated from `meshSystems:` to `components:`; that is a fixture change, not a behaviour change, and any test whose *expectation* moves is a finding to report rather than to edit away.

- [ ] **Step 6: Commit**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/HaulTargetPlanner.swift
git add app/Modules/DirectiveEngine
git commit -m "fix(theatre): haul filters by component and ranks by round-trip"
```
