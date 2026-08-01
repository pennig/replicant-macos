//
//  DirectFTLLinks.swift
//  Replicould — shared game models
//
//  The mesh read path.
//
//  `ftlLinks` stores the backend's CLOSURE: within a connected subgraph there
//  are no hops, so every relay reports every peer in its subgraph however
//  distant — live data has pairs up to 19 ly against a 7.5 ly edge range.
//  Drawing those as links is what made the galaxy map a hairball (11 relays ->
//  55 edges, a complete clique, growing quadratically with every new relay).
//
//  A direct link is `distanceLy <= max(rangeA, rangeB)`. The MAX (rather than
//  the min) is union semantics: a 12.5 ly `system_hub` reaches a 7.5 ly relay
//  that cannot reach back. It is the safe direction — a union can never split a
//  component the server considers whole — and it is one word to change if hub
//  behaviour proves otherwise.
//
//  The closure is deliberately still what gets STORED. Classifying on read keeps
//  the rule revisable without a mesh rebuild (O(relays) serial network reads,
//  fired only on roster or liveness changes), and it makes the parity repair
//  below exact rather than a reconstruction.
//

import Foundation
import SQLiteData

/// The direct-link view of the persisted mesh, computed once per database change
/// rather than per SwiftUI body evaluation.
public struct DirectFTLLinks: FetchKeyRequest {
    public struct Value: Equatable, Sendable {
        public var links: [FTLLink] = []
        public init(links: [FTLLink] = []) { self.links = links }
    }

    public init() {}

    public func fetch(_ db: Database) throws -> Value {
        Value(links: Self.reduce(rows: try FTLLinkRecord.all.fetchAll(db)))
    }

    /// Fail-open: a row missing any metric counts as a real link. A slightly
    /// noisy map beats a missing link, and it keeps the repair below from
    /// misfiring on rows it cannot judge.
    static func isDirect(_ row: FTLLinkRecord) -> Bool {
        guard let distance = row.distanceLy, let rangeA = row.rangeA, let rangeB = row.rangeB
        else { return true }
        return distance <= max(rangeA, rangeB)
    }

    /// Closure rows in, drawable links out.
    ///
    /// The invariant this enforces: **drawn components always equal server
    /// components.** Filtering could in principle split a network the server
    /// reports as whole (a relay whose view failed to read, an unexpected range
    /// asymmetry, a borderline float), which would have the map lying in the
    /// opposite direction — showing two networks where there is one. So after
    /// filtering, the shortest closure edges are added back, Kruskal-wise, until
    /// the component count matches the closure's.
    static func reduce(rows: [FTLLinkRecord]) -> [FTLLink] {
        guard !rows.isEmpty else { return [] }

        var closure = UnionFind()
        for row in rows { closure.union(row.a, row.b) }
        let closureComponents = closure.componentCount()

        // Seed with every endpoint, not just the ones direct rows mention, so the
        // two component counts are comparable: a star whose every edge was
        // filtered out is its own component and must be counted as such.
        var direct = UnionFind()
        for row in rows {
            direct.add(row.a)
            direct.add(row.b)
        }
        var kept = rows.filter(isDirect)
        for row in kept { direct.union(row.a, row.b) }

        if direct.componentCount() != closureComponents {
            let candidates = rows
                .filter { !isDirect($0) }
                .sorted { ($0.distanceLy ?? .infinity) < ($1.distanceLy ?? .infinity) }
            for candidate in candidates {
                if direct.union(candidate.a, candidate.b) {
                    kept.append(candidate)
                    if direct.componentCount() == closureComponents { break }
                }
            }
        }

        return kept.map(\.link)
    }
}

/// Minimal union-find over star designations, for component parity.
private struct UnionFind {
    private var parent: [String: String] = [:]

    mutating func add(_ x: String) {
        if parent[x] == nil { parent[x] = x }
    }

    mutating func find(_ x: String) -> String {
        add(x)
        var root = x
        while let next = parent[root], next != root { root = next }
        var cursor = x
        while cursor != root {
            let next = parent[cursor]!
            parent[cursor] = root
            cursor = next
        }
        return root
    }

    /// Returns true when the two were in different components — i.e. a merge
    /// actually happened, so the caller knows this edge was load-bearing.
    @discardableResult
    mutating func union(_ a: String, _ b: String) -> Bool {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return false }
        parent[rootA] = rootB
        return true
    }

    mutating func componentCount() -> Int {
        var roots: Set<String> = []
        // Snapshot the keys because `find` path-compresses, which mutates
        // `parent` mid-iteration. Swift would define that away (the iterator
        // holds the pre-mutation storage, and compression never adds or removes
        // keys), so this is for the reader, not for correctness.
        for key in Array(parent.keys) { roots.insert(find(key)) }
        return roots.count
    }
}
