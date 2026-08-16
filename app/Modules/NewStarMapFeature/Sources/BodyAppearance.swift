import UniverseModels
import simd

/// Everything about how one body looks, independent of where it sits in a system.
/// Exactly the inputs `PlanetMaterial` and `BodySpin` need — nothing scene-scoped.
struct BodyAppearance: Equatable, Sendable {
    var planetType: PlanetType
    /// The raw API type string. `PlanetMaterial.irregularity` reads this, not
    /// `planetType` — "Captured Asteroid" has no `PlanetType` case.
    var rawType: String?
    var lifeStage: String?
    var estimated: Bool
    var tags: [String]
    var surfaceTempC: Double?
    var atmosphere: Atmosphere
    var inHabitableZone: Bool
    var hasSubsurfaceOcean: Bool
    var appearanceSeed: Float
    var spin: BodySpin
    var rings: RingSystem?
}

extension OrreryMapping {
    static func appearance(planet p: Planet, options: OrreryPlaneOptions = .default) -> BodyAppearance {
        let type = PlanetType(apiType: p.type)
        let seed = appearanceSeed(designation: p.designation,
                                  rotationPeriodHours: p.physical?.rotationPeriodHours)
        return BodyAppearance(
            planetType: type,
            rawType: p.type,
            lifeStage: p.lifeStage,
            estimated: p.typeEstimated,
            tags: p.physical?.tags ?? [],
            surfaceTempC: p.physical?.surfaceTempC,
            atmosphere: Atmosphere(apiValue: p.physical?.atmosphere),
            inHabitableZone: p.inHabitableZone,
            hasSubsurfaceOcean: p.physical?.hasSubsurfaceOcean ?? false,
            appearanceSeed: seed,
            spin: BodySpin(tiltDeg: p.physical?.axialTiltDeg,
                           rotationHours: p.physical?.rotationPeriodHours,
                           tidallyLocked: p.physical?.tidallyLocked ?? false,
                           tiltCapDeg: options.tiltCapDeg),
            rings: PlanetMaterial.ringSystem(hasRings: p.physical?.rings ?? false,
                                             type: type, seed: seed))
    }

    static func appearance(moon m: Moon, options: OrreryPlaneOptions = .default) -> BodyAppearance {
        BodyAppearance(
            planetType: PlanetType(apiType: m.type),
            rawType: m.type,
            lifeStage: m.lifeStage,
            estimated: m.recon != .scanned,
            tags: m.physical?.tags ?? [],
            surfaceTempC: m.physical?.surfaceTempC,
            atmosphere: moonAtmosphere(m),
            inHabitableZone: false,
            hasSubsurfaceOcean: m.physical?.hasSubsurfaceOcean ?? false,
            appearanceSeed: appearanceSeed(designation: m.designation,
                                           rotationPeriodHours: m.physical?.rotationPeriodHours),
            spin: BodySpin(tiltDeg: m.physical?.axialTiltDeg,
                           rotationHours: m.physical?.rotationPeriodHours,
                           tidallyLocked: m.physical?.tidallyLocked ?? false,
                           tiltCapDeg: options.tiltCapDeg),
            rings: nil)
    }
}
