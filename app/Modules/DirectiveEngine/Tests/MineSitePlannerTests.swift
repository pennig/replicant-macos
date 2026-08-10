//
//  MineSitePlannerTests.swift
//  Replicould — DirectiveEngine
//
//  Task 5: MineSitePlanner ranks candidate belts for a new mine — class,
//  then the rares/conductive scarcity bonus, then hub distance, then
//  designation as the stable last tie-break.
//

import Foundation
import Testing
import UniverseModels
@testable import DirectiveEngine

private func siteView(
    belts: [String: [BeltInfo]],
    meshSystems: Set<String>,
    positions: [String: Position],
    hub: String? = "AINALRAM-BELT-1"
) -> WorldView {
    WorldView(
        devices: [:], starPositions: positions, meshSystems: meshSystems,
        salvageUnits: [:], eventSystems: [], hubLocation: hub,
        beltsBySystem: belts, now: Date(timeIntervalSince1970: 1_750_000_000)
    )
}

private func belt(_ des: String, _ cls: BeltClass, rares: String = "scarce", conductive: String = "scarce") -> BeltInfo {
    BeltInfo(designation: des, beltClass: cls, richness: ["rares": rares, "conductive": conductive])
}

@Suite("MineSitePlanner — the siting key")
struct MineSitePlannerTests {
    @Test("a far rich belt beats a near sparse one")
    func classDominatesDistance() {
        let view = siteView(
            belts: ["NEAR": [belt("NEAR-BELT-1", .sparse)], "FAR": [belt("FAR-BELT-1", .rich)]],
            meshSystems: ["AINALRAM", "NEAR", "FAR"],
            positions: ["AINALRAM": .init(x: 0, y: 0, z: 0), "NEAR": .init(x: 1, y: 0, z: 0), "FAR": .init(x: 30, y: 0, z: 0)]
        )
        #expect(MineSitePlanner.site(view: view, occupiedBelts: [])?.belt == "FAR-BELT-1")
    }

    @Test("rares at moderate outranks conductive at high")
    func raresOutranksConductive() {
        #expect(MineSitePlanner.scarceBonus(richness: ["rares": "moderate", "conductive": "scarce"]) == 2)
        #expect(MineSitePlanner.scarceBonus(richness: ["rares": "scarce", "conductive": "high"]) == 1)
        #expect(MineSitePlanner.scarceBonus(richness: ["rares": "moderate", "conductive": "moderate"]) == 3)
    }

    @Test("the bonus breaks a same-class tie whatever the distances")
    func bonusBreaksClassTie() {
        let view = siteView(
            belts: [
                "NEAR": [belt("NEAR-BELT-1", .rich)],
                "FAR": [belt("FAR-BELT-1", .rich, rares: "moderate")],
            ],
            meshSystems: ["AINALRAM", "NEAR", "FAR"],
            positions: ["AINALRAM": .init(x: 0, y: 0, z: 0), "NEAR": .init(x: 1, y: 0, z: 0), "FAR": .init(x: 30, y: 0, z: 0)]
        )
        #expect(MineSitePlanner.site(view: view, occupiedBelts: [])?.belt == "FAR-BELT-1")
    }

    @Test("an unmeshed system's belt is never a candidate")
    func unmeshedFiltered() {
        let view = siteView(
            belts: ["OFFMESH": [belt("OFFMESH-BELT-1", .rich)]],
            meshSystems: ["AINALRAM"],
            positions: ["AINALRAM": .init(x: 0, y: 0, z: 0), "OFFMESH": .init(x: 5, y: 0, z: 0)]
        )
        #expect(MineSitePlanner.site(view: view, occupiedBelts: []) == nil)
    }

    @Test("an occupied belt is filtered while its unoccupied twin survives")
    func occupiedFiltered() {
        let view = siteView(
            belts: ["S": [belt("S-BELT-1", .rich), belt("S-BELT-2", .moderate)]],
            meshSystems: ["AINALRAM", "S"],
            positions: ["AINALRAM": .init(x: 0, y: 0, z: 0), "S": .init(x: 5, y: 0, z: 0)]
        )
        #expect(MineSitePlanner.site(view: view, occupiedBelts: ["S-BELT-1"])?.belt == "S-BELT-2")
    }

    @Test("no hub or no placeable position yields no site")
    func noHubNoSite() {
        let noHub = siteView(
            belts: ["S": [belt("S-BELT-1", .rich)]], meshSystems: ["S"],
            positions: ["S": .init(x: 5, y: 0, z: 0)], hub: nil
        )
        #expect(MineSitePlanner.site(view: noHub, occupiedBelts: []) == nil)
    }

    @Test("designation is the stable last tie-break")
    func stableTieBreak() {
        let view = siteView(
            belts: ["S": [belt("S-BELT-2", .rich), belt("S-BELT-1", .rich)]],
            meshSystems: ["AINALRAM", "S"],
            positions: ["AINALRAM": .init(x: 0, y: 0, z: 0), "S": .init(x: 5, y: 0, z: 0)]
        )
        #expect(MineSitePlanner.site(view: view, occupiedBelts: [])?.belt == "S-BELT-1")
    }
}
