//
//  PruneTests.swift
//  Replicould — DirectiveEngine
//
//  The path-union & prune partition — grow's computation read inversely. Worlds
//  are built by `prunableWorld`, whose mesh is DERIVED from its relay rows, so no
//  test can assert against a mesh production could not produce. Two facts decide
//  most cases: the union is rooted at the ANCHOR, not the mesh (a deployed relay
//  is a free interior node, never a source); and since an existing relay is free,
//  any path using the mesh beats one re-planting around it, so exact ties only
//  arise between two all-free chains. Hop range is 7.5 ly.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Prune predicate (the path-union, read inversely)")
struct PruneTests {
    /// Live salvage at T is commandable only because W bridges 14 ly the anchor
    /// cannot span. T already HOLDS a relay, which is what sharpens this: grow's
    /// `reach` reports nothing for an already-meshed target, so a union read off
    /// grow's chains would call the whole chain reclaimable and strand the salvage.
    @Test func loadBearingRelayIsPinned() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "W": .init(x: 0, y: 7, z: 0),
            "T": .init(x: 0, y: 14, z: 0), // 14 ly from SOL — two hops, never one
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_W": "W", "REL_T": "T"],
            salvage: ["T": 500]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_W", "REL_T"])
        #expect(analysis.reclaimable.isEmpty)
        // Pinned by JUDGEMENT, and this is the only line that says so — the
        // partition is byte-identical to what a decline returns.
        #expect(analysis.declined == nil)
    }

    /// The thrash guard. Planting W makes every path through W one relay cheaper
    /// while leaving paths avoiding it untouched, so the through-W path is STRICTLY
    /// cheapest and no tiebreak can drop it — which makes
    /// plant-then-immediately-reclaim structurally impossible, not merely unlikely.
    @Test func brandNewHopTowardUnreachedValueIsPinnedByConstruction() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "W": .init(x: 0, y: 7, z: 0),
            "V": .init(x: 0, y: 14, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_W": "W"], // V is NOT yet meshed
            salvage: ["V": 500]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_W"])
        #expect(analysis.reclaimable.isEmpty)
    }

    /// A standing relay is not made useless by a shorter route that must be BUILT.
    /// `AA` offers 12 ly against W's 13.4 and wins on distance, but taking it means
    /// planting. This is what stops prune recommending the brain tear down a
    /// working chain to rebuild a marginally tidier one.
    @Test func standingRelayOutranksACheaperRouteThatWouldHaveToBePlanted() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "W": .init(x: 3, y: 6, z: 0), // relay standing, 6.7 + 6.7 = 13.4 ly to V
            "AA": .init(x: 0, y: 6, z: 0), // unmeshed, 6 + 6 = 12 ly to V — shorter, but must be planted
            "V": .init(x: 0, y: 12, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_W": "W"],
            salvage: ["V": 500]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_W"])
        #expect(analysis.reclaimable.isEmpty)
    }

    /// The thrash-guard world with one variable changed: V's salvage depleted, so
    /// V drops out of the live-value set and W falls off the union. Depletion is
    /// sticky, so this is a durable transition rather than a flicker.
    @Test func durablyUselessRelayIsReclaimable() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "W": .init(x: 0, y: 7, z: 0),
            "V": .init(x: 0, y: 14, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_W": "W"],
            salvage: [:] // V's pile is spent
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.reclaimable == [ReclaimableRelay(deviceCode: "REL_W", system: "W")])
        // The anchor's own relay is never reclaimable even with nothing left to
        // serve — every path begins there, so reclaiming it cuts the mesh from the
        // replicant that authorises it.
        #expect(analysis.pinned == ["REL_SOL"])
    }

    /// A mine belt never depletes, so its relay can never fall off the union. The
    /// variable is ISOLATED: `MINE` and `DEAD` are the same shape and differ only
    /// in the belt, so a predicate ignoring belts returns them identically.
    @Test func perpetualMineBeltRelayIsNeverPrunable() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "MINE": .init(x: 0, y: 7, z: 0),
            "DEAD": .init(x: 0, y: -7, z: 0), // 14 ly from MINE — not adjacent to it
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_MINE": "MINE", "REL_DEAD": "DEAD"],
            belts: ["MINE": [BeltInfo(designation: "MINE-2-BELT", beltClass: .rich)]]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_MINE"])
        #expect(analysis.reclaimable == [ReclaimableRelay(deviceCode: "REL_DEAD", system: "DEAD")])
    }

    /// Value AT the relay's own system pins it, through every channel the
    /// live-value set is built from. `SALV` (salvage) and `EVT` (a live
    /// location event) are pinned; `DEAD`, identical in every other respect,
    /// is not — so each channel is shown to decide on its own rather than the
    /// whole leaf set being pinned for a shared reason.
    @Test func relayAtASystemHoldingValueItselfIsPinned() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "SALV": .init(x: 0, y: 7, z: 0),
            "EVT": .init(x: 7, y: 0, z: 0),
            "DEAD": .init(x: 0, y: 0, z: 7),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_SALV": "SALV", "REL_EVT": "EVT", "REL_DEAD": "DEAD"],
            salvage: ["SALV": 100],
            events: ["EVT"]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_SALV", "REL_EVT"])
        #expect(analysis.reclaimable == [ReclaimableRelay(deviceCode: "REL_DEAD", system: "DEAD")])
    }

    /// Two equal-cost chains reach T and the tiebreak pins ONE COMPLETE chain, so
    /// the loser's reclamation cannot strand T — the pinned set is by construction
    /// a connected subgraph still serving every live target. That does NOT license
    /// reclaiming the whole complement at once: taking a nearer reclaimable relay
    /// first can remove the authority needed to reach a farther one.
    ///
    /// Proven geometry-independently: the two positions are mirror images about the
    /// SOL→T axis and the run repeats with the designations SWAPPED, so designation
    /// rather than position or dictionary order is isolated as the decider.
    @Test func equalCostAlternativeChainsPinOneCompleteServingChain() {
        for (west, east) in [("AWEST", "ZEAST"), ("ZEAST", "AWEST")] {
            let positions: [String: Position] = [
                "SOL": .init(x: 0, y: 0, z: 0),
                west: .init(x: -3, y: 6.5, z: 0), // 7.16 ly from both SOL and T
                east: .init(x: 3, y: 6.5, z: 0), // ditto, exactly
                "T": .init(x: 0, y: 13, z: 0), // 13 ly from SOL — never one hop
            ]
            let world = prunableWorld(
                positions: positions,
                relays: [
                    "REL_SOL": "SOL", "REL_\(west)": west, "REL_\(east)": east, "REL_T": "T",
                ],
                salvage: ["T": 500]
            )
            let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
            #expect(analysis.pinned == ["REL_SOL", "REL_AWEST", "REL_T"])
            #expect(analysis.reclaimable == [ReclaimableRelay(deviceCode: "REL_ZEAST", system: "ZEAST")])
        }
    }

    /// Nothing deployed, nothing known: an empty partition, not a crash and
    /// not a phantom entry.
    @Test func emptyMeshYieldsAnEmptyPartition() {
        let world = prunableWorld(positions: [:], relays: [:], hub: nil)
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: [:]))
        #expect(analysis == PruneAnalysis(pinned: [], reclaimable: []))
        // Not `.noAnchor`, though there is no hub: with nothing deployed
        // there is nothing to judge, which is a real (empty) answer.
        #expect(analysis.declined == nil)
    }

    /// No anchor, no judgement. Without a hub the brain has nothing to root
    /// the union at, and an unrooted union would call the whole mesh useless
    /// — so the predicate refuses to judge and pins everything.
    ///
    /// The world is `durablyUselessRelayIsReclaimable`'s exactly, minus the
    /// hub: that test proves REL_W is reclaimable when the anchor is known,
    /// so the flip here can only be the missing anchor.
    @Test func missingAnchorPinsEveryRelay() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "W": .init(x: 0, y: 7, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_W": "W"],
            hub: nil,
            salvage: [:]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_W"])
        #expect(analysis.reclaimable.isEmpty)
        #expect(analysis.declined == .noAnchor)
    }

    /// An anchor the census cannot place is the same "cannot judge" as no
    /// anchor at all — the search would have no source to run from, and an
    /// empty union reads as "reclaim everything". Same world as
    /// `loadBearingRelayIsPinned`, with SOL's census row missing.
    @Test func anchorWithNoCensusPositionPinsEveryRelay() {
        let positions: [String: Position] = [
            "W": .init(x: 0, y: 7, z: 0),
            "T": .init(x: 0, y: 14, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_W": "W", "REL_T": "T"],
            salvage: ["T": 500]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_W", "REL_T"])
        #expect(analysis.reclaimable.isEmpty)
        #expect(analysis.declined == .censusIncomplete(systems: ["SOL"]))
    }

    /// A census hole ANYWHERE stops the whole judgement, not just that of the
    /// unplaceable relay: a missing row breaks every path that would have run
    /// through it, offering up load-bearing relays behind the hole. Isolated
    /// against `perpetualMineBeltRelayIsNeverPrunable` — same world, MINE's census
    /// row removed, MINE still surveyed, and DEAD is the verdict that flips.
    @Test func censusHoleAnywhereInTheMeshPinsEveryRelay() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            // MINE's census row has not been paged in yet.
            "DEAD": .init(x: 0, y: -7, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_MINE": "MINE", "REL_DEAD": "DEAD"],
            belts: ["MINE": [BeltInfo(designation: "MINE-2-BELT", beltClass: .rich)]],
            surveyed: ["SOL", "MINE", "DEAD"]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_MINE", "REL_DEAD"])
        #expect(analysis.reclaimable.isEmpty)
        #expect(analysis.declined == .censusIncomplete(systems: ["MINE"]))
    }

    /// The value sources are all independent of the `stars` table, so "we know V
    /// holds salvage but have no census row for it" is reachable. An unplaceable
    /// target drops silently out of `pathUnion`, taking W's only pin with it — and
    /// W was planted THIS tick, so it would be planted and reclaimed consecutively.
    /// Isolated against `brandNewHopToward…`, where `declined == nil` tells apart
    /// the same verdict reached by judgement rather than by refusal.
    @Test func inProgressChainTowardUnplaceableValueIsNotOfferedUp() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "W": .init(x: 0, y: 7, z: 0),
            // V holds a live assay, but its census row has not arrived.
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_W": "W"],
            salvage: ["V": 500]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_W"])
        #expect(analysis.reclaimable.isEmpty)
        #expect(analysis.declined == .censusIncomplete(systems: ["V"]))
    }

    /// A system holding our own deployed hardware is pinned even with its value
    /// gone: the assay at `WORKING` depletes while the vessel is still on station,
    /// and value-only targeting would offer up the relay that makes it commandable
    /// at all — stranding hardware, not merely losing value. `EMPTY` is the control.
    @Test func systemHoldingOurOwnDeployedDevicesIsPinned() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "WORKING": .init(x: 0, y: 7, z: 0),
            "EMPTY": .init(x: 0, y: -7, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_WORKING": "WORKING", "REL_EMPTY": "EMPTY"],
            salvage: [:], // the pile depleted this tick
            fleet: ["V1": "WORKING"] // …but the vessel is still there
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_WORKING"])
        #expect(analysis.reclaimable == [ReclaimableRelay(deviceCode: "REL_EMPTY", system: "EMPTY")])
    }

    /// Unknown value reads as pinned. Belt richness is legible only after a full
    /// scan, and `beltsBySystem` cannot tell "scanned, no belt" from "never
    /// scanned". `SURVEYED` is the control: same shape, same lack of known value,
    /// but looked at — so its emptiness is a fact rather than an absence of one.
    @Test func meshedSystemNobodyHasSurveyedIsPinned() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "UNKNOWN": .init(x: 0, y: 7, z: 0),
            "SURVEYED": .init(x: 0, y: -7, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_UNKNOWN": "UNKNOWN", "REL_SURVEYED": "SURVEYED"],
            surveyed: ["SOL", "SURVEYED"]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_UNKNOWN"])
        #expect(
            analysis.reclaimable == [ReclaimableRelay(deviceCode: "REL_SURVEYED", system: "SURVEYED")]
        )
    }

    /// A relay that reports itself relaying but carries no location cannot be
    /// placed on the map, so it cannot be judged useless — it is pinned. The
    /// case is reachable in the live fleet: stowing clears `location` while
    /// the row's status can still read `relaying` until the next confirm-read
    /// lands.
    @Test func relayWithNoLocationIsPinned() {
        let positions: [String: Position] = ["SOL": .init(x: 0, y: 0, z: 0)]
        var world = prunableWorld(positions: positions, relays: ["REL_SOL": "SOL"])
        let homeless = deviceFixture(
            code: "REL_LOST", type: "ftl_relay", location: nil,
            status: "relaying", features: ["relay"]
        )
        var devices = world.devices
        devices[homeless.deviceCode] = homeless
        world = WorldView(
            devices: devices, starPositions: world.starPositions, meshSystems: world.meshSystems,
            salvageUnits: world.salvageUnits, eventSystems: world.eventSystems,
            hubLocation: world.hubLocation, beltsBySystem: world.beltsBySystem,
            surveyedSystems: world.surveyedSystems, now: world.now
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_LOST"])
        #expect(analysis.reclaimable.isEmpty)
    }

    /// `reclaimable` is ordered by device code. `WorldView.devices` is a
    /// Dictionary, so without an explicit sort the order would vary run to
    /// run — and a later task picks a reclaim source off this list, which
    /// must not depend on hash seeding.
    @Test func reclaimableIsOrderedByDeviceCode() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "ONE": .init(x: 0, y: 7, z: 0),
            "TWO": .init(x: 7, y: 0, z: 0),
            "THREE": .init(x: 0, y: 0, z: 7),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_C": "ONE", "REL_A": "TWO", "REL_B": "THREE"]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.reclaimable.map(\.deviceCode) == ["REL_A", "REL_B", "REL_C"])
        #expect(analysis.reclaimable.map(\.system) == ["TWO", "THREE", "ONE"])
    }

    // MARK: - The census precondition, enforced against the GRAPH

    /// The precondition is only worth anything if it validates the census the
    /// SEARCH reads. Here the view can place `W` and the graph cannot: read off the
    /// graph the anchor cannot span 14 ly to `T`, the union collapses to the
    /// anchor, and both relays read reclaimable with live salvage behind them. The
    /// predicate must refuse to judge instead.
    @Test func aGraphThatCannotPlaceAMeshSystemDeclinesRatherThanShrinkingTheUnion() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "W": .init(x: 0, y: 7, z: 0),
            "T": .init(x: 0, y: 14, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_W": "W", "REL_T": "T"],
            salvage: ["T": 500]
        )
        // The one difference from `loadBearingRelayIsPinned`: the graph is
        // built from a census missing `W`, which the VIEW still lists.
        let deficient = MeshGraph(positions: positions.filter { $0.key != "W" })
        let analysis = PrunePredicate.analyse(view: world, graph: deficient)

        #expect(analysis.declined == .censusIncomplete(systems: ["W"]))
        #expect(analysis.reclaimable.isEmpty, "a declined analysis offers up nothing at all")
        #expect(analysis.pinned == ["REL_SOL", "REL_W", "REL_T"])
    }

    // MARK: - The anchor is authority, not just the printer

    /// **The print hub is not where authority comes from — a replicant is.** The
    /// anchor is the hub's system on the assumption the two are co-located, which
    /// nothing enforces. Here they are not, and judged on the hub→value path alone
    /// the relays on the replicant's road read reclaimable — severing the mesh from
    /// the one stationary replicant that makes any of it commandable.
    @Test func relaysOnTheRoadToAReplicantAwayFromTheHubArePinned() {
        let positions: [String: Position] = [
            "HUBSYS": .init(x: 0, y: 0, z: 0),
            "MID": .init(x: 0, y: 7, z: 0),
            "REPSYS": .init(x: 0, y: 14, z: 0),
            "VALUE": .init(x: 0, y: -7, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: [
                "REL_HUB": "HUBSYS", "REL_MID": "MID", "REL_REP": "REPSYS", "REL_VAL": "VALUE",
            ],
            hub: "HUBSYS",
            salvage: ["VALUE": 500],
            replicants: ["REPSYS"]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))

        #expect(analysis.declined == nil)
        #expect(analysis.reclaimable.isEmpty, "nothing here is spare — every relay carries authority or value")
        #expect(analysis.pinned == ["REL_HUB", "REL_MID", "REL_REP", "REL_VAL"])
    }

    /// The other side of the same rule, so the fix above is a TARGET and not a
    /// blanket "pin everything near a replicant". `SPUR` holds a relay, holds
    /// no replicant, and lies on no path from the hub to value or to the
    /// replicant — it is still spare, and prune still says so.
    @Test func aRelayOffEveryAuthorityAndValueRoadIsStillReclaimable() {
        let positions: [String: Position] = [
            "HUBSYS": .init(x: 0, y: 0, z: 0),
            "REPSYS": .init(x: 0, y: 7, z: 0),
            "VALUE": .init(x: 0, y: -7, z: 0),
            "SPUR": .init(x: 7, y: 0, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: [
                "REL_HUB": "HUBSYS", "REL_REP": "REPSYS", "REL_VAL": "VALUE", "REL_SPUR": "SPUR",
            ],
            hub: "HUBSYS",
            salvage: ["VALUE": 500],
            replicants: ["REPSYS"]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))

        #expect(analysis.pinned == ["REL_HUB", "REL_REP", "REL_VAL"])
        #expect(analysis.reclaimable == [ReclaimableRelay(deviceCode: "REL_SPUR", system: "SPUR")])
    }

    /// An OFF-MESH replicant adds no target: authority there is a replicant
    /// present, which no relay grants or takes away, and admitting it would force
    /// the census precondition to place every roaming replicant or decline forever.
    /// `ROAMING` sits 14 ly out, reachable only THROUGH `SPUR`, so the test
    /// discriminates — treat every replicant system as a target and `REL_SPUR` pins.
    @Test func anOffMeshReplicantPinsNothing() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "SPUR": .init(x: 0, y: 7, z: 0),
            "ROAMING": .init(x: 0, y: 14, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_SPUR": "SPUR"],
            salvage: ["SOL": 500],
            replicants: ["ROAMING"]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))

        #expect(analysis.declined == nil)
        #expect(analysis.reclaimable == [ReclaimableRelay(deviceCode: "REL_SPUR", system: "SPUR")])
    }
}
