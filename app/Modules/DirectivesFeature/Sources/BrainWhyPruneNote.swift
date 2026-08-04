//
//  BrainWhyPruneNote.swift
//  Replicould — Directives feature
//
//  One line of "what prune made of the mesh this tick" in the why-view. Kept
//  in its own file for the same reason `BrainWhyPressure` and `BrainWhyRow`
//  are: it is rendered from a `ForEach`, and a row struct beside a `#Preview`
//  crashes the Xcode 26 preview JIT.
//
//  **PRUNE NEVER ESCALATES, and this type is where that is made structural.**
//  Growth can halt and need an operator; prune has no stall path at all,
//  because "there is a spare relay I haven't reused yet" is never a problem
//  requiring human intervention. So nothing here can raise `BrainWhy
//  .isEscalated`, and the states that describe a mesh at rest are tagged
//  `isObservation` so the view can render them as something noticed rather than
//  something wrong.
//
//  `kind` is the load-bearing field, not `spans` — the same argument
//  `BrainWhyPressure` makes about a 429 versus self-throttling, and it applies
//  twice as hard here. `PrunePredicate` returns an all-pinned partition BOTH
//  when it cannot judge the world (`declined`) and when every relay is
//  genuinely load-bearing, and the two were byte-identical before
//  `PruneDeclineReason` existed. "I can't judge right now" and "nothing is
//  spare" are different facts with different fixes; typing the kind is what
//  lets the view style them apart and what lets a test assert the distinction
//  structurally instead of by matching prose.
//

/// A single prune fact, split into prose and designation runs so the
/// system names inside it render monospaced (`BrainWhySpan`).
public struct BrainWhyPruneNote: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The tick sourced a grow from a spare relay instead of printing one.
        /// An action taken — and the only kind that can share a card with
        /// another.
        case reclaimed
        /// Spare relays left where they stand. An observation, never a stall.
        case spare
        /// Prune judged the mesh and found nothing spare — every relay is on a
        /// road the mesh needs.
        case pinned
        /// Prune refused to judge this world. Distinct from `pinned` on
        /// purpose: see this file's header.
        case declined
    }

    public let kind: Kind
    /// The fact, with its designations tagged for the mono token.
    public let spans: [BrainWhySpan]

    /// At most one note of each kind is ever produced in a tick, so the kind
    /// identifies it.
    public var id: String { kind.rawValue }

    /// The line as plain text — what an operator would read aloud.
    public var text: String { spans.text }

    /// Whether this note describes a mesh at rest rather than something the
    /// brain did or could not do. The view's cue for rendering it a step back:
    /// a spare relay is a fact about the fleet's shape, and a surface that gave
    /// it the weight of a problem would be teaching the operator to act on it.
    public var isObservation: Bool { kind == .spare || kind == .pinned }

    public init(kind: Kind, spans: [BrainWhySpan]) {
        self.kind = kind
        self.spans = spans
    }
}
