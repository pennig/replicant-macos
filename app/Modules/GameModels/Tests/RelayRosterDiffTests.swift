//
//  RelayRosterDiffTests.swift
//  Replicould — GameModels
//
//  `RelayNode.changed(from:to:)` — which relays a roster diff names, so the
//  star map can note them instead of forcing an unattributed full sweep.
//

import Testing
@testable import GameModels

@Suite struct RelayRosterDiffTests {

    private func node(_ code: String, _ star: String) -> RelayNode {
        RelayNode(deviceCode: code, star: star)
    }

    @Test func anIdenticalRosterNamesNoRelay() {
        let roster = [node("AAA", "SOL"), node("BBB", "VEGA")]
        #expect(RelayNode.changed(from: roster, to: roster).isEmpty)
    }

    @Test func aReorderedRosterNamesNoRelay() {
        let before = [node("AAA", "SOL"), node("BBB", "VEGA")]
        let after = [node("BBB", "VEGA"), node("AAA", "SOL")]
        #expect(RelayNode.changed(from: before, to: after).isEmpty)
    }

    @Test func anAddedRelayIsNamed() {
        let before = [node("AAA", "SOL")]
        let after = [node("AAA", "SOL"), node("BBB", "VEGA")]
        #expect(RelayNode.changed(from: before, to: after) == ["BBB"])
    }

    @Test func aRemovedRelayIsNamed() {
        let before = [node("AAA", "SOL"), node("BBB", "VEGA")]
        let after = [node("AAA", "SOL")]
        #expect(RelayNode.changed(from: before, to: after) == ["BBB"])
    }

    /// A relay that moved star is a mesh change even though the roster's
    /// membership is untouched.
    @Test func aRelayThatChangedStarIsNamed() {
        let before = [node("AAA", "SOL")]
        let after = [node("AAA", "VEGA")]
        #expect(RelayNode.changed(from: before, to: after) == ["AAA"])
    }

    @Test func severalChangesAreAllNamed() {
        let before = [node("AAA", "SOL"), node("BBB", "VEGA")]
        let after = [node("AAA", "RIGEL"), node("CCC", "DENEB")]
        #expect(RelayNode.changed(from: before, to: after) == ["AAA", "BBB", "CCC"])
    }
}
