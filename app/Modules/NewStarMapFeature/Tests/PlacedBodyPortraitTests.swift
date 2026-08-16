import Testing
import UniverseModels
import simd
@testable import NewStarMapFeature

@Suite("PlacedBody portrait")
struct PlacedBodyPortraitTests {
    private func planet(_ type: String, rings: Bool = false) -> Planet {
        Planet(designation: "SOL-6", type: type, typeEstimated: false,
               inHabitableZone: false, recon: .scanned,
               physical: BodyPhysical(rings: rings, rotationPeriodHours: 10.7))
    }

    private func portrait(_ p: Planet) -> PlacedBody {
        PlacedBody(portrait: OrreryMapping.appearance(planet: p, options: .default),
                   designation: p.designation, center: .zero, radius: 1,
                   sun: SIMD3(28, 12, 20))
    }

    @Test("a portrait body is never central and sits at the origin")
    func placement() {
        let b = portrait(planet("Gas Giant"))
        #expect(!b.isCentral)
        #expect(b.center == .zero)
        #expect(b.radius == 1)
    }

    @Test("a ringed giant carries its rings into the uniform builder")
    func rings() {
        #expect(ringUniform(portrait(planet("Gas Giant", rings: true))) != nil)
        #expect(ringUniform(portrait(planet("Gas Giant", rings: false))) == nil)
    }

    @Test("a captured asteroid is irregular, read off the raw type string")
    func irregular() {
        let moon = Moon(designation: "SOL-5-9", type: "Captured Asteroid", recon: .scanned)
        let b = PlacedBody(portrait: OrreryMapping.appearance(moon: moon, options: .default),
                           designation: moon.designation, center: .zero, radius: 1,
                           sun: SIMD3(28, 12, 20))
        #expect(b.irregularity > 0)
    }

    @Test("a tidally locked body still spins from its designation, not an orbit angle")
    func lockedPhase() {
        let moon = Moon(designation: "SOL-3-1", type: "Rocky", recon: .scanned,
                        physical: BodyPhysical(rotationPeriodHours: 655, tidallyLocked: true))
        let b = PlacedBody(portrait: OrreryMapping.appearance(moon: moon, options: .default),
                           designation: moon.designation, center: .zero, radius: 1,
                           sun: SIMD3(28, 12, 20))
        #expect(b.spinRate != 0)
    }

    @Test("the sun position reaches the body uniform unchanged")
    func sunTravels() {
        let sun = SIMD3<Float>(28, 12, 20)
        let u = bodyUniform(portrait(planet("Terrestrial")))
        #expect(SIMD3(u.sunEmissive.x, u.sunEmissive.y, u.sunEmissive.z) == sun)
    }
}
