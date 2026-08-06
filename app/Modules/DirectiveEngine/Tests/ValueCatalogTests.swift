//
//  ValueCatalogTests.swift
//  Replicould — DirectiveEngine
//
//  Task 10: the value model over `WorldView`'s known-value signals (salvage +
//  belts + events) the next task's ranking pass sorts on. Survey frontier — a
//  bare star position with no salvage/belt/event — is deliberately excluded;
//  growing toward unexplored space is a different capability. Already-meshed
//  systems are excluded too — they're already reached.
//
//  The locked tier ordering is `event(5) ▸ richBelt(4) ▸ moderateBelt(3) ▸
//  stockpile(2) ▸ salvage(1) ▸ sparseBelt(0)`. Two placements in it are
//  deliberate rather than mistakes: salvage sits BETWEEN the two belt tiers,
//  not below both, and stockpile sits above salvage but below every belt —
//  already-extracted units need no mining cycle, but a belt never depletes.
//

import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("ValueCatalog")
struct ValueCatalogTests {
    @Test func bestTierIsTheMaxHeld() {
        var view = WorldView.empty(meshSystems: ["SOL"])
        view = view.with(salvageUnits: ["VEGA": 3200], eventSystems: ["VEGA"])  // event beats salvage
        let targets = ValueCatalog.build(from: view)
        let vega = try! #require(targets.first { $0.system == "VEGA" })
        #expect(vega.bestTier == .event)
        #expect(vega.salvageUnits == 3200)
        #expect(vega.hasEvent)
    }

    /// A system holding nothing but already-mined units is a target in its own
    /// right. Nothing else here yields one — no assay, no belt, no event — so
    /// the pile is doing all the work.
    @Test func stockpileOnlySystemProducesTargetAtStockpileTier() throws {
        let view = WorldView.empty(meshSystems: ["SOL"]).with(stockpileUnits: ["COCIBOLCU": 2206])
        let target = try #require(ValueCatalog.build(from: view).first { $0.system == "COCIBOLCU" })
        #expect(target.bestTier == .stockpile)
        #expect(target.stockpileUnits == 2206)
        #expect(target.salvageUnits == 0)
    }

    /// A pile in a system the mesh already reaches is not a grow target: the
    /// `ferry` that collects it can already be issued, so there is nothing left
    /// to plant. Prune is the half that keeps that relay standing.
    @Test func meshedSystemWithAStockpileIsNotATarget() {
        let view = WorldView.empty(meshSystems: ["ORASALAS"])
            .with(stockpileUnits: ["ORASALAS": 1191])
        #expect(ValueCatalog.build(from: view).allSatisfy { $0.system != "ORASALAS" })
    }

    /// The tier's place in the order, proven from both sides at one system.
    /// Units already on the ground beat an unmined assay — no mining cycle
    /// stands between us and them — but lose to a belt that never depletes.
    @Test func stockpileOutranksSalvageAndLosesToAModerateBelt() throws {
        let overSalvage = WorldView.empty().with(
            salvageUnits: ["MIXED": 99_999], stockpileUnits: ["MIXED": 1]
        )
        let salvageCase = try #require(ValueCatalog.build(from: overSalvage).first)
        #expect(salvageCase.bestTier == .stockpile, "a single mined unit still outranks any assay")

        let underBelt = WorldView.empty().with(
            beltsBySystem: ["MIXED": [BeltInfo(designation: "MIXED-BELT-1", beltClass: .moderate)]],
            stockpileUnits: ["MIXED": 99_999]
        )
        let beltCase = try #require(ValueCatalog.build(from: underBelt).first)
        #expect(beltCase.bestTier == .moderateBelt, "a perpetual belt outranks any finite pile")
    }

    @Test func meshedSystemsAreNotTargets() {
        let view = WorldView.empty(meshSystems: ["SOL"]).with(salvageUnits: ["SOL": 999])
        #expect(ValueCatalog.build(from: view).allSatisfy { $0.system != "SOL" })
    }

