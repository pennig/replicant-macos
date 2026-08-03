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
///
/// Only `.idle` and `.stall` exist in this build. `.dispatch(Goal, ranked:
/// [GrowCandidate])` is defined in Task 12 once `GrowCandidate` (the grow
/// ranking's own type) exists — adding it is a deliberate forcing function
/// that revisits every switch over this enum, not something to stub around.
public enum BrainDecision: Equatable, Sendable {
    /// Nothing worth doing this tick. Surfaced, not escalated — see the
    /// robustness bar's safe-degradation clause.
    case idle(reason: String)
    /// A directive needs operator attention before the brain can proceed.
    case stall(DirectiveAttentionReason)
}
