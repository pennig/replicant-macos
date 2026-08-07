//
//  MeshUpdateTests.swift
//  Replicould — GameModels tests
//
//  The incremental resolver: one relay's view plus the local roster folded into
//  the stored closure, and the two topology changes that force a full read.
//

import Foundation
import Testing

@testable import GameModels

@Suite("FTL mesh incremental update")
struct MeshUpdateTests {
    let now = Date(timeIntervalSince1970: 0)

    /// A stored closure row. Ranges are given in the caller's argument order and
    /// swapped here if canonicalisation flipped the pair.
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

    func view(_ star: String, range: Double? = 7.5, _ peers: [(String, Double?)]) -> RelayNetworkView
    {
        RelayNetworkView(
            star: star, rangeLy: range,
            connections: peers.map { .init(star: $0.0, distanceLy: $0.1) })
    }

    func roster(_ stars: String...) -> [String: Int] {
        stars.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    // MARK: - The cheap path

    /// The case the whole change exists for: a relay activating into a mesh it
    /// joins at one component. Its own view names every pair it is an endpoint
    /// of, so one read is the entire update.
    @Test func aRelayJoiningOneComponentNeedsNoSweep() {
        let update = FTLLinkRecord.incremental(
            view: view("N", [("A", 6), ("B", 7)]),
            relaysByStar: roster("A", "B", "N"),
            stored: [row("A", "B", distance: 5)],
            now: now)

        #expect(!update.needsFullSweep)
        #expect(update.rewritten == ["N"])
        #expect(update.rows.map(\.id) == ["A|N", "B|N"])
    }

    /// The very first relay: no peers, nothing to escalate to.
    @Test func theFirstRelayNeedsNoSweep() {
        let update = FTLLinkRecord.incremental(
            view: view("N", []), relaysByStar: roster("N"), stored: [], now: now)

        #expect(!update.needsFullSweep)
        #expect(update.rows.isEmpty)
    }

    /// No view to fold and no star left defunct — a relay event that changed
    /// nothing this side of the network.
    @Test func nothingToDoIsNotASweep() {
        let update = FTLLinkRecord.incremental(
            view: nil,
            relaysByStar: roster("A", "B"),
            stored: [row("A", "B", distance: 5)],
            now: now)

        #expect(update.isEmpty)
        #expect(!update.needsFullSweep)
    }

    // MARK: - Escalation

    /// A relay bridging two separate networks also creates closure pairs BETWEEN
    /// them, and its own view never mentions those pairs.
    @Test func bridgingTwoComponentsSweeps() {
        let update = FTLLinkRecord.incremental(
            view: view("N", [("A", 6), ("C", 6)]),
            relaysByStar: roster("A", "B", "C", "D", "N"),
            stored: [row("A", "B", distance: 5), row("C", "D", distance: 5)],
            now: now)

        #expect(update.needsFullSweep)
    }

    /// A cleared table is every peer in its own component, so the first relay
    /// event after a migration rebuilds rather than half-filling the mesh.
    @Test func peersAbsentFromTheStoredClosureSweep() {
        let update = FTLLinkRecord.incremental(
            view: view("N", [("A", 6), ("B", 6), ("C", 6)]),
            relaysByStar: roster("A", "B", "C", "N"),
            stored: [],
            now: now)

        #expect(update.needsFullSweep)
    }

    /// Two relays can share a system — a `system_hub`'s integrated relay beside a
    /// standalone one — and either view alone understates the star's reach.
    @Test func aCoLocatedSecondRelaySweeps() {
        let update = FTLLinkRecord.incremental(
            view: view("S", [("A", 6)]),
            relaysByStar: ["S": 2, "A": 1],
            stored: [row("A", "S", distance: 6)],
            now: now)

        #expect(update.needsFullSweep)
    }

    /// Reclaiming the relay that held a chain together splits the network, and
    /// which closure pairs the server drops is not derivable from here.
    @Test func reclaimingACutVertexSweeps() {
        let update = FTLLinkRecord.incremental(
            view: nil,
            relaysByStar: roster("A", "B"),  // S's relay is gone
            stored: [
                row("A", "S", distance: 5),
                row("S", "B", distance: 5),
                row("A", "B", distance: 15),  // closure only — 15 > 7.5
            ],
            now: now)

        #expect(update.needsFullSweep)
    }

    /// Deactivation is the same split, reached the other way: the relay stays in
    /// the roster and its view simply reports no connections.
    @Test func deactivatingACutVertexSweeps() {
        let update = FTLLinkRecord.incremental(
            view: view("S", []),
            relaysByStar: roster("A", "B", "S"),
            stored: [
                row("A", "S", distance: 5),
                row("S", "B", distance: 5),
                row("A", "B", distance: 15),
            ],
            now: now)

        #expect(update.needsFullSweep)
    }

    // MARK: - Local cleanup

    /// The reclaim the roster answers on its own: a star with no relay left has
    /// defunct edges, and dropping them costs no network read.
    @Test func aReclaimedRelayLeavesItsStarsEdgesToBeDropped() {
        let update = FTLLinkRecord.incremental(
            view: nil,
            relaysByStar: roster("A", "B"),
            stored: [
                row("A", "S", distance: 5),
                row("S", "B", distance: 5),
                row("A", "B", distance: 6),  // a real link — the network stays whole
            ],
            now: now)

        #expect(!update.needsFullSweep)
        #expect(update.rewritten == ["S"])
        #expect(update.rows.isEmpty)
    }

    /// Same shape for a relay that merely went dark, where the roster still lists
    /// it: an empty view is what the backend returns for a deactivated relay.
    @Test func aDeactivatedRelayDropsItsOwnRows() {
        let update = FTLLinkRecord.incremental(
            view: view("S", []),
            relaysByStar: roster("A", "B", "S"),
            stored: [
                row("A", "S", distance: 5),
                row("S", "B", distance: 5),
                row("A", "B", distance: 6),
            ],
            now: now)

        #expect(!update.needsFullSweep)
        #expect(update.rewritten == ["S"])
        #expect(update.rows.isEmpty)
    }

    /// A read that failed leaves a nil view, which must hold that star's rows
    /// rather than mistake silence for a dark relay.
    @Test func aFailedReadDoesNotDropTheStarsRows() {
        let update = FTLLinkRecord.incremental(
            view: nil,
            relaysByStar: roster("A", "B", "S"),  // S still holds a relay
            stored: [row("A", "S", distance: 5), row("S", "B", distance: 5)],
            now: now)

        #expect(update.isEmpty)
    }

    /// A defunct star must not come back as a peer of the relay being folded in.
    @Test func defunctPeersAreExcludedFromTheNewRows() {
        let update = FTLLinkRecord.incremental(
            view: view("N", [("A", 6), ("S", 6)]),
            relaysByStar: roster("A", "N"),  // S is gone
            stored: [row("A", "S", distance: 6)],
            now: now)

        #expect(!update.needsFullSweep)
        #expect(update.rewritten == ["S", "N"])
        #expect(update.rows.map(\.id) == ["A|N"])
    }

    // MARK: - Ranges

    /// A single view knows its own range but never its peer's, and there is no
    /// second view here to merge one out of — so the peer's range comes off the
    /// stored closure. Left nil it would fail open, and a 10 ly pair between two
    /// 7.5 ly relays would draw as a real link.
    @Test func peerRangesAreRecoveredFromTheStoredClosure() {
        let update = FTLLinkRecord.incremental(
            view: view("N", range: 7.5, [("A", 10)]),
            relaysByStar: roster("A", "B", "N"),
            stored: [row("A", "B", distance: 5, rangeFirst: 7.5, rangeSecond: 7.5)],
            now: now)

        #expect(update.rows.count == 1)
        #expect(update.rows[0].rangeA == 7.5)  // A, from the stored rows
        #expect(update.rows[0].rangeB == 7.5)  // N, from its own view
        #expect(!DirectFTLLinks.isDirect(update.rows[0]))
    }

    /// A hub's longer reach is likewise recovered, so the union rule still sees
    /// the endpoint that can actually make the link.
    @Test func aStoredHubRangeSurvivesTheFold() {
        let update = FTLLinkRecord.incremental(
            view: view("N", range: 7.5, [("H", 10)]),
            relaysByStar: roster("H", "B", "N"),
            stored: [row("H", "B", distance: 5, rangeFirst: 12.5, rangeSecond: 7.5)],
            now: now)

        #expect(update.rows.count == 1)
        #expect(update.rows[0].rangeA == 12.5)  // H
        #expect(DirectFTLLinks.isDirect(update.rows[0]))
    }
}
