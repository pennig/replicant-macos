//
//  BrainWhySurvey.swift
//  Replicould — Directives feature
//
//  Survey's own line in the why-view, kept out of `BrainWhyPruneNote`
//  because it answers a different question over a disjoint fleet. Own file
//  per the list-row-preview-crash rule (`BrainWhyPruneNote`'s header).
//

/// One line of "what the roaming Survey Run is doing" in the why-view.
public struct BrainWhySurvey: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// A live run, actively working.
        case running
        /// A live run that halted and needs the operator's attention.
        case halted
        /// A live run the operator paused — a choice, never a fault.
        case paused
        /// The fleet is staged and tagged; nothing owns it yet.
        case ready
        /// Nothing can launch. See `spans` for the named reason.
        case idle
    }

    public let kind: Kind
    /// The fact, with any designation tagged for the mono token.
    public let spans: [BrainWhySpan]

    public var id: String { kind.rawValue }
    public var text: String { spans.text }

    public init(kind: Kind, spans: [BrainWhySpan]) {
        self.kind = kind
        self.spans = spans
    }
}
