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
//  level, and field 1's own comparator line is dead code (see the matching
//  note on `GrowRanking.swift`'s sort closure). `completesNowBeatsCheaperDistantChain`
//  therefore shows fields 1+2 together beating field 3 (value);
//  `fewerRelaysBeatsMoreRelays` isolates field 2 alone by tying field 1
//  (both candidates NOT completing now — 2 vs 3 relays) while field 3 also
//  ties. `tierBeatsMagnitude` and `magnitudeDecidesWithinATiedTier` isolate
//  field 3's two sub-components (bestTier, then magnitudeAtTier) from each
//  other and from field 2, each with an exact `hopDistance` tie so the sort
//  is forced to actually reach field 3 — see each test's own doc comment
//  for why the world is built the way it is.
//
//  Every world-lookup that can legitimately fail uses `try #require` inside
//  a `throws` test function (never `try!`), so a broken assumption reports
//  as a clean test failure rather than trapping the whole 396-test process.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("GrowRanking")
struct GrowRankingTests {
    /// Two one-hop targets at an EXACT `hopDistance` tie (both 5 ly from
    /// MESH — `EV` at `(5,0,0)`, `AV` at `(0,5,0)`) so the sort is forced
    /// past field 2 and must decide on field 3's `bestTier` alone. Named so
    /// the tiebreak below it (designation) would pick the WRONG answer if
    /// tier were skipped: "AV" < "EV" lexicographically, so if this test
    /// only reached designation, it would (wrongly) pick the salvage
    /// system by coincidence. A non-tied-distance version of this test
    /// (the original write-up) was vacuous: distance alone already decided
    /// before the tier comparison ever ran, so the assertion held for the
    /// wrong reason — the exact tie plus the contrarian naming closes that
    /// hole.
    @Test func tierBeatsMagnitude() {
        let view = WorldView.empty(meshSystems: ["MESH"])
            .with(
                salvageUnits: ["AV": 999_999], eventSystems: ["EV"],
                starPositions: [
                    "MESH": .init(x: 0, y: 0, z: 0),
                    "EV": .init(x: 5, y: 0, z: 0),
                    "AV": .init(x: 0, y: 5, z: 0),
                ]
            )
        let graph = MeshGraph(positions: view.starPositions)
        let ranked = GrowRanking.rank(view: view, graph: graph)
        #expect(ranked.first?.firstHop == "EV") // event tier out-ranks a huge salvage pile
    }

