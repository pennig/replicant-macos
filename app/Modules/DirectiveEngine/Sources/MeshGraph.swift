//
//  MeshGraph.swift
//  Replicould — DirectiveEngine
//
//  The spatial grid, hop adjacency, and the one search over them. A pure graph
//  over census star systems where two systems are adjacent iff they are within
//  FTL relay range (`SalvageTargetPlanner.relayRangeLY`). No I/O, no clock, no
//  mutable state — the brain rebuilds this from a fresh `WorldView` on every
//  5-second tick, so `neighbours(of:)` must stay far from O(n²) over the whole
//  census; a uniform spatial grid (cell size == hopRange) gets a query down to
//  the 27 cells around the point.
//
//  One multi-source Dijkstra, `search(sources:free:targets:)`, carries two
//  public readings: `reach` (Grow — the cheapest new-relay chain from the mesh
//  toward value) and `pathUnion` (Prune — every system on a cheapest
//  anchor→value path). Cost model: a source is zero-cost, entering a `free`
//  system adds no relay, entering anything else adds one, and the key is
//  `(relays, distance, designation)`. Splitting `sources` from `free` is what
//  lets Prune root at the anchor while traversing deployed relays for nothing,
//  and it is the only way a relay can appear inside a returned path at all.
//  Grow passes the mesh as both. Correctness here is load-bearing for both.
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

    /// One grid bucket, addressed by its integer `x`/`y`/`z` cell indices.
    struct Cell: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    /// Builds the grid from `positions` (system designation → position), with
    /// `hopRange` serving as both the adjacency radius and the grid's cell
    /// size. A system absent from `positions` is invisible to every query on
    /// this graph — see `canPlace`.
    public init(positions: [String: Position], hopRange: Double = SalvageTargetPlanner.relayRangeLY) {
        self.positions = positions
        self.hopRange = hopRange
        var cells: [Cell: [String]] = [:]
        for (name, p) in positions {
            cells[Self.cell(for: p, hopRange: hopRange), default: []].append(name)
        }
        self.cells = cells
    }

    /// Buckets position `p` into the grid cell containing it, cell size ==
    /// `hopRange`. Uses `.rounded(.down)` (floor), not truncation toward zero:
    /// floor gives every cell the same width on both sides of the origin, where
    /// truncation would double the width of the single cell straddling zero on
    /// each axis and concentrate points in it.
    static func cell(for p: Position, hopRange: Double) -> Cell {
        Cell(
            x: Int((p.x / hopRange).rounded(.down)),
            y: Int((p.y / hopRange).rounded(.down)),
            z: Int((p.z / hopRange).rounded(.down))
        )
    }

    /// Whether this graph can place `system` at all — whether the search can
    /// ever reach it, settle it, or return it inside a path.
    ///
    /// `PrunePredicate.analyse` proves this of every system its judgement
    /// depends on before judging anything: a system the graph has never heard
    /// of drops silently out of the union, taking with it every pin it was the
    /// sole source of and offering up load-bearing relays. Ask the GRAPH and
    /// not a caller's own census, because this reads the very dictionary
    /// `search` and `backtrack` read, so the two cannot disagree however the
    /// graph was built.
    ///
    /// What it catches is a graph that is a SUBSET of the caller's census, not
    /// a superset: a graph carrying stars the caller does not list passes every
    /// check and can still reroute the union through a system the caller has
    /// never heard of.
    func canPlace(_ system: String) -> Bool { positions[system] != nil }

    /// Straight-line distance between systems `a` and `b` in light-years, or
    /// nil if this graph cannot place either of them.
    ///
    /// Read off the graph rather than off a caller's own census dictionary for
    /// the reason `canPlace` exists: distance and reachability must be answered
    /// from one set of positions, or a system can be "3 ly away" and
    /// simultaneously unreachable.
    ///
    /// Deliberately NOT a graph distance: it is the geometry, not a path cost,
    /// and it answers "how far out of the way is this?" rather than "how many
    /// relays would it take to get there?"
    func separation(_ a: String, _ b: String) -> Double? {
        guard let p = positions[a], let q = positions[b] else { return nil }
        return p.distance(to: q)
    }

    /// The systems within `hopRange` of `system`. Empty (not an error) if
    /// `system` isn't in the graph at all.
    ///
    /// The 27-cell scan is exhaustive rather than approximate, so narrowing it
    /// drops in-range systems and widening it gains none: cells span exactly
    /// one unit of `coord / hopRange`, and for any two positions no further
    /// apart than `hopRange` each axis delta is itself at most `hopRange` (an
    /// axis delta can never exceed the full 3D distance), so their floor values
    /// differ by at most 1 independently on x, y and z.
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
    /// One candidate path's running cost while it's still open: its `relays`
    /// count, accumulated `dist`, and predecessor `pred`. `pred == nil` marks a
    /// zero-cost source, which is where `backtrack` stops.
    private struct DijkstraState {
        let relays: Int
        let dist: Double
        let pred: String?
    }

    /// A frontier entry: a candidate (not-yet-settled) cost to reach
    /// `system`. Total order over `(relays, dist, system)` — the system
    /// designation is a REQUIRED tie-break, not decoration: it is what makes
    /// pop order (and therefore which predecessor wins a cost tie)
    /// independent of Dictionary/insertion-order incidentals. Drop it and the
    /// search stops answering the same way tick to tick.
    private struct Frontier: Comparable {
        let system: String
        let relays: Int
        let dist: Double

        static func < (lhs: Frontier, rhs: Frontier) -> Bool {
            (lhs.relays, lhs.dist, lhs.system) < (rhs.relays, rhs.dist, rhs.system)
        }
    }

    /// A minimal binary min-heap. Because `Frontier` is a strict total order,
    /// the sequence of `popMin()` results is independent of insertion order —
    /// only the internal tree shape varies, never which element compares
    /// smallest at each pop — so the heap keeps insert/pop at O(log n) and
    /// costs nothing in determinism against a plain sorted-array frontier.
    private struct Heap<Element: Comparable> {
        private var storage: [Element] = []

        /// Adds `element`, sifting it up into place.
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

        /// Removes and returns the smallest element, or `nil` when empty.
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
    /// a system in `free` adds no relay, entering anything else adds one; the
    /// walk stops once every system in `targets` has settled or the frontier
    /// empties. Returns the settled cost/predecessor map, which the two public
    /// readings below interpret differently — `reach` turns it into per-
    /// target chains for Grow, `pathUnion` backtracks it into the set of
    /// systems Prune must not reclaim.
    ///
    /// `sources` and `free` are separate parameters even though `reach`
    /// passes the same set for both, because Prune needs them to differ: it
    /// roots the search at the ANCHOR alone while still letting every
    /// deployed relay be traversed for free. Pass the mesh as `sources` and a
    /// relay can never be an interior node of a returned path — see
    /// `PrunePredicate`'s header for why that answers no prune question.
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

    /// Walks `pred` links in `best` from `target` back to its zero-cost source,
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
    /// chain from *any* system in `meshSystems` to each of `targets`, all
    /// searched simultaneously.
    ///
    /// Cost model: a system already in `meshSystems` is a zero-cost source;
    /// entering any other system costs +1 relay. Primary key is relay
    /// count; ties break on accumulated hop distance, then (inside the
    /// frontier ordering itself, so predecessor selection is stable too —
    /// see `Frontier`) on system designation. A target already in
    /// `meshSystems` is omitted (nothing new to plant). A target with no
    /// chain within `hopRange` of the mesh is simply absent, never a partial
    /// chain.
    ///
    /// The early exit below fires only once every requested target has
    /// settled, and for the intended caller (value-bearing candidates
    /// scattered across the census) at least one target is typically out of
    /// range of the mesh — so expect the search to run to exhaustion of the
    /// mesh's REACHABLE CONNECTED COMPONENT rather than some smaller
    /// early-terminated slice. That, not the early exit, is what the heap
    /// frontier is sized for.
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
    /// path from `sources` to any of `targets`, unioned — systems in `free`
    /// and the sources themselves INCLUDED, which is exactly what `reach`
    /// throws away.
    ///
    /// The asymmetry between the two readings is load-bearing. `reach` seeds
    /// sources AT the mesh, so a mesh system is always a path's origin and
    /// never an interior node; Prune instead seeds one anchor and marks the
    /// mesh `free`, so the returned paths run THROUGH the deployed relays that
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
