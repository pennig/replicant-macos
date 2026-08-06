//
//  PrunePredicate.swift
//  Replicould — DirectiveEngine
//
//  Which deployed relays are useless — grow's computation (`MeshGraph`) read
//  inversely. Grow asks "what is the cheapest chain of new relays to reach
//  value?"; prune asks "which existing relays lie on no such chain?" One graph,
//  one cost model, one target vocabulary, two readings.
//
//    A deployed relay is USELESS iff its system lies on the cheapest
//    anchor→live-target path-union for NO live-value target (reached or
//    grow-wanted). On the union → pinned; off it → reclaimable.
//
//  THE UNION IS ANCHOR-ROOTED, NOT MESH-ROOTED. In `MeshGraph.reach` — the
//  reading Grow uses — every mesh system is a ZERO-COST SOURCE and
//  `Chain.waypoints` filters mesh systems out entirely, so a deployed relay
//  never appears on a chain `reach` returns and a union read off those chains
//  contains no relay at all: every relay reads as reclaimable. The predicate
//  roots the search at the anchor and lets deployed relays be free INTERIOR
//  nodes, which is what `MeshGraph.pathUnion(to:from:free:)` does.
//
//  One inherited optimism, stated because prune is where optimism turns
//  destructive: `MeshGraph` models every relay link as a uniform 7.5 ly hop, so
//  a modelled-but-nonexistent link makes a real chain look redundant and the
//  redundant-looking half is what gets reclaimed. (Grow reads the same model
//  harmlessly — it over-plans, and the plant simply fails to link.) Reading the
//  per-endpoint `rangeA`/`rangeB` those rows carry would close it, but only
//  through `DirectFTLLinks`, never off the raw `ftlLinks` rows, which store the
//  closure rather than the real links (see the ftl-authority-rule note).
//
//  Pure function of `(WorldView, MeshGraph)` — no state, no I/O, no clock, no
//  database, and no logging.
//

import Foundation
import GameModels
import UniverseModels

/// A deployed relay judged useless: on the path-union for nothing. Carries its
/// `system` as well as its `deviceCode` because reclaim is demand-driven — the
/// brain sources the useless relay NEAREST the grow it needs to feed, which is
/// a question about where the relay stands, not what it is called.
public struct ReclaimableRelay: Equatable, Sendable {
    public let deviceCode: String
    public let system: String

    public init(deviceCode: String, system: String) {
        self.deviceCode = deviceCode
        self.system = system
    }
}

/// Why prune refused to judge this tick.
///
/// A refusal pins every relay, which is byte-identical to the answer a
/// healthy, fully load-bearing mesh gives — so without this the why-view
/// could not tell "declined" from "nothing to reclaim" without recomputing
/// the preconditions itself, and a chronically incomplete census would read
/// as a permanently tidy mesh. Both cases carry the FACT that caused them
/// (never a scalar or a bare flag), because every prune statement the
/// operator sees is meant to be checkable against the map.
public enum PruneDeclineReason: Equatable, Sendable {
    /// No print hub, or its system is off-mesh — nothing to root the
    /// anchor→target paths at. `WorldView.hubLocation` is nil unless the hub's
    /// own system is meshed.
    case noAnchor
    /// The census cannot place one or more systems the judgement depends on,
    /// named here (sorted). See the precondition in `analyse`.
    case censusIncomplete(systems: [String])
}

