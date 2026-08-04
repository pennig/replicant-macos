//
//  MeshGraph.swift
//  Replicould — DirectiveEngine
//
//  Task 7: the spatial grid + hop adjacency. A pure graph over census star
//  systems where two systems are adjacent iff they are within FTL relay
//  range (SalvageTargetPlanner.relayRangeLY). No I/O, no clock, no mutable
//  state — the brain rebuilds this from a fresh WorldView on every 5-second
//  tick, so `neighbours(of:)` must stay far from O(n²) even at the full
//  ~14,000-system census. A uniform spatial grid (cell size == hopRange)
//  gets a query down to scanning the 27 cells around the point, since no
//  system within hopRange of a query point can ever land outside them (see
//  the reasoning on `cell(for:hopRange:)` below).
//
//  Task 8: multi-source Dijkstra over that adjacency — `reach(targets:
//  meshSystems:)`, the cheapest new-relay chain from the live mesh to each
//  target. Node cost model: a mesh system is a zero-cost source; entering
//  any other system costs +1 relay. Primary key is relay count; ties break
//  on accumulated hop distance, then (to stay deterministic tick-to-tick —
//  see `Frontier` below) on system designation. Both Grow and Prune read
//  this one computation, so correctness here is load-bearing for the whole
//  brain.
//
//  Task 21: that promise made structural. The search itself moved into a
//  private `search(sources:free:targets:)` with TWO public readings over it —
//  `reach` (Grow: cheapest chain from the mesh toward value) and `pathUnion`
//  (Prune: every system lying on a cheapest anchor→value path). Splitting
//  `sources` from `free` is what lets Prune root at the anchor while still
//  traversing deployed relays for nothing, which is the only way a relay can
//  appear inside a returned path at all. Grow's behaviour is unchanged: it
//  passes the mesh as both.
//

import Foundation
import UniverseModels

/// A pure adjacency graph over star systems: two systems are neighbours iff
/// their positions are within `hopRange` light-years of each other.
///
/// Stateless value type — holds only the positions it was built from and a
/// grid derived from them, never a database reference or a query cache.
public struct MeshGraph: Sendable {
    private let positions: [String: Position]
    private let hopRange: Double
    private let cells: [Cell: [String]]

    struct Cell: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    public init(positions: [String: Position], hopRange: Double = SalvageTargetPlanner.relayRangeLY) {
        self.positions = positions
        self.hopRange = hopRange
        var cells: [Cell: [String]] = [:]
        for (name, p) in positions {
            cells[Self.cell(for: p, hopRange: hopRange), default: []].append(name)
        }
        self.cells = cells
    }

    /// Buckets a position into the grid cell containing it, cell size ==
    /// `hopRange`. Uses `.rounded(.down)` (floor), not truncation: floor
    /// gives every cell the same width on both sides of zero, which is what
    /// keeps the galaxy's negative-coordinate half exactly as fast as its
    /// positive half. (Truncation toward zero would still be *correct* here —
    /// the 27-cell coverage argument below only needs adjacent-cell-index
    /// deltas bounded by 1, which truncation also happens to satisfy — but it
    /// would double the width of the single cell straddling zero on each
    /// axis, concentrating points there and locally degrading the grid's
    /// flat per-cell cost. Floor avoids that degenerate cell entirely.)
    static func cell(for p: Position, hopRange: Double) -> Cell {
        Cell(
            x: Int((p.x / hopRange).rounded(.down)),
            y: Int((p.y / hopRange).rounded(.down)),
            z: Int((p.z / hopRange).rounded(.down))
        )
    }

    /// The systems within `hopRange` of `system`. Empty (not an error) if
    /// `system` isn't in the graph at all.
    ///
    /// Correctness of the 27-cell scan: bucketing uses `floor(coord /
    /// hopRange)` per axis, so each cell spans exactly one unit of
    /// `coord / hopRange`. For any two positions p, q with distance(p, q) <=
    /// hopRange, each axis individually satisfies |p.axis - q.axis| <=
    /// hopRange (an axis delta can never exceed the full 3D distance), i.e.
    /// |a - b| <= 1 where a = p.axis / hopRange, b = q.axis / hopRange. Since
    /// floor(a) <= a and floor(b) > b - 1, floor(a) - floor(b) < (a - b) + 1
    /// <= 2, so the two floor values differ by at most 1 (they're integers,
    /// and the bound is strict). That holds independently on x, y, and z, so
    /// q's cell is always within {-1, 0, +1} of p's cell on every axis — i.e.
    /// inside the 27-cell block scanned below. No in-range system can ever
    /// fall outside it.
    public func neighbours(of system: String) -> [String] {
        guard let p = positions[system] else { return [] }
        let base = Self.cell(for: p, hopRange: hopRange)
        var out: [String] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let c = Cell(x: base.x + dx, y: base.y + dy, z: base.z + dz)
                    for other in cells[c] ?? [] where other != system {
                        if let q = positions[other], q.distance(to: p) <= hopRange {
                            out.append(other)
                        }
                    }
                }
            }
        }
        return out
    }
}

