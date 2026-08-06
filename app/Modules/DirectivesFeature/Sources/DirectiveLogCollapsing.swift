//
//  DirectiveLogCollapsing.swift
//  Replicould — Directives feature
//
//  Collapses consecutive same-step repeats into one display row. SwiftUI-free
//  namespace on purpose — pure logic hung off a `View` traps `swift test`
//  (see the statics-in-tests memory note).
//

import GameModels

/// One timeline display row: the entry that opened a run of identical
/// consecutive entries, plus how many times it repeated.
public struct DirectiveTimelineDisplayRow: Identifiable, Equatable, Sendable {
    public let entry: DirectiveLogEntry
    public let count: Int
    public var id: String { entry.id }
}

public enum DirectiveLogCollapsing {
    /// Folds adjacent entries sharing a non-nil `step` and the same `kind`
    /// into one row. `step` is set only on `.stepStarted`, so a distinct-step
    /// progression (kind still equal, step differs) is left untouched, and
    /// any other entry sitting between two same-step rows keeps them apart.
    public static func collapse(_ entries: [DirectiveLogEntry]) -> [DirectiveTimelineDisplayRow] {
        var rows: [DirectiveTimelineDisplayRow] = []
        for entry in entries {
            if let last = rows.last, let step = entry.step,
               last.entry.step == step, last.entry.kind == entry.kind {
                rows[rows.count - 1] = DirectiveTimelineDisplayRow(entry: last.entry, count: last.count + 1)
            } else {
                rows.append(DirectiveTimelineDisplayRow(entry: entry, count: 1))
            }
        }
        return rows
    }
}
