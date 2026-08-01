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

@Suite("FTL direct-link reduction")
struct DirectFTLLinksTests {
    /// A closure row with explicit metrics. Ranges are given in the caller's
    /// argument order and swapped here if canonicalisation flipped the pair, so
    /// a test always names `rangeFor(first)`, `rangeFor(second)`.
    func row(
        _ first: String, _ second: String,
        distance: Double?, rangeFirst: Double? = 7.5, rangeSecond: Double? = 7.5
    ) -> FTLLinkRecord {
        let link = FTLLink(first, second)
        let flipped = link.a != first
        return FTLLinkRecord(
            a: link.a, b: link.b, updatedAt: Date(timeIntervalSince1970: 0),
            distanceLy: distance,
            rangeA: flipped ? rangeSecond : rangeFirst,
            rangeB: flipped ? rangeFirst : rangeSecond)
    }

    /// The core case: a 3-clique closure where only two pairs are in range.
    @Test func dropsClosurePairsBeyondRange() {
        let rows = [
            row("A", "B", distance: 4),
            row("B", "C", distance: 5),
            row("A", "C", distance: 9),  // closure only — 9 > 7.5
        ]

        #expect(Set(DirectFTLLinks.reduce(rows: rows)) == [FTLLink("A", "B"), FTLLink("B", "C")])
    }

    /// A 12.5 ly hub reaches a 7.5 ly relay 10 ly away. Union semantics: the
    /// larger of the two ranges decides, so the edge survives.
    @Test func longerRangedEndpointKeepsTheEdge() {
        let rows = [row("HUB", "RELAY", distance: 10, rangeFirst: 12.5, rangeSecond: 7.5)]

        #expect(DirectFTLLinks.reduce(rows: rows) == [FTLLink("HUB", "RELAY")])
    }

    /// The same pair with both ranges short is NOT a link — proves the previous
    /// test passes because of the hub's range, not by accident.
    @Test func bothEndpointsShortOfTheDistanceDropsTheEdge() {
        let rows = [
            row("HUB", "RELAY", distance: 10, rangeFirst: 7.5, rangeSecond: 7.5),
            row("HUB", "OTHER", distance: 3),
            row("OTHER", "RELAY", distance: 3),
        ]

        #expect(!DirectFTLLinks.reduce(rows: rows).contains(FTLLink("HUB", "RELAY")))
    }

    /// If filtering would split a component the server reports as whole, the
    /// shortest closure edge is added back until parity is restored.
    @Test func repairsAComponentTheFilterWouldSplit() {
        let rows = [
            row("A", "B", distance: 4),  // direct
            row("B", "C", distance: 20),  // closure only
            row("A", "C", distance: 30),  // closure only, longer
        ]

        // One component, and the repair chose the SHORTER of the two candidates.
        #expect(Set(DirectFTLLinks.reduce(rows: rows)) == [FTLLink("A", "B"), FTLLink("B", "C")])
    }

    /// When the direct set already matches, the repair adds nothing.
    @Test func repairIsANoOpWhenParityAlreadyHolds() {
        let rows = [row("A", "B", distance: 4), row("B", "C", distance: 5)]

        #expect(DirectFTLLinks.reduce(rows: rows).count == 2)
    }

    /// Two genuinely separate networks must stay separate — the repair must not
    /// merge across components the server never joined.
    @Test func doesNotMergeGenuinelySeparateComponents() {
        let rows = [row("A", "B", distance: 4), row("C", "D", distance: 4)]

        #expect(Set(DirectFTLLinks.reduce(rows: rows)) == [FTLLink("A", "B"), FTLLink("C", "D")])
    }

