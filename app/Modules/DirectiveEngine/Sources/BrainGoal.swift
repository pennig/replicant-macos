//
//  BrainGoal.swift
//  Replicould — DirectiveEngine
//
//  The automation brain's output vocabulary. Every tick the brain reads a
//  `WorldView`, ranks what is worth pursuing, and emits exactly one
//  `BrainDecision`; the plan loop and the why-view UI both speak these types
//  rather than a shape of their own.
//
//  Inert value types describing what to do, never something that acts — the
//  brain is a PURE SELECTOR (`brain-robustness-bar` clause 1), and enactment
//  stays confined to launching/cancelling directives and driving
//  `DirectiveResolutionClient.{retry, cancel}` elsewhere.
//

import GameModels

/// Something worth pursuing this tick: its `kind` of work, the `target` that
/// work acts on, and the `rationale` an operator reads.
public struct Goal: Equatable, Sendable {
    /// The five goal kinds the brain's decision policy names
    /// (`brain-goal-decision-policy`). Only `.tendMesh` is ever emitted today,
    /// so a consumer switching over this handles four cases nothing produces.
    public enum Kind: String, Sendable {
        case survey, tendMesh, mine, salvage, fulfillEvent
    }

    public let kind: Kind
    /// Grow: the first-hop system to plant. Prune: the useless relay code.
    public let target: String
    /// A graph fact — "meshing POLARISUM — 3,200 units at VEGA, 2 hops".
    /// Never reduce this to a score: an operator checks the brain's decisions
    /// against the map, and a number cannot be checked against anything.
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
    /// A directive was launched for this `Goal`, chosen from `ranked` — the
    /// whole ranked field, best first, so the why-view can show the runners-up
    /// the choice was made against.
    ///
    /// Reports what the tick DID, never what it intends to do: `Brain
    /// .evaluateOnce()` answers this only once the row is committed, so a
    /// failed write degrades to `.idle` rather than claiming a launch that
    /// never happened.
    case dispatch(Goal, ranked: [GrowCandidate])
    /// A directive needs operator attention before the brain can proceed.
    case stall(DirectiveAttentionReason)

    /// How a DEFERRED tick names itself inside `.idle`'s reason — a deferral
    /// carries no case of its own, having done nothing, but reads to an
    /// operator as its own state.
    ///
    /// Both the producer and the why-view must build and test the prefix
    /// through this constant: it is the sole signal separating "we chose not
    /// to, and here is what changed under us" from "there was nothing to do",
    /// and a literal spelled on either side silently merges the two.
    public static let deferralPrefix = "deferred — "

    /// Whether this decision is a deferral rather than an ordinary idle.
    public var isDeferral: Bool {
        guard case let .idle(reason) = self else { return false }
        return reason.hasPrefix(Self.deferralPrefix)
    }
}
