# 01 — Mesh component labelling

Type: task
Status: open
Blocked by: —
Labels: multi-theatre

Give `MeshGraph` the ability to partition a set of systems into connected components. This is the primitive every inward-facing theatre rule is built on, and it is pure graph work with no database and no clock.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MeshGraph.swift`
- Test: `app/Modules/DirectiveEngine/Tests/MeshComponentTests.swift` (create)

**Interfaces:**
- Consumes: `MeshGraph.neighbours(of:)` (already public, `MeshGraph.swift:113`), `MeshGraph.canPlace(_:)` (`:86`).
- Produces:
  ```swift
  extension MeshGraph {
      public func components(of systems: Set<String>) -> [String: String]
  }
  ```
  System designation → component label. The label is the lexicographically smallest member of that component, which makes it total, deterministic and free of any persisted identifier.

---

- [ ] **Step 1: Write the failing test**

Create `app/Modules/DirectiveEngine/Tests/MeshComponentTests.swift`:

```swift
//
//  MeshComponentTests.swift
//  Replicould — DirectiveEngine
//
//  `MeshGraph.components(of:)`: disjoint clusters stay disjoint, a bridging
//  system merges them, and a system the census cannot place stands alone.
//

import Foundation
import Testing
import UniverseModels
@testable import DirectiveEngine

/// Two clusters 100 ly apart, each internally within one 7.5 ly hop.
private let twoClusters: [String: Position] = [
    "HOME": Position(x: 0, y: 0, z: 0),
    "NEAR": Position(x: 5, y: 0, z: 0),
    "FAR": Position(x: 100, y: 0, z: 0),
    "FARTHER": Position(x: 105, y: 0, z: 0),
]

@Suite("Mesh components")
struct MeshComponentTests {
    @Test("Disjoint clusters get distinct labels")
    func disjointClusters() {
        let graph = MeshGraph(positions: twoClusters)
        let labels = graph.components(of: ["HOME", "NEAR", "FAR", "FARTHER"])

        #expect(labels["HOME"] == labels["NEAR"])
        #expect(labels["FAR"] == labels["FARTHER"])
        #expect(labels["HOME"] != labels["FAR"])
    }

    @Test("The label is the component's smallest designation")
    func labelIsMinimum() {
        let graph = MeshGraph(positions: twoClusters)
        let labels = graph.components(of: ["HOME", "NEAR", "FAR", "FARTHER"])

        #expect(labels["HOME"] == "HOME")
        #expect(labels["NEAR"] == "HOME")
        #expect(labels["FARTHER"] == "FAR")
    }

    @Test("A bridging system merges two components")
    func bridgeMerges() {
        var positions = twoClusters
        // Two hops of 50 ly are still out of range; a chain of stepping stones
        // at 5 ly each is what actually joins them.
        for step in 1...19 {
            positions["STEP\(String(format: "%02d", step))"] = Position(
                x: Double(step) * 5, y: 0, z: 0
            )
        }
        let graph = MeshGraph(positions: positions)
        let labels = graph.components(of: Set(positions.keys))

        #expect(labels["HOME"] == labels["FARTHER"])
        #expect(Set(labels.values).count == 1)
    }

    @Test("A system the census cannot place is its own component")
    func unplaceableStandsAlone() {
        let graph = MeshGraph(positions: twoClusters)
        let labels = graph.components(of: ["HOME", "NEAR", "GHOST"])

        #expect(labels["GHOST"] == "GHOST")
        #expect(labels["GHOST"] != labels["HOME"])
    }

    @Test("Membership is respected: a system outside the set never joins one")
    func outsideMembershipIgnored() {
        let graph = MeshGraph(positions: twoClusters)
        let labels = graph.components(of: ["HOME", "FAR"])

        #expect(labels.count == 2)
        #expect(labels["HOME"] == "HOME")
        #expect(labels["FAR"] == "FAR")
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
cd app/Modules && swift test --filter MeshComponentTests --event-stream-output-path /tmp/t01.json
```

Expected: a compile failure, `value of type 'MeshGraph' has no member 'components'`.

- [ ] **Step 3: Implement `components(of:)`**

Append to `app/Modules/DirectiveEngine/Sources/MeshGraph.swift`, inside the `MeshGraph` extension that holds `reach` and `pathUnion`:

```swift
    /// Connected components over `systems`, each labelled by its own smallest
    /// designation. A system this graph cannot place neighbours nothing and so
    /// stands alone — the safe reading, since an unplaceable system must never
    /// inherit another's reachability.
    public func components(of systems: Set<String>) -> [String: String] {
        var labels: [String: String] = [:]
        for seed in systems.sorted() where labels[seed] == nil {
            var stack = [seed]
            var members: [String] = []
            labels[seed] = seed
            while let next = stack.popLast() {
                members.append(next)
                for hop in neighbours(of: next) where systems.contains(hop) && labels[hop] == nil {
                    labels[hop] = seed
                    stack.append(hop)
                }
            }
            let label = members.min() ?? seed
            for member in members { labels[member] = label }
        }
        return labels
    }
```

- [ ] **Step 4: Run the test and confirm it passes**

```bash
cd app/Modules && swift test --filter MeshComponentTests --event-stream-output-path /tmp/t01.json
```

Expected: 5 passing, 0 failing, read from the event stream.

- [ ] **Step 5: Run the whole suite**

```bash
cd app/Modules && swift test --event-stream-output-path /tmp/t01-all.json
```

Expected: no regression against the ~335 tests that passed before this task.

- [ ] **Step 6: Check comments and commit**

```bash
cd /Users/matt/Developer/replicant-macos && ./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/MeshGraph.swift app/Modules/DirectiveEngine/Tests/MeshComponentTests.swift
git add app/Modules/DirectiveEngine/Sources/MeshGraph.swift app/Modules/DirectiveEngine/Tests/MeshComponentTests.swift
git commit -m "feat(theatre): connected-component labelling on MeshGraph"
```
