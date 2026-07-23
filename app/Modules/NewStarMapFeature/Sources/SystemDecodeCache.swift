import Foundation
import UniverseModels

/// Memoizes the JSON-decode of a persisted system blob across `NewStarMapView`
/// body evaluations.
///
/// The map's body re-evaluates on EVERY observed table change — the device roster
/// alone refreshes every few seconds — and, while focused, a single evaluation
/// used to decode the same `SystemDetail.systemJSON` blob several times over
/// (`focusedModel`, `deviceClusters`, `locationDetail`, the nav title). That
/// repeated main-thread decode is the same stall class as the drill-in hydrate
/// hitch (see the starmap-hydrate-fly-hitch memory note). Keyed by
/// (designation, hydratedAt), so a re-hydrate invalidates naturally.
///
/// One entry only: the map decodes exactly one focused system at a time.
@MainActor
final class SystemDecodeCache {
    private var designation: String?
    private var hydratedAt: Date?
    private var system: StarSystem?

    /// The decoded system for `detail`, from cache when the row is unchanged.
    func system(for detail: SystemDetail) -> StarSystem? {
        if designation == detail.designation, hydratedAt == detail.hydratedAt {
            return system
        }
        let decoded = try? detail.system()
        designation = detail.designation
        hydratedAt = detail.hydratedAt
        system = decoded
        return decoded
    }
}
