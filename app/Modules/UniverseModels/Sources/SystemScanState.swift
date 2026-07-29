//
//  SystemScanState.swift
//  UniverseModels
//
//  When is a star system completely surveyed, and what happens to its census
//  row when it becomes so.
//
//  The predicate lives here rather than on the survey mission that first needed
//  it because it is phrased entirely in a `StarSystem`'s own fields — and
//  because the persistence layer below the engine has to ask it too.
//  UniverseModels cannot import DirectiveEngine, so this is the only level at
//  which one shared definition is possible.
//

import Foundation
import SQLiteData

extension StarSystem {
    /// Whether this system's scan counts say it is completely surveyed.
    ///
    /// UNKNOWN counts are never "scanned": re-surveying an already-done system
    /// costs one wasted trip, but skipping an unscanned one silently loses the
    /// whole point of the survey. Wrong in the cheap direction, deliberately.
    public var isFullyScanned: Bool {
        guard let planetsTotal, planetsTotal > 0,
              let planetsScanned, planetsScanned >= planetsTotal
        else { return false }
        // Moons are optional in the payload; when the server reports a total, it
        // has to be met too.
        if let moonsTotal, moonsTotal > 0 {
            guard let moonsScanned, moonsScanned >= moonsTotal else { return false }
        }
        return true
    }
}

extension SystemDetail {
    /// Persist a system's blob AND reconcile its census row's scan lifecycle
    /// stamp, in one transaction.
    ///
    /// Every path that writes a `SystemDetail` goes through here — the seven in
    /// `LocationsClient`, the star map's hydrate, and the Locations catalog's
    /// hydrate-on-select. That is the point: `stars.fullyScannedAt` was declared,
    /// documented, and read by the star map as the `.full` survey tier, but
    /// written by nothing at all, so it was null on every one of 14,122 rows and
    /// the map could never show a system as fully scanned. A stamp attached to
    /// one write path would simply have grown new holes.
    ///
    /// The stamp is WRITE-ONCE. The column is named for an event, not a state,
    /// and `Star`'s three local lifecycle timestamps are documented as ones the
    /// survey never overwrites. Concretely: `moonsTotalEstimated` means moon
    /// totals do get revised upward, and a retractable stamp would flip systems
    /// between `.full` and `.partial` on estimate churn.
    ///
    /// A system with no census row still persists its blob — nothing to stamp is
    /// not a failure.
    public static func persist(system: StarSystem, at now: Date, in db: Database) throws {
        let row = try SystemDetail(system: system, hydratedAt: now)
        try SystemDetail.upsert { row }.execute(db)

        guard system.isFullyScanned else { return }
        // Read-then-write rather than a nullable predicate in the UPDATE: it
        // makes write-once explicit at the call site, and folds "no census row"
        // into the same guard. Only ever reached on the completing write, which
        // happens once per system.
        let star = try Star.where { $0.designation.eq(system.designation) }.fetchOne(db)
        guard let star, star.fullyScannedAt == nil else { return }
        try Star.where { $0.designation.eq(system.designation) }
            .update { $0.fullyScannedAt = #bind(now) }
            .execute(db)
    }
}
