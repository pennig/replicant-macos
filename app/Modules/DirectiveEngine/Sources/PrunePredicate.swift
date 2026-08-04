//
//  PrunePredicate.swift
//  Replicould — DirectiveEngine
//
//  Task 21: which deployed relays are useless? Grow's computation
//  (`MeshGraph`) read inversely — grow asks "what is the cheapest chain of
//  new relays to reach value?", prune asks "which existing relays lie on no
//  such chain?" One graph, one cost model, one target vocabulary, two
//  readings. There is deliberately no second notion of usefulness here: the
//  only thing this file adds over `GrowRanking` is the direction of the
//  question.
//
//    A deployed relay is USELESS iff its system lies on the cheapest
//    anchor→live-target path-union for NO live-value target (reached or
//    grow-wanted). On the union → pinned; off it → reclaimable.
//
//  THE UNION IS ANCHOR-ROOTED, NOT MESH-ROOTED. This is the one structural
//  correction this task makes to its own brief, and it is not a detail: in
//  `MeshGraph.reach` — the reading Grow uses — every mesh system is a
//  ZERO-COST SOURCE, and `Chain.waypoints` filters mesh systems out entirely.
//  A deployed relay therefore never appears on a chain `reach` returns, so a
//  union read off those chains contains no relay system at all and EVERY
//  relay reads as reclaimable. The predicate has to root the search at the
//  anchor and let deployed relays be free INTERIOR nodes, which is what
//  `MeshGraph.pathUnion(to:from:free:)` does. The tests in `PruneTests` fail
//  loudly against the mesh-rooted reading (all four brief conditions), which
//  is how this was caught rather than shipped.
//
//  Why the anchor is the hub's system: command authority flows from a
//  STATIONARY replicant outward through linked relays (see the
//  ftl-authority-rule note), and the single print hub of this effort is
//  anchor-co-located by design (automation-brain ticket 06). `WorldView`
//  carries no replicant position, and `hubLocation` is already the brain's
//  handle on "where authority lives" — it is `nil` unless the hub's own
//  system is meshed. When it IS nil, or the census cannot place it, the
//  predicate cannot judge anything and pins everything: prune is the one
//  part of this capability that destroys rather than creates, so every
//  uncertain edge errs PINNED.
//
//  Pure function of `(WorldView, MeshGraph)` — no state, no I/O, no clock,
//  no database, and no logging (there is nothing here a later why-view
//  cannot re-derive). `graph` must be built from `view.starPositions`, the
//  same contract `GrowRanking.rank` already relies on.
//

import Foundation
import GameModels
import UniverseModels

/// A deployed relay judged useless: on the path-union for nothing. Carries
/// its system as well as its code because reclaim is demand-driven — a later
/// task picks the useless relay NEAREST the grow it needs to feed, which is a
/// question about where the relay stands, not what it is called.
public struct ReclaimableRelay: Equatable, Sendable {
    public let deviceCode: String
    public let system: String

    public init(deviceCode: String, system: String) {
        self.deviceCode = deviceCode
        self.system = system
    }
}

/// The partition of every deployed, actively-relaying device into the ones
/// the mesh needs and the ones it does not. Total by construction: each
/// active relay lands in exactly one side.
public struct PruneAnalysis: Equatable, Sendable {
    /// Device codes on the path-union — must not be reclaimed.
    public let pinned: Set<String>
    /// The useless ones, ordered by device code. Ordering is load-bearing,
    /// not cosmetic: `WorldView.devices` is a Dictionary, and a later task
    /// sources a reclaim from this list — an order that varied with hash
    /// seeding would make the brain's choice irreproducible tick to tick.
    public let reclaimable: [ReclaimableRelay]

    public init(pinned: Set<String>, reclaimable: [ReclaimableRelay]) {
        self.pinned = pinned
        self.reclaimable = reclaimable
    }
}