/// A cheapest new-relay chain from the live mesh to `target`: the sequence
/// of *unmeshed* systems that must each receive a relay, in order, to bring
/// `target` onto the mesh.
public struct Chain: Equatable, Sendable {
    /// The system this chain unlocks.
    public let target: String
    /// The first unmeshed system to plant a relay at — equal to `target`
    /// when the chain completes in a single relay.
    public let firstHop: String
    /// Count of new relays required to fully unlock `target`, including the
    /// target itself.
    public let relaysRemaining: Int
    /// `relaysRemaining == 1`: planting `firstHop` alone completes the chain.
    public let completesNow: Bool
    /// The full ordered unmeshed path, including `target` (the path-union
    /// input for prune).
    public let waypoints: [String]
    /// Total accumulated hop distance (ly) along the chain from its mesh
    /// source. A minor sub-tiebreak — relay count is the primary key.
    public let hopDistance: Double
}

extension MeshGraph {
    /// One candidate path's running cost while it's still open. `pred ==
    /// nil` marks a zero-cost mesh source (the search's starting point).
    private struct DijkstraState {
        let relays: Int
        let dist: Double
        let pred: String?
    }

    /// A frontier entry: a candidate (not-yet-settled) cost to reach
    /// `system`. Total order over `(relays, dist, system)` — the system
    /// designation is a REQUIRED tie-break, not decoration: it's what makes
    /// pop order (and therefore which predecessor wins a cost tie)
    /// independent of Dictionary/insertion-order incidentals, which is the
    /// whole determinism guarantee `reach` relies on. See the header comment
    /// and the exact-tie test in MeshGraphReachTests.
    private struct Frontier: Comparable {
        let system: String
        let relays: Int
        let dist: Double

        static func < (lhs: Frontier, rhs: Frontier) -> Bool {
            (lhs.relays, lhs.dist, lhs.system) < (rhs.relays, rhs.dist, rhs.system)
        }
    }

    /// A minimal binary min-heap. For a strict total order (which `Frontier`
    /// is, since designation makes every comparison decisive) the sequence
    /// of `popMin()` results is independent of insertion order — only the
    /// internal tree shape varies, never which element compares smallest at
    /// each pop. That's what lets `reach` stay deterministic while still
    /// scaling past a plain sorted-array frontier: see the header comment on
    /// `reach` for the sizing rationale.
    private struct Heap<Element: Comparable> {
        private var storage: [Element] = []

        mutating func insert(_ element: Element) {
            storage.append(element)
            var child = storage.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard storage[child] < storage[parent] else { break }
                storage.swapAt(child, parent)
                child = parent
            }
        }

        mutating func popMin() -> Element? {
            guard !storage.isEmpty else { return nil }
            storage.swapAt(0, storage.count - 1)
            let min = storage.removeLast()
            var parent = 0
            while true {
                let left = 2 * parent + 1
                let right = 2 * parent + 2
                var smallest = parent
                if left < storage.count, storage[left] < storage[smallest] { smallest = left }
                if right < storage.count, storage[right] < storage[smallest] { smallest = right }
                guard smallest != parent else { break }
                storage.swapAt(parent, smallest)
                parent = smallest
            }
            return min
        }
    }

    /// The one search. `sources` are the zero-cost starting points; entering
    /// a system in `free` adds no relay, entering anything else adds one.
    /// Returns the settled cost/predecessor map, which the two public
    /// readings below interpret differently — `reach` turns it into per-
    /// target chains for Grow, `pathUnion` backtracks it into the set of
    /// systems Prune must not reclaim.
    ///
    /// `sources` and `free` are separate parameters even though `reach`
    /// passes the same set for both, because Prune needs them to differ: it
    /// roots the search at the ANCHOR alone while still letting every
    /// deployed relay be traversed for free. That distinction is the whole
    /// reason a relay can appear INSIDE a returned path at all — see
    /// `PrunePredicate`'s header for why a mesh-rooted search structurally
    /// cannot answer the prune question.
    private func search(
        sources: Set<String>, free: Set<String>, targets: Set<String>
    ) -> [String: DijkstraState] {
        guard !targets.isEmpty, !sources.isEmpty else { return [:] }

        var best: [String: DijkstraState] = [:]
        var frontier = Heap<Frontier>()
        for source in sources where positions[source] != nil {
            best[source] = DijkstraState(relays: 0, dist: 0, pred: nil)
            frontier.insert(Frontier(system: source, relays: 0, dist: 0))
        }

        var settled: Set<String> = []
        var remaining = targets
        while !remaining.isEmpty, let node = frontier.popMin() {
            guard !settled.contains(node.system) else { continue }
            settled.insert(node.system)
            remaining.remove(node.system)

            guard let origin = positions[node.system] else { continue }
            for neighbour in neighbours(of: node.system) {
                guard !settled.contains(neighbour), let neighbourPosition = positions[neighbour] else { continue }
                let stepDist = origin.distance(to: neighbourPosition)
                let addedRelay = free.contains(neighbour) ? 0 : 1
                let candidate = DijkstraState(
                    relays: node.relays + addedRelay,
                    dist: node.dist + stepDist,
                    pred: node.system
                )
                if let current = best[neighbour], (current.relays, current.dist) <= (candidate.relays, candidate.dist) {
                    continue
                }
                best[neighbour] = candidate
                frontier.insert(Frontier(system: neighbour, relays: candidate.relays, dist: candidate.dist))
            }
        }
        return best
    }

    /// Walks `pred` links from `target` back to its zero-cost source,
    /// returning the full path in source-to-target order (source first,
    /// `target` last).
    private static func backtrack(to target: String, best: [String: DijkstraState]) -> [String] {
        var path: [String] = []
        var current: String? = target
        while let system = current {
            path.append(system)
            current = best[system]?.pred
        }
        return path.reversed()
    }
}

