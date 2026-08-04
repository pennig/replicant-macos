//
//  BrainWhyPressure.swift
//  Replicould — Directives feature
//
//  One line of "what is constraining the brain right now" in the why-view.
//  Kept in its own file for the same reason `BrainWhyRow` is: it is rendered
//  from a `ForEach`, and a row struct beside a `#Preview` crashes the Xcode 26
//  preview JIT.
//
//  `kind` is the load-bearing field, not `detail`. A recent 429 must surface
//  DISTINCTLY from self-throttling (the brain-design's "limits are signals"
//  clause): the server refusing us and us pacing ourselves are different
//  operational facts with different fixes, and a surface that renders them as
//  two similar grey lines has hidden the one that matters. Typing the kind is
//  what lets the view style them apart — and what lets a test assert the
//  distinction structurally instead of by matching prose.
//

/// A single limit-pressure fact.
public struct BrainWhyPressure: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The actions budget the `CommandGovernor` paces dispatches against.
        /// Voluntary: WE stop, before the server has to.
        case governor
        /// The reserve floor (`BrainCeiling`) standing between hub stock and
        /// a print. Also voluntary.
        case reserveFloor
        /// The server answered 429. Not voluntary, and never inferred from a
        /// low budget — see `BrainLimits.rateLimitedAt`.
        case rateLimited
    }

    public let kind: Kind
    /// The fact, in the operator's words. Contains no designation — the
    /// rails are about budgets and stock, not places.
    public let detail: String

    public var id: String { kind.rawValue }

    /// Whether this pressure was imposed on us rather than chosen by us. The
    /// view's cue for treating a 429 differently from self-pacing.
    public var isImposed: Bool { kind == .rateLimited }

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}
