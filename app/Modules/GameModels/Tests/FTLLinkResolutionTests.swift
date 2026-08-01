//
//  FTLLinkResolutionTests.swift
//  Replicould — GameModels tests
//
//  The two pure resolvers behind the FTL mesh: ingest (relay network views ->
//  persistable closure rows) and read (closure rows -> drawable direct links).
//

import Foundation
import Testing

@testable import GameModels

@Suite("FTL link ingest resolution")
struct FTLLinkIngestTests {
    let now = Date(timeIntervalSince1970: 0)

    /// A relay's view knows its OWN range but not its peer's, so ranges must be
    /// merged across every view before rows are stamped.
    @Test func mergesRangesFromBothEndpointViews() {
        let views = [
            RelayNetworkView(
                star: "A", rangeLy: 7.5,
                connections: [.init(star: "B", distanceLy: 10)]),
            RelayNetworkView(
                star: "B", rangeLy: 12.5,
                connections: [.init(star: "A", distanceLy: 10)]),
        ]

        let rows = FTLLinkRecord.rows(from: views, now: now)

        #expect(rows.count == 1)
        #expect(rows[0].a == "A")
        #expect(rows[0].b == "B")
        #expect(rows[0].distanceLy == 10)
        #expect(rows[0].rangeA == 7.5)
        #expect(rows[0].rangeB == 12.5)
    }

    /// A relay whose network read failed contributes no view. Its range is then
    /// unknown — but the edge its peer reported must survive, with a nil range.
    @Test func absentViewLeavesNilRangeRatherThanDroppingTheEdge() {
        let views = [
            RelayNetworkView(
                star: "A", rangeLy: 7.5,
                connections: [.init(star: "GHOST", distanceLy: 3)])
        ]

        let rows = FTLLinkRecord.rows(from: views, now: now)

        #expect(rows.count == 1)
        #expect(rows[0].rangeA == 7.5)
        #expect(rows[0].rangeB == nil)
    }

    /// Both relays report the same connection; the canonical pair collapses them.
    @Test func reciprocalReportsCollapseToOneRow() {
        let views = [
            RelayNetworkView(star: "B", rangeLy: 7.5, connections: [.init(star: "A", distanceLy: 4)]),
            RelayNetworkView(star: "A", rangeLy: 7.5, connections: [.init(star: "B", distanceLy: 4)]),
        ]

        #expect(FTLLinkRecord.rows(from: views, now: now).count == 1)
    }

    /// One side reporting no distance must not erase the side that did report one.
    @Test func prefersTheReportThatCarriedADistance() {
        let views = [
            RelayNetworkView(star: "A", rangeLy: 7.5, connections: [.init(star: "B", distanceLy: 4)]),
            RelayNetworkView(star: "B", rangeLy: 7.5, connections: [.init(star: "A", distanceLy: nil)]),
        ]

        let rows = FTLLinkRecord.rows(from: views, now: now)

        #expect(rows.count == 1)
        #expect(rows[0].distanceLy == 4)
    }

    @Test func selfReferentialConnectionIsIgnored() {
        let views = [
            RelayNetworkView(star: "A", rangeLy: 7.5, connections: [.init(star: "A", distanceLy: 0)])
        ]

        #expect(FTLLinkRecord.rows(from: views, now: now).isEmpty)
    }

    @Test func emptyInputProducesNoRows() {
        #expect(FTLLinkRecord.rows(from: [], now: now).isEmpty)
    }

    /// Rows are written in a stable order so a rebuild resolving the same set
    /// writes the same rows.
    @Test func rowsAreOrderedDeterministically() {
        let views = [
            RelayNetworkView(
                star: "M", rangeLy: 7.5,
                connections: [.init(star: "Z", distanceLy: 1), .init(star: "A", distanceLy: 2)])
        ]

        #expect(FTLLinkRecord.rows(from: views, now: now).map(\.id) == ["A|M", "M|Z"])
    }
}
