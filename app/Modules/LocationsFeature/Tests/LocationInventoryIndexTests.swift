//
//  LocationInventoryIndexTests.swift
//  LocationsFeature
//

import Testing
import UniverseModels
@testable import LocationsFeature

@Suite struct LocationInventoryIndexTests {
    /// The footprint overlay the tree reads: holdings at a moon, at a Lagrange
    /// point, and at a system whose designation is a prefix of another system's.
    private let footprints: [String: LocationCounts] = [
        "SOL-3-1": LocationCounts(resources: 40),
        "SOL-5-L4": LocationCounts(resources: 60),
        "SOL-BELT-1": LocationCounts(resourceSites: 1, resources: 0),
        "SOLARIS-1": LocationCounts(resources: 500),
        "VEGA": LocationCounts(resources: 7),
    ]

    /// The roll-up must agree with the whole-table scan it replaces: a location
    /// counts toward a designation when it *is* that designation or sits beneath
    /// it, and `SOL` must never claim `SOLARIS-1`.
    @Test func rolledUpMatchesTheScanItReplaces() {
        let index = LocationInventoryIndex(footprints: footprints)

        func scan(_ designation: String) -> Double {
            let prefix = designation + "-"
            return footprints.reduce(0.0) { sum, entry in
                (entry.key == designation || entry.key.hasPrefix(prefix))
                    ? sum + Double(entry.value.resources)
                    : sum
            }
        }

        for designation in ["SOL", "SOL-3", "SOL-3-1", "SOL-5", "SOL-5-L4",
                            "SOL-BELT-1", "SOLARIS", "SOLARIS-1", "VEGA", "RIGEL"] {
            #expect(index.rolledUp(at: designation) == scan(designation), "\(designation)")
        }
    }

    @Test func rollsHoldingsUpToEveryAncestor() {
        let index = LocationInventoryIndex(footprints: footprints)
        #expect(index.rolledUp(at: "SOL") == 100)     // 40 at the moon + 60 at the L-point
        #expect(index.rolledUp(at: "SOL-3") == 40)
        #expect(index.rolledUp(at: "SOL-5") == 60)
        #expect(index.rolledUp(at: "SOLARIS") == 500)
        #expect(index.rolledUp(at: "RIGEL") == 0)
    }

    /// A row that asks about itself alone (a moon, a belt, an L-point) must not
    /// see its descendants' holdings.
    @Test func resourcesAtAsksAboutThatLocationAlone() {
        let index = LocationInventoryIndex(footprints: footprints)
        #expect(index.resources(at: "SOL") == 0)
        #expect(index.resources(at: "SOL-3-1") == 40)
        #expect(index.resources(at: "SOL-BELT-1") == 0)
    }

    /// The system row flags holdings anywhere beneath it; a sibling system whose
    /// designation merely shares a prefix does not.
    @Test func systemRowFlagsDescendantHoldings() {
        let star = Star(
            designation: "SOL", spectralType: "G2", color: "yellow-white",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 8,
            explored: true, hasLife: nil, entryPoint: nil, createdAt: .distantPast
        )
        let solaris = Star(
            designation: "SOLARIS", spectralType: "K1", color: "orange",
            positionX: 1, positionY: 0, positionZ: 0, estimatedPlanets: 2,
            explored: true, hasLife: nil, entryPoint: nil, createdAt: .distantPast
        )
        let rigel = Star(
            designation: "RIGEL", spectralType: "B8", color: "blue",
            positionX: 2, positionY: 0, positionZ: 0, estimatedPlanets: 1,
            explored: true, hasLife: nil, entryPoint: nil, createdAt: .distantPast
        )
        let forest = LocationTree.forest(
            stars: [star, solaris, rigel], details: [:], footprints: footprints,
            myPosition: nil, filter: .all, sort: .alphabetical
        )
        func badges(_ id: String) -> [String] {
            forest.first { $0.id == id }?.badges.map(\.symbol) ?? []
        }
        #expect(badges("SOL").contains("shippingbox"))
        #expect(badges("SOLARIS").contains("shippingbox"))
        #expect(!badges("RIGEL").contains("shippingbox"))
    }

    /// The inventory sort keys each system once; the order must still be by
    /// descending holdings with the designation breaking ties.
    @Test func inventorySortRanksByDescendantHoldings() {
        func star(_ designation: String, _ x: Double) -> Star {
            Star(
                designation: designation, spectralType: "G2", color: "white",
                positionX: x, positionY: 0, positionZ: 0, estimatedPlanets: 1,
                explored: true, hasLife: nil, entryPoint: nil, createdAt: .distantPast
            )
        }
        let forest = LocationTree.forest(
            stars: [star("SOL", 0), star("SOLARIS", 1), star("VEGA", 2), star("RIGEL", 3)],
            details: [:], footprints: footprints,
            myPosition: nil, filter: .all, sort: .inventory
        )
        #expect(forest.map(\.id) == ["SOLARIS", "SOL", "VEGA", "RIGEL"])
    }
}
