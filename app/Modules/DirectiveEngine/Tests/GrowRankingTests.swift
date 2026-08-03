//
//  GrowRankingTests.swift
//  Replicould — DirectiveEngine
//
//  Task 12: the grow ranking key — the brain's central judgement of which
//  single system to plant the next FTL relay at. Each key field is proven to
//  decide IN ISOLATION: a candidate-level `GrowCandidate` always ties
//  `completesNow` to `relaysRemaining == 1` (a group's `completesNow` is true
//  iff some served target's chain completes in exactly one relay, which is
//  exactly when the group's minimum `relaysRemaining` is 1) — so field 1 and
//  the primary component of field 2 can never disagree at the candidate
//  level. `completesNowBeatsCheaperDistantChain` therefore shows fields
//  1+2 together beating field 3 (value); `fewerRelaysBeatsMoreRelays`
//  isolates field 2 alone by tying field 1 (both candidates NOT completing
//  now — 2 vs 3 relays) while field 3 also ties.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("GrowRanking")
struct GrowRankingTests {
    // Two targets, both one hop from the mesh: an event system outranks a
    // huge salvage pile — field 3 (value: tier before magnitude).
    @Test func tierBeatsMagnitude() {
        let view = WorldView.empty(meshSystems: ["MESH"])
            .with(
                salvageUnits: ["SV": 999_999], eventSystems: ["EV"],
                starPositions: [
                    "MESH": .init(x: 0, y: 0, z: 0),
                    "EV": .init(x: 5, y: 0, z: 0),
                    "SV": .init(x: 5, y: 3, z: 0),
                ]
            )
        let graph = MeshGraph(positions: view.starPositions)
        let ranked = GrowRanking.rank(view: view, graph: graph)
        #expect(ranked.first?.firstHop == "EV") // event tier out-ranks a huge salvage pile
    }

    /// A one-hop salvage completes now; a two-hop event-rich target does
    /// not. completesNow (fields 1+2) dominates before value (field 3),
    /// even though the distant target's tier (event) beats the near one's
    /// (salvage) — if the ranking compared value first, NEAR-EVENT (the
    /// firstHop toward the 2-relay event target) would win instead.
    @Test func completesNowBeatsCheaperDistantChain() {
        let positions: [String: Position] = [
            "MESH": .init(x: 0, y: 0, z: 0),
            "NEAR": .init(x: 5, y: 0, z: 0), // 1 relay, low-value salvage
            "MID": .init(x: 0, y: 7, z: 0), // pure infrastructure hop, 1 relay from MESH
            "FAR": .init(x: 0, y: 14, z: 0), // 2 relays via MID, holds the event
        ]
        let view = WorldView.empty(meshSystems: ["MESH"]).with(
            salvageUnits: ["NEAR": 10],
            eventSystems: ["FAR"],
            starPositions: positions
        )
        let graph = MeshGraph(positions: positions)
        let ranked = GrowRanking.rank(view: view, graph: graph)

        #expect(ranked.first?.firstHop == "NEAR")
        #expect(ranked.first?.completesNow == true)
    }

