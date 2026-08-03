//
//  GrowRanking.swift
//  Replicould — DirectiveEngine
//
//  Task 12: the grow ranking key — the brain's central judgement of which
//  single system to plant the next FTL relay at. Joins the value model
//  (`ValueCatalog`, Task 10 — what's worth reaching) and the pathfinder
//  (`MeshGraph.reach`, Task 8 — what it costs to reach it), grouping the
//  resulting chains by their first unmeshed hop and sorting those hops by
//  the locked lexicographic key (automation-brain ticket 10):
//
//    1. completesNow (true first)
//    2. fewest relaysRemaining, then shorter hopDistance
//    3. value: (bestTier, magnitudeAtTier) — higher wins
//    4. resource cost — inert (every relay costs a fixed 370×6), skipped
//    5. designation — lexicographic, the stable final tiebreak
//
//  Encoded below as an explicit field-by-field comparison, never a collapsed
//  scalar score — the brain must be able to explain a choice as a fact
//  ("EV completes now, VEGA doesn't"), and a single number destroys that
//  explainability.
//
//  `rank` is a PURE function of `(WorldView, MeshGraph)`: no state, no I/O,
//  no database. The brain is stateless and re-ranks from scratch every
//  5-second tick, so determinism is load-bearing — field 5 exists
//  specifically so two candidates tied on every field above still resolve
//  the same way every time (see `designationBreaksExactTies` in the test
//  suite, and `MeshGraphReachTests`' own exact-tie test for the sibling
//  guarantee `reach` already provides upstream: `Frontier`'s designation
//  tiebreak is what keeps `firstHop`/`hopDistance` themselves deterministic
//  before this ranking ever runs).
//

import UniverseModels

