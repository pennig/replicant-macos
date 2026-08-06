//
//  MeshValue.swift
//  Replicould — DirectiveEngine
//
//  Belt-richness classification plus the value model over `WorldView`'s
//  known-value signals. Deliberately narrow: no pathfinding, no `MeshGraph`,
//  no cost — this says only WHAT is worth reaching, never how to reach it or
//  in what order.
//

/// Three-tier belt richness, ordered `sparse < moderate < rich`, `Comparable`
/// by `rawValue` so a ranking pass can compare classes directly.
///
/// Inserting a fourth case or reordering these three silently re-ranks every
/// grow candidate, since `ValueTier` is keyed off this order. The live
/// `density`/`richness` vocabulary these map from is recorded in full in
/// `app/.claude/memory/belt-value-vocabulary.md`.
public enum BeltClass: Int, Comparable, CaseIterable, Sendable {
    case sparse = 0
    case moderate = 1
    case rich = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Classifies a belt from its raw `density` string, falling back to its
    /// `richness` map (resource name → qualifier, richest entry wins) when
    /// `density` is absent or unrecognised.
    ///
    /// Returns `nil` when neither field resolves: unknown must be left unknown
    /// rather than guessed at, so a belt with no legible value data yields no
    /// target instead of a `.sparse` one.
    public static func classify(density: String?, richness: [String: String]) -> BeltClass? {
        switch density?.lowercased() {
        case "dense": return .rich
        case "moderate": return .moderate
        case "sparse": return .sparse
        default: break
        }
        let ranks = richness.values.compactMap { rank(forRichnessQualifier: $0) }
        return ranks.max().flatMap(BeltClass.init(rawValue:))
    }

    /// Maps one `richness` `qualifier` to its class's `rawValue`, or `nil` for
    /// an unrecognised string — an unrecognised qualifier must never silently
    /// rank a belt in.
    private static func rank(forRichnessQualifier qualifier: String) -> Int? {
        switch qualifier.lowercased() {
        case "rich", "high": return BeltClass.rich.rawValue
        case "moderate": return BeltClass.moderate.rawValue
        case "low", "scarce": return BeltClass.sparse.rawValue
        default: return nil
        }
    }
}

/// A belt's `designation` plus its classified `beltClass` — the slice of `Belt`
/// (`UniverseModels`) the value model ranks on, decoupled from the radii,
/// sites, inventory and devices `Belt` carries for the Locations catalog.
public struct BeltInfo: Equatable, Sendable {
    public let designation: String
    public let beltClass: BeltClass

    public init(designation: String, beltClass: BeltClass) {
        self.designation = designation
        self.beltClass = beltClass
    }
}

/// The tier ordering the brain's `tendMesh` grow heuristic ranks known value
/// on, weakest first. `Comparable` is keyed directly off `rawValue`, so
/// inserting or reordering a case re-ranks every grow candidate without any
/// comparator changing.
public enum ValueTier: Int, Comparable, Sendable {
    case sparseBelt = 0
    case salvage = 1
    /// Units already extracted and awaiting collection. Above `salvage`
    /// because no mining cycle stands between the fleet and them, below the
    /// belt tiers because a pile is finite and a belt never depletes.
    case stockpile = 2
    case moderateBelt = 3
    case richBelt = 4
    case event = 5

    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// One unmeshed `system` holding known value: the `bestTier` it reaches, plus
/// the `salvageUnits`, `beltCount` and `hasEvent` magnitudes that rank it among
/// peers at that same tier.
///
/// Every magnitude field reports the system's own real total regardless of
/// which tier won `bestTier`, so a system whose best tier is `event` still
/// carries its real salvage and belt magnitude for a later tie-break.
public struct ValueTarget: Equatable, Sendable {
    public let system: String
    public let bestTier: ValueTier
    /// Summed non-depleted assay units, carried through from
    /// `WorldView.salvageUnits` unmodified. `0` when the system holds no
    /// salvage.
    public let salvageUnits: Double
    /// How many belts the system hosts AT EACH class, not just the class that
    /// won `bestTier`. An absent key means zero belts at that class — never an
    /// explicit `0`, so a caller must coalesce rather than subscript blindly.
    public let beltCount: [BeltClass: Int]
    /// Whether the system currently hosts a live location event.
    public let hasEvent: Bool
    /// Units already extracted and sitting at this system's locations, summed,
    /// carried through from `WorldView.stockpileUnits`. `0` when the system
    /// holds no pile.
    public let stockpileUnits: Double