    /// Two candidates, same tier and magnitude, NEITHER completes now (2 vs
    /// 3 relays) — isolates field 2 (relaysRemaining) alone, since field 1
    /// ties at `false` for both and field 3 ties exactly. Designations are
    /// deliberately chosen so field 5 (the final tiebreak) would pick the
    /// WRONG candidate ("ALPHA") if field 2 were skipped — i.e. this isn't
    /// a case where the right answer falls out of the designation order by
    /// coincidence; field 2 is genuinely load-bearing for this assertion.
    @Test func fewerRelaysBeatsMoreRelays() {
        let positions: [String: Position] = [
            "MESH": .init(x: 0, y: 0, z: 0),
            // 2-relay chain: MESH -> ZULU -> ZULU-TARGET (event). Should win.
            "ZULU": .init(x: 0, y: 7, z: 0),
            "ZULU-TARGET": .init(x: 0, y: 14, z: 0),
            // 3-relay chain: MESH -> ALPHA -> ALPHA-MID -> ALPHA-TARGET
            // (event, same magnitude). Should lose DESPITE sorting first
            // alphabetically — proving field 2, not field 5, decided.
            "ALPHA": .init(x: 7, y: 0, z: 0),
            "ALPHA-MID": .init(x: 14, y: 0, z: 0),
            "ALPHA-TARGET": .init(x: 21, y: 0, z: 0),
        ]
        let view = WorldView.empty(meshSystems: ["MESH"]).with(
            eventSystems: ["ZULU-TARGET", "ALPHA-TARGET"],
            starPositions: positions
        )
        let graph = MeshGraph(positions: positions)
        let ranked = GrowRanking.rank(view: view, graph: graph)

        let zulu = try! #require(ranked.first { $0.firstHop == "ZULU" })
        let alpha = try! #require(ranked.first { $0.firstHop == "ALPHA" })
        #expect(zulu.relaysRemaining == 2)
        #expect(!zulu.completesNow)
        #expect(alpha.relaysRemaining == 3)
        #expect(!alpha.completesNow)
        #expect(zulu.bestTier == alpha.bestTier)
        #expect(zulu.magnitudeAtTier == alpha.magnitudeAtTier)

        #expect(ranked.first?.firstHop == "ZULU") // fewer relays wins despite losing on designation
    }

    /// Identical everything (completesNow, relaysRemaining, hopDistance,
    /// bestTier, magnitudeAtTier) between two perfectly symmetric one-hop
    /// event targets — only `designation` (== firstHop) can break the tie.
    /// Determinism matters here: the brain re-ranks from scratch every
    /// 5-second tick, so an unstable order would thrash the fleet between
    /// destinations.
    @Test func designationBreaksExactTies() {
        let positions: [String: Position] = [
            "MESH": .init(x: 0, y: 0, z: 0),
            "ALPHA": .init(x: 5, y: 0, z: 0),
            "BRAVO": .init(x: 0, y: 5, z: 0),
        ]
        let view = WorldView.empty(meshSystems: ["MESH"]).with(
            eventSystems: ["ALPHA", "BRAVO"],
            starPositions: positions
        )
        let graph = MeshGraph(positions: positions)
        let ranked = GrowRanking.rank(view: view, graph: graph)

        let alpha = try! #require(ranked.first { $0.firstHop == "ALPHA" })
        let bravo = try! #require(ranked.first { $0.firstHop == "BRAVO" })
        #expect(alpha.completesNow == bravo.completesNow)
        #expect(alpha.relaysRemaining == bravo.relaysRemaining)
        #expect(alpha.hopDistance == bravo.hopDistance)
        #expect(alpha.bestTier == bravo.bestTier)
        #expect(alpha.magnitudeAtTier == bravo.magnitudeAtTier)

        #expect(ranked.first?.firstHop == "ALPHA") // lexicographically first designation wins
    }

    // MARK: - Beyond the brief's floor

