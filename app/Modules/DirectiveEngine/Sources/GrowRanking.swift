//
//  GrowRanking.swift
//  Replicould — DirectiveEngine
//
//  The grow ranking key — which single system to plant the next FTL relay at.
//  Joins the value model (`ValueCatalog`: what is worth reaching) with the
//  pathfinder (`MeshGraph.reach`: what it costs to reach it), groups the
//  resulting chains by their first unmeshed hop, and sorts those hops by one
//  lexicographic key:
//
//    1. completesNow (true first)
//    2. fewest relaysRemaining, then shorter hopDistance
//    3. value: (bestTier, magnitudeAtTier) — higher wins
//    4. resource cost — inert (every relay costs the same fixed bill, 370
//       units across six resource types), skipped
//    5. designation — lexicographic, the stable final tiebreak
//
//  The key is encoded as an explicit field-by-field comparison; collapsing it
//  into a single scalar score leaves the brain unable to state a choice as a
//  checkable fact ("EV completes now, VEGA doesn't").
//
//  `rank` is a PURE function of `(WorldView, MeshGraph)` — no state, no I/O,
//  no database — and its order is total: field 5 resolves candidates tied on
//  every field above, so the same world ranks the same way on every tick.
//

import Foundation
import UniverseModels

/// One grow candidate: an unmeshed system worth planting a relay at, plus
/// everything the ranking key and a why-view need to justify the choice.
/// Several `ValueTarget`s share one `GrowCandidate` when they are all reached
/// via the same first hop — see `servedTargets`.
public struct GrowCandidate: Equatable, Sendable {
    /// The system to plant a relay at — the first unmeshed hop on the
    /// cheapest chain toward every target in `servedTargets`.
    public let firstHop: String
    /// True when planting `firstHop` alone completes at least one served
    /// target's chain; equivalently, `relaysRemaining == 1`.
    public let completesNow: Bool
    /// The fewest relays (including `firstHop` itself) needed to complete
    /// ANY one of the targets this hop serves — the minimum across the group,
    /// which is what makes `completesNow` and `relaysRemaining == 1` exactly
    /// equivalent at the candidate level.
    public let relaysRemaining: Int
    /// The best `ValueTier` over ALL targets this hop serves.
    public let bestTier: ValueTier
    /// The winning tier's magnitude, aggregated over every served target;
    /// `GrowRanking.magnitude(at:over:)` gives the per-tier definition.
    public let magnitudeAtTier: Double
    /// The accumulated length (ly) of the WHOLE winning served chain — from a
    /// mesh source, THROUGH `firstHop`, all the way to that chain's own target.
    /// Equal to `Chain.hopDistance` for whichever served chain achieves
    /// `relaysRemaining`, and equal to the leg to `firstHop` only when
    /// `relaysRemaining == 1`; reading it as the distance to `firstHop` for a
    /// multi-relay candidate overstates that leg by every hop beyond it. The
    /// sub-tiebreak within field 2.
    public let hopDistance: Double
    /// Every target this hop's chains serve, sorted — dictionary and set
    /// iteration order is not guaranteed, and an unsorted why-view would
    /// reorder itself tick to tick.
    public let servedTargets: [String]
    /// == `firstHop`. The stable, always-decisive final tiebreak (field 5).
    public let designation: String

    public init(
        firstHop: String,
        completesNow: Bool,
        relaysRemaining: Int,
        bestTier: ValueTier,
        magnitudeAtTier: Double,
        hopDistance: Double,
        servedTargets: [String],
        designation: String
    ) {
        self.firstHop = firstHop
        self.completesNow = completesNow
        self.relaysRemaining = relaysRemaining
        self.bestTier = bestTier
        self.magnitudeAtTier = magnitudeAtTier
        self.hopDistance = hopDistance
        self.servedTargets = servedTargets
        self.designation = designation
    }
}

// MARK: - Graph facts

