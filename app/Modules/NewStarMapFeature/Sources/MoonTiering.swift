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
    /// mining site, stored inventory, or a detected biosignature) or when it is among
    /// the largest few by known radius. Interest is checked first and is never
    /// overridden: everything that needs an exact anchor from `OrreryLayout` must be a
    /// full orbiter, which is what makes the swarm's coarser treatment safe. A
    /// life-bearing moon in particular must never fall into the anonymous swarm — see
    /// `OrreryMapping.moonIsInteresting`.
    ///
    /// When NO moon in the roster reports a `radiusEarth`, size cannot rank anything, so
    /// the first `topBySize` moons in ROSTER ORDER promote instead. This is not an
    /// arbitrary pick dressed up as one: index order IS orbital order in generated
    /// systems (`OrreryMapping` verified this on ASTELLIO-1 and ABEEMIM-6), so while we
    /// genuinely do not know which moons are biggest, we do know which are innermost —
    /// and the innermost are the ones a player reads as "the moons" of the planet.
    ///
    /// Promoting nothing here was the alternative, and it fails on live data: SAFANA-7
    /// carries 21 moons with zero `physical` blocks, so a size-only rule renders the
    /// planet plus a 21-dot additive band and not one lit moon — strictly less legible
    /// than the pre-swarm build, which drew every one of them as a sphere. ALASII-4
    /// (48 moons, exactly one measured) degenerated the same way to a single impostor.
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
        } else {
            // Nothing measured anywhere in the roster — fall back to orbital order.
            promotedIDs.formUnion(moons.prefix(rules.topBySize).map(\.designation))
        }

        return (moons.filter { promotedIDs.contains($0.designation) },
                moons.filter { !promotedIDs.contains($0.designation) })
    }
}
