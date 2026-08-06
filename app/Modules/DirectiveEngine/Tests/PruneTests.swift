//
//  PruneTests.swift
//  Replicould — DirectiveEngine
//
//  Task 21: the path-union & prune partition — grow's computation read
//  inversely. Every world below is built by `prunableWorld`, whose mesh is
//  DERIVED from its relay device rows, so no test can assert against a mesh
//  production could not produce.
//
//  Two structural facts decide almost every case here, and both are worth
//  holding in mind while reading:
//
//  1. The union is rooted at the ANCHOR (the hub's system), not at "the mesh"
//     — a deployed relay is a free INTERIOR node on the way out from the
//     anchor, never a source. Rooting at the whole mesh (which is what
//     `MeshGraph.reach` does for grow) makes every relay a zero-cost source
//     that is then filtered out of `Chain.waypoints`, so no relay could ever
//     land on the union and every one of them would read as reclaimable. See
//     `PrunePredicate.swift`'s header.
//  2. Because an existing relay is free and a new one costs a relay, any path
//     that USES the existing mesh is strictly cheaper than one that re-plants
//     around it. Exact ties are therefore only ever between two all-free
//     paths — two parallel existing chains — where one really is redundant;
//     `equalCostAlternativeChainsPinOneCompleteServingChain` pins that.
//
//  Geometry: `MeshGraph`'s hop range is 7.5 ly, so a 7 ly gap is one hop and
//  a 13–14 ly gap is not.
//

import Foundation
import Testing
import UniverseModels

@testable import DirectiveEngine