/// The candidate, said out loud. One vocabulary, defined here beside the
/// fields it describes, so the brain's launch rationale (`Brain.rationale`)
/// and the why-view's per-candidate rows cannot describe the same candidate
/// two different ways. Every summary states a graph fact rather than a scalar,
/// so a choice stays checkable against the map.
extension GrowCandidate {
    /// The winning tier's magnitude in ITS OWN units — belts as belts, events
    /// as events, salvage as units, per `GrowRanking.magnitude(at:over:)`.
    /// Rendering a belt count as "units" would be a fact the operator could
    /// not check.
    public var magnitudeSummary: String {
        switch bestTier {
        case .salvage: Self.counted(magnitudeAtTier, "unit")
        // Named apart from `.salvage`'s bare "unit": the operator checking this
        // against the map needs to know whether the units are still in the
        // ground or already on it.
        case .stockpile: Self.counted(magnitudeAtTier, "mined unit")
        case .event: Self.counted(magnitudeAtTier, "live event")
        case .richBelt: Self.counted(magnitudeAtTier, "rich belt")
        case .moderateBelt: Self.counted(magnitudeAtTier, "moderate belt")
        case .sparseBelt: Self.counted(magnitudeAtTier, "sparse belt")
        }
    }

    /// How far the winning chain still has to run, including this hop.
    public var hopSummary: String {
        "\(relaysRemaining) hop\(relaysRemaining == 1 ? "" : "s")"
    }

    /// Where the value is, when it is not at the hop itself. Without this a
    /// two-hop grow reads as a hop toward nothing, at a system with no value
    /// of its own.
    public var targetsBeyondFirstHop: [String] {
        servedTargets.filter { $0 != firstHop }
    }

    /// Renders `value` against a pluralised `noun`: `3200, "unit"` →
    /// `"3,200 units"`. Grouping is pinned to `en_US` rather than the current
    /// locale — the surrounding sentence is a hard-coded English string, and a
    /// locale-dependent separator would make this line, and its test, read
    /// differently on different machines.
    private static func counted(_ value: Double, _ noun: String) -> String {
        // `Int(_: Double)` TRAPS on NaN, infinity, and anything past `Int.max`,
        // and this value is summed straight out of server-supplied assay
        // totals — a trap here takes the whole process down from inside a
        // 5-second background loop, over a log line. Clamping instead degrades
        // a nonsense magnitude to a nonsense-looking number.
        let rounded = value.rounded()
        let whole = rounded.isFinite && rounded.magnitude < Double(Int.max) ? Int(rounded) : Int.max
        return "\(whole.formatted(.number.locale(Locale(identifier: "en_US")))) \(noun)\(whole == 1 ? "" : "s")"
    }
}

