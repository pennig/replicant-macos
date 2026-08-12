//
//  BrainWhyRow.swift
//  Replicould — Directives feature
//
//  One candidate the brain's why-view is showing the operator, expressed as
//  a graph fact rather than a score — mirrors `Goal`'s own `target`/
//  `rationale` pair (`DirectiveEngine/BrainGoal.swift`). Kept in its own file
//  per the list-row-preview-crash rule: a row struct beside a `#Preview`
//  crashes the Xcode 26 preview JIT. Its view is `BrainWhyRowView`, the same
//  split `DirectiveRow`/`DirectiveRowView` already uses.
//
//  Designations are stored SEPARATELY from the prose (`target` and
//  `servedTargets` beside `fact`) rather than pre-composed into a sentence,
//  so the view can render them in a mono token without taking a sentence
//  apart again. `fact` is guaranteed designation-free.
//

import UI

/// A single candidate the brain considered, as the operator would read it on
/// the map: the system it plants at, whose value that hop unlocks, and how
/// far the chain still has to run.
public struct BrainWhyRow: Equatable, Identifiable, Sendable {
    public var id: String { target }

    /// 1-based position in the brain's ranked field. Shown rather than
    /// implied by array order: the list scrolls, and a row read out of
    /// context should still say where it placed.
    public let rank: Int
    /// The candidate's first unmeshed hop — the system a relay would be
    /// planted at. A designation: always mono.
    public let target: String
    /// The systems whose value this hop unlocks, EXCLUDING `target` itself
    /// (naming the hop twice reads as a mistake). Empty when the hop is its
    /// own target. Designations: always mono.
    public let servedTargets: [String]
    /// The graph fact, in the winning tier's own units plus the chain length
    /// — "3,200 units · 1 hop". Never a score, and never contains a
    /// designation, so the view renders it wholly in the prose token.
    public let fact: String
    /// Whether this is the candidate the tick actually launched. Only ever
    /// true on a dispatch tick, and only for one row.
    public let isChosen: Bool

    public init(rank: Int, target: String, servedTargets: [String], fact: String, isChosen: Bool) {
        self.rank = rank
        self.target = target
        self.servedTargets = servedTargets
        self.fact = fact
        self.isChosen = isChosen
    }

    /// "serves ALTAIR, DENEB", already split so the designations render mono
    /// and the prose around them does not. Empty when the hop is its own
    /// target. Built here rather than in the view so it stays testable
    /// without SwiftUI in the loop.
    public var servedSpans: [BrainWhySpan] {
        guard !servedTargets.isEmpty else { return [] }
        var spans: [BrainWhySpan] = [.prose("serves ")]
        for (offset, target) in servedTargets.enumerated() {
            if offset > 0 { spans.append(.prose(", ")) }
            spans.append(.designation(target))
        }
        return spans
    }
}
