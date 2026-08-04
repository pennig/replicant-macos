//
//  BrainWhyViewTests.swift
//  Replicould — Directives feature
//
//  `BrainWhy.from(decision:view:)` is the brain's derived why-view model: it
//  projects a `BrainDecision` into graph-fact text an operator reads
//  directly, never a score. `isEscalated` is the load-bearing bit — an idle
//  brain must read as calm-but-surfaced, a stalled one as surfaced AND
//  escalated (robustness bar clause 6); they must not look alike.
//
//  Exhaustive over `BrainDecision`'s three cases — no `default:`. `.dispatch`
//  arrived in Task 16 and forced this file open, exactly as intended; a
//  fourth case would do the same.
//

import GameModels
import Testing
@testable import DirectiveEngine
@testable import DirectivesFeature

@Suite("BrainWhy")
struct BrainWhyViewTests {
    @Test func idleIsSurfacedButNotEscalated() {
        let why = BrainWhy.from(decision: .idle(reason: "no grow or prune work"), view: nil)
        #expect(why.topGoalGate == "idle — no grow or prune work")
        #expect(why.candidates.isEmpty)
        #expect(!why.isEscalated) // idle-calm must NOT read as a stall (clause 6)
    }

    /// A launch is surfaced and calm — a directive going out is normal
    /// operation, not an escalation. The gate is the goal's own rationale
    /// (already a graph fact), and `candidates` stays empty on purpose:
    /// rendering the ranked field is Task 19's job, and this asserts that the
    /// minimal arm added with `.dispatch` does not quietly half-render it.
    @Test func dispatchIsSurfacedAndCalm() {
        let goal = Goal(kind: .tendMesh, target: "VEGA", rationale: "meshing VEGA — 3,200 units, 1 hop")
        let why = BrainWhy.from(decision: .dispatch(goal, ranked: []), view: nil)
        #expect(why.topGoalGate == "launched — meshing VEGA — 3,200 units, 1 hop")
        #expect(why.candidates.isEmpty)
        #expect(!why.isEscalated)
    }

    @Test func stallIsSurfacedAndEscalated() {
        let why = BrainWhy.from(decision: .stall(.relayActivationFailed), view: nil)
        #expect(why.topGoalGate == "stalled — \(DirectiveAttentionReason.relayActivationFailed.displayName)")
        #expect(why.candidates.isEmpty)
        #expect(why.isEscalated)
    }
}
