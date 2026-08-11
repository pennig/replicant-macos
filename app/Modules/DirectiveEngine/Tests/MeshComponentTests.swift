//
//  MeshComponentTests.swift
//  Replicould — DirectiveEngine
//
//  `MeshGraph.components(of:)`: disjoint clusters, a bridging merge, and an
//  unplaceable system standing alone.
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
