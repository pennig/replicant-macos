//
//  MoonTiering.swift
//  NewStarMapFeature
//
//  Splits a planet's moon roster into the moons that earn their own orbit ring and
//  the ones that become a swarm. Pure + deterministic, so the rules are unit-tested
//  rather than eyeballed on the GPU.
//
//  The point of the split is screen budget: the body-level orrery spends ~1.33 scene
//  units of radius per ringed moon, so a 59-moon roster pushes the outermost orbit
//  past 90 units and shrinks the drilled planet to ~3% of the frame radius. Promoted
//  moons keep the old per-moon treatment; the swarm costs one band regardless of
//  count (see `OrreryMapping.bodyModel`).
//

import UniverseModels

enum MoonTiering {

    /// The promotion thresholds. Values are the shipped defaults; tests override them.
    struct Rules: Equatable, Sendable {
        /// A roster this size or smaller promotes EVERY moon, so the overwhelming
        /// majority of planets (all but five in the live census) render exactly as
        /// they did before this work.
        var promoteAllAtOrBelow: Int = 8
        /// At most this many moons promote on size alone.
        var topBySize: Int = 4
        /// A moon must be at least this fraction of the largest KNOWN radius to
        /// promote on size. Without it, a roster of similarly-sized moons would
        /// promote `topBySize` of them arbitrarily.
        var relativeSizeFloor: Double = 0.5

        static let `default` = Rules()
    }

    /// Split a roster into (promoted, swarm), each preserving the input order.
    ///
    /// A moon promotes when it is *interesting* (hosts a device, a live salvage site, a
    /// mining site, or stored inventory) or when it is among the largest few by known
    /// radius. Interest is checked first and is never overridden: everything that needs
    /// an exact anchor from `OrreryLayout` must be a full orbiter, which is what makes
    /// the swarm's coarser treatment safe.
    ///
    /// A roster with no `radiusEarth` readings promotes nothing on size — with no data
    /// we genuinely do not know which moons are major, and inventing an answer would
    /// put arbitrary moons on rings.
    static func split(_ moons: [Moon], rules: Rules = .default) -> (promoted: [Moon], swarm: [Moon]) {
        guard moons.count > rules.promoteAllAtOrBelow else { return (moons, []) }

        var promotedIDs = Set(moons.lazy.filter(OrreryMapping.moonIsInteresting).map(\.designation))

        let radii = moons.compactMap { m -> (id: String, r: Double)? in
            guard let r = m.physical?.radiusEarth, r > 0 else { return nil }
            return (m.designation, r)
        }
        if let largest = radii.map(\.r).max() {
            let floor = largest * rules.relativeSizeFloor
            let bySize = radii
                .filter { $0.r >= floor }
                .sorted { $0.r > $1.r }
                .prefix(rules.topBySize)
            promotedIDs.formUnion(bySize.map(\.id))
        }

        return (moons.filter { promotedIDs.contains($0.designation) },
                moons.filter { !promotedIDs.contains($0.designation) })
    }
}
