//
//  RelayNetworkView.swift
//  Replicould — shared game models
//
//  One relay's live network view, reduced to what mesh resolution needs.
//
//  The backend reports the CLOSURE of a relay's subgraph, not its topology:
//  within a connected subgraph there are no hops, so every relay reports every
//  peer however distant (live data: pairs up to 18 ly against a 7.5 ly edge
//  range). The distance and range carried here are what let the read path tell
//  a real link from a closure pair — see `DirectFTLLinks`.
//

import Foundation

/// One relay's `GET /v1/devices/{code}/network` response, in domain terms.
public struct RelayNetworkView: Equatable, Sendable {
    /// The star system this relay sits in.
    public let star: String
    /// This relay's own edge range. Nil when the field was absent. Ranges are
    /// heterogeneous — a `system_hub` carries an integrated relay with a longer
    /// reach than a standalone `ftl_relay` — which is why this is read per relay
    /// rather than assumed as a constant.
    public let rangeLy: Double?
    /// Every peer the backend reports — the closure, not just direct links.
    public let connections: [Connection]

    public struct Connection: Equatable, Sendable {
        public let star: String
        public let distanceLy: Double?

        public init(star: String, distanceLy: Double?) {
            self.star = star
            self.distanceLy = distanceLy
        }
    }

    public init(star: String, rangeLy: Double?, connections: [Connection]) {
        self.star = star
        self.rangeLy = rangeLy
        self.connections = connections
    }
}

extension FTLLinkRecord {
    /// Resolve every relay's network view into the persistable closure.
    ///
    /// A single view knows its own range but never its peer's, so ranges are
    /// merged across ALL views first and then stamped onto each canonical pair.
    /// A peer with no view of its own (its read failed, or it is not in the
    /// roster) leaves a nil range, which the read path treats as fail-open.
    public static func rows(from views: [RelayNetworkView], now: Date) -> [FTLLinkRecord] {
        let rangeByStar = Dictionary(
            views.map { ($0.star, $0.rangeLy) },
            uniquingKeysWith: { first, second in first ?? second })

        var byID: [String: FTLLinkRecord] = [:]
        for view in views {
            for connection in view.connections where connection.star != view.star {
                let link = FTLLink(view.star, connection.star)
                let row = FTLLinkRecord(
                    a: link.a,
                    b: link.b,
                    updatedAt: now,
                    distanceLy: connection.distanceLy,
                    rangeA: rangeByStar[link.a] ?? nil,
                    rangeB: rangeByStar[link.b] ?? nil)

                // Both endpoints report the same pair. Prefer whichever report
                // actually carried a distance — a nil from one side must not
                // erase a real measurement from the other.
                if let existing = byID[row.id], existing.distanceLy != nil, row.distanceLy == nil {
                    continue
                }
                byID[row.id] = row
            }
        }
        // Deterministic order, so a rebuild that resolves the same set writes
        // the same rows — mirrors the ordering `relayLinks` used to guarantee.
        return byID.values.sorted { $0.id < $1.id }
    }
}