/// The partition of every deployed, actively-relaying device into the ones
/// the mesh needs and the ones it does not. Total by construction: each
/// active relay lands in exactly one side.
public struct PruneAnalysis: Equatable, Sendable {
    /// Device codes on the path-union — must not be reclaimed.
    public let pinned: Set<String>
    /// The useless ones, ordered by device code. Ordering is load-bearing,
    /// not cosmetic: `WorldView.devices` is a Dictionary and the brain sources
    /// a reclaim from this list, so an order that varied with hash seeding
    /// would make its choice irreproducible tick to tick.
    public let reclaimable: [ReclaimableRelay]
    /// `nil` when the predicate actually judged — the only state in which an
    /// empty `reclaimable` really means "nothing is useless". Non-nil means
    /// every relay is pinned because prune declined, not because the mesh
    /// earned it.
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
    /// The pinned/reclaimable partition over `view`'s active relays, with
    /// `graph` answering every path and placement question. See the file
    /// header for the predicate itself and why the union is anchor-rooted.
    ///
    /// Every uncertain edge errs PINNED — no anchor, an unplaceable system, or
    /// a relay whose location is unknown all pin rather than reclaim, because
    /// this is the one part of the capability that destroys rather than
    /// creates.
    public static func analyse(view: WorldView, graph: MeshGraph) -> PruneAnalysis {
        // Mesh membership is read off device rows (`Device.isActiveRelay`),
        // never `ftlLinks` — the same authority `WorldView.meshSystems` uses.
        let relays = view.devices.values
            .filter(\.isActiveRelay)
            .sorted { $0.deviceCode < $1.deviceCode }

        // Nothing deployed is not a refusal to judge — there is simply
        // nothing to judge — so this returns a real (empty) partition with
        // no decline reason, rather than reporting a hubless world as one.
        guard !relays.isEmpty else { return PruneAnalysis(pinned: [], reclaimable: []) }

        func decline(_ reason: PruneDeclineReason) -> PruneAnalysis {
            PruneAnalysis(
                pinned: Set(relays.map(\.deviceCode)), reclaimable: [], declined: reason
            )
        }

        // No anchor to root the union at: nothing can be judged useless, so
        // nothing is. An unrooted search returns an empty union, which reads
        // as "reclaim the entire mesh" — the exact failure this capability
        // must not have.
        guard let anchor = view.hubLocation.map({ SiteAssay.system(of: $0) }) else {
            return decline(.noAnchor)
        }

        // CENSUS-COVERAGE PRECONDITION, global rather than per-relay. A system
        // the graph cannot place is absent from the union however load-bearing
        // it is, and the hole breaks the union DOWNSTREAM of it too, since no
        // path can route through a system the graph has never heard of — so a
        // per-relay check would save only the unplaceable relay itself and
        // still offer up everything standing behind it.
        //
        // TARGETS are covered too, not just the mesh: every source
        // `servedSystems` unions is independent of the `stars` census —
        // `salvageUnits` from `SiteAssay`, `beltsBySystem`/`surveyedSystems`
        // from `SystemDetail`, `eventSystems` from `LocationEvent`,
        // `devices`/`meshSystems` from `Device`, `replicantSystems` from
        // `Replicant` — so an unplaceable target drops out
        // of `pathUnion` taking with it the pin it was the sole source of, and
        // an in-progress chain toward value the census has not paged in yet
        // reads as reclaimable — the brain plants and un-plants it.
        //
        // Asked of `graph.canPlace`, never of `view.starPositions`: the search
        // reads `MeshGraph`'s own positions, so a caller handing over a
        // filtered or older graph must DECLINE rather than silently shrink the
        // union under its own judgement.
        let targets = servedSystems(in: view)
        let mustBePlaceable = view.meshSystems
            .union(relays.compactMap { $0.location.map { SiteAssay.system(of: $0) } })
            .union([anchor])
            .union(targets)
        let unplaceable = mustBePlaceable.filter { !graph.canPlace($0) }.sorted()
        guard unplaceable.isEmpty else { return decline(.censusIncomplete(systems: unplaceable)) }

        var union = graph.pathUnion(to: targets, from: [anchor], free: view.meshSystems)
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

    /// Everything the mesh must keep serving in `view` — the target set the
    /// union is built over. FIVE sources, each answering "would losing
    /// authority here cost us something we cannot get back?" from a different
    /// direction:
    ///
    ///   - live VALUE, reached or grow-wanted (`liveValueSystems`);
    ///   - units already EXTRACTED and awaiting collection
    ///     (`stockpileSystems`) — value we own rather than value we might get;
    ///   - where our own deployed hardware actually STANDS (`fleetSystems`) —
    ///     a system can hold a working vessel long after its last assay
    ///     depletes;
    ///   - meshed systems whose value is UNKNOWN because nobody has surveyed
    ///     them (`unsurveyedMeshSystems`) — unknown must read as pinned;
    ///   - meshed systems where a REPLICANT stands (`replicantSystems`) —
    ///     where authority itself comes from.
    ///
    /// All five only ever ADD targets, so a source can only ever move a relay
    /// from reclaimable to pinned, never the other way.
    static func servedSystems(in view: WorldView) -> Set<String> {
        liveValueSystems(in: view)
            .union(stockpileSystems(in: view))
            .union(fleetSystems(in: view))
            .union(unsurveyedMeshSystems(in: view))
            .union(replicantSystems(in: view))
    }

    /// Systems holding resources already extracted and waiting to be collected.
    ///
    /// A pile is not a prospect, it is inventory the fleet has already paid
    /// for, and `HaulTargetPlanner` can only issue the `ferry` that collects it
    /// while both ends sit on the mesh — so reclaiming the relay standing over
    /// one strands the units rather than merely postponing them.
    ///
    /// **Not bounded to meshed systems**, which puts it alongside
    /// `liveValueSystems` rather than the two mesh-bounded sources. An
    /// unmeshed pile cannot be ferried at all, so the ferry it protects is one
    /// the mesh does not yet offer — and `ValueCatalog` ranks assays, belts and
    /// events but not piles, so no grow is currently extending a chain toward
    /// one either. Admitting it anyway only ever adds pins, which is the
    /// direction every uncertain edge in this file errs in.
    ///
    /// It carries the cost `liveValueSystems` already carries: a pile in a
    /// system the census cannot place makes the coverage precondition decline
    /// the whole judgement, pinning everything.
    static func stockpileSystems(in view: WorldView) -> Set<String> {
        view.stockpileSystems
    }

    /// Meshed systems in `view` holding one of the account's replicants.
    ///
    /// Without this source the union is rooted at the print hub alone, which
    /// carries authority only while hub and anchor replicant are co-located —
    /// an assertion nothing enforces. Break it and the relays on the
    /// replicant's own road into the mesh lie on no anchor→target path: they
    /// read reclaimable, and reclaiming them severs the mesh from the one
    /// stationary replicant that makes any of it commandable
    /// (`ftl-authority-rule`, rule 2).
    ///
    /// **A TARGET, never a second root.** Adding sources to a multi-source
    /// Dijkstra only makes paths cheaper, which SHRINKS the union — the unsafe
    /// direction — and forces an arbitrary choice of "the" anchor among several
    /// replicants. Adding targets is monotone: the union stays the pointwise
    /// union of complete anchor→target paths, so it remains a connected serving
    /// subgraph spanning the hub, every value system AND every replicant, and
    /// whichever replicant is actually the stationary one sits inside it. The
    /// root choice then decides only WHICH redundant relay is kept.
    ///
    /// **Bounded to MESHED systems**, and that is not a shortcut. A system
    /// holding no relay is on nobody's mesh road: authority there is rule (1),
    /// a replicant physically present, which no relay confers and none can take
    /// away. Admitting off-mesh systems would also drag every roaming
    /// replicant's star into the census-coverage precondition, and a survey
    /// replicant wandering ahead of the census would make prune decline
    /// forever.
    static func replicantSystems(in view: WorldView) -> Set<String> {
        view.meshSystems.intersection(view.replicantSystems)
    }

    /// Where our own deployed, non-relay devices stand, per `view`.
    ///
    /// Per the ftl-authority-rule note a device is commandable only while its
    /// system shares a mesh subgraph with the stationary replicant, so
    /// reclaiming the chain to a system holding a working vessel does not
    /// merely lose value — it strands the hardware, unrecoverably. The case is
    /// ordinary: a system's last assay depletes, dropping it from the value set
    /// that same tick, while the salvage vessel and its drones are still on
    /// station and a Haul Run is still draining its pile.
    ///
    /// ACTIVE RELAYS ARE EXCLUDED, and that exclusion is load-bearing: a
    /// relay is itself a deployed device, so counting relays here would make
    /// every relay pin its own system and prune could never return anything.
    /// A relay is exactly the thing being judged, never evidence for itself.
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

    /// Every system in `view` holding live value — un-depleted salvage, a belt
    /// worth mining, or a live location event.
    ///
    /// The ONE difference from `ValueCatalog.build`, and the whole reason this
    /// is separate from it: meshed systems are NOT subtracted. Grow wants what
    /// it has not yet reached; prune must also keep serving what it already
    /// has, so a reached target counts exactly as much as a grow-wanted one.
    ///
    /// Reached mine belts specifically: `WorldView.beltsBySystem` is populated
    /// for surveyed systems whether meshed or not. What it still cannot report
    /// is a system nobody has scanned — handled as unknown by
    /// `unsurveyedMeshSystems` rather than silently read as "holds nothing".
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
