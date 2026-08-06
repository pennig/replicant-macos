//
//  DirectiveLogCollapsing.swift
//  Replicould — Directives feature
//
//  Collapses repeating step cycles into one display row. SwiftUI-free
//  namespace on purpose — pure logic hung off a `View` traps `swift test`
//  (see the statics-in-tests memory note).
//

import GameModels

/// One timeline display row: one repetition's entries (period 1 for a plain
/// step repeat), plus how many times that repetition repeated.
public struct DirectiveTimelineDisplayRow: Identifiable, Equatable, Sendable {
    public let unit: [DirectiveLogEntry]
    public let count: Int
    public var id: String { unit[0].id }
}

public enum DirectiveLogCollapsing {
    /// No mission's steady-state loop cycles through more distinct steps than
    /// this (Haul Run's assigning→surveying→hauling, the largest known, is
    /// 3); bounding the search keeps a wide window from matching by luck.
    static let maxPeriod = 4

    /// Collapses each maximal run of ≥2 consecutive repetitions of a
    /// period-p step cycle into one row, preferring the smallest p that
    /// explains it. A one-off pass through distinct steps renders unchanged.
    public static func collapse(_ entries: [DirectiveLogEntry]) -> [DirectiveTimelineDisplayRow] {
        var rows: [DirectiveTimelineDisplayRow] = []
        var i = 0
        while i < entries.count {
            let (period, repeats) = longestCycle(in: entries, from: i)
            if repeats >= 2 {
                rows.append(DirectiveTimelineDisplayRow(unit: Array(entries[i..<i + period]), count: repeats))
                i += period * repeats
            } else {
                rows.append(DirectiveTimelineDisplayRow(unit: [entries[i]], count: 1))
                i += 1
            }
        }
        return rows
    }

    /// Smallest period in `1...maxPeriod` whose unit, starting at `from`,
    /// repeats at least twice — tried smallest-first so a true period-3
    /// cycle is never read as its period-6 harmonic. `(1, 1)` means no cycle.
    private static func longestCycle(in entries: [DirectiveLogEntry], from start: Int) -> (period: Int, repeats: Int) {
        guard entries[start].step != nil else { return (1, 1) }
        let n = entries.count
        for period in 1...maxPeriod where start + period * 2 <= n {
            let unit = entries[start..<start + period]
            var repeats = 1
            while start + (repeats + 1) * period <= n,
                  matches(entries[(start + repeats * period)..<(start + (repeats + 1) * period)], unit) {
                repeats += 1
            }
            if repeats >= 2 { return (period, repeats) }
        }
        return (1, 1)
    }

    /// Element-wise `step`/`kind` equality; a nil `step` never matches, so a
    /// non-`.stepStarted` entry can only ever stand on its own.
    private static func matches(_ lhs: ArraySlice<DirectiveLogEntry>, _ rhs: ArraySlice<DirectiveLogEntry>) -> Bool {
        zip(lhs, rhs).allSatisfy { $0.step != nil && $0.step == $1.step && $0.kind == $1.kind }
    }
}
