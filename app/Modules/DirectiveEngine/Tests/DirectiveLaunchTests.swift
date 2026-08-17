//
//  DirectiveLaunchTests.swift
//  Replicould — DirectiveEngine tests
//
//  The one row factory: per-kind fleet tag, and the invariants no site owns.
//

import Foundation
import GameModels
import Testing

@testable import DirectiveEngine

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private let theatre = Theatre(
    depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
    readiness: .operational, stock: 50_000
)

@Suite("Directive.launch")
struct DirectiveLaunchTests {
    @Test func aSurveyRunCarriesTheTheatreScopedSurveyTag() {
        let row = Directive.launch(
            .init(kind: .surveyRun, deviceCode: "VESSEL-1", theatre: theatre, roamCentre: "SOL"),
            id: "D1", now: now
        )
        #expect(row.id == "D1")
        #expect(row.kind == .surveyRun)
        #expect(row.status == .running)
        #expect(row.targetIndex == 0)
        #expect(row.step == SurveyRun().firstStep)
        #expect(row.stepStartedAt == now)
        #expect(row.createdAt == now)
        #expect(row.updatedAt == now)
        #expect(row.attentionReason == nil)
        #expect(row.deletedAt == nil)
        #expect(row.theatreDepot == theatre.depot)
        #expect(row.roamCentre == "SOL")
        #expect(row.fleetTag == SurveyRun.fleetTag(forTheatre: theatre.depot).string)
        #expect(row.fleetTag == "auto:survey:ainalram-belt-1")
    }

    @Test func aSalvageRunCarriesTheTheatreScopedSalvageTag() {
        let row = Directive.launch(
            .init(kind: .salvageRun, deviceCode: "VESSEL-1", theatre: theatre), id: "D2", now: now
        )
        #expect(row.step == SalvageRun().firstStep)
        #expect(row.fleetTag == SalvageRun.fleetTag(forTheatre: theatre.depot).string)
        #expect(row.theatreDepot == theatre.depot)
    }

    @Test func aGeneralHaulRunCarriesTheTheatreScopedHaulTag() {
        let row = Directive.launch(
            .init(kind: .haulRun, deviceCode: "CTRL-1", theatre: theatre), id: "D3", now: now
        )
        #expect(row.step == HaulRun().firstStep)
        #expect(row.fleetTag == HaulRun.fleetTag(forTheatre: theatre.depot).string)
    }

    /// R1: a mine ferry wears `auto:mine:<belt>`, never `auto:haul:<belt>` —
    /// retagging it would drop it out of every `auto:mine` query.
    @Test func aMineFerryCarriesTheBeltScopedMineTag() {
        let row = Directive.launch(
            .init(kind: .haulRun, deviceCode: "CTRL-2", theatre: theatre, targets: ["ARIDOS-BELT-2"],
                  controllerCode: "CTRL-2", belt: "ARIDOS-BELT-2"),
            id: "D4", now: now
        )
        #expect(row.fleetTag == "auto:mine:aridos-belt-2")
        #expect(row.fleetTag != FleetTag(goal: .haul, scope: .belt(designation: "ARIDOS-BELT-2")).string)
        #expect(row.controllerCode == "CTRL-2")
        #expect(row.targets == ["ARIDOS-BELT-2"])
        #expect(row.theatreDepot == theatre.depot)
    }

    @Test func aMineRunCarriesTheTheatreScopedMineTag() {
        let row = Directive.launch(
            .init(kind: .mineRun, deviceCode: "CARRIER-1", theatre: theatre, targets: ["ARIDOS-BELT-2"],
                  returnToOrigin: true, originDesignation: theatre.system),
            id: "D5", now: now
        )
        #expect(row.step == MineRun().firstStep)
        #expect(row.fleetTag == MineRecipe.fleetTag(forTheatre: theatre.depot).string)
        #expect(row.returnToOrigin)
        #expect(row.originDesignation == theatre.system)
    }

    @Test func aMineFleetPrintCarriesTheTheatreScopedMineTag() {
        let row = Directive.launch(
            .init(kind: .mineFleetPrint, deviceCode: "HUB-1", theatre: theatre), id: "D6", now: now
        )
        #expect(row.step == MineFleetPrint().firstStep)
        #expect(row.fleetTag == MineRecipe.fleetTag(forTheatre: theatre.depot).string)
        #expect(row.fleetTag != MineRecipe.fleetTag.string)
    }

    @Test func anEventRunCarriesTheTheatreScopedEventTagAndBothHulls() {
        let row = Directive.launch(
            .init(kind: .eventRun, deviceCode: "CARRIER-1", theatre: theatre, targets: ["SOL-3"],
                  returnToOrigin: true, originDesignation: theatre.system, freighterCode: "FREIGHT-1"),
            id: "D7", now: now
        )
        #expect(row.step == EventRun().firstStep)
        #expect(row.fleetTag == EventRun.fleetTag(forTheatre: theatre.depot).string)
        #expect(row.freighterCode == "FREIGHT-1")
    }

    @Test func aRelayRunIsUntagged() {
        let row = Directive.launch(
            .init(kind: .relayRun, deviceCode: "CARRIER-1", theatre: theatre, targets: ["SOL"],
                  returnToOrigin: true, originDesignation: "AINALRAM", sourceRelayCode: "RELAY-9"),
            id: "D8", now: now
        )
        #expect(row.step == RelayRun().firstStep)
        #expect(row.fleetTag == nil)
        #expect(row.sourceRelayCode == "RELAY-9")
        #expect(row.theatreDepot == theatre.depot)
    }

    @Test func aRestockRunIsUntagged() {
        let row = Directive.launch(
            .init(kind: .restockRun, deviceCode: "HUB-1", theatre: theatre, targets: ["SOL"]),
            id: "D9", now: now
        )
        #expect(row.step == RestockRun().firstStep)
        #expect(row.fleetTag == nil)
    }

    @Test func anEventCourierPrintIsUntagged() {
        let row = Directive.launch(
            .init(kind: .eventCourierPrint, deviceCode: "HUB-1", theatre: theatre), id: "D10", now: now
        )
        #expect(row.step == EventCourierPrint().firstStep)
        #expect(row.fleetTag == nil)
    }

    @Test func noTheatreLeavesTheRowUnstampedAndTheTagUnscoped() {
        let row = Directive.launch(
            .init(kind: .surveyRun, deviceCode: "VESSEL-1", theatre: nil), id: "D11", now: now
        )
        #expect(row.theatreDepot == nil)
        #expect(row.fleetTag == SurveyRun.defaultFleetTag.string)
    }

    /// Literal steps, not `MissionRegistry.firstStep(for:)` — comparing against
    /// the very expression the factory evaluates would compare a value to
    /// itself. Sweeping `allCases` also proves no kind trips the precondition.
    @Test func everyKindLaunchesOnItsOwnFirstStep() {
        let expected: [DirectiveKind: String] = [
            .surveyRun: "preflight", .salvageRun: "preflight", .haulRun: "preflight",
            .mineRun: "preflight", .eventRun: "preflight", .relayRun: "acquire",
            .restockRun: "stocking", .mineFleetPrint: "stocking", .eventCourierPrint: "printing",
        ]
        for kind in DirectiveKind.allCases {
            let row = Directive.launch(.init(kind: kind, deviceCode: "D", theatre: theatre), id: "X", now: now)
            #expect(row.step == expected[kind], "\(kind.rawValue)")
        }
    }
}
