//
//  MeshValue.swift
//  Replicould — DirectiveEngine
//
//  Task 9 (VERIFICATION): the belt-richness classification feeding the
//  brain's value model. The tier ordering `Rich ▸ Moderate ▸ Sparse` was
//  already locked by automation-brain ticket 10 — this only pins the
//  concrete string vocabulary the live API actually emits onto that
//  ordering.
//
//  Confirmed 2026-08-03 by probing the live API (`replicant raw GET
//  locations/SOL`) plus aggregating the local synced `systemDetails` table
//  across 141 scanned systems / 56 belts (see
//  app/.claude/memory/belt-value-vocabulary.md for the full findings):
//  `Belt.density` has EXACTLY three live values (`sparse`, `moderate`,
//  `dense` — no `rich`/`abundant`/`medium`/`thin`), and `Belt.richness`
//  qualifiers are `scarce`/`low`/`moderate`/`high`/`rich` (no `abundant`).
//

/// Three-tier belt richness, ordered `sparse < moderate < rich` to match the
/// locked automation-brain value tiers (Event ▸ Rich belt ▸ Moderate belt ▸
/// salvage ▸ Sparse belt). `Comparable` by `rawValue` so a ranking pass can
/// compare classes directly.
///
/// Exactly these three cases — do not add a fourth or reorder the existing
/// ones; the ordering is a locked design decision, not an implementation
/// detail this task revisits.
public enum BeltClass: Int, Comparable, CaseIterable, Sendable {
    case sparse = 0
    case moderate = 1
    case rich = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Classifies a belt from its raw `density` string, falling back to its
    /// `richness` map (resource name → qualifier) when `density` is absent
    /// or unrecognised. Returns `nil` — "unknown" — when neither field
    /// resolves to a recognised value; unknown must be left unknown rather
    /// than guessed at, so a belt with no legible value data contributes no
    /// class and yields no target.
    ///
    /// `density` mapping (VERIFIED live, the only three values ever
    /// observed): `dense` → `.rich`, `moderate` → `.moderate`, `sparse` →
    /// `.sparse`.
    ///
    /// `richness` fallback mapping (the five real qualifiers folded onto the
    /// three classes, richest-per-resource wins when several are present):
    /// `rich`/`high` → `.rich` (the top two observed qualifiers both read as
    /// "abundant here"), `moderate` → `.moderate`, `low`/`scarce` → `.sparse`
    /// (both read as "not much here" — the belt is present but thin).
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

    /// Maps one real `richness` qualifier to its class's `rawValue`, or
    /// `nil` for an unrecognised string — an unrecognised qualifier must
    /// never silently rank a belt in.
    private static func rank(forRichnessQualifier qualifier: String) -> Int? {
        switch qualifier.lowercased() {
        case "rich", "high": return BeltClass.rich.rawValue
        case "moderate": return BeltClass.moderate.rawValue
        case "low", "scarce": return BeltClass.sparse.rawValue
        default: return nil
        }
    }
}

/// A belt's designation plus its classified richness — the slice of `Belt`
/// the brain's value model ranks on, decoupled from the full domain model
/// (radii, sites, inventory, devices) that `Belt` (`UniverseModels`) carries
/// for the Locations catalog.
public struct BeltInfo: Equatable, Sendable {
    public let designation: String
    public let beltClass: BeltClass

    public init(designation: String, beltClass: BeltClass) {
        self.designation = designation
        self.beltClass = beltClass
    }
}