    /// Two one-hop SALVAGE targets (same tier, so field 3a ties) at an
    /// EXACT `hopDistance` tie, differing only in unit total — isolates
    /// field 3b (`magnitudeAtTier`) alone. Named so designation contradicts
    /// magnitude: "POOR" < "RICH" lexicographically, but RICH (500 units)
    /// must win over POOR (100 units) — if magnitude were skipped, the sort
    /// would fall through tier (tied) straight to designation and wrongly
    /// pick POOR.
    @Test func magnitudeDecidesWithinATiedTier() {
        let positions: [String: Position] = [
            "MESH": .init(x: 0, y: 0, z: 0),
            "RICH": .init(x: 5, y: 0, z: 0), // 5 ly, 500 units — should win
            "POOR": .init(x: 0, y: 5, z: 0), // 5 ly, 100 units — should lose despite "P" < "R"
        ]
        let view = WorldView.empty(meshSystems: ["MESH"]).with(
            salvageUnits: ["RICH": 500, "POOR": 100],
            starPositions: positions
        )
        let graph = MeshGraph(positions: positions)
        let ranked = GrowRanking.rank(view: view, graph: graph)
        #expect(ranked.first?.firstHop == "RICH")
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
    /// Also asserts `hopDistance` on the winning (multi-relay) candidate:
    /// it's 14 — the FULL chain length from MESH through ZULU to
    /// ZULU-TARGET — not 7 (the distance to ZULU alone), which is exactly
    /// the quantity `GrowCandidate.hopDistance`'s doc comment now describes.
    @Test func fewerRelaysBeatsMoreRelays() throws {
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

        let zulu = try #require(ranked.first { $0.firstHop == "ZULU" })
        let alpha = try #require(ranked.first { $0.firstHop == "ALPHA" })
        #expect(zulu.relaysRemaining == 2)
        #expect(!zulu.completesNow)
        #expect(zulu.hopDistance == 14) // full MESH->ZULU->ZULU-TARGET chain, not just the 7 ly to ZULU
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
    @Test func designationBreaksExactTies() throws {
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

        let alpha = try #require(ranked.first { $0.firstHop == "ALPHA" })
        let bravo = try #require(ranked.first { $0.firstHop == "BRAVO" })
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
    @Test func beltMagnitudeSumsTheWinningClassCountAcrossServedTargets() throws {
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

        let candidate = try #require(ranked.first { $0.firstHop == "BELT" })
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
    @Test func candidateServingMultipleTargetsAggregatesThem() throws {
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

        let candidate = try #require(ranked.first { $0.firstHop == "ZULU" })
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

    /// Distinguishes "min distance AMONG the min-relay chains" (correct)
    /// from a plain global min across every pair regardless of relay count
    /// (a plausible regression). Two branches share `firstHop == "X"`, and
    /// `chain.hopDistance` accumulates from the MESH SOURCE (not from X) —
    /// so every total below includes the fixed MESH->X leg (7.4):
    ///
    ///   - MESH -> X -> Y0 -> TP0: 3 relays, total chain length
    ///     7.4 + 5 + 5 = 17.4 ly. This is the group's cheapest relay count
    ///     (minRelays == 3).
    ///   - MESH -> X -> Y1 -> Y2 -> TQ: 4 relays, total chain length
    ///     7.4 + 1 + 7 + 1 = 16.4 ly — MORE relays but LESS total distance
    ///     than the minRelays branch.
    ///
    /// A naive `pairs.map(\.chain.hopDistance).min()` (no relay filter)
    /// would report 16.4 (TQ's), which is wrong: the group's `hopDistance`
    /// must describe the branch that actually achieves `relaysRemaining ==
    /// 3`, i.e. 17.4, not the shortest chain among ALL branches regardless
    /// of how many relays they cost.
    ///
    /// This required going one level deeper than a literal "2 vs 3 relays"
    /// version: I proved by triangle inequality that when the CHEAPER
    /// (fewer-relay) branch is only 1 hop past the shared first hop, its
    /// distance is bounded by the single-hop maximum (`relayRangeLY`,
    /// 7.5 ly), while any branch needing a further FORCED hop (its direct
    /// shortcut provably blocked) must have a chain length exceeding that
    /// same bound — so a 2-relay branch can NEVER be beaten on distance by
    /// a 3-relay branch sharing its first hop; the two computations
    /// (filtered vs. global min) are providably IDENTICAL at that depth,
    /// and no test could distinguish them there. Going one level deeper
    /// (3-relay minimum vs. a 4-relay alternative, where the minimum
    /// branch ITSELF is multi-hop past X and so isn't bounded by a single
    /// `relayRangeLY`) is where the two computations can genuinely diverge
    /// — verified numerically (not just asserted) before writing this test
    /// by checking every pairwise distance in the fixture stays on the
    /// intended side of `relayRangeLY`, so the constructed graph forces
    /// EXACTLY the two chains described above and no cheaper alternative.
    @Test func hopDistanceIsTheMinimumAmongMinRelayChainsNotTheGlobalMinimum() throws {
        let positions: [String: Position] = [
            "MESH": .init(x: 0, y: 0, z: 0),
            "X": .init(x: 7.4, y: 0, z: 0), // the shared firstHop, 7.4 ly from MESH

            // Branch 1 — 2 hops past X (3 relays total), chain length 10.
            "Y0": .init(x: 7.4, y: 5, z: 0), // X-Y0 = 5
            "TP0": .init(x: 7.4, y: 10, z: 0), // Y0-TP0 = 5; X-TP0 = 10 (blocked, forces Y0)

            // Branch 2 — 3 hops past X (4 relays total), chain length 9,
            // shorter overall despite needing one more relay.
            "Y1": .init(x: 8.4, y: 0, z: 0), // X-Y1 = 1
            "Y2": .init(x: 15.4, y: 0, z: 0), // Y1-Y2 = 7; X-Y2 = 8 (blocked, forces Y1)
            "TQ": .init(x: 16.4, y: 0, z: 0), // Y2-TQ = 1; Y1-TQ = 8 (blocked, forces Y2)
        ]
        let view = WorldView.empty(meshSystems: ["MESH"]).with(
            salvageUnits: ["TP0": 50, "TQ": 30],
            starPositions: positions
        )
        let graph = MeshGraph(positions: positions)
        let ranked = GrowRanking.rank(view: view, graph: graph)

        let candidate = try #require(ranked.first { $0.firstHop == "X" })
        #expect(candidate.relaysRemaining == 3) // TP0's branch is cheaper in relay count
        #expect(candidate.hopDistance == 17.4) // TP0's chain length, NOT TQ's shorter 16.4
        #expect(candidate.servedTargets == ["TP0", "TQ"])
    }
}
