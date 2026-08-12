//
//  WhyViewTheatreTests.swift
//  Replicould — Directives feature
//
//  Theatres on the Directives list and the brain's why-view: `BrainWhy.groups(for:)`
//  sections the why-view by theatre, and `DirectiveRow`/`DirectivesFeature.State`
//  carry the theatre onto rows and their filter.
//

import ComposableArchitecture
import DirectiveEngine
import Foundation
import GameDatabase
import GameModels
import Testing
@testable import DirectivesFeature

@Suite("Directives and the why-view, grouped by theatre")
struct WhyViewTheatreTests {
    private func directiveFixture(
        id: String,
        deviceCode: String = "V1",
        theatreDepot: String? = nil
    ) -> Directive {
        Directive(
            id: id, kind: .salvageRun, status: .running, deviceCode: deviceCode,
            targets: [], targetIndex: 0, step: "step",
            stepStartedAt: Date(timeIntervalSince1970: 0),
            returnToOrigin: false, originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            theatreDepot: theatreDepot
        )
    }

    private func brainReportFixture(theatres: [Theatre]) -> BrainReport {
        BrainReport(
            decision: .idle(reason: "no grow or prune work"),
            ranked: [],
            theatres: theatres,
            limits: BrainWhyViewTests.calmLimits(),
            survey: .idle(reason: "no vessel is tagged auto:survey"),
            observedAt: BrainWhyViewTests.now
        )
    }

    // MARK: - Why-view grouping

    @Test("The why-view renders one group per theatre")
    func oneGroupPerTheatre() {
        let report = brainReportFixture(theatres: [
            Theatre(
                depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                readiness: .operational, stock: 40_000
            ),
            Theatre(
                depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
                readiness: .operational, stock: 900
            ),
        ])

        let groups = BrainWhy.groups(for: report)

        #expect(groups.map(\.depot) == ["AINALRAM-BELT-1", "DENEBED-BELT-1"])
        #expect(groups.allSatisfy { $0.goalLines.count == 5 })
    }

    @Test("A claimed theatre renders its shortfalls in place of goal lines")
    func claimedRendersShortfalls() {
        let report = brainReportFixture(theatres: [
            Theatre(
                depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
                readiness: .claimed(missing: [.noPrintCapableDevice]), stock: 0
            ),
        ])

        let groups = BrainWhy.groups(for: report)

        #expect(groups[0].goalLines.isEmpty)
        #expect(groups[0].shortfallLines.count == 1)
    }

    // MARK: - Directive row

    @Test("A directive with no theatre reads as unassigned rather than disappearing")
    func unassignedRowVisible() {
        let row = DirectiveRow.custom(directiveFixture(id: "A", theatreDepot: nil))
        #expect(row.theatreLabel == "unassigned")
    }

    @Test("A directive with a theatre reads its depot")
    func assignedRowReadsItsDepot() {
        let row = DirectiveRow.custom(directiveFixture(id: "A", theatreDepot: "AINALRAM-BELT-1"))
        #expect(row.theatreLabel == "AINALRAM-BELT-1")
    }

    // MARK: - The filter

    @Test("The theatre filter narrows the list without hiding unassigned rows")
    func filterKeepsUnassignedVisible() throws {
        try withDependencies {
            $0.defaultDatabase = try GameDatabase.bootstrap()
        } operation: {
            var state = DirectivesFeature.State()
            state.theatreFilter = "AINALRAM-BELT-1"
            let shown = state.visibleRows([
                .custom(directiveFixture(id: "A", theatreDepot: "AINALRAM-BELT-1")),
                .custom(directiveFixture(id: "B", theatreDepot: "DENEBED-BELT-1")),
                .custom(directiveFixture(id: "C", theatreDepot: nil)),
            ])

            #expect(shown.map(\.id) == ["custom:A", "custom:C"])
        }
    }

    @Test("With no filter, every row shows")
    func noFilterShowsEverything() throws {
        try withDependencies {
            $0.defaultDatabase = try GameDatabase.bootstrap()
        } operation: {
            let state = DirectivesFeature.State()
            let shown = state.visibleRows([
                .custom(directiveFixture(id: "A", theatreDepot: "AINALRAM-BELT-1")),
                .custom(directiveFixture(id: "B", theatreDepot: "DENEBED-BELT-1")),
            ])

            #expect(shown.map(\.id) == ["custom:A", "custom:B"])
        }
    }
}
