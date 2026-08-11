# 12 — Theatre site ranking

Type: task
Status: open
Blocked by: 04
Labels: multi-theatre

The brain's half of "brain proposes, operator establishes": rank candidate systems for a new theatre and explain why. Read-only — this ticket adds no acting capability and must not spend anything.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/TheatreSiteRanking.swift`
- Test: `app/Modules/DirectiveEngine/Tests/TheatreSiteRankingTests.swift` (create)

**Interfaces:**
- Consumes: `WorldView` (04) — `salvageUnits`, `stockpileUnits`, `beltsBySystem`, `surveyedSystems`, `replicantSystems`, `starPositions`, `theatres`.
- Produces:
  ```swift
  public enum TheatreSiteRanking {
      public struct Candidate: Equatable, Sendable, Identifiable {
          public var id: String { system }
          public let system: String
          public let score: Double
          public let unservicedValue: Double
          public let distanceToNearestTheatre: Double
          public let hasAuthority: Bool
          public let isSurveyed: Bool
          /// One line per clause that moved the score, for the why-view.
          public let reasons: [String]
      }
      public static func rank(view: WorldView, limit: Int = 5) -> [Candidate]
  }
  ```

**Scoring clauses, all four required:**

1. **Unserviced value** — `salvageUnits` + `stockpileUnits` within a radius of the candidate that no operational theatre already services. Value an existing theatre can already reach is worth nothing here.
2. **Survey state** — an unsurveyed system's belts are unknown rather than absent (the distinction `beltsBySystem` cannot carry on its own). Treat unknown as a discount, never as zero, and set `isSurveyed` so the UI can say so.
3. **Authority** — a system holding or adjacent to one of the account's replicants scores higher, because command authority is the hard prerequisite for a theatre that is not on the home mesh. `replicantSystems` is the input.
4. **Redundancy** — distance to the nearest existing theatre, where farther is better up to a ceiling. A candidate 10 ly from an existing theatre duplicates it.

Ordering is total: score descending, designation ascending on ties, so two ticks over one world propose the same list in the same order.

---

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/TheatreSiteRankingTests.swift`:

```swift
//
//  TheatreSiteRankingTests.swift
//  Replicould — DirectiveEngine
//
//  Candidate ranking for a new theatre: value an existing theatre already
//  reaches counts for nothing, and the order is total.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Theatre site ranking")
struct TheatreSiteRankingTests {
    @Test("Value an existing theatre already services does not count")
    func servicedValueIsWorthless() {
        let ranked = TheatreSiteRanking.rank(view: valueBesideHomeTheatre())
        #expect(ranked.first?.system != "GRAZ")
    }

    @Test("A rich unserviced cluster outranks a poor one")
    func richerUnservicedWins() {
        let ranked = TheatreSiteRanking.rank(view: twoUnservicedClusters())
        #expect(ranked.first?.system == "OMEROPE")
    }

    @Test("A system holding a replicant outranks an equal one without")
    func authorityBreaksTies() {
        let ranked = TheatreSiteRanking.rank(view: equalClustersOneWithReplicant())
        #expect(ranked.first?.hasAuthority == true)
    }

    @Test("A candidate beside an existing theatre is discounted as redundant")
    func redundancyDiscounted() {
        let ranked = TheatreSiteRanking.rank(view: candidateBesideExistingTheatre())
        let neighbour = ranked.first { $0.system == "GRAZ" }
        #expect(neighbour?.reasons.contains { $0.contains("redundant") } == true)
    }

    @Test("The order is total and repeatable")
    func orderIsTotal() {
        let view = twoUnservicedClusters()
        #expect(TheatreSiteRanking.rank(view: view) == TheatreSiteRanking.rank(view: view))
    }

    @Test("An unsurveyed candidate is offered, flagged, and discounted rather than dropped")
    func unsurveyedStillOffered() {
        let ranked = TheatreSiteRanking.rank(view: unsurveyedRichCluster())
        #expect(ranked.contains { $0.system == "OMEROPE" && !$0.isSurveyed })
    }
}
```

Build the six world fixtures as private helpers, reusing the `WorldView` construction idiom from ticket 04's tests.

- [ ] **Step 2: Run and confirm it fails**

```bash
cd app/Modules && swift test --filter TheatreSiteRankingTests --event-stream-output-path /tmp/t12.json
```

- [ ] **Step 3: Implement the ranking**

Write `TheatreSiteRanking.swift` against the four clauses above. Keep it a pure function of `WorldView` with no database and no clock, matching `GrowRanking` and `SalvageTargetPlanner` — both are the house pattern for this kind of pass and both are worth reading first.

Every clause that moves a score appends a line to `reasons`. The why-view renders those verbatim, so write them as sentences an operator reads, not as debug output.

- [ ] **Step 4: Run the tests, then the suite**

```bash
cd app/Modules && swift test --filter TheatreSiteRankingTests --event-stream-output-path /tmp/t12.json
cd app/Modules && swift test --event-stream-output-path /tmp/t12-all.json
```

Expected: 6 new tests pass, nothing else moves — this ticket adds a function nobody calls yet.

- [ ] **Step 5: Commit**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/TheatreSiteRanking.swift
git add app/Modules/DirectiveEngine
git commit -m "feat(theatre): rank candidate systems for a new theatre"
```