/// The grow ranking: sorts every reachable first-hop candidate by the
/// lexicographic key in the file header.
public enum GrowRanking {
    /// Builds the candidate set from `ValueCatalog` over `view` and
    /// `MeshGraph.reach` over `graph`, aggregates chains by their shared
    /// `firstHop`, and sorts by the key in the file header. Empty in, empty
    /// out — no targets, or no reachable targets, both yield `[]`.
    public static func rank(view: WorldView, graph: MeshGraph) -> [GrowCandidate] {
        let targets = ValueCatalog.build(from: view)
        guard !targets.isEmpty else { return [] }

        let chains = graph.reach(targets: Set(targets.map(\.system)), meshSystems: view.meshSystems)

        var byHop: [String: [(chain: Chain, target: ValueTarget)]] = [:]
        for target in targets {
            guard let chain = chains[target.system] else { continue } // unreachable — no candidate
            byHop[chain.firstHop, default: []].append((chain, target))
        }

        let candidates = byHop.map { hop, pairs -> GrowCandidate in
            // `pairs` is never empty here — a `byHop` entry exists only because
            // at least one `(chain, target)` was appended to it above — so every
            // `?? …` below is a sentinel for that invariant, not a live path.
            // `?? .max` would otherwise produce an absurd `relaysRemaining`.
            let completesNow = pairs.contains { $0.chain.completesNow }
            let minRelays = pairs.map(\.chain.relaysRemaining).min() ?? .max
            // Filtered, not global: the distance must come from a chain that
            // actually ACHIEVES `minRelays`. A higher-relay chain can be the
            // shorter one, and a plain `.map(\.hopDistance).min()` would pair a
            // relay count with a distance no single chain has.
            let minDistance = pairs
                .filter { $0.chain.relaysRemaining == minRelays }
                .map(\.chain.hopDistance)
                .min() ?? 0
            let bestTier = pairs.map(\.target.bestTier).max() ?? .sparseBelt
            let magnitude = magnitude(at: bestTier, over: pairs.map(\.target))
            return GrowCandidate(
                firstHop: hop,
                completesNow: completesNow,
                relaysRemaining: minRelays,
                bestTier: bestTier,
                magnitudeAtTier: magnitude,
                hopDistance: minDistance,
                servedTargets: pairs.map { $0.target.system }.sorted(),
                designation: hop
            )
        }

        return candidates.sorted { a, b in
            // Field 1: completesNow, true first. Inert — `reach` only emits
            // chains with `relaysRemaining >= 1`, so at the candidate level
            // `completesNow ⟺ relaysRemaining == 1` exactly, and field 2 below
            // already agrees wherever this line would fire. Written out anyway
            // so the comparator reads as the key verbatim, but nothing
            // distinguishes it from field 2: redefine candidate aggregation
            // (`completesNow` as "ALL served chains complete" rather than
            // "any") and this line goes live with no test guarding it.
            if a.completesNow != b.completesNow { return a.completesNow }
            // Field 2: fewest relaysRemaining, then shorter hopDistance.
            if a.relaysRemaining != b.relaysRemaining { return a.relaysRemaining < b.relaysRemaining }
            if a.hopDistance != b.hopDistance { return a.hopDistance < b.hopDistance }
            // Field 3: value — (bestTier, magnitudeAtTier), higher wins.
            if a.bestTier != b.bestTier { return a.bestTier > b.bestTier }
            if a.magnitudeAtTier != b.magnitudeAtTier { return a.magnitudeAtTier > b.magnitudeAtTier }
            // Field 4 (resource cost) is inert — every relay costs the same
            // fixed bill, 370 units across six resource types — so it decides
            // nothing between candidates and is skipped.
            // Field 5: designation, lexicographic — the stable final tiebreak
            // that keeps the sort total and deterministic tick to tick even on
            // an exact tie through field 3.
            return a.designation < b.designation
        }
    }

    /// `magnitudeAtTier`'s exact definition: how much of `tier`'s own resource
    /// is reachable across `targets`, one clause per tier.
    ///
    ///   - `.salvage`: the summed non-depleted salvage UNIT total over every
    ///     target. `ValueTarget.salvageUnits` is populated independently of
    ///     which tier won that target's own `bestTier`, so this is the real
    ///     reachable total — not just the targets whose own `bestTier` was
    ///     `.salvage`.
    ///   - `.stockpile`: the same, over already-extracted units
    ///     (`ValueTarget.stockpileUnits`).
    ///   - `.richBelt` / `.moderateBelt` / `.sparseBelt`: the summed belt COUNT
    ///     at that exact class (`beltCount[class]`, read via the tier's
    ///     matching `BeltClass` — see `ValueTier.beltClass` below), never the
    ///     count of targets holding one; two targets with one rich belt each
    ///     read as "2 rich belts".
    ///   - `.event`: the COUNT of targets currently hosting a live event —
    ///     events carry no sub-magnitude of their own.
    static func magnitude(at tier: ValueTier, over targets: [ValueTarget]) -> Double {
        switch tier {
        case .event:
            return Double(targets.count { $0.hasEvent })
        case .richBelt, .moderateBelt, .sparseBelt:
            guard let beltClass = tier.beltClass else { return 0 }
            return Double(targets.reduce(0) { $0 + ($1.beltCount[beltClass] ?? 0) })
        case .salvage:
            return targets.reduce(0) { $0 + $1.salvageUnits }
        case .stockpile:
            return targets.reduce(0) { $0 + $1.stockpileUnits }
        }
    }
}

extension ValueTier {
    /// The `BeltClass` whose `valueTier` is `self`, or `nil` for `.salvage` and
    /// `.event`, which have no belt class of their own. DERIVED by searching
    /// `BeltClass.allCases` rather than by a second hand-written switch, so
    /// `BeltClass.valueTier` (`MeshValue.swift`) stays the one place the
    /// correspondence is spelled out and the two directions cannot drift.
    var beltClass: BeltClass? {
        BeltClass.allCases.first { $0.valueTier == self }
    }
}
