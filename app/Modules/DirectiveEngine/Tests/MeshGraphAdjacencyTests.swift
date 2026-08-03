//
//  MeshGraphAdjacencyTests.swift
//  DirectiveEngineTests
//
//  Task 7: the spatial grid + hop adjacency. MeshGraph is pure, dependency-free
//  logic — no database, no clock — so every case here is a plain value-in,
//  value-out assertion against `neighbours(of:)`.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Mesh graph adjacency")
struct MeshGraphAdjacencyTests {
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

    /// The exact-boundary case: `distance == hopRange` must be INCLUDED
    /// ("within" is `<=`, not `<`), and the very next representable step past
    /// it must be excluded. The random cloud below stresses points *near* the
    /// boundary but — because its coordinates are evenly spaced — never lands
    /// a pair exactly on it, so this is the one test that pins the `<=`
    /// itself.
    @Test func boundaryIsInclusiveNotExclusive() {
        let positions: [String: Position] = [
            "A": .init(x: 0, y: 0, z: 0),
            "AtRange": .init(x: 7.5, y: 0, z: 0),        // exactly hopRange — included
            "JustOver": .init(x: 7.5001, y: 0, z: 0),    // a hair beyond — excluded
        ]
        let g = MeshGraph(positions: positions, hopRange: 7.5)
        #expect(Set(g.neighbours(of: "A")) == ["AtRange"])
    }

    /// A deterministic but irregular point cloud, checked against an O(n²)
    /// brute-force distance scan. Deliberately NOT the tidy `* 2` cloud a
    /// naive version of this test might use: integer-multiple-of-2
    /// coordinates against a 7.5 cell size produce squared-distance sums that
    /// are always a multiple of 4, and by the sum-of-three-squares theorem
    /// 15 (the integer just above the (7.5/2)²·... boundary term 14) is NOT
    /// expressible as a sum of three squares — so that tidier cloud's
    /// closest-excluded pair sits at distance exactly 8.0, nearly half a
    /// light-year clear of the 7.5 cutoff, and it never touches a diagonal
    /// grid corner in a stressed way either.
    ///
    /// This cloud uses three different irrational-ish per-axis step sizes
    /// (0.97, 1.3, 1.1) and an offset that centers the range on zero, so:
    ///  - it spans roughly 5 grid cells on X, 5 on Y, 4 on Z (hopRange=7.5),
    ///    including negative *and* positive cells — exercising `.rounded(.down)`
    ///    on both sides of zero;
    ///  - of the ~1,600 in-range pairs, over 500 sit in cells that differ on
    ///    two or more axes at once, i.e. genuinely diagonal neighbour-cell
    ///    lookups, not just face-adjacent ones;
    ///  - the closest excluded pair sits only ~0.04 ly outside the cutoff and
    ///    the closest included pair only ~0.02 ly inside it — verified with a
    ///    standalone script before writing this test, not eyeballed.
    @Test func gridMatchesBruteForceOnRandomCloud() {
        var positions: [String: Position] = [:]
        for i in 0..<200 {
            let x = Double(i % 29) * 0.97 - 12
            let y = Double((i * 13) % 23) * 1.3 - 12
            let z = Double((i * 7) % 17) * 1.1 - 8
            positions["S\(i)"] = .init(x: x, y: y, z: z)
        }
        let g = MeshGraph(positions: positions, hopRange: 7.5)
        for (s, p) in positions {
            let brute = Set(positions.filter { $0.key != s && $0.value.distance(to: p) <= 7.5 }.keys)
            #expect(Set(g.neighbours(of: s)) == brute, "grid disagrees at \(s)")
        }
    }

    /// Querying a system that isn't in the graph at all — not an error case,
    /// just an empty result.
    @Test func unknownSystemHasNoNeighbours() {
        let positions: [String: Position] = [
            "A": .init(x: 0, y: 0, z: 0),
        ]
        let g = MeshGraph(positions: positions, hopRange: 7.5)
        #expect(g.neighbours(of: "DOES-NOT-EXIST") == [])
    }

    /// Two systems at the identical position (distance 0) are mutual
    /// neighbours, same as any other pair within range.
    @Test func duplicatePositionsAreMutualNeighbours() {
        let positions: [String: Position] = [
            "A": .init(x: 3, y: 3, z: 3),
            "B": .init(x: 3, y: 3, z: 3),
            "Far": .init(x: 100, y: 100, z: 100),
        ]
        let g = MeshGraph(positions: positions, hopRange: 7.5)
        #expect(Set(g.neighbours(of: "A")) == ["B"])
        #expect(Set(g.neighbours(of: "B")) == ["A"])
    }
}
