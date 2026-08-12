//
//  PrunePredicate.swift
//  Replicould — DirectiveEngine
//
//  Which deployed relays are useless — grow's computation read inversely.
//
//    A relay is USELESS iff its system lies on the cheapest anchor→live-target
//    path-union for NO live-value target. On the union → pinned, off → reclaimable.
//
//  THE UNION IS ANCHOR-ROOTED, NOT MESH-ROOTED: `MeshGraph.reach` makes every mesh
//  system a zero-cost source and filters them out of the chains it returns, so a
//  union read off those chains holds no relay at all and every relay reads as
//  reclaimable. This roots at the anchor with relays as free INTERIOR nodes.
//
//  One inherited optimism, stated because prune is where optimism turns
//  destructive: `MeshGraph` models every link as a uniform 7.5 ly hop, so a
//  modelled-but-nonexistent link makes a real chain look redundant and the
//  redundant-looking half is what gets reclaimed. Closing it means reading
//  `rangeA`/`rangeB` through `DirectFTLLinks`, never off raw `ftlLinks` rows.
//
//  Pure function of `(WorldView, MeshGraph)`.
//

import Foundation
import GameModels
import UniverseModels

/// A deployed relay on the path-union for nothing. Carries its `system` because
/// reclaim is demand-driven — the brain sources the useless relay NEAREST the grow
/// it feeds, which is a question about where it stands, not what it is called.
public struct ReclaimableRelay: Equatable, Sendable {
    public let deviceCode: String
    public let system: String

    public init(deviceCode: String, system: String) {
        self.deviceCode = deviceCode
        self.system = system
    }
}

/// Why prune refused to judge. A refusal pins every relay, which is
/// byte-identical to a healthy load-bearing mesh's answer — so without this a
/// chronically incomplete census reads as a permanently tidy one. Both cases carry
/// the FACT that caused them, never a bare flag, because every prune statement an
/// operator sees is meant to be checkable against the map.
public enum PruneDeclineReason: Equatable, Sendable {
    /// No operational theatre — nothing to root any component's union at.
    case noAnchor
    /// The census cannot place systems the judgement depends on, named sorted.
    case censusIncomplete(systems: [String])
}

/// Every deployed, actively-relaying device partitioned into the ones the mesh
/// needs and the ones it does not. Total by construction.
public struct PruneAnalysis: Equatable, Sendable {
    /// Device codes on the path-union — must not be reclaimed.
    public let pinned: Set<String>
    /// Ordered by device code, and the ordering is load-bearing: the brain sources
    /// a reclaim from this list, so an order varying with hash seeding would make
    /// its choice irreproducible tick to tick.
    public let reclaimable: [ReclaimableRelay]
    /// `nil` when the predicate actually judged — the only state in which an empty
    /// `reclaimable` means "nothing is useless" rather than "prune declined".
    public let declined: PruneDeclineReason?

    public init(
        pinned: Set<String>,
        reclaimable: [ReclaimableRelay],
        declined: PruneDeclineReason? = nil
    ) {
        self.pinned = pinned
        self.reclaimable = reclaimable
        self.declined = declined
    }
}

/// The prune predicate: which of the live mesh's relays it still needs.
public enum PrunePredicate {
    /// The pinned/reclaimable partition over `view`'s active relays. **Every
    /// uncertain edge errs PINNED** — no anchor, an unplaceable system, an unknown
    /// location — because this is the one part of the capability that destroys
    /// rather than creates.
    public static func analyse(view: WorldView, graph: MeshGraph) -> PruneAnalysis {
        // Mesh membership is read off device rows, never `ftlLinks`.
        let relays = view.devices.values
            .filter(\.isActiveRelay)
            .sorted { $0.deviceCode < $1.deviceCode }

        // Nothing deployed is not a refusal to judge, so this returns a real empty
        // partition rather than reporting a hubless world as declined.
        guard !relays.isEmpty else { return PruneAnalysis(pinned: [], reclaimable: []) }

        func decline(_ reason: PruneDeclineReason) -> PruneAnalysis {
            PruneAnalysis(
                pinned: Set(relays.map(\.deviceCode)), reclaimable: [], declined: reason
            )
        }

        // No theatre anywhere: nothing can root a union, so nothing is judged
        // useless — an unrooted search would read as "reclaim the entire mesh".
        let anchors = view.theatres.filter(\.isOperational)
        guard !anchors.isEmpty else { return decline(.noAnchor) }

        // CENSUS-COVERAGE PRECONDITION, global rather than per-relay: the hole
        // breaks the union DOWNSTREAM too, so a per-relay check would save the
        // unplaceable relay and still offer up everything behind it. TARGETS are
        // covered as well — every source `servedSystems` unions is independent of
        // the `stars` census, so an unplaceable target drops out of `pathUnion`
        // taking its pin with it and the brain plants then un-plants a chain.
        // Asked of `graph.canPlace`, never `view.starPositions`: the search reads
        // the graph's own positions, so a filtered graph must DECLINE.
        let targets = servedSystems(in: view)
        let anchorSystems = Set(anchors.map(\.system))
        let mustBePlaceable = view.meshSystems
            .union(relays.compactMap { $0.location.map { SiteAssay.system(of: $0) } })
            .union(anchorSystems)
            .union(targets)
        let unplaceable = mustBePlaceable.filter { !graph.canPlace($0) }.sorted()
        guard unplaceable.isEmpty else { return decline(.censusIncomplete(systems: unplaceable)) }

        // One union PER COMPONENT, rooted at that component's own theatres —
        // separate per-anchor searches unioned together only ever ADD pins.
        var unionByComponent: [String: Set<String>] = [:]
        for anchor in anchors {
            guard let component = view.components[anchor.system] else { continue }
            // Nil-component targets (not yet meshed) stay candidates; only a
            // target KNOWN to belong elsewhere is excluded.
            let localTargets = targets.filter {
                view.components[$0] == nil || view.components[$0] == component
            }
            var union = graph.pathUnion(to: localTargets, from: [anchor.system], free: view.meshSystems)
            union.insert(anchor.system)
            unionByComponent[component, default: []].formUnion(union)
        }

        // An unanchored component is pinned ONLY while it holds something
        // worth protecting — nothing to protect, nothing to be cautious about.
        let anchoredComponents = Set(unionByComponent.keys)
        let unanchoredComponentsWithValue = Set(view.components.values)
            .subtracting(anchoredComponents)
            .filter { component in targets.contains { view.components[$0] == component } }

        var pinned: Set<String> = []
        var reclaimable: [ReclaimableRelay] = []
        for relay in relays {
            // Stowing clears `location` while the status can still read `relaying`
            // until the next confirm-read, and what cannot be placed on the map
            // cannot be judged useless.
            guard let system = relay.location.map({ SiteAssay.system(of: $0) }) else {
                pinned.insert(relay.deviceCode)
                continue
            }
            guard let component = view.components[system] else {
                pinned.insert(relay.deviceCode)
                continue
            }
            if let union = unionByComponent[component] {
                if union.contains(system) {
                    pinned.insert(relay.deviceCode)
                } else {
                    reclaimable.append(
                        ReclaimableRelay(deviceCode: relay.deviceCode, system: system)
                    )
                }
            } else if unanchoredComponentsWithValue.contains(component) {
                pinned.insert(relay.deviceCode)
            } else {
                reclaimable.append(
                    ReclaimableRelay(deviceCode: relay.deviceCode, system: system)
                )
            }
        }
        return PruneAnalysis(pinned: pinned, reclaimable: reclaimable)
    }

