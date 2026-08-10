//
//  DirectiveStallDetail.swift
//  Replicould — Directives feature
//
//  Recovering a stall's detail from the timeline. A plain namespace, not a View
//  static — pure logic on a SwiftUI View traps (signal 5) under `swift test`.
//

import GameModels

public enum DirectiveStallDetail {
    /// The detail of the newest `.stalled` entry in `entries`, or nil.
    /// The executor writes the summary as `"<reason.rawValue>: <detail>"`, so the
    /// suffix counts only when the prefix names the row's CURRENT `reason`.
    public static func detail(
        for reason: DirectiveAttentionReason,
        in entries: [DirectiveLogEntry]
    ) -> String? {
        let newest = entries
            .filter { $0.kind == .stalled }
            .max { $0.occurredAt < $1.occurredAt }
        guard let summary = newest?.summary else { return nil }
        let prefix = "\(reason.rawValue): "
        guard summary.hasPrefix(prefix) else { return nil }
        let detail = String(summary.dropFirst(prefix.count))
        return detail.isEmpty ? nil : detail
    }
}
