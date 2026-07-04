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

    /// A system scanned while the app was closed reads `explored == false` in the
    /// stale bulk census, but its hydrated detail shows it's scanned. It must still
    /// land in the Explored filter (and out of Uncharted), matching its row's
    /// "N/N scanned" subtitle.
    @Test func hydratedScanOverridesStaleCensusExploredFlag() {
        let krios = Star(
            designation: "KRIOS", spectralType: "M6", color: "Red",
            positionX: 0, positionY: 0, positionZ: 0, estimatedPlanets: 2,
            explored: false, hasLife: true, entryPoint: "KRIOS-3-L4", createdAt: .distantPast
        )
        let scanned = StarSystem(
            designation: "KRIOS", systemScanned: true, planetsScanned: 3, planetsTotal: 3,
            planets: [Planet(designation: "KRIOS-3", type: "Terrestrial", recon: .scanned)]
        )
        let details = ["KRIOS": scanned]

        let explored = LocationTree.forest(
            stars: [krios], details: details, footprints: [:],
            myPosition: nil, filter: .explored, sort: .alphabetical
        )
        #expect(explored.map(\.id) == ["KRIOS"])

        let uncharted = LocationTree.forest(
            stars: [krios], details: details, footprints: [:],
            myPosition: nil, filter: .unexplored, sort: .alphabetical
        )
        #expect(uncharted.isEmpty)
    }

    /// Refreshing a cached system via the star-level `system(_:)` endpoint takes the
    /// fresh scan counts but must keep scanned-only detail the star-level response
    /// never carries — shops, megastructures, and richer per-body detail.
    @Test func mergingSystemDetailKeepsScannedOnlyDetail() {
        let cached = StarSystem(
            designation: "KRIOS", systemScanned: true, planetsScanned: 2, planetsTotal: 3,
            planets: [Planet(designation: "KRIOS-2", type: "Ocean World", recon: .scanned,
                             moons: [Moon(designation: "KRIOS-2-1")])],
            structures: [SpecialSite(designation: "KRIOS-MEGA-1", kind: .megastructure)],
            shops: [Shop(controllerCode: "SHOP1", shopName: "Outfitter", location: "KRIOS-2")]
        )
        // Star-level refresh: newer counts, fuller roster, but no shops/structures.
        let fresh = StarSystem(
            designation: "KRIOS", systemScanned: true, planetsScanned: 3, planetsTotal: 3,
            planets: [Planet(designation: "KRIOS-2", type: "Ocean World", recon: .visited),
                      Planet(designation: "KRIOS-3", type: "Super Earth", recon: .visited)]
        )

        let merged = cached.mergingSystemDetail(fresh)
        #expect(merged.planetsScanned == 3)                      // fresh counts win
        #expect(merged.planets.map(\.designation) == ["KRIOS-2", "KRIOS-3"])
        #expect(merged.shops.map(\.id) == ["SHOP1"])             // scanned-only, preserved
        #expect(merged.structures.map(\.designation) == ["KRIOS-MEGA-1"])
        // Richer body (scanned, with a moon) kept over the fresh estimated stub.
        let krios2 = try! #require(merged.planets.first { $0.designation == "KRIOS-2" })
        #expect(krios2.recon == .scanned)
        #expect(krios2.moons.map(\.designation) == ["KRIOS-2-1"])
    }
}
