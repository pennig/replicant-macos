import Foundation
import UniverseModels

// The single source of truth for a system's "resource density" — derived from its
// asteroid belts. The star-label pip and the system dossier both read it, so the
// two can never disagree.

/// A system's resource readout, derived from its strongest asteroid belt: the raw
/// 0…1 `factor` (drives the gauge/pip) paired with the belt's qualitative density
/// `label` ("dense"/"moderate"/"sparse", nil when the belt carries no qualifier).
struct BeltDensityReading: Equatable {
    var factor: Float
    var label: String
}

/// A system's derived star-pip inputs, computed from a single decode of its
/// `SystemDetail` blob: the strongest belt reading and whether any body shows
/// detected life. Both feed the galaxy terrain's per-star pips.
struct SystemPips: Equatable {
    var beltDensity: BeltDensityReading?
    var hasDetectedLife: Bool
}

extension SystemPips {
    /// The strongest belt in a system as a `BeltDensityReading` (raw factor + its
    /// density label), or nil when the system has no belt.
    static func highestDensity(in system: StarSystem) -> BeltDensityReading? {
        func factor(_ density: String) -> Float {
            let d = density.lowercased()
            if d.contains("dense")    { return 1.0 }
            if d.contains("moderate") { return 0.65 }
            if d.contains("sparse")   { return 0.35 }
            return 0
        }
        
        return system.belts.compactMap { belt -> BeltDensityReading? in
            guard let density = belt.density else { return nil }
            return BeltDensityReading(
                factor: factor(density),
                label: density
            )
        }
        .sorted { $0.factor < $1.factor }
        .first
    }

    /// Whether any body (planet or moon) in the system shows a detected life stage.
    /// This is the fine-grained scan signal that supersedes the census `hasLife`
    /// boolean — that coarse flag lags the scan and stays false for, e.g., a
    /// `prebiotic` world the scan has already revealed.
    static func hasDetectedLife(in system: StarSystem) -> Bool {
        system.planets.contains { planet in
            OrreryMapping.hasDetectedLife(planet.lifeStage)
                || planet.moons.contains { OrreryMapping.hasDetectedLife($0.lifeStage) }
        }
    }
}

/// Memoizes the per-system star-pip derivation across `NewStarMapView` body
/// evaluations.
///
/// The map's body re-evaluates on every observed table change, and the galaxy
/// terrain needs each hydrated system's belt density and life signal to drive its
/// pips. Decoding every `SystemDetail` blob on every evaluation is the same
/// main-thread stall class as the drill-in hydrate hitch, so we decode once and
/// cache the tiny derived value keyed by (designation, hydratedAt) — a re-hydrate
/// refreshes naturally. Unlike `SystemDecodeCache` this holds many entries, since
/// the whole galaxy is in view.
@MainActor
final class SystemPipCache {
    private var entries: [String: (hydratedAt: Date, pips: SystemPips)] = [:]

    /// Derived star-pip inputs for a system (belt density + detected-life flag).
    /// Decodes the blob at most once per (designation, hydratedAt).
    func pips(for detail: SystemDetail) -> SystemPips {
        if let e = entries[detail.designation], e.hydratedAt == detail.hydratedAt {
            return e.pips
        }
        let system = try? detail.system()
        let pips = SystemPips(
            beltDensity: system.flatMap(SystemPips.highestDensity),
            hasDetectedLife: system.map(SystemPips.hasDetectedLife) ?? false
        )
        entries[detail.designation] = (detail.hydratedAt, pips)
        return pips
    }
}