    /// Belt-tier magnitude exercises the shared tier↔class mapping
    /// (`ValueTier.beltClass`) neither `tierBeatsMagnitude` (event vs.
    /// salvage) nor any earlier test above reaches. BELT holds 2 rich belts
    /// + 1 moderate belt — `bestTier` must pick `.richBelt` (ignoring the
    /// moderate one) and magnitude must count ONLY the rich belts (2, not
    /// 3). FARBELT, one further hop past BELT, adds 1 more rich belt served
    /// by the same firstHop — proving the count SUMS across served targets
    /// (2 + 1 = 3) rather than reporting just one target's count.
    @Test func beltMagnitudeSumsTheWinningClassCountAcrossServedTargets() {
        let positions: [String: Position] = [
            "MESH": .init(x: 0, y: 0, z: 0),
            "BELT": .init(x: 5, y: 0, z: 0), // 1 relay
            "FARBELT": .init(x: 10, y: 0, z: 0), // 2 relays, via BELT
        ]
        let view = WorldView.empty(meshSystems: ["MESH"]).with(
            starPositions: positions,
            beltsBySystem: [
                "BELT": [
                    BeltInfo(designation: "BELT-1", beltClass: .rich),
                    BeltInfo(designation: "BELT-2", beltClass: .rich),
                    BeltInfo(designation: "BELT-3", beltClass: .moderate),
                ],
                "FARBELT": [BeltInfo(designation: "FARBELT-1", beltClass: .rich)],
            ]
        )
        let graph = MeshGraph(positions: positions)
        let ranked = GrowRanking.rank(view: view, graph: graph)

        let candidate = try! #require(ranked.first { $0.firstHop == "BELT" })
        #expect(candidate.bestTier == .richBelt) // richest class present, moderate ignored
        #expect(candidate.magnitudeAtTier == 3) // 2 (BELT) + 1 (FARBELT) rich belts
        #expect(candidate.servedTargets == ["BELT", "FARBELT"])
    }

    @Test func emptyWorldRanksNothing() {
        let view = WorldView.empty()
        let graph = MeshGraph(positions: view.starPositions)
        #expect(GrowRanking.rank(view: view, graph: graph).isEmpty)
    }

    /// A single relay unlocks TWO targets at once: ZULU (the hop itself,
    /// holding an event) and ALPHA (one further hop past ZULU, holding
    /// salvage). Both aggregate into ONE `GrowCandidate` keyed on the shared
    /// firstHop. `servedTargets` names are chosen so plain insertion order
    /// (["ZULU", "ALPHA"]) would NOT already be alphabetical — proving the
    /// sort in the implementation is real, not incidental.
    @Test func candidateServingMultipleTargetsAggregatesThem() {
        let positions: [String: Position] = [
            "MESH": .init(x: 0, y: 0, z: 0),
            "ZULU": .init(x: 5, y: 0, z: 0), // 1 relay, itself an event target
            "ALPHA": .init(x: 10, y: 0, z: 0), // 2 relays via ZULU, salvage
        ]
        let view = WorldView.empty(meshSystems: ["MESH"]).with(
            salvageUnits: ["ALPHA": 500],
            eventSystems: ["ZULU"],
            starPositions: positions
        )
        let graph = MeshGraph(positions: positions)
        let ranked = GrowRanking.rank(view: view, graph: graph)

        let candidate = try! #require(ranked.first { $0.firstHop == "ZULU" })
        #expect(candidate.servedTargets == ["ALPHA", "ZULU"])
        #expect(candidate.bestTier == .event) // event (ZULU) outranks salvage (ALPHA)
        #expect(candidate.magnitudeAtTier == 1) // one served target holds a live event
        #expect(candidate.completesNow) // ZULU's own chain completes in 1 relay
        #expect(candidate.relaysRemaining == 1)
        #expect(candidate.hopDistance == 5)

        // No separate candidate exists for ALPHA — it was folded into ZULU.
        #expect(ranked.first { $0.firstHop == "ALPHA" } == nil)
    }

    /// A target with no chain within relay range of the mesh contributes no
    /// candidate at all — it simply never appears, rather than producing an
    /// empty/placeholder entry.
    @Test func unreachableTargetContributesNoCandidate() {
        let positions: [String: Position] = [
            "MESH": .init(x: 0, y: 0, z: 0),
            "NEAR": .init(x: 5, y: 0, z: 0),
            "FARAWAY": .init(x: 100, y: 0, z: 0),
        ]
        let view = WorldView.empty(meshSystems: ["MESH"]).with(
            salvageUnits: ["NEAR": 10, "FARAWAY": 999_999],
            starPositions: positions
        )
        let graph = MeshGraph(positions: positions)
        let ranked = GrowRanking.rank(view: view, graph: graph)

        #expect(ranked.count == 1)
        #expect(ranked.first?.firstHop == "NEAR")
        #expect(ranked.first { $0.firstHop == "FARAWAY" } == nil)
    }
}
