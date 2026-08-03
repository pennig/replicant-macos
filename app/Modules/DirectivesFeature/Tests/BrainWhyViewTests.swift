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
//  Only `.idle`/`.stall` exist on `BrainDecision` yet, so this switch is
//  exhaustive over exactly those two cases — no `default:`. `.dispatch`
//  arrives in Task 12 and will force this file open again on purpose.
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

    @Test func stallIsSurfacedAndEscalated() {
        let why = BrainWhy.from(decision: .stall(.relayActivationFailed), view: nil)
        #expect(why.topGoalGate == "stalled — \(DirectiveAttentionReason.relayActivationFailed.displayName)")
        #expect(why.candidates.isEmpty)
        #expect(why.isEscalated)
    }
}
