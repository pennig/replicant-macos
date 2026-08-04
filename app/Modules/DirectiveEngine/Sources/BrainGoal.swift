//
//  BrainGoal.swift
//  Replicould — DirectiveEngine
//
//  The automation brain's output vocabulary. Every tick the brain reads a
//  `WorldView`, ranks what's worth pursuing, and emits exactly one
//  `BrainDecision` — the plan loop (Task 7) and the why-view UI (Task's
//  successor) both speak this type, never a bespoke shape of their own.
//
//  The brain is a PURE SELECTOR (see `brain-robustness-bar` clause 1): these
//  are inert value types describing what to do, never something that acts.
//  Enactment stays confined to launching/cancelling directives and driving
//  `DirectiveResolutionClient.{retry, cancel}` elsewhere.
//

import GameModels

/// Something worth pursuing this tick, named legibly enough to explain
/// itself.
///
/// `Goal.Kind` is the shared five-case vocabulary from the brain design
/// (`brain-goal-decision-policy`); this build populates only `.tendMesh`,
/// but the enum carries all five so later tasks don't need to widen it.
public struct Goal: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case survey, tendMesh, mine, salvage, fulfillEvent
    }

    public let kind: Kind
    /// Grow: the first-hop system to plant. Prune: the useless relay code.
    public let target: String
    /// A graph fact, never a scalar — e.g. "meshing POLARISUM — 3,200 units
    /// at VEGA, 2 hops". The brain's decisions must be explainable in terms
    /// an operator can verify against the map, not as an opaque score; a
    /// later task must not turn this into a number.
    public let rationale: String

    public init(kind: Kind, target: String, rationale: String) {
        self.kind = kind
        self.target = target
        self.rationale = rationale
    }
}

/// What the brain's plan loop hands back for a single tick.
public enum BrainDecision: Equatable, Sendable {
    /// Nothing worth doing this tick. Surfaced, not escalated — see the
    /// robustness bar's safe-degradation clause.
    case idle(reason: String)
    /// A directive was launched for `Goal`, chosen from `ranked` (the whole
    /// ranked field, best first, so the why-view can show the runners-up the
    /// choice was made against — Task 19).
    ///
    /// Reports what the tick DID, not what it intends to do: `Brain
    /// .evaluateOnce()` only answers this once the row is committed, so a
    /// failed write degrades to `.idle` rather than claiming a launch that
    /// never happened.
    case dispatch(Goal, ranked: [GrowCandidate])
    /// A directive needs operator attention before the brain can proceed.
    case stall(DirectiveAttentionReason)

    /// How a DEFERRED tick names itself inside `.idle`'s reason.
    ///
    /// A deferral is folded into `.idle` on purpose (Task 18: a deferred tick
    /// did nothing, so it idled), but it is a distinct state to an operator —
    /// "we chose not to, and here is what changed under us" reads nothing
    /// like "there was nothing to do". The why-view needs to tell them apart,
    /// and the only honest signal is this prefix, so it is a shared constant
    /// both sides reference rather than a magic string the UI sniffs for.
    public static let deferralPrefix = "deferred — "

    /// Whether this decision is a deferral rather than an ordinary idle.
    public var isDeferral: Bool {
        guard case let .idle(reason) = self else { return false }
        return reason.hasPrefix(Self.deferralPrefix)
    }
}
