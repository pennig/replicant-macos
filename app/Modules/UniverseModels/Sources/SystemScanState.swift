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
