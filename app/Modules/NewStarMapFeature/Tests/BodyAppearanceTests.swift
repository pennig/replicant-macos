import Testing
import UniverseModels
@testable import NewStarMapFeature

@Suite("BodyAppearance")
struct BodyAppearanceTests {
    @Test("a planet carries its raw type through, so irregularity can read it")
    func rawTypeSurvives() {
        let planet = Planet(designation: "SOL-3", type: "Terrestrial",
                            typeEstimated: false, inHabitableZone: true, recon: .scanned)
        #expect(OrreryMapping.appearance(planet: planet, options: .default).rawType == "Terrestrial")
    }

    @Test("a ringed gas giant resolves a ring system")
    func ringedGiant() {
        let planet = Planet(
            designation: "SOL-6", type: "Gas Giant", typeEstimated: false,
            inHabitableZone: false, recon: .scanned,
            physical: BodyPhysical(rings: true, rotationPeriodHours: 10.7)
        )
        #expect(OrreryMapping.appearance(planet: planet, options: .default).rings != nil)
    }

    @Test("an unringed planet resolves no ring system")
    func unringed() {
        let planet = Planet(designation: "SOL-4", type: "Barren", typeEstimated: false,
                            inHabitableZone: false, recon: .scanned)
        #expect(OrreryMapping.appearance(planet: planet, options: .default).rings == nil)
    }

    @Test("a planet's estimated flag is its own typeEstimated")
    func planetEstimated() {
        let planet = Planet(designation: "SOL-9", type: "Ice Giant", typeEstimated: true,
                            inHabitableZone: false, recon: .scanned)
        #expect(OrreryMapping.appearance(planet: planet, options: .default).estimated)
    }

    @Test("a moon's estimated flag comes from recon, since it has no typeEstimated")
    func moonEstimated() {
        let scanned = Moon(designation: "SOL-3-1", type: "Rocky", recon: .scanned)
        let aware = Moon(designation: "SOL-3-2", type: "Rocky", recon: .aware)
        #expect(!OrreryMapping.appearance(moon: scanned, options: .default).estimated)
        #expect(OrreryMapping.appearance(moon: aware, options: .default).estimated)
    }

    @Test("a moon never has rings and is never in a habitable zone")
    func moonDefaults() {
        let moon = Moon(designation: "SOL-6-1", type: "Icy", recon: .scanned,
                        physical: BodyPhysical(rings: true))
        let a = OrreryMapping.appearance(moon: moon, options: .default)
        #expect(a.rings == nil)
        #expect(!a.inHabitableZone)
    }

    @Test("a moon's atmosphere goes through the moon-specific derivation")
    func moonAtmosphere() {
        let moon = Moon(designation: "SOL-6-2", type: "Rocky", recon: .scanned,
                        physical: BodyPhysical(tags: ["thick_atmosphere"], hasAtmosphere: true))
        #expect(OrreryMapping.appearance(moon: moon, options: .default).atmosphere == .dense)
    }

    @Test("the appearance seed depends only on designation and rotation period")
    func seedIsStable() {
        let a = Planet(designation: "SOL-3", type: "Terrestrial", typeEstimated: false,
                       inHabitableZone: true, recon: .scanned,
                       physical: BodyPhysical(rotationPeriodHours: 24))
        let b = Planet(designation: "SOL-3", type: "Gas Giant", typeEstimated: true,
                       inHabitableZone: false, recon: .aware,
                       physical: BodyPhysical(rotationPeriodHours: 24))
        #expect(OrreryMapping.appearance(planet: a, options: .default).appearanceSeed
                == OrreryMapping.appearance(planet: b, options: .default).appearanceSeed)
    }

    @Test("a tidally locked moon reports a locked spin")
    func lockedSpin() {
        let moon = Moon(designation: "SOL-3-1", type: "Rocky", recon: .scanned,
                        physical: BodyPhysical(rotationPeriodHours: 655, tidallyLocked: true))
        #expect(OrreryMapping.appearance(moon: moon, options: .default).spin.tidallyLocked)
    }
}