    /// Two separate networks that EACH need repairing — the repair must restore
    /// both without joining them to each other.
    @Test func repairsEachComponentWithoutMergingThem() {
        let rows = [
            row("A", "B", distance: 4), row("B", "C", distance: 40), row("A", "C", distance: 50),
            row("X", "Y", distance: 4), row("Y", "Z", distance: 60), row("X", "Z", distance: 70),
        ]

        let links = Set(DirectFTLLinks.reduce(rows: rows))

        #expect(
            links == [
                FTLLink("A", "B"), FTLLink("B", "C"), FTLLink("X", "Y"), FTLLink("Y", "Z"),
            ])
    }

    /// Fail-open: a row missing any metric is treated as a real link.
    @Test func missingMetricsKeepTheEdge() {
        #expect(DirectFTLLinks.reduce(rows: [row("A", "B", distance: nil)]).count == 1)
        #expect(
            DirectFTLLinks.reduce(rows: [row("A", "B", distance: 99, rangeFirst: nil)]).count == 1)
        #expect(
            DirectFTLLinks.reduce(rows: [row("A", "B", distance: 99, rangeSecond: nil)]).count == 1)
    }

    @Test func emptyInputProducesNoLinks() {
        #expect(DirectFTLLinks.reduce(rows: []).isEmpty)
    }

    /// Regression fixture from the real 11-relay mesh (2026-08-01): 55 closure
    /// pairs reduce to the 22 in-range edges, and all 11 systems stay in ONE
    /// component — so the map's reachability read is unchanged by the filter.
    @Test func realMeshReducesTo22EdgesInOneComponent() {
        let stars = [
            "AINALRAM", "ALPHERATOZ", "ARCTURUSAN", "ATIANFU", "BARNARIDS", "MAHOSATI",
            "MENKENTAN", "PIPIROMA", "SANSUNU", "SHERATANON", "TENEGSHE",
        ]
        // Distances measured from the live census positions (world unit == 1 ly).
        let distance: [String: Double] = [
            "MENKENTAN|SANSUNU": 2.94, "MAHOSATI|TENEGSHE": 3.56, "SANSUNU|TENEGSHE": 3.95,
            "AINALRAM|TENEGSHE": 4.34, "AINALRAM|SANSUNU": 4.93, "AINALRAM|ATIANFU": 5.32,
            "ATIANFU|SHERATANON": 5.48, "ARCTURUSAN|BARNARIDS": 5.76, "ATIANFU|SANSUNU": 5.87,
            "ARCTURUSAN|PIPIROMA": 5.96, "MAHOSATI|SANSUNU": 6.01, "BARNARIDS|PIPIROMA": 6.13,
            "SHERATANON|TENEGSHE": 6.20, "ALPHERATOZ|ATIANFU": 6.46, "ATIANFU|TENEGSHE": 6.59,
            "BARNARIDS|SANSUNU": 6.84, "MENKENTAN|TENEGSHE": 6.86, "AINALRAM|SHERATANON": 6.88,
            "AINALRAM|BARNARIDS": 6.96, "BARNARIDS|MENKENTAN": 7.06, "ATIANFU|MENKENTAN": 7.25,
            "AINALRAM|MENKENTAN": 7.28, "MAHOSATI|SHERATANON": 7.51, "MENKENTAN|PIPIROMA": 7.59,
            "AINALRAM|MAHOSATI": 7.89, "PIPIROMA|SANSUNU": 7.97, "MAHOSATI|MENKENTAN": 8.35,
            "SANSUNU|SHERATANON": 8.44, "BARNARIDS|TENEGSHE": 8.57, "ATIANFU|MAHOSATI": 8.99,
            "ALPHERATOZ|MENKENTAN": 9.57, "PIPIROMA|TENEGSHE": 9.65, "ALPHERATOZ|SANSUNU": 10.18,
            "MAHOSATI|PIPIROMA": 10.31, "ARCTURUSAN|MENKENTAN": 10.63, "AINALRAM|ALPHERATOZ": 10.71,
            "AINALRAM|PIPIROMA": 10.76, "ATIANFU|BARNARIDS": 10.76, "MENKENTAN|SHERATANON": 10.90,
            "BARNARIDS|MAHOSATI": 11.16, "ARCTURUSAN|SANSUNU": 11.44, "ALPHERATOZ|SHERATANON": 11.49,
            "ALPHERATOZ|TENEGSHE": 12.53, "AINALRAM|ARCTURUSAN": 12.68, "ARCTURUSAN|TENEGSHE": 13.51,
            "BARNARIDS|SHERATANON": 13.54, "ATIANFU|PIPIROMA": 13.69, "ALPHERATOZ|BARNARIDS": 13.75,
            "ALPHERATOZ|MAHOSATI": 14.65, "ARCTURUSAN|MAHOSATI": 15.27, "PIPIROMA|SHERATANON": 15.71,
            "ARCTURUSAN|ATIANFU": 16.09, "ALPHERATOZ|PIPIROMA": 16.87, "ALPHERATOZ|ARCTURUSAN": 18.06,
            "ARCTURUSAN|SHERATANON": 19.03,
        ]

        var rows: [FTLLinkRecord] = []
        for i in stars.indices {
            for j in stars.indices where j > i {
                let link = FTLLink(stars[i], stars[j])
                rows.append(
                    FTLLinkRecord(
                        a: link.a, b: link.b, updatedAt: Date(timeIntervalSince1970: 0),
                        distanceLy: distance["\(link.a)|\(link.b)"], rangeA: 7.5, rangeB: 7.5))
            }
        }
        // Every pair must have a measured distance, or the fixture is fail-open
        // by accident rather than exercising the filter.
        #expect(rows.count == 55)
        #expect(rows.allSatisfy { $0.distanceLy != nil })

        let links = DirectFTLLinks.reduce(rows: rows)

        #expect(links.count == 22)

        // All 11 systems still reachable from one another.
        var seen: Set<String> = ["AINALRAM"]
        var changed = true
        while changed {
            changed = false
            for link in links {
                if seen.contains(link.a), !seen.contains(link.b) {
                    seen.insert(link.b)
                    changed = true
                }
                if seen.contains(link.b), !seen.contains(link.a) {
                    seen.insert(link.a)
                    changed = true
                }
            }
        }
        #expect(seen.count == 11)

        // The specific case that motivated the change: ALPHERATOZ reported ten
        // peers but has exactly one within range.
        #expect(links.filter { $0.a == "ALPHERATOZ" || $0.b == "ALPHERATOZ" }
            == [FTLLink("ALPHERATOZ", "ATIANFU")])
    }
}
