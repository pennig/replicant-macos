//
//  DeviceListSearch.swift
//  Replicould — Devices feature
//
//  The list's search: AND across whitespace-split terms, OR across each device's
//  haystack fields, case- and diacritic-insensitive. Folding happens once per
//  term at parse time and once per field at match time.
//

import Foundation
import GameModels

extension DeviceListLayout {

    /// A parsed search query. Empty (no non-whitespace terms) matches everything.
    public struct Query: Equatable, Sendable {
        let terms: [String]

        public init(_ text: String) {
            terms = text
                .split(whereSeparator: \.isWhitespace)
                .map { Self.fold(String($0)) }
                .filter { !$0.isEmpty }
        }

        public var isEmpty: Bool { terms.isEmpty }

        /// Case- and diacritic-insensitive normalisation. `locale: nil` keeps the
        /// fold locale-independent so tests don't depend on the host locale.
        static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
    }

    /// Every field a query term may match, folded.
    static func haystack(for device: Device) -> [String] {
        var fields = [
            device.deviceCode,
            DevicePresentation.displayName(device.deviceType),
            device.deviceType,
            device.statusBase,
        ]
        if let location = device.location { fields.append(location) }
        if let locationName = device.locationName { fields.append(locationName) }
        fields.append(contentsOf: device.tags)
        return fields.map(Query.fold)
    }

    /// Every term must match some field; a term matches a field on substring.
    public static func matches(_ device: Device, query: Query) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = haystack(for: device)
        return query.terms.allSatisfy { term in
            fields.contains { $0.contains(term) }
        }
    }
}

extension DeviceListLayout {

    /// Prunes the forest to nodes that match, or that have a matching
    /// descendant, and reports the ancestors to force open for the duration of
    /// the query. A match is never unreachable behind a collapsed host, and the
    /// operator's own `expandedHosts` is untouched.
    static func pruned(_ nodes: [Node], query: Query) -> (nodes: [Node], forcedOpen: Set<String>) {
        guard !query.isEmpty else { return (nodes, []) }

        var kept: [Node] = []
        var forcedOpen: Set<String> = []
        for node in nodes {
            let below = pruned(node.children, query: query)
            guard matches(node.device, query: query) || !below.nodes.isEmpty else { continue }
            kept.append(Node(device: node.device, children: below.nodes))
            forcedOpen.formUnion(below.forcedOpen)
            if !below.nodes.isEmpty { forcedOpen.insert(node.device.deviceCode) }
        }
        return (kept, forcedOpen)
    }
}
