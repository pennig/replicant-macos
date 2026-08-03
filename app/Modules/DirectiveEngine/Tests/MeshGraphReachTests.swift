//
//  MeshGraphReachTests.swift
//  DirectiveEngineTests
//
//  Task 8: multi-source Dijkstra over MeshGraph — the cheapest new-relay
//  chain from the live mesh to each target. This is the single computation
//  both Grow and Prune read, so correctness (and determinism — see the
//  tie-break tests) matters far more than speed here.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Mesh graph reach (multi-source Dijkstra)")
struct MeshGraphReachTests {
    // Line world: MESH(0) — W(6) — T(12). hopRange 7.5.
    let positions: [String: Position] = [
        "MESH": .init(x: 0, y: 0, z: 0),
        "W": .init(x: 6, y: 0, z: 0),
        "T": .init(x: 12, y: 0, z: 0),
        "FAR": .init(x: 40, y: 0, z: 0),
    ]

    @Test func oneHopCompletesNow() throws {
        let g = MeshGraph(positions: positions)
        let chains = g.reach(targets: ["W"], meshSystems: ["MESH"])
        let c = try #require(chains["W"])
        #expect(c.firstHop == "W")
        #expect(c.relaysRemaining == 1)
        #expect(c.completesNow)
        #expect(c.waypoints == ["W"])
        #expect(c.target == "W")
    }

    @Test func twoHopReportsFirstHopAndCount() throws {
        let g = MeshGraph(positions: positions)
        let chains = g.reach(targets: ["T"], meshSystems: ["MESH"])
        let c = try #require(chains["T"])
        #expect(c.firstHop == "W") // plant W first, not T
        #expect(c.relaysRemaining == 2) // W then T
        #expect(!c.completesNow)
        #expect(c.waypoints == ["W", "T"])
    }

    @Test func outOfRangeTargetIsUnreachable() {
        let g = MeshGraph(positions: positions)
        #expect(g.reach(targets: ["FAR"], meshSystems: ["MESH"]).isEmpty)
    }

    // MARK: - Beyond the brief's floor

    /// A target already covered by the mesh (relays == 0) is not a grow
    /// target — the brain has nothing new to plant there.
    @Test func alreadyMeshedTargetIsExcluded() {
        let g = MeshGraph(positions: positions)
        let chains = g.reach(targets: ["W"], meshSystems: ["MESH", "W"])
        #expect(chains["W"] == nil)
    }

    /// Multi-source: the search must genuinely start from every mesh system
    /// at once, not just the first one. T2 is only reachable (within
    /// hopRange) from MESH2 — if the search only seeded from MESH1 (too far
    /// from anything), T2 would come back unreachable.
    @Test func multiSourceRoutesFromEveryMeshSystem() throws {
        let positions: [String: Position] = [
            "MESH1": .init(x: 0, y: 0, z: 0),
            "MESH2": .init(x: 50, y: 0, z: 0),
            "T2": .init(x: 54, y: 0, z: 0), // 4 ly from MESH2, unreachable from MESH1
        ]
        let g = MeshGraph(positions: positions)
        let chains = g.reach(targets: ["T2"], meshSystems: ["MESH1", "MESH2"])
        let c = try #require(chains["T2"])
        #expect(c.firstHop == "T2")
        #expect(c.relaysRemaining == 1)
        #expect(c.completesNow)
    }

    /// A target reachable from BOTH mesh sources, at different distances,
    /// must route from the nearer one — a genuine multi-source contention
    /// where the second-processed source must strictly improve `best[target]`
    /// after the first already wrote it. (A world where one source is
    /// simply unreachable, as in `multiSourceRoutesFromEveryMeshSystem`
    /// above, can't exercise this: there'd be only one candidate route.)
    @Test func multiSourcePicksNearerSource() throws {
        let positions: [String: Position] = [
            "MESH1": .init(x: 0, y: 0, z: 0),
            "MESH2": .init(x: 6, y: 0, z: 0),
            "T": .init(x: 7, y: 0, z: 0), // 7 ly from MESH1, 1 ly from MESH2 — both in range
        ]
        let g = MeshGraph(positions: positions)
        let chains = g.reach(targets: ["T"], meshSystems: ["MESH1", "MESH2"])
        let c = try #require(chains["T"])
        #expect(c.firstHop == "T")
        #expect(c.relaysRemaining == 1)
        #expect(c.hopDistance == 1)
    }

