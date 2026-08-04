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
//  Two inherited optimisms, recorded because prune is where optimism turns
//  destructive:
//
//  1. `MeshGraph` models every relay link as a uniform 7.5 ly hop
//     (`SalvageTargetPlanner.relayRangeLY`). For grow that is harmless — it
//     over-plans and the plant simply fails to link. Here the same optimism
//     runs the other way: a modelled-but-nonexistent link makes a real chain
//     look redundant, and the redundant-looking half is what gets reclaimed.
//     `ftlLinks` now carries per-endpoint `rangeA`/`rangeB` (see the
//     ftl-authority-rule note); reading the real ranges would close it.
//  2. The anchor is the hub's system rather than the stationary replicant's.
//     Nothing ENFORCES the co-location the design assumes, and an autofactory
//     meshed away from the replicant would put the relays on the replicant's
//     own road on the reclaimable side — total authority loss.
//     `Replicant.currentStar` already carries the truth. Fine to defer while
//     this is an unwired pure function; it must NOT be deferred past the tick
//     that first acts on a `reclaimable` entry.
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
    /// anchor→target paths at.
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
    /// not cosmetic: `WorldView.devices` is a Dictionary, and a later task
    /// sources a reclaim from this list — an order that varied with hash
    /// seeding would make the brain's choice irreproducible tick to tick.
    public let reclaimable: [ReclaimableRelay]
    /// `nil` when the predicate actually judged — which is the only state in
    /// which an empty `reclaimable` really means "nothing is useless".
    /// Non-nil means every relay is pinned because prune declined, not
    /// because the mesh earned it.
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

public enum PrunePredicate {
    /// The pinned/reclaimable partition. See the file header for the
    /// predicate itself and why the union is anchor-rooted.
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

        // CENSUS-COVERAGE PRECONDITION. The union can only ever contain
        // systems the graph can place: `search` seeds sources and relaxes
        // neighbours only `where positions[…] != nil`, and `backtrack` walks
        // nodes the search settled. So a system missing from the census is
        // absent from the union however load-bearing it is — and a hole
        // anywhere in the mesh breaks the union DOWNSTREAM of it too, since no
        // path can be routed through a system the graph has never heard of. A
        // per-relay check would save only the unplaceable relay itself and
        // still offer up everything standing behind it.
        //
        // The `stars` census genuinely lags — it repopulates after a reset and
        // trails `systemDetails` (app/.claude/memory/sqlite-db-location.md) —
        // so this is a live state, not a theoretical one. Robustness clause 3
        // says staleness may degrade efficiency but never safety: an
        // incompletely-placed mesh means prune declines to judge this tick and
        // tries again on the next. Nothing is lost but a reclaim's latency.
        //
        // The TARGETS are covered too, not just the mesh. Every target source
        // is independent of the `stars` table (`salvageUnits` from
        // `SiteAssay`, `beltsBySystem` from `SystemDetail`, `eventSystems`
        // from `LocationEvent`), so an unplaceable target is reachable — and
        // it drops silently out of `pathUnion`, taking with it the pin it
        // was the sole source of. That is the thrash guard failing under
        // exactly the lag this precondition exists for: an in-progress chain
        // toward value the census has not paged in yet would read as
        // reclaimable, and the brain would plant and un-plant it.
        let targets = servedSystems(in: view)
        let mustBePlaceable = view.meshSystems
            .union(relays.compactMap { $0.location.map { SiteAssay.system(of: $0) } })
            .union([anchor])
            .union(targets)
        let unplaceable = mustBePlaceable.filter { view.starPositions[$0] == nil }.sorted()
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

    /// Everything the mesh must keep serving — the target set the union is
    /// built over. Three sources, each answering the same question ("would
    /// losing authority here cost us something we cannot get back?") from a
    /// different direction:
    ///
    ///   - live VALUE, reached or grow-wanted (`liveValueSystems`);
    ///   - where our own deployed hardware actually STANDS (`fleetSystems`) —
    ///     the design's target set is value-only, but a system can hold a
    ///     working vessel long after its last assay depletes;
    ///   - meshed systems whose value is UNKNOWN because nobody has surveyed
    ///     them (`unsurveyedMeshSystems`) — unknown must read as pinned.
    ///
    /// The second and third exist because the value model answers "is there
    /// something worth going to?", and prune is also asking "is there
    /// something already there?". Both extra sources only ever ADD targets,
    /// so they can only ever move a relay from reclaimable to pinned.
    static func servedSystems(in view: WorldView) -> Set<String> {
        liveValueSystems(in: view)
            .union(fleetSystems(in: view))
            .union(unsurveyedMeshSystems(in: view))
    }

    /// Where our own deployed, non-relay devices stand.
    ///
    /// Per the ftl-authority-rule note a device is commandable only while its
    /// system shares a mesh subgraph with the stationary replicant, so
    /// reclaiming the chain to a system holding a working vessel does not
    /// merely lose value — it strands the hardware, unrecoverably. The case
    /// is ordinary, not exotic: the last assay at S depletes while the
    /// salvage vessel and its drones are still on station and a Haul Run is
    /// still draining S's pile. S leaves the value set that same tick.
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

    /// Meshed systems nobody has surveyed. Their belts — the one value signal
    /// that never depletes — are unknowable until a system scan lands, and
    /// `beltsBySystem` cannot distinguish "looked, found none" from "never
    /// looked" (both are simply absent), which is why `WorldView` publishes
    /// `surveyedSystems` separately. Treating the unknown as a target keeps
    /// the uncertain case on the pinned side.
    static func unsurveyedMeshSystems(in view: WorldView) -> Set<String> {
        view.meshSystems.subtracting(view.surveyedSystems)
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
    /// Reached mine belts specifically: `WorldView.beltsBySystem` is populated
    /// for surveyed systems whether meshed or not (widened by this task for
    /// exactly this reason). What it still cannot report is a system nobody
    /// has scanned — handled as unknown by `unsurveyedMeshSystems` rather than
    /// silently read as "holds nothing".
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
