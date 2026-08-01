// SCRATCH — review probes for DirectFTLLinks. DELETE BEFORE FINISHING.
import Foundation
import Testing

@testable import GameModels

@Suite("REVIEW PROBES")
struct ScratchReviewProbeTests {
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

    /// ALL rows filtered out: repair must rebuild one component from nothing,
    /// choosing the shortest spanning edges.
    @Test func allRowsFilteredOutRebuildsSpanningTree() {
        let rows = [
            row("A", "B", distance: 20),
            row("B", "C", distance: 21),
            row("A", "C", distance: 22),
        ]
        let links = DirectFTLLinks.reduce(rows: rows)
        #expect(Set(links) == [FTLLink("A", "B"), FTLLink("B", "C")])
    }

    /// 4-node clique, everything out of range: needs THREE repair edges — the
    /// early break must not fire before parity is truly restored.
    @Test func multiEdgeRepairWithinOneComponent() {
        let rows = [
            row("A", "B", distance: 20), row("B", "C", distance: 21),
            row("C", "D", distance: 22), row("A", "C", distance: 30),
            row("A", "D", distance: 31), row("B", "D", distance: 32),
        ]
        let links = DirectFTLLinks.reduce(rows: rows)
        #expect(Set(links) == [FTLLink("A", "B"), FTLLink("B", "C"), FTLLink("C", "D")])
    }

    /// Exact boundary: distance == range must classify as DIRECT via <=, proven
    /// by giving alternates so a repair could NOT be what keeps the edge.
    @Test func exactBoundaryIsDirectNotRepaired() {
        let rows = [
            row("A", "B", distance: 7.5),  // exactly at range
            row("A", "C", distance: 3),
            row("B", "C", distance: 3),
        ]
        #expect(DirectFTLLinks.reduce(rows: rows).count == 3)
    }

    /// THE union-semantics discriminator the shipped suite lacks: with an
    /// alternate path present, only max-semantics keeps the hub edge. Under
    /// min-semantics the repair would NOT restore it (parity already holds).
    @Test func unionSemanticsDiscriminator() {
        let rows = [
            row("HUB", "RELAY", distance: 10, rangeFirst: 12.5, rangeSecond: 7.5),
            row("HUB", "OTHER", distance: 3),
            row("OTHER", "RELAY", distance: 3),
        ]
        #expect(DirectFTLLinks.reduce(rows: rows).count == 3)
    }

    /// Duplicate input rows (impossible from the DB: id is the primary key).
    @Test func duplicateRowsProduceDuplicateLinks() {
        let rows = [row("A", "B", distance: 4), row("A", "B", distance: 4)]
        let links = DirectFTLLinks.reduce(rows: rows)
        #expect(links.count == 2)  // observing, not endorsing
    }

    /// Self-loop row (ingest filters these; probing robustness only).
    @Test func selfLoopDoesNotCrashOrBreakParity() {
        let direct = DirectFTLLinks.reduce(rows: [row("A", "A", distance: 1)])
        #expect(direct == [FTLLink("A", "A")])
        let filtered = DirectFTLLinks.reduce(
            rows: [row("A", "A", distance: 99), row("A", "B", distance: 4)])
        #expect(filtered == [FTLLink("A", "B")])
    }

    /// A single out-of-range row is restored by repair — meaning the
    /// longerRangedEndpointKeepsTheEdge test CANNOT distinguish direct-kept
    /// from repair-restored.
    @Test func singleNonDirectRowIsRestoredByRepair() {
        let rows = [row("X", "Y", distance: 50)]
        #expect(DirectFTLLinks.reduce(rows: rows) == [FTLLink("X", "Y")])
    }
}
