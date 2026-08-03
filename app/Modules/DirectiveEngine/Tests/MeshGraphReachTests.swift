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

    /// A target nearer a SECOND mesh system than the first must route from
    /// the nearer source, not always from the first-listed one.
    @Test func multiSourcePicksNearerSource() throws {
        let positions: [String: Position] = [
            "MESH1": .init(x: 0, y: 0, z: 0),
            "MESH2": .init(x: 20, y: 0, z: 0),
            "NEAR2": .init(x: 24, y: 0, z: 0), // one hop from MESH2 only
        ]
        let g = MeshGraph(positions: positions)
        let chains = g.reach(targets: ["NEAR2"], meshSystems: ["MESH1", "MESH2"])
        let c = try #require(chains["NEAR2"])
        #expect(c.firstHop == "NEAR2")
        #expect(c.relaysRemaining == 1)
        #expect(c.hopDistance == 4)
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
    /// routes resolves inconsistently (e.g. because it silently rode on
    /// Dictionary iteration order), `firstHop` could flap between ticks and
    /// thrash the fleet. MESH -- A -- T and MESH -- B -- T are exactly
    /// symmetric (same relay count, same total distance); the tie must
    /// always resolve the same way — here, to "A" (lexicographically first)
    /// — regardless of how the input dictionaries were built.
    @Test func exactTieBreaksDeterministicallyOnDesignation() throws {
        // Two insertion orders for the SAME logical content: Dictionary
        // iteration order is not guaranteed stable across instances, so
        // building from differently-ordered sequences is the closest a unit
        // test can get to stressing that non-guarantee.
        // MESH-T direct is 10 ly (out of range); A and B are each exactly
        // 7.071 ly from both MESH and T, a genuine exact tie on (relays,
        // dist) between the two routes.
        let forwardOrder: [(String, Position)] = [
            ("MESH", .init(x: 0, y: 0, z: 0)),
            ("A", .init(x: 5, y: 0, z: 5)),
            ("B", .init(x: -5, y: 0, z: 5)),
            ("T", .init(x: 0, y: 0, z: 10)),
        ]
        let reverseOrder = Array(forwardOrder.reversed())

        var results: [Chain] = []
        for order in [forwardOrder, reverseOrder] {
            let positions = Dictionary(uniqueKeysWithValues: order)
            let g = MeshGraph(positions: positions)
            let meshSystems = Set(order.map(\.0)).intersection(["MESH"])
            let chains = g.reach(targets: ["T"], meshSystems: meshSystems)
            let c = try #require(chains["T"])
            results.append(c)
        }

        for c in results {
            #expect(c.firstHop == "A")
            #expect(c.waypoints == ["A", "T"])
        }
        #expect(results[0] == results[1], "the tie must resolve identically across differently-ordered input")
    }
}