public enum PrunePredicate {
    /// The pinned/reclaimable partition. See the file header for the
    /// predicate itself and why the union is anchor-rooted.
    public static func analyse(view: WorldView, graph: MeshGraph) -> PruneAnalysis {
        // Mesh membership is read off device rows (`Device.isActiveRelay`),
        // never `ftlLinks` — the same authority `WorldView.meshSystems` uses.
        let relays = view.devices.values
            .filter(\.isActiveRelay)
            .sorted { $0.deviceCode < $1.deviceCode }

        // No anchor to root the union at: nothing can be judged useless, so
        // nothing is. An unrooted search returns an empty union, which reads
        // as "reclaim the entire mesh" — the exact failure this capability
        // must not have.
        guard let anchor = anchorSystem(in: view) else {
            return PruneAnalysis(pinned: Set(relays.map(\.deviceCode)), reclaimable: [])
        }

        var union = graph.pathUnion(
            to: liveValueSystems(in: view), from: [anchor], free: view.meshSystems
        )
        // The anchor is on every anchor→target path by definition, so it is
        // already in the union whenever any target is reachable. Inserting it
        // unconditionally covers the one case that isn't — no live value
        // anywhere — where an empty union would otherwise offer up the relay
        // that links the mesh to its own replicant.
        union.insert(anchor)

        var pinned: Set<String> = []
        var reclaimable: [ReclaimableRelay] = []
        for relay in relays {
            // A relay reporting itself `relaying` with no location cannot be
            // placed on the map — stowing clears `location` while the status
            // can still read `relaying` until the next confirm-read lands —
            // and what cannot be placed cannot be judged useless.
            guard let system = relay.location.map({ SiteAssay.system(of: $0) }) else {
                pinned.insert(relay.deviceCode)
                continue
            }
            if union.contains(system) {
                pinned.insert(relay.deviceCode)
            } else {
                reclaimable.append(
                    ReclaimableRelay(deviceCode: relay.deviceCode, system: system)
                )
            }
        }
        return PruneAnalysis(pinned: pinned, reclaimable: reclaimable)
    }

    /// The system every anchor→target path is rooted at: the print hub's, on
    /// the design's anchor-co-location (see the file header). `nil` — "cannot
    /// judge" — when there is no hub, when its system is off-mesh (which is
    /// how `WorldView.hubLocation` already reports one), or when the census
    /// cannot place that system, since a search from a system the graph has
    /// never heard of settles nothing and yields an empty union.
    private static func anchorSystem(in view: WorldView) -> String? {
        guard let hub = view.hubLocation else { return nil }
        let system = SiteAssay.system(of: hub)
        return view.starPositions[system] != nil ? system : nil
    }

    /// Every system holding live value — un-depleted salvage, a belt worth
    /// mining, or a live location event.
    ///
    /// The ONE difference from `ValueCatalog.build`, and the whole reason
    /// this is separate from it: meshed systems are NOT subtracted. Grow
    /// wants what it has not yet reached; prune must also keep serving what
    /// it already has, so a reached target counts exactly as much as a
    /// grow-wanted one. Same three signals, same `WorldView` fields, opposite
    /// end of the same question.
    ///
    /// KNOWN GAP — reached mine belts: `WorldView.beltsBySystem` is populated
    /// for surveyed systems whether meshed or not (widened by this task for
    /// exactly this reason), but it depends on the system having been through
    /// a full system scan. A meshed system whose belts have never been
    /// surveyed contributes no target and its relay reads as reclaimable —
    /// which is the unsafe direction. It is bounded in practice: `tendMesh`
    /// only ever grows toward value it can already see, so a system meshed
    /// for its belts was surveyed before it was meshed.
    static func liveValueSystems(in view: WorldView) -> Set<String> {
        // `> 0` rather than key-presence: `WorldView.salvageUnits` already
        // excludes depleted sites, but a system whose remaining assays sum to
        // nothing is not live value either.
        var systems = Set(view.salvageUnits.filter { $0.value > 0 }.keys)
        systems.formUnion(view.beltsBySystem.keys)
        systems.formUnion(view.eventSystems)
        return systems
    }
}
