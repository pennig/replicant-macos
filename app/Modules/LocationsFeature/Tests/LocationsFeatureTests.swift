//
//  LocationsFeatureTests.swift
//  LocationsFeature
//

import Testing
import UniverseModels
@testable import LocationsFeature

@Suite struct LocationsFeatureTests {
    @Test func forestFiltersUnexploredAndBuildsHierarchy() {
        let sol = Star(
            designation: "SOL", spectralType: "G2", color: "yellow-white",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 8,
            explored: true, hasLife: true, entryPoint: "SOL-5-L4", createdAt: .distantPast
        )
        let dabah = Star(
            designation: "DABAH", spectralType: "M9", color: "Red",
            positionX: 5, positionY: 0, positionZ: 0, estimatedPlanets: 6,
            explored: false, hasLife: nil, entryPoint: nil, createdAt: .distantPast
        )
        let system = StarSystem(
            designation: "SOL", systemScanned: true, planetsScanned: 1, planetsTotal: 1,
            belts: [Belt(designation: "SOL-BELT-1", sites: [ResourceSite(designation: "SOL-BELT-1-SITE-0")])],
            planets: [Planet(designation: "SOL-3", type: "Terrestrial", recon: .scanned,
                             moons: [Moon(designation: "SOL-3-1")])]
        )

        let all = LocationTree.forest(
            stars: [sol, dabah], details: ["SOL": system], footprints: [:],
            myPosition: nil, filter: .all, sort: .alphabetical
        )
        #expect(all.map(\.id) == ["DABAH", "SOL"])
        let solNode = try! #require(all.first { $0.id == "SOL" })
        // Belt + planet as children; planet has a moon child.
        #expect(solNode.children?.map(\.id) == ["SOL-BELT-1", "SOL-3"])
        #expect(solNode.children?.first(where: { $0.id == "SOL-3" })?.children?.map(\.id) == ["SOL-3-1"])

        let explored = LocationTree.forest(
            stars: [sol, dabah], details: [:], footprints: [:],
            myPosition: nil, filter: .explored, sort: .alphabetical
        )
        #expect(explored.map(\.id) == ["SOL"])
    }
}