    /// Everything the mesh must keep serving — live value, uncollected stockpiles,
    /// where our own hardware stands, meshed systems nobody has surveyed, and
    /// meshed systems holding a replicant. All five only ever ADD targets, so a
    /// source can move a relay from reclaimable to pinned and never the other way.
    static func servedSystems(in view: WorldView) -> Set<String> {
        liveValueSystems(in: view)
            .union(stockpileSystems(in: view))
            .union(fleetSystems(in: view))
            .union(unsurveyedMeshSystems(in: view))
            .union(replicantSystems(in: view))
    }

    /// Systems holding resources already extracted and awaiting collection. A pile
    /// is inventory the fleet has already paid for, and `HaulTargetPlanner` issues
    /// the `ferry` that collects it only while both ends sit on the mesh, so
    /// reclaiming the relay over one strands the units rather than postponing them.
    ///
    /// **Not bounded to meshed systems**, unlike the two below it: `ValueCatalog`
    /// ranks an unmeshed pile as a grow target, so the hops already planted along
    /// a chain toward one must not read as spare while it is being built.
    static func stockpileSystems(in view: WorldView) -> Set<String> {
        Set(view.stockpileUnits.keys)
    }

    /// Meshed systems holding one of the account's replicants. Without this the
    /// union is rooted at the print hub alone, which carries authority only while
    /// hub and anchor replicant are co-located — an assertion nothing enforces.
    ///
    /// **A TARGET, never a second root.** Extra sources only make paths cheaper,
    /// which SHRINKS the union (the unsafe direction) and forces an arbitrary
    /// choice of "the" anchor. Extra targets are monotone, so the union stays a
    /// connected subgraph spanning the hub, every value system and every replicant.
    ///
    /// **Bounded to MESHED systems**: a system holding no relay is on nobody's mesh
    /// road, and admitting off-mesh ones would drag every roaming replicant's star
    /// into the census precondition and make prune decline forever.
    static func replicantSystems(in view: WorldView) -> Set<String> {
        view.meshSystems.intersection(view.replicantSystems)
    }

    /// Where our own deployed, non-relay devices stand. A device is commandable
    /// only while its system shares a subgraph with the stationary replicant, so
    /// reclaiming the chain to a system holding a working vessel strands the
    /// hardware unrecoverably rather than merely losing value.
    ///
    /// **ACTIVE RELAYS ARE EXCLUDED**, and that is load-bearing: counting them
    /// would make every relay pin its own system and prune could never return
    /// anything. A relay is the thing being judged, never evidence for itself.
    static func fleetSystems(in view: WorldView) -> Set<String> {
        Set(
            view.devices.values
                .filter { !$0.isActiveRelay }
                .compactMap { $0.location.map { SiteAssay.system(of: $0) } }
        )
    }

    /// Meshed systems in `view` nobody has surveyed. Their belts — the one
    /// value signal that never depletes — are unknowable until a system scan
    /// lands, and `beltsBySystem` cannot distinguish "looked, found none" from
    /// "never looked" (both are simply absent), so treating the unknown as a
    /// target is what keeps the uncertain case on the pinned side.
    static func unsurveyedMeshSystems(in view: WorldView) -> Set<String> {
        view.meshSystems.subtracting(view.surveyedSystems)
    }

    /// Every system holding live value. The ONE difference from
    /// `ValueCatalog.build`, and the reason this is separate: meshed systems are
    /// NOT subtracted. Grow wants what it has not reached; prune must keep serving
    /// what it already has, so a reached target counts as much as a wanted one.
    static func liveValueSystems(in view: WorldView) -> Set<String> {
        // `> 0` rather than key-presence: a system whose remaining assays sum to
        // nothing is not live value either.
        var systems = Set(view.salvageUnits.filter { $0.value > 0 }.keys)
        systems.formUnion(view.beltsBySystem.keys)
        systems.formUnion(view.eventSystems)
        return systems
    }
}