    /// Primary key is relay count, not distance: a 2-relay chain that's
    /// geometrically longer must still beat a 3-relay chain that's shorter.
    @Test func fewerRelaysWinsOverShorterDistance() throws {
        let positions: [String: Position] = [
            "MESH": .init(x: 0, y: 0, z: 0),
            // 2-relay route: MESH -> A -> T, each leg ~7.43 ly (total ~14.86).
            // MESH-T direct is 11 ly (out of range), so 2 relays is the floor.
            "A": .init(x: 5.5, y: 5, z: 0),
            "T": .init(x: 11, y: 0, z: 0),
            // 3-relay route: MESH -> B -> C -> T, total ~14.69 ly — shorter
            // than the A route, but MORE relays. B-T (8.94) and MESH-C (9.49)
            // are both out of range, so there is no 2-relay shortcut through
            // B or C; relay count must still make A win despite A costing
            // more total distance.
            "B": .init(x: 3, y: 4, z: 0),
            "C": .init(x: 9, y: 3, z: 0),
        ]
        let g = MeshGraph(positions: positions)
        let chains = g.reach(targets: ["T"], meshSystems: ["MESH"])
        let c = try #require(chains["T"])
        #expect(c.relaysRemaining == 2)
        #expect(c.firstHop == "A")
        #expect(c.waypoints == ["A", "T"])
    }

    /// Empty mesh (no sources at all) must yield no chains, not crash.
    @Test func emptyMeshYieldsNoChains() {
        let g = MeshGraph(positions: positions)
        #expect(g.reach(targets: ["W", "T"], meshSystems: []).isEmpty)
    }

    /// Determinism is a requirement, not a nicety: the brain recomputes this
    /// graph from scratch every 5-second tick with no memory of what it
    /// decided last time. If a genuine exact tie between two symmetric
    /// routes resolves inconsistently, `firstHop` could flap between ticks
    /// and thrash the fleet. MESH -- A -- T and MESH -- B -- T are exactly
    /// symmetric (same relay count, same total distance); the tie must
    /// always resolve the same way — to "A" (lexicographically first).
    ///
    /// This is proven geometry-independently: the SAME two physical
    /// positions are used in both runs, but which designation ("A" or "B")
    /// occupies which position is swapped between them. If the winner were
    /// actually decided by position (e.g. by `neighbours(of:)`'s grid scan
    /// order, or by which literal happened to be built first) rather than
    /// by designation, swapping the labels would flip — or at least
    /// destabilize — the outcome. It doesn't: "A" wins both times, which
    /// isolates designation as the deciding factor.
    @Test func exactTieBreaksDeterministicallyOnDesignation() throws {
        // MESH-T direct is 10 ly (out of range); each of the two positions
        // below is exactly 7.071 ly from both MESH and T, a genuine exact
        // tie on (relays, dist) between whichever labels occupy them.
        let mesh = Position(x: 0, y: 0, z: 0)
        let target = Position(x: 0, y: 0, z: 10)
        let positionOne = Position(x: 5, y: 0, z: 5)
        let positionTwo = Position(x: -5, y: 0, z: 5)

        var results: [Chain] = []
        for (aPosition, bPosition) in [(positionOne, positionTwo), (positionTwo, positionOne)] {
            let positions: [String: Position] = [
                "MESH": mesh,
                "A": aPosition,
                "B": bPosition,
                "T": target,
            ]
            let g = MeshGraph(positions: positions)
            let chains = g.reach(targets: ["T"], meshSystems: ["MESH"])
            let c = try #require(chains["T"])
            results.append(c)
        }

        for c in results {
            #expect(c.firstHop == "A")
            #expect(c.waypoints == ["A", "T"])
        }
        #expect(results[0] == results[1], "the tie must resolve identically regardless of which position each designation occupies")
    }

    // MARK: - Randomized cross-check against a brute-force reference