/// One grow candidate: an unmeshed system worth planting a relay at, plus
/// everything the ranking key and a later why-view need to justify the
/// choice. Several `ValueTarget`s can share one `GrowCandidate` when they're
/// all reached via the same first hop — see `servedTargets`.
public struct GrowCandidate: Equatable, Sendable {
    /// The system to plant a relay at — the first unmeshed hop on the
    /// cheapest chain toward every target in `servedTargets`.
    public let firstHop: String
    /// True when planting `firstHop` alone completes at least one served
    /// target's chain (equivalently, `relaysRemaining == 1` — see the type's
    /// doc on that field).
    public let completesNow: Bool
    /// The fewest relays (including `firstHop` itself) needed to complete
    /// ANY one of the targets this hop serves — the minimum across the
    /// group. Note this makes `completesNow` and `relaysRemaining == 1`
    /// exactly equivalent at the candidate level: some served target's own
    /// chain completes in one relay if and only if the group's minimum is 1.
    public let relaysRemaining: Int
    /// The best `ValueTier` over ALL targets this hop serves.
    public let bestTier: ValueTier
    /// The winning tier's magnitude, aggregated over every served target —
    /// see `GrowRanking.magnitude(at:over:)` for the exact per-tier
    /// definition and its rationale.
    public let magnitudeAtTier: Double
    /// The accumulated length (ly) of the WHOLE winning served chain — from
    /// a mesh source, THROUGH `firstHop`, all the way to that chain's own
    /// target — not merely the distance to `firstHop` itself. Equal to
    /// `Chain.hopDistance` (see that type's own doc) for whichever served
    /// chain achieves `relaysRemaining`. The two quantities coincide only
    /// when `relaysRemaining == 1` (a completing candidate, where `firstHop`
    /// IS the chain's target); for a multi-relay candidate this is LONGER
    /// than the leg to `firstHop` alone, since it also covers every hop
    /// beyond it. The sub-tiebreak within field 2.
    public let hopDistance: Double
    /// Every target this hop's chains serve, sorted for a stable why-view
    /// (dictionary/set iteration order is not guaranteed).
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

/// The grow ranking: sorts every reachable first-hop candidate by the
/// locked lexicographic key. See the file header for the key itself.
public enum GrowRanking {
    /// Builds the candidate set from `ValueCatalog` + `MeshGraph.reach`,
    /// aggregates chains by their shared `firstHop`, and sorts by the
    /// locked key. Empty in, empty out — no targets or no reachable targets
    /// both yield `[]`, never a crash or a placeholder entry.
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
            // Every `?? …` fallback below is unreachable in practice: `pairs`
            // is never empty here (a `byHop` entry only exists because at
            // least one `(chain, target)` was appended to it above), so
            // `.min()`/`.max()` always succeeds. The fallbacks are a defensive
            // sentinel for that invariant, not a real code path — `?? .max`
            // would otherwise silently produce an absurd `relaysRemaining`
            // if it ever broke, which is worth flagging rather than assuming.
            let completesNow = pairs.contains { $0.chain.completesNow }
            let minRelays = pairs.map(\.chain.relaysRemaining).min() ?? .max
            // Filtered, not global: the min distance must come from a chain
            // that actually ACHIEVES `minRelays` — see
            // `hopDistanceIsTheMinimumAmongMinRelayChainsNotTheGlobalMinimum`
            // for a constructed case where a higher-relay chain is shorter,
            // proving this filter (and not a plain `.map(\.hopDistance).min()`)
            // is load-bearing.
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
            // Field 1: completesNow, true first. INERT today, same spirit as
            // field 4 below, but for a different reason: `reach` only ever
            // emits chains with `relaysRemaining >= 1`, so a group's minimum
            // relay count equals 1 if and only if some pair's own chain
            // completes (see `GrowCandidate.completesNow`'s doc) — i.e.
            // `completesNow ⟺ relaysRemaining == 1` EXACTLY at the candidate
            // level. Field 2 immediately below already agrees whenever this
            // line would fire, so it can never actually change the sort
            // outcome. Kept anyway (not deleted) because the comparator
            // must read as the locked key verbatim — but if a later task
            // ever redefines candidate aggregation (e.g. `completesNow`
            // becomes "ALL served chains complete," not "any") this line
            // goes from dead to live with zero test coverage guarding it;
            // revisit `GrowRankingTests` if that redefinition ever happens.
            if a.completesNow != b.completesNow { return a.completesNow }
            // Field 2: fewest relaysRemaining, then shorter hopDistance.
            if a.relaysRemaining != b.relaysRemaining { return a.relaysRemaining < b.relaysRemaining }
            if a.hopDistance != b.hopDistance { return a.hopDistance < b.hopDistance }
            // Field 3: value — (bestTier, magnitudeAtTier), higher wins.
            if a.bestTier != b.bestTier { return a.bestTier > b.bestTier }
            if a.magnitudeAtTier != b.magnitudeAtTier { return a.magnitudeAtTier > b.magnitudeAtTier }
            // Field 4 (resource cost) is inert — every relay costs a fixed
            // 370×6, so it decides nothing between candidates and is
            // deliberately skipped here.
            // Field 5: designation, lexicographic — the stable final
            // tiebreak that keeps the sort total and deterministic tick to
            // tick even on an exact tie through field 3.
            return a.designation < b.designation
        }
    }

    /// `magnitudeAtTier`'s exact definition, one clause per tier. Each
    /// answers the same question — "how much of the winning tier's resource
    /// is reachable via this hop, summed across every target it serves" —
    /// so the number stays explainable to a human (a later task surfaces it
    /// in the why-view), and consistent in KIND with how `ValueTarget`
    /// itself reports magnitude (a summed quantity, not a target count):
    ///
    ///   - `.salvage`: the summed non-depleted salvage UNIT total across
    ///     every served target. `ValueTarget.salvageUnits` is populated
    ///     independently of which tier actually won that target's own
    ///     `bestTier` (see that field's doc comment), so this sums the real
    ///     total reachable via this hop — not just the subset of served
    ///     targets whose own `bestTier` happened to be `.salvage`.
    ///   - `.richBelt` / `.moderateBelt` / `.sparseBelt`: the summed belt
    ///     COUNT at that exact class across every served target
    ///     (`beltCount[class]`, read via the tier's matching `BeltClass` —
    ///     see `ValueTier.beltClass` below), not the count of targets that
    ///     happen to hold one. Two served targets each with one rich belt
    ///     reads as "2 rich belts," matching the salvage case above: a
    ///     summed quantity, not a system count.
    ///   - `.event`: the COUNT of served targets currently hosting a live
    ///     event ("2 live events reachable via this hop") — events have no
    ///     natural sub-magnitude the way salvage/belts do, so target count
    ///     is the only quantity available, and it's still directly
    ///     explainable on its own terms.
    static func magnitude(at tier: ValueTier, over targets: [ValueTarget]) -> Double {
        switch tier {
        case .event:
            return Double(targets.count { $0.hasEvent })
        case .richBelt, .moderateBelt, .sparseBelt:
            guard let beltClass = tier.beltClass else { return 0 }
            return Double(targets.reduce(0) { $0 + ($1.beltCount[beltClass] ?? 0) })
        case .salvage:
            return targets.reduce(0) { $0 + $1.salvageUnits }
        }
    }
}

extension ValueTier {
    /// The reverse of `BeltClass.valueTier` (`MeshValue.swift`), needed here
    /// to read a served target's belt count at the tier that won the
    /// ranking. Rather than hand-writing a second tier↔class switch —
    /// exactly the kind of duplicated correspondence that silently drifts —
    /// this DERIVES the reverse by searching `BeltClass.allCases` for the
    /// class whose forward `valueTier` matches, so `BeltClass.valueTier`'s
    /// switch stays the one place the correspondence is spelled out. `nil`
    /// for `.salvage`/`.event`, which have no belt class of their own.
    var beltClass: BeltClass? {
        BeltClass.allCases.first { $0.valueTier == self }
    }
}
