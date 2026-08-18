//
//  DirectiveStallDetail.swift
//  Replicould — Directives feature
//
//  Recovering a stall's detail from the timeline. A plain namespace, not a View
//  static — pure logic on a SwiftUI View traps (signal 5) under `swift test`.
//

import GameModels

public enum DirectiveStallDetail {
    /// The `detail` of the newest `.stalled` entry in `entries`, or nil. The
    /// summary is what still names the reason, so an entry recording some
    /// earlier stall never speaks under the row's CURRENT `reason`.
    public static func detail(
        for reason: DirectiveAttentionReason,
        in entries: [DirectiveLogEntry]
    ) -> String? {
        let newest = entries
            .filter { $0.kind == .stalled }
            .max { $0.occurredAt < $1.occurredAt }
        guard let newest else { return nil }
        let prefix = "\(reason.rawValue): "
        guard newest.summary.hasPrefix(prefix) else { return nil }
        guard let detail = newest.detail, !detail.isEmpty else { return nil }
        return detail
    }
}