@Suite("Prune predicate (the path-union, read inversely)")
struct PruneTests {
    /// Load-bearing. Live salvage at T is only commandable because the relay
    /// at W bridges the 14 ly the anchor cannot span alone, so W is on the
    /// anchor→T path and must be pinned.
    ///
    /// T already HOLDS a relay (it is reached value, not grow-wanted), which
    /// is what makes this the sharpest case in the suite: grow's own
    /// `reach` deliberately reports nothing at all for an already-meshed
    /// target, so a union read off grow's chains is empty here and would
    /// call every relay in the chain reclaimable — stranding the salvage
    /// behind the very relay it reclaimed.
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
        // Pinned-by-judgement, and this is the ONLY thing that says so: the
        // partition itself is byte-identical to what a decline returns.
        #expect(analysis.declined == nil)
    }

    /// The thrash guard. W was planted this tick as the first hop toward V,
    /// which still holds live salvage and is still unmeshed — so W lies on
    /// the cheapest anchor→V path and is pinned BY CONSTRUCTION.
    ///
    /// Not a coincidence of this geometry: planting W makes every path
    /// through W exactly one relay cheaper while leaving every path that
    /// avoids W untouched, so the through-W path is STRICTLY cheapest and no
    /// tiebreak can drop it. A fresh hop can therefore never read as useless,
    /// which is what makes plant-then-immediately-reclaim structurally
    /// impossible rather than merely unlikely.
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

    /// A relay already standing is not made useless by the existence of a
    /// shorter route that would have to be BUILT. `AA` offers a 12 ly path to
    /// the salvage at V against W's 13.4, and would win on distance — but
    /// taking it means planting a relay, and the union costs an existing
    /// relay at nothing. So the union runs through W, and W stays pinned.
    ///
    /// This is the predicate-level half of `MeshGraph`'s
    /// `freeRouteBeatsAShorterRouteThatMustPlant`, and it is what stops prune
    /// from recommending the brain tear down a working chain to rebuild a
    /// marginally tidier one — the graph-shaped form of thrash.
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

    /// Durable uselessness. The SAME world as the thrash-guard case above,
    /// with one variable changed: V's salvage has depleted, so V drops out of
    /// the live-value set. Nothing else routes through W, it falls off the
    /// union, and it becomes reclaimable — carrying its system, which is what
    /// a later task's nearest-source search needs.
    ///
    /// Depletion is sticky (`SiteAssay.depleted` never un-sets and
    /// `WorldView.salvageUnits` excludes depleted sites), so this is a
    /// durable transition, not a flicker.
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
        // The anchor's own relay is never reclaimable, even with no value left
        // to serve: every anchor→target path begins there, so reclaiming it
        // would cut the mesh from the replicant that authorises it.
        #expect(analysis.pinned == ["REL_SOL"])
    }

    /// A mine belt never depletes, so its system stays a live-value target
    /// forever and the relay standing in it can never fall off the union.
    ///
    /// The variable is ISOLATED: `MINE` and `DEAD` are the same shape — both
    /// meshed leaves exactly 7 ly off the anchor, neither on the way to
    /// anything else, adjacent to nothing but SOL. The only difference is
    /// that MINE holds a rich belt. If the predicate ignored belts (or pinned
    /// leaves for some unrelated reason) the two would come out the same way.
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

    /// The equal-cost tie carried forward from the Dijkstra task's review: two
    /// chains of the same cost reach T, `reach`'s total order picks exactly
    /// one, and a relay on the road not taken lies on no returned path.
    ///
    /// It resolves, and the reason is worth stating precisely. Because an
    /// existing relay is free to traverse while a new one costs a relay, an
    /// exact tie can only ever arise between two ALL-EXISTING chains — one of
    /// which is genuinely redundant. The tiebreak then pins ONE COMPLETE
    /// chain (SOL→AWEST→T here), so the loser's reclamation cannot strand T:
    /// the pinned set is by construction a connected subgraph that still
    /// serves every live target.
    ///
    /// That property is about SERVING THE TARGETS, and it does not license
    /// reclaiming the whole complement in one go: a reclaim is itself an
    /// operation on a relay, and taking a nearer reclaimable relay first can
    /// remove the command authority needed to reach a farther one. Sequencing
    /// reclaims is the reclaim task's problem; the partition only promises
    /// that nothing on the pinned side is ever needed by nothing.
    ///
    /// Proven geometry-independently, the same way `MeshGraphReachTests`
    /// proves `reach`'s own tiebreak: the two positions are mirror images
    /// about the SOL→T axis (identical distances to the digit), and the run
    /// is repeated with the designations SWAPPED between them. "AWEST" wins
    /// both times, which isolates designation — not position, not dictionary
    /// order — as the deciding factor.
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

    /// A census hole ANYWHERE in the mesh stops the whole judgement, not just
    /// the judgement of the unplaceable relay.
    ///
    /// The union can only contain systems the graph can place, so a missing
    /// census row makes a system invisible to the search — and, worse, breaks
    /// every path that would have run THROUGH it, offering up load-bearing
    /// relays standing behind the hole. The `stars` census really does lag
    /// (it repopulates after a reset and trails `systemDetails`), so this is
    /// a live state.
    ///
    /// Isolated to one variable against `perpetualMineBeltRelayIsNeverPrunable`
    /// — the identical world, in which REL_DEAD is reclaimable — with MINE's
    /// census row removed and MINE still marked surveyed, so the flip can only
    /// be the census hole and not the unknown-value clause. Note MINE is not
    /// the relay whose verdict changes: DEAD is placeable and still stops
    /// being offered.
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

    /// An in-progress chain toward value the census has not paged in yet must
    /// not be offered up — the thrash guard failing under exactly the lag the
    /// coverage precondition exists for.
    ///
    /// The target sources are all independent of the `stars` table (salvage
    /// from `SiteAssay`, belts from `SystemDetail`, events from
    /// `LocationEvent`), so "we know V holds salvage but have no census row
    /// for it" is a reachable state. An unplaceable target drops silently out
    /// of `pathUnion`, taking with it the only pin W had — and W is a relay
    /// the brain planted THIS tick, so it would be planted and reclaimed in
    /// consecutive ticks.
    ///
    /// Isolated against `brandNewHopTowardUnreachedValueIsPinnedByConstruction`
    /// — the identical world WITH V's census row, where REL_W is pinned by
    /// judgement (`declined == nil`). Same verdict on REL_W here, reached the
    /// other way, and `declined` is what tells the two apart.
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

    /// A system holding our own deployed hardware is pinned even when its
    /// value is gone.
    ///
    /// The scenario is ordinary: the last salvage assay at `WORKING` depletes
    /// while the vessel and its drones are still on station and a Haul Run is
    /// still draining the pile. Value-only targeting drops the system that
    /// same tick and offers up the relay that makes the vessel commandable at
    /// all — and per the FTL authority rule, a device whose system leaves the
    /// mesh subgraph cannot be recovered, so this strands hardware rather
    /// than merely losing value.
    ///
    /// `EMPTY` is the control: identical in every respect, no vessel.
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

    /// A system whose value is spent but whose EXTRACTED units are still on
    /// the ground is pinned.
    ///
    /// The pile is not value in the ground — it is inventory we already own,
    /// waiting for a Haul Run to collect it, and `HaulTargetPlanner` can only
    /// issue the `ferry` that collects it while both ends sit on the mesh. So
    /// reclaiming the relay does not lose a prospect, it strands units already
    /// paid for. Depleted salvage is exactly the state that leaves a full pile
    /// behind, which puts this on the ordinary path out of every finished
    /// Salvage Run rather than in a corner of the state space.
    ///
    /// `EMPTY` is the control: identical in every respect, nothing left on the
    /// ground.
    @Test func systemHoldingAnUncollectedStockpileIsPinned() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "PILE": .init(x: 0, y: 7, z: 0),
            "EMPTY": .init(x: 0, y: -7, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_PILE": "PILE", "REL_EMPTY": "EMPTY"],
            salvage: [:], // every assay in both systems is spent
            stockpiles: ["PILE": 500] // …but PILE's mined units are still sitting there
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_PILE"])
        #expect(analysis.reclaimable == [ReclaimableRelay(deviceCode: "REL_EMPTY", system: "EMPTY")])
    }

    /// A stockpile is a TARGET, so the whole road to it is pinned and not just
    /// the relay standing on top of it.
    ///
    /// `W` holds nothing itself and bridges the 14 ly the anchor cannot span,
    /// so it survives only if the pile at `PILE` is a target the union is built
    /// over. Pinning the pile's own system alone would leave `W` spare and the
    /// units just as unreachable.
    @Test func relaysOnTheRoadToAStockpileArePinned() {
        let positions: [String: Position] = [
            "SOL": .init(x: 0, y: 0, z: 0),
            "W": .init(x: 0, y: 7, z: 0),
            "PILE": .init(x: 0, y: 14, z: 0),
        ]
        let world = prunableWorld(
            positions: positions,
            relays: ["REL_SOL": "SOL", "REL_W": "W", "REL_PILE": "PILE"],
            salvage: [:],
            stockpiles: ["PILE": 500]
        )
        let analysis = PrunePredicate.analyse(view: world, graph: MeshGraph(positions: positions))
        #expect(analysis.pinned == ["REL_SOL", "REL_W", "REL_PILE"])
        #expect(analysis.reclaimable.isEmpty)
        #expect(analysis.declined == nil)
    }

    /// A meshed system nobody has surveyed holds UNKNOWN value, and unknown
    /// reads as pinned.
    ///
    /// Belt richness — the one value signal that never depletes — is only
    /// legible after a full system scan, and `beltsBySystem` cannot tell
    /// "scanned, holds no belt" from "never scanned": both are simply absent.
    /// `SURVEYED` is the control that proves the distinction is really being
    /// drawn — same shape, same lack of any known value, but it HAS been
    /// looked at, so its emptiness is a fact rather than an absence of one.
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
    /// SEARCH reads, and until Task 23 it did not: it filtered
    /// `view.starPositions` while `search`/`backtrack` read `MeshGraph`'s own
    /// positions. The contract "build the graph from `view.starPositions`" was
    /// documented and unenforced, so a caller handing over a filtered or older
    /// graph passed the precondition vacuously — and every system the graph
    /// could not place then dropped silently out of the union, taking with it
    /// the pins it was the sole source of.
    ///
    /// This is that exact divergence: the view can place `W`, the graph cannot.
    /// Read off the graph, `W` is unplaceable, the anchor cannot span the 14 ly
    /// to `T` at all, the union collapses to the anchor, and both `REL_W` and
    /// `REL_T` read reclaimable — with live salvage sitting behind them. The
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

    /// **The print hub is not where authority comes from — a replicant is.**
    /// The anchor is the hub's system because the design asserts the two are
    /// co-located (`brain-resource-hub-model`), and nothing enforces that. Here
    /// they are not: the hub sits at `HUBSYS`, the replicant three systems away
    /// at `REPSYS`, and the only value is at `VALUE` in the opposite direction.
    ///
    /// Judged on the hub→value path alone, the two relays on the replicant's
    /// road (`REL_MID`, `REL_REP`) lie on no anchor→target path and read
    /// reclaimable — and reclaiming them severs the mesh from the one
    /// stationary replicant that makes ANY of it commandable
    /// (`ftl-authority-rule`, rule 2). Total authority loss, dressed up as
    /// tidying.
    ///
    /// So every meshed system holding a replicant is a served system in its own
    /// right, and the road to it is pinned like any other.
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

    /// An OFF-MESH replicant adds no target. It is not an oversight: a system
    /// holding no relay is on nobody's mesh road — authority there is rule (1),
    /// a replicant present, which no relay grants and none can take away — and
    /// admitting it would force the census precondition to place every roaming
    /// replicant's system or decline forever.
    ///
    /// `ROAMING` sits 14 ly out — reachable only THROUGH `SPUR` — so the test
    /// discriminates: treat every replicant system as a target and the road to
    /// it pins `REL_SPUR`; treat only the meshed ones and `REL_SPUR` stays
    /// spare, which is the answer.
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