/// Task 10: the locked tier ordering the brain's `tendMesh` grow heuristic
/// ranks known value on — `event(4) ▸ richBelt(3) ▸ moderateBelt(2) ▸
/// salvage(1) ▸ sparseBelt(0)`. Note salvage sits BETWEEN the two belt
/// tiers, not below both — a deliberate design decision (automation-brain
/// ticket 10), not something later work should re-derive.
///
/// Exactly these five cases in this raw-value order — do not reorder or
/// insert; `Comparable` is keyed directly off `rawValue` so a ranking pass
/// can compare tiers with `<`/`>` and get the locked ordering for free.
public enum ValueTier: Int, Comparable, Sendable {
    case sparseBelt = 0
    case salvage = 1
    case moderateBelt = 2
    case richBelt = 3
    case event = 4

    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// One unmeshed system holding known value, plus enough magnitude to rank
/// among peers at the same `bestTier`. Every field is populated on its own
/// terms — `salvageUnits`, `beltCount`, and `hasEvent` all report the
/// system's real, independent totals regardless of which tier actually won
/// `bestTier`, so a system whose best tier is `event` still carries its real
/// salvage/belt magnitude for a later tie-break or display.
public struct ValueTarget: Equatable, Sendable {
    public let system: String
    public let bestTier: ValueTier
    /// Magnitude within the salvage tier: summed non-depleted assay units,
    /// carried through from `WorldView.salvageUnits` unmodified. `0` when
    /// the system holds no salvage.
    public let salvageUnits: Double
    /// Magnitude within a belt tier: how many belts the system hosts AT
    /// EACH class, not just the class that won `bestTier` — a system with
    /// two rich belts and one moderate belt reports both entries, so a
    /// later ranking pass can read the winning tier's own count via
    /// `beltCount[bestBeltClass]` while still seeing the full picture.
    /// Absent keys mean zero belts at that class (never an explicit `0`).
    public let beltCount: [BeltClass: Int]
    /// Whether the system currently hosts a live location event.
    public let hasEvent: Bool
}

/// Task 10: the value model over `WorldView`'s known-value signals — the
/// enumeration the next task's ranking pass sorts on. Deliberately narrow:
/// no pathfinding, no `MeshGraph`, no cost — this only says WHAT is worth
/// reaching, not how to reach it or in what order.
public enum ValueCatalog {
    /// Every unmeshed system holding known value (salvage assays, mine
    /// belts, or a live event), each tiered on the richest signal it holds.
    /// Survey frontier — a system with only a known position, no
    /// salvage/belt/event — is EXCLUDED: growing toward unexplored space is
    /// a different capability from chasing known value. Already-meshed
    /// systems are excluded too — there's nothing left to grow toward.
    ///
    /// Pure function of `view`: no I/O, no graph work, deterministic given
    /// the same snapshot (results are sorted by `system` for a stable order
    /// across calls, since dictionary/set iteration order isn't guaranteed).
    public static func build(from view: WorldView) -> [ValueTarget] {
        var candidateSystems = Set(view.salvageUnits.keys)
        candidateSystems.formUnion(view.beltsBySystem.keys)
        candidateSystems.formUnion(view.eventSystems)
        candidateSystems.subtract(view.meshSystems)

        let targets = candidateSystems.compactMap { system -> ValueTarget? in
            let salvageUnits = view.salvageUnits[system] ?? 0
            let hasEvent = view.eventSystems.contains(system)

            var beltCount: [BeltClass: Int] = [:]
            for belt in view.beltsBySystem[system] ?? [] {
                beltCount[belt.beltClass, default: 0] += 1
            }

            // Every signal the system actually holds is a candidate tier;
            // `bestTier` is whichever ranks highest. A signal absent or at
            // zero magnitude contributes no candidate — that's what keeps
            // survey-only systems (no salvage/belt/event at all) out.
            var candidateTiers: [ValueTier] = []
            if hasEvent { candidateTiers.append(.event) }
            if salvageUnits > 0 { candidateTiers.append(.salvage) }
            if let richestBeltClass = beltCount.keys.max() {
                candidateTiers.append(richestBeltClass.valueTier)
            }
            guard let bestTier = candidateTiers.max() else { return nil }

            return ValueTarget(
                system: system, bestTier: bestTier,
                salvageUnits: salvageUnits, beltCount: beltCount, hasEvent: hasEvent
            )
        }
        return targets.sorted { $0.system < $1.system }
    }
}

extension BeltClass {
    /// This class's place in the locked `ValueTier` ordering. Module-internal
    /// (not `fileprivate`) rather than `public`: `ValueCatalog.build(from:)`
    /// above is the only forward-direction caller, but `GrowRanking.swift`
    /// (Task 12, same target) also needs this correspondence — in reverse,
    /// to turn a winning `ValueTier` back into the `BeltClass` whose count it
    /// should read — via `ValueTier.beltClass` there. That reverse accessor
    /// is DERIVED from this one map (a search over `BeltClass.allCases`,
    /// which is why `BeltClass` is `CaseIterable`), so this switch stays the
    /// single source of truth for the tier↔class correspondence rather than
    /// two switches drifting apart.
    var valueTier: ValueTier {
        switch self {
        case .sparse: return .sparseBelt
        case .moderate: return .moderateBelt
        case .rich: return .richBelt
        }
    }
}
