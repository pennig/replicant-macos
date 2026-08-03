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
public enum BeltClass: Int, Comparable, Sendable {
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
