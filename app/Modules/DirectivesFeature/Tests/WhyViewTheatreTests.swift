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

    private func brainReportFixture(
        theatres: [Theatre],
        theatreSurvey: [String: BrainSurveyStatus] = [:],
        theatreSalvage: [String: BrainGoalStatus] = [:],
        theatreHaul: [String: BrainGoalStatus] = [:],
        theatreLimits: [String: BrainLimits] = [:]
    ) -> BrainReport {
        BrainReport(
            decision: .idle(reason: "no grow or prune work"),
            ranked: [],
            theatres: theatres,
            limits: BrainWhyViewTests.calmLimits(),
            survey: .idle(reason: "no vessel is tagged auto:survey"),
            observedAt: BrainWhyViewTests.now,
            theatreSurvey: theatreSurvey,
            theatreSalvage: theatreSalvage,
            theatreHaul: theatreHaul,
            theatreLimits: theatreLimits
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
        #expect(groups.allSatisfy { $0.goalLines.count == 6 })
    }

    /// A live run reported for AINALRAM must not leak into DENEBED's own
    /// line — the fleet-wide-scan defect Task 7 closed, now checked at the
    /// rendered card rather than just the engine verdict.
    @Test("a live run in one theatre does not mask another theatre's idle or halted state")
    func aLiveRunDoesNotMaskAnotherTheatresLine() {
        let ainalram = Theatre(
            depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
            readiness: .operational, stock: 40_000
        )
        let denebed = Theatre(
            depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
            readiness: .operational, stock: 900
        )
        let report = brainReportFixture(
            theatres: [ainalram, denebed],
            theatreSurvey: [
                ainalram.depot: .launched(carrier: "V1", roamCentre: "AINALRAM", status: .running),
                denebed.depot: .idle(reason: "no vessel is tagged auto:survey"),
            ],
            theatreSalvage: [
                ainalram.depot: .launched(vessel: "V1", focus: "AINALRAM", status: .running),
                denebed.depot: .idle(reason: "no auto:salvage vessel"),
            ],
            theatreHaul: [
                ainalram.depot: .launched(vessel: "T1", focus: ainalram.depot, status: .running),
                denebed.depot: .idle(reason: "no free auto:haul controller offering ferry"),
            ]
        )

        let groups = Dictionary(uniqueKeysWithValues: BrainWhy.groups(for: report).map { ($0.depot, $0) })
        let ainalramLines = Dictionary(uniqueKeysWithValues: groups[ainalram.depot]!.goalLines.map { ($0.id, $0.text) })
        let denebedLines = Dictionary(uniqueKeysWithValues: groups[denebed.depot]!.goalLines.map { ($0.id, $0.text) })

        #expect(ainalramLines["survey"] != denebedLines["survey"])
        #expect(ainalramLines["salvage"] != denebedLines["salvage"])
        #expect(ainalramLines["haul"] != denebedLines["haul"])
        #expect(denebedLines["survey"] == "no vessel is tagged auto:survey")
        #expect(denebedLines["haul"] == "no free auto:haul controller offering ferry")
    }

    /// Each theatre's own footprint renders under its own heading — the
    /// `Snapshot.hubFootprint` fix.
    @Test("two theatres with different footprint resources each report their own number")
    func eachTheatreReportsItsOwnStockLine() {
        let ainalram = Theatre(
            depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
            readiness: .operational, stock: 40_000
        )
        let denebed = Theatre(
            depot: "DENEBED-BELT-1", system: "DENEBED", origin: .pinned,
            readiness: .operational, stock: 900
        )
        func limits(hubStock: Int) -> BrainLimits {
            BrainLimits(
                actionsRemaining: 54, actionsLimit: 60, actionsFloor: 6,
                hubStock: hubStock, hubStockFetchedAt: BrainWhyViewTests.now,
                spendFloor: 35_078, rateLimitedAt: nil
            )
        }
        let report = brainReportFixture(
            theatres: [ainalram, denebed],
            theatreLimits: [ainalram.depot: limits(hubStock: 40_000), denebed.depot: limits(hubStock: 900)]
        )

        let groups = Dictionary(uniqueKeysWithValues: BrainWhy.groups(for: report).map { ($0.depot, $0) })
        let ainalramStock = groups[ainalram.depot]!.goalLines.first { $0.id == "stock" }!.text
        let denebedStock = groups[denebed.depot]!.goalLines.first { $0.id == "stock" }!.text

        #expect(ainalramStock.contains("40,000"))
        #expect(denebedStock.contains("900"))
        #expect(ainalramStock != denebedStock)
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

    @Test("A claimed-only world still shows the flat sections")
    func claimedOnlyWorldShowsFlatSections() {
        let report = brainReportFixture(theatres: [
            Theatre(
                depot: "OMEROPE-BELT-1", system: "OMEROPE", origin: .pinned,
                readiness: .claimed(missing: [.noStock]), stock: 0
            ),
        ])

        #expect(BrainWhy.from(report: report).flatSectionsVisible)
    }

    @Test("An operational theatre with goal lines hides the flat sections")
    func operationalTheatreHidesFlatSections() {
        let report = brainReportFixture(theatres: [
            Theatre(
                depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                readiness: .operational, stock: 40_000
            ),
        ])

        #expect(!BrainWhy.from(report: report).flatSectionsVisible)
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
            state.$brainReport.withLock {
                $0 = brainReportFixture(theatres: [
                    Theatre(
                        depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                        readiness: .operational, stock: 40_000
                    ),
                ])
            }
            state.theatreFilter = "AINALRAM-BELT-1"
            let shown = state.visibleRows([
                .custom(directiveFixture(id: "A", theatreDepot: "AINALRAM-BELT-1")),
                .custom(directiveFixture(id: "B", theatreDepot: "DENEBED-BELT-1")),
                .custom(directiveFixture(id: "C", theatreDepot: nil)),
            ])

            #expect(shown.map(\.id) == ["custom:A", "custom:C"])
        }
    }

    @Test("A filter naming a theatre no longer offered shows everything")
    func staleFilterShowsEverything() throws {
        try withDependencies {
            $0.defaultDatabase = try GameDatabase.bootstrap()
        } operation: {
            var state = DirectivesFeature.State()
            state.$brainReport.withLock {
                $0 = brainReportFixture(theatres: [
                    Theatre(
                        depot: "AINALRAM-BELT-1", system: "AINALRAM", origin: .derived,
                        readiness: .operational, stock: 40_000
                    ),
                ])
            }
            // Names a theatre that no longer appears in the latest report — a
            // failed world read, or a reclaimed depot.
            state.theatreFilter = "DENEBED-BELT-1"
            let shown = state.visibleRows([
                .custom(directiveFixture(id: "A", theatreDepot: "AINALRAM-BELT-1")),
                .custom(directiveFixture(id: "B", theatreDepot: "DENEBED-BELT-1")),
            ])

            #expect(shown.map(\.id) == ["custom:A", "custom:B"])
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