public extension MeshGraph {
    /// Multi-source Dijkstra over the live mesh: the cheapest new-relay
    /// chain from *any* mesh system to each target, all searched
    /// simultaneously. This is the single computation both Grow (cheapest
    /// chain to plant toward) and Prune (which relays lie on no such chain)
    /// read — see the file header.
    ///
    /// Cost model: a system already in `meshSystems` is a zero-cost source;
    /// entering any other system costs +1 relay. Primary key is relay
    /// count; ties break on accumulated hop distance, then (inside the
    /// frontier ordering itself, so predecessor selection is stable too —
    /// see `Frontier`) on system designation. A target already in
    /// `meshSystems` is omitted (nothing new to plant). A target with no
    /// chain within `hopRange` of the mesh is simply absent.
    ///
    /// Frontier choice: a binary heap, not a sorted array. `neighbours(of:)`
    /// bounds *fan-out per pop*, but a multi-source search over the full
    /// ~14,000-system census can still push total frontier churn well past
    /// what a sorted-array insert (O(n) per insert) stays comfortable at;
    /// a heap keeps insert/pop at O(log n) with no added complexity risk,
    /// and — because `Frontier` is a strict total order — costs nothing in
    /// determinism versus the array.
    ///
    /// Cost bound: the early exit below only fires once every requested
    /// target has settled, and for the intended caller (value-bearing
    /// candidates scattered across the census) at least one target is
    /// typically out of range of the mesh — so in practice the search runs
    /// to exhaustion of the mesh's REACHABLE CONNECTED COMPONENT, not some
    /// smaller early-terminated slice. At full census scale that's still
    /// comfortably inside the 5-second tick budget: ~14k pops × ≤27-cell
    /// probes plus an O(n log n) heap is single-digit milliseconds.
    func reach(targets: Set<String>, meshSystems: Set<String>) -> [String: Chain] {
        // Grow's reading: every mesh system is both a source and free, which
        // is what makes this "the cheapest chain from ANYWHERE on the mesh".
        let best = search(sources: meshSystems, free: meshSystems, targets: targets)

        var chains: [String: Chain] = [:]
        for target in targets {
            // relays == 0 means `target` is already meshed — not a grow target.
            guard let state = best[target], state.relays > 0 else { continue }
            let path = Self.backtrack(to: target, best: best)
            let waypoints = path.filter { !meshSystems.contains($0) }
            guard let firstHop = waypoints.first else { continue }
            chains[target] = Chain(
                target: target,
                firstHop: firstHop,
                relaysRemaining: waypoints.count,
                completesNow: waypoints.count == 1,
                waypoints: waypoints,
                hopDistance: state.dist
            )
        }
        return chains
    }

    /// Prune's reading of the same search: every system lying on a cheapest
    /// path from `sources` to any of `targets`, unioned — free systems and
    /// sources included, which is exactly what `reach` throws away.
    ///
    /// The two readings differ in one deliberate way. `reach` seeds sources
    /// AT the mesh, so a mesh system is always a path's origin and never an
    /// interior node; Prune instead seeds one anchor and marks the mesh
    /// `free`, so the returned paths run THROUGH the deployed relays that
    /// carry authority outward. Same graph, same cost model, same total
    /// order — see `search`.
    ///
    /// A target with no path from any source contributes nothing (it is
    /// simply absent, never a partial path). Ties resolve exactly as `reach`
    /// resolves them, on `(relays, dist, designation)`, so the union is the
    /// same set on every tick given the same world.
    ///
    /// The union is a SERVING SUBGRAPH, and that property is what makes it
    /// safe to read as a keep-list: it is the pointwise union of complete
    /// source→target paths, so discarding everything outside it leaves every
    /// one of those paths intact. That holds however the ties fell.
    func pathUnion(to targets: Set<String>, from sources: Set<String>, free: Set<String>) -> Set<String> {
        let best = search(sources: sources, free: free, targets: targets)
        var union: Set<String> = []
        for target in targets where best[target] != nil {
            union.formUnion(Self.backtrack(to: target, best: best))
        }
        return union
    }
}