    @Test func surveyFrontierIsExcluded() {
        // A system with a position but no salvage/belt/event yields no target.
        let view = WorldView.empty(meshSystems: ["SOL"]).with(starPositions: ["DARK": .init(x: 3, y: 0, z: 0)])
        #expect(ValueCatalog.build(from: view).isEmpty)
    }

    /// A system holding only belts (no salvage, no event) still yields a
    /// target, tiered on its richest belt class.
    @Test func beltOnlySystemProducesTargetAtRightTier() {
        let view = WorldView.empty().with(
            beltsBySystem: ["KRIOS": [BeltInfo(designation: "KRIOS-BELT-1", beltClass: .rich)]]
        )
        let target = try! #require(ValueCatalog.build(from: view).first { $0.system == "KRIOS" })
        #expect(target.bestTier == .richBelt)
        #expect(target.salvageUnits == 0)
        #expect(!target.hasEvent)
    }

    /// A system with only sparse belts still lands as a target at the bottom
    /// tier — present, not conflated with "no value."
    @Test func sparseOnlyBeltSystemLandsAtSparseTier() {
        let view = WorldView.empty().with(
            beltsBySystem: ["DUST": [BeltInfo(designation: "DUST-BELT-1", beltClass: .sparse)]]
        )
        let target = try! #require(ValueCatalog.build(from: view).first { $0.system == "DUST" })
        #expect(target.bestTier == .sparseBelt)
    }

    /// A mix of belt classes at one system: `bestTier` follows the richest
    /// class present, and `beltCount` reports the full per-class histogram —
    /// not just the count at the winning tier — so a later ranking pass can
    /// read exact per-class magnitude.
    @Test func beltCountTracksEachClassAcrossAMix() {
        let view = WorldView.empty().with(
            beltsBySystem: [
                "MIX": [
                    BeltInfo(designation: "MIX-BELT-1", beltClass: .rich),
                    BeltInfo(designation: "MIX-BELT-2", beltClass: .rich),
                    BeltInfo(designation: "MIX-BELT-3", beltClass: .moderate),
                ]
            ]
        )
        let target = try! #require(ValueCatalog.build(from: view).first { $0.system == "MIX" })
        #expect(target.bestTier == .richBelt)
        #expect(target.beltCount[.rich] == 2)
        #expect(target.beltCount[.moderate] == 1)
        #expect(target.beltCount[.sparse] == nil)
    }

    /// A belt whose class could never be resolved (`BeltClass.classify` →
    /// `nil`) never becomes a `BeltInfo` in the first place, so a system
    /// whose only belt was unclassifiable shows up here as an empty belt
    /// array — with nothing else at the system, that yields no target,
    /// mirroring survey exclusion rather than defaulting to some class.
    @Test func unknownClassBeltWithNothingElseYieldsNoTarget() {
        let view = WorldView.empty().with(beltsBySystem: ["FOG": []])
        #expect(ValueCatalog.build(from: view).isEmpty)
    }

    /// `salvageUnits` magnitude is carried through exactly, not rounded or
    /// re-derived.
    @Test func salvageMagnitudeIsCarriedThroughAccurately() {
        let view = WorldView.empty().with(salvageUnits: ["ORE": 1837.5])
        let target = try! #require(ValueCatalog.build(from: view).first { $0.system == "ORE" })
        #expect(target.bestTier == .salvage)
        #expect(target.salvageUnits == 1837.5)
    }

    /// The winning tier never zeroes out the other fields — a system whose
    /// best tier is `event` still reports its real salvage magnitude and
    /// belt histogram, each field populated on its own terms rather than
    /// blanked by whichever tier won.
    @Test func fieldsArePopulatedIndependentlyOfTheWinningTier() {
        let view = WorldView.empty().with(
            salvageUnits: ["HUB": 500],
            eventSystems: ["HUB"],
            beltsBySystem: ["HUB": [BeltInfo(designation: "HUB-BELT-1", beltClass: .moderate)]]
        )
        let target = try! #require(ValueCatalog.build(from: view).first { $0.system == "HUB" })
        #expect(target.bestTier == .event)
        #expect(target.salvageUnits == 500)
        #expect(target.beltCount[.moderate] == 1)
        #expect(target.hasEvent)
    }
}
