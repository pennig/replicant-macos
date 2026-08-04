//
//  BrainGoalTests.swift
//  Replicould — DirectiveEngine
//
//  The brain's output vocabulary: a `Goal` names what to pursue with a
//  legible graph-fact rationale, and `BrainDecision` is what the plan loop
//  hands back each tick. Only `.idle`/`.stall` exist yet — `.dispatch`
//  arrives in Task 12 once `GrowCandidate` is defined.
//

import GameModels
import Testing
@testable import DirectiveEngine

@Suite("BrainDecision")
struct BrainGoalTests {
    @Test func decisionsAreDistinct() {
        #expect(BrainDecision.idle(reason: "x") != BrainDecision.stall(.relayActivationFailed))
    }

    @Test func goalCarriesItsFields() {
        let a = Goal(
            kind: .tendMesh, target: "POLARISUM",
            rationale: "meshing POLARISUM — 3,200 units at VEGA, 2 hops"
        )
        let b = Goal(kind: .tendMesh, target: "POLARISUM", rationale: "a different rationale")
        #expect(a.kind == .tendMesh)
        #expect(a.target == "POLARISUM")
        #expect(a.rationale == "meshing POLARISUM — 3,200 units at VEGA, 2 hops")
        // Two goals differing only in rationale are unequal — the rationale
        // is a load-bearing field, not decoration.
        #expect(a != b)
    }
}