    /// A deterministic, seedable PRNG (SplitMix64). Fixed integer seeds only
    /// — never `SystemRandomNumberGenerator` — so any disagreement this
    /// cross-check finds reproduces exactly from the seed alone, rather than
    /// depending on when the test happened to run.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Exhaustive reference, independent of `MeshGraph`/Dijkstra: enumerates
    /// every SIMPLE path (no repeated systems) from any mesh source to
    /// `target` within `hopRange` via plain pairwise-distance adjacency
    /// (not `neighbours(of:)`), branch-and-bound pruned on the same
    /// `(relays, dist)` key `reach` uses, and returns the lexicographically
    /// cheapest on `(relays, dist)`.
    private static func bruteForceCheapest(
        positions: [String: Position],
        hopRange: Double,
        meshSystems: Set<String>,
        target: String
    ) -> (relays: Int, dist: Double, firstHop: String)? {
        guard !meshSystems.contains(target) else { return nil } // already meshed — not a grow target
        var best: (relays: Int, dist: Double, firstHop: String)?

        func dfs(current: String, visited: Set<String>, relays: Int, dist: Double, firstHop: String?) {
            if let best, (relays, dist) >= (best.relays, best.dist) { return } // can't improve from here
            if current == target, relays > 0, let firstHop {
                best = (relays, dist, firstHop)
                return // a simple path can't usefully extend past its own target
            }
            guard let currentPosition = positions[current] else { return }
            for (candidate, candidatePosition) in positions where !visited.contains(candidate) {
                let stepDist = currentPosition.distance(to: candidatePosition)
                guard stepDist <= hopRange else { continue }
                let addedRelay = meshSystems.contains(candidate) ? 0 : 1
                let nextFirstHop = firstHop ?? (meshSystems.contains(candidate) ? nil : candidate)
                dfs(
                    current: candidate,
                    visited: visited.union([candidate]),
                    relays: relays + addedRelay,
                    dist: dist + stepDist,
                    firstHop: nextFirstHop
                )
            }
        }

        for source in meshSystems where positions[source] != nil {
            dfs(current: source, visited: [source], relays: 0, dist: 0, firstHop: nil)
        }
        return best
    }

    /// `reach` is the single computation both Grow and Prune will read in
    /// opposite directions, so it's worth checking against an independent,
    /// exhaustive reference — not just the hand-picked worlds above. Builds
    /// ~2,000 deterministic small random worlds (12 systems, 2-3 mesh
    /// sources, one random unmeshed target each) and asserts `reach`'s
    /// answer (relay count, distance, first hop, and reachability itself)
    /// matches brute-force enumeration of every simple path.
    @Test func randomizedCrossCheckAgainstBruteForce() throws {
        let hopRange = 6.0
        let systemNames = (0..<12).map { "S\($0)" }

        for seed in UInt64(1)...2000 {
            var rng = SplitMix64(seed: seed)
            var positions: [String: Position] = [:]
            for name in systemNames {
                positions[name] = Position(
                    x: Double.random(in: -8...8, using: &rng),
                    y: Double.random(in: -8...8, using: &rng),
                    z: Double.random(in: -8...8, using: &rng)
                )
            }
            let meshCount = Int.random(in: 2...3, using: &rng)
            let meshSystems = Set(systemNames.shuffled(using: &rng).prefix(meshCount))
            let remaining = systemNames.filter { !meshSystems.contains($0) }
            guard let target = remaining.shuffled(using: &rng).first else { continue }

            let g = MeshGraph(positions: positions, hopRange: hopRange)
            let chains = g.reach(targets: [target], meshSystems: meshSystems)
            let reference = Self.bruteForceCheapest(
                positions: positions, hopRange: hopRange, meshSystems: meshSystems, target: target
            )

            switch (chains[target], reference) {
            case (nil, nil):
                continue
            case let (.some(c), .some(r)):
                #expect(c.relaysRemaining == r.relays, "seed \(seed): relay count mismatch")
                #expect(c.hopDistance == r.dist, "seed \(seed): distance mismatch")
                #expect(c.firstHop == r.firstHop, "seed \(seed): first-hop mismatch")
            default:
                Issue.record(
                    "seed \(seed): reachability mismatch — reach=\(String(describing: chains[target])), brute force=\(String(describing: reference))"
                )
            }
        }
    }
}