    public init(
        system: String,
        bestTier: ValueTier,
        salvageUnits: Double,
        beltCount: [BeltClass: Int],
        hasEvent: Bool,
        stockpileUnits: Double = 0
    ) {
        self.system = system
        self.bestTier = bestTier
        self.salvageUnits = salvageUnits
        self.beltCount = beltCount
        self.hasEvent = hasEvent
        self.stockpileUnits = stockpileUnits
    }
}

/// The value model over `WorldView`'s known-value signals — the enumeration a
/// ranking pass sorts on.
public enum ValueCatalog {
    /// Every unmeshed system in `view` holding known value (salvage assays,
    /// mine belts, a live event, or already-extracted units awaiting
    /// collection), each tiered on the richest signal it holds and sorted by
    /// `system` for a stable order across calls.
    ///
    /// Survey frontier — a system with a known position but no
    /// salvage/belt/event/pile — is EXCLUDED, as are already-meshed systems, so
    /// a caller wanting unexplored space must not read this as the frontier.
    ///
    /// Pure function of `view`: no I/O, no graph work, deterministic given the
    /// same snapshot.
    public static func build(from view: WorldView) -> [ValueTarget] {
        var candidateSystems = Set(view.salvageUnits.keys)
        candidateSystems.formUnion(view.beltsBySystem.keys)
        candidateSystems.formUnion(view.eventSystems)
        candidateSystems.formUnion(view.stockpileUnits.keys)
        candidateSystems.subtract(view.meshSystems)

        let targets = candidateSystems.compactMap { system -> ValueTarget? in
            let salvageUnits = view.salvageUnits[system] ?? 0
            let hasEvent = view.eventSystems.contains(system)
            let stockpileUnits = Double(view.stockpileUnits[system] ?? 0)

            var beltCount: [BeltClass: Int] = [:]
            for belt in view.beltsBySystem[system] ?? [] {
                beltCount[belt.beltClass, default: 0] += 1
            }

            // A signal that is absent or at zero magnitude contributes no
            // candidate tier, which is what keeps survey-only systems out.
            var candidateTiers: [ValueTier] = []
            if hasEvent { candidateTiers.append(.event) }
            if salvageUnits > 0 { candidateTiers.append(.salvage) }
            if stockpileUnits > 0 { candidateTiers.append(.stockpile) }
            if let richestBeltClass = beltCount.keys.max() {
                candidateTiers.append(richestBeltClass.valueTier)
            }
            guard let bestTier = candidateTiers.max() else { return nil }

            return ValueTarget(
                system: system, bestTier: bestTier,
                salvageUnits: salvageUnits, beltCount: beltCount, hasEvent: hasEvent,
                stockpileUnits: stockpileUnits
            )
        }
        return targets.sorted { $0.system < $1.system }
    }
}

extension BeltClass {
    /// This class's place in the `ValueTier` ordering, and the single source of
    /// truth for the tier↔class correspondence. `ValueTier.beltClass`
    /// (`GrowRanking.swift`) derives the reverse direction by searching
    /// `BeltClass.allCases` against this switch, so a second hand-written
    /// switch would let the two directions drift apart.
    var valueTier: ValueTier {
        switch self {
        case .sparse: return .sparseBelt
        case .moderate: return .moderateBelt
        case .rich: return .richBelt
        }
    }
}
