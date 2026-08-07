//
//  MeshUpdate.swift
//  Replicould — shared game models
//
//  The mesh incremental path: fold ONE relay's network view into the stored
//  closure rather than re-reading every relay. A view reports every peer in its
//  subgraph, so it carries every closure pair that relay is an endpoint of — but
//  a change that joins or splits components also moves pairs it never mentions,
//  and `needsFullSweep` is that predicate.
//

import Foundation

/// What one relay event implies for the stored mesh.
public struct MeshUpdate: Equatable, Sendable {
    /// Stars whose stored rows this update replaces wholesale. Every row with an
    /// endpoint here is deleted before `rows` is written.
    public let rewritten: Set<String>
    /// The replacement rows for `rewritten`.
    public let rows: [FTLLinkRecord]
    /// The single view cannot describe this change — rebuild from every relay.
    /// When true, `rewritten` and `rows` must be ignored.
    public let needsFullSweep: Bool

    public init(rewritten: Set<String> = [], rows: [FTLLinkRecord] = [], needsFullSweep: Bool = false)
    {
        self.rewritten = rewritten
        self.rows = rows
        self.needsFullSweep = needsFullSweep
    }

    /// Nothing to write and nothing to read.
    public var isEmpty: Bool { !needsFullSweep && rewritten.isEmpty }
}

extension FTLLinkRecord {
    /// Fold one relay's live view, plus the local roster, into the stored closure.
    ///
    /// `relaysByStar` counts relay-capable devices per system. A star it does not
    /// name holds no relay any more, so its stored rows are defunct and drop
    /// without any network read — the reclaim case.
    public static func incremental(
        view: RelayNetworkView?,
        relaysByStar: [String: Int],
        stored: [FTLLinkRecord],
        now: Date
    ) -> MeshUpdate {
        let storedStars = Set(stored.flatMap { [$0.a, $0.b] })
        let defunct = storedStars.filter { (relaysByStar[$0] ?? 0) == 0 }

        var rewritten = defunct
        if let view { rewritten.insert(view.star) }
        guard !rewritten.isEmpty else { return MeshUpdate() }

        // Two relays can share a system (a `system_hub`'s integrated relay beside
        // a standalone one), and one of their views is not the star's whole reach.
        if let view, (relaysByStar[view.star] ?? 0) > 1 {
            return MeshUpdate(needsFullSweep: true)
        }

        let others = stored.filter { !rewritten.contains($0.a) && !rewritten.contains($0.b) }
        let rows = view.map { rewrite($0, excluding: rewritten.subtracting([$0.star]), stored: stored, now: now) } ?? []

        if let view, joinsSeparateComponents(view, rewritten: rewritten, others: others) {
            return MeshUpdate(needsFullSweep: true)
        }
        if splitsAComponent(before: stored, after: others + rows, storedStars: storedStars) {
            return MeshUpdate(needsFullSweep: true)
        }
        return MeshUpdate(rewritten: rewritten, rows: rows)
    }

    /// This relay's rows, with peer ranges recovered from the stored closure — a
    /// view knows its own range but never its peer's, and there is no second view
    /// here to merge one out of.
    private static func rewrite(
        _ view: RelayNetworkView,
        excluding defunct: Set<String>,
        stored: [FTLLinkRecord],
        now: Date
    ) -> [FTLLinkRecord] {
        var rangeByStar: [String: Double] = [:]
        func note(_ star: String, _ range: Double?) {
            guard let range else { return }
            rangeByStar[star] = Swift.max(rangeByStar[star] ?? range, range)
        }
        for row in stored {
            note(row.a, row.rangeA)
            note(row.b, row.rangeB)
        }
        // The view's own reading wins outright: it is this read's ground truth,
        // where the stored value is whatever the last rebuild happened to see.
        rangeByStar[view.star] = view.rangeLy

        var rows: [FTLLinkRecord] = []
        for connection in view.connections
        where connection.star != view.star && !defunct.contains(connection.star) {
            let link = FTLLink(view.star, connection.star)
            rows.append(
                FTLLinkRecord(
                    a: link.a,
                    b: link.b,
                    updatedAt: now,
                    distanceLy: connection.distanceLy,
                    rangeA: rangeByStar[link.a],
                    rangeB: rangeByStar[link.b]))
        }
        return rows.sorted { $0.id < $1.id }
    }

    /// True when this relay's peers sit in more than one component of the mesh it
    /// is joining. The server's closure then also gains pairs BETWEEN those
    /// components, and no read of this one relay reports them. A peer the stored
    /// closure has never heard of counts as its own component, which is what makes
    /// a cleared table escalate rather than half-fill.
    private static func joinsSeparateComponents(
        _ view: RelayNetworkView,
        rewritten: Set<String>,
        others: [FTLLinkRecord]
    ) -> Bool {
        var closure = UnionFind()
        for row in others { closure.union(row.a, row.b) }

        var roots: Set<String> = []
        for connection in view.connections
        where connection.star != view.star && !rewritten.contains(connection.star) {
            roots.insert(closure.find(connection.star))
        }
        return roots.count > 1
    }

    /// True when dropping these rows disconnects stars the mesh still holds. The
    /// server's closure then loses pairs across the new divide, and which ones is
    /// not answerable from a single relay's view.
    ///
    /// The RAW direct filter, never `DirectFTLLinks.reduce`: the parity repair
    /// guarantees drawn components equal closure components, so a repaired graph
    /// answers this question by construction and can never report a split.
    private static func splitsAComponent(
        before: [FTLLinkRecord],
        after: [FTLLinkRecord],
        storedStars: Set<String>
    ) -> Bool {
        // Only stars we still hold rows for are evidence: one that vanished
        // entirely took its own component slot with it.
        let common = storedStars.intersection(after.flatMap { [$0.a, $0.b] })
        guard !common.isEmpty else { return false }
        return components(of: after.filter(DirectFTLLinks.isDirect), over: common)
            > components(of: before.filter(DirectFTLLinks.isDirect), over: common)
    }

    /// How many components `stars` fall into. Links through a star outside the set
    /// still connect — a path is a path whether or not its waypoints are counted.
    private static func components(of rows: [FTLLinkRecord], over stars: Set<String>) -> Int {
        var uf = UnionFind()
        for star in stars { uf.add(star) }
        for row in rows { uf.union(row.a, row.b) }
        return Set(stars.map { uf.find($0) }).count
    }
}
