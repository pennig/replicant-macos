import Testing
import UniverseModels
@testable import LocationsFeature

@Suite("BodyFacts")
struct BodyFactsTests {
    @Test("a planet promotes type, orbit, habitable zone, life and moons")
    func planetRows() {
        let planet = Planet(
            designation: "SOL-3", name: "Terra", type: "Terrestrial",
            typeEstimated: false, orbitalDistanceAu: 1.0, inHabitableZone: true,
            lifeStage: "complex", recon: .scanned, moonCount: 1
        )
        #expect(BodyFacts.rows(planet: planet) == [
            BodyFact(label: "Type", value: "Terrestrial", mono: false),
            BodyFact(label: "Orbit", value: "1.00 AU", mono: false),
            BodyFact(label: "Habitable zone", value: "Yes", mono: false),
            BodyFact(label: "Life", value: "Complex", mono: false),
            BodyFact(label: "Moons", value: "1", mono: false),
        ])
    }

    @Test("an estimated type is marked, and absent values drop their rows")
    func planetSparse() {
        let planet = Planet(
            designation: "SOL-9", type: "Gas Giant", typeEstimated: true,
            inHabitableZone: false, recon: .aware
        )
        #expect(BodyFacts.rows(planet: planet) == [
            BodyFact(label: "Type", value: "Gas Giant (est.)", mono: false),
            BodyFact(label: "Habitable zone", value: "No", mono: false),
        ])
    }

    @Test("a life stage of none is not a fact")
    func planetLifeNone() {
        let planet = Planet(
            designation: "SOL-4", type: "Barren", typeEstimated: false,
            inHabitableZone: false, lifeStage: "none", recon: .scanned
        )
        #expect(!BodyFacts.rows(planet: planet).contains { $0.label == "Life" })
    }

    @Test("a moon draws its remaining rows from physical characteristics")
    func moonRows() {
        let moon = Moon(
            designation: "SOL-3-1", name: "Luna", type: "Rocky", recon: .scanned,
            physical: BodyPhysical(
                radiusEarth: 0.27, surfaceGravity: 0.17,
                surfaceTempC: -20, atmosphere: "none"
            )
        )
        #expect(BodyFacts.rows(moon: moon) == [
            BodyFact(label: "Type", value: "Rocky", mono: false),
            BodyFact(label: "Radius", value: "0.27 R⊕", mono: false),
            BodyFact(label: "Gravity", value: "0.17 g", mono: false),
            BodyFact(label: "Surface", value: "-20 °C", mono: false),
            BodyFact(label: "Atmosphere", value: "None", mono: false),
        ])
    }

    @Test("a moon with no physical block yields only its type")
    func moonUnscanned() {
        let moon = Moon(designation: "SOL-5-2", recon: .aware)
        #expect(BodyFacts.rows(moon: moon) == [
            BodyFact(label: "Type", value: "—", mono: false),
        ])
    }

    @Test("a star promotes class, colour, age, mining bonus and distance")
    func starRows() {
        let star = SystemStar(
            designation: "SOL", stellarClass: "G2V", color: "yellow",
            ageMy: 4600, miningBonusPct: 12, distanceFromSol: 0
        )
        #expect(BodyFacts.rows(star: star) == [
            BodyFact(label: "Class", value: "G2V", mono: false),
            BodyFact(label: "Color", value: "Yellow", mono: false),
            BodyFact(label: "Age", value: "4600 My", mono: false),
            BodyFact(label: "Mining bonus", value: "+12%", mono: false),
            BodyFact(label: "From Sol", value: "0.0 ly", mono: false),
        ])
    }

    @Test("a zero mining bonus is not a fact")
    func starZeroBonus() {
        let star = SystemStar(designation: "VEGA", stellarClass: "A0V", miningBonusPct: 0)
        #expect(!BodyFacts.rows(star: star).contains { $0.label == "Mining bonus" })
    }

    @Test("a belt promotes density and radius")
    func beltRows() {
        let belt = Belt(designation: "SOL-BELT-1", innerRadiusAu: 2.1,
                        outerRadiusAu: 3.4, density: "moderate")
        #expect(BodyFacts.rows(belt: belt) == [
            BodyFact(label: "Density", value: "Moderate", mono: false),
            BodyFact(label: "Radius", value: "2.1–3.4 AU", mono: false),
        ])
    }

    @Test("a Lagrange point names its parent in monospace")
    func lagrangeRows() {
        let parent = Planet(designation: "SOL-3", typeEstimated: false,
                            orbitalDistanceAu: 1.0, inHabitableZone: true, recon: .scanned)
        #expect(BodyFacts.rows(lagrangePoint: 4, parent: parent, site: nil) == [
            BodyFact(label: "Point", value: "L4", mono: false),
            BodyFact(label: "Stability", value: "Stable", mono: false),
            BodyFact(label: "Parent", value: "SOL-3", mono: true),
            BodyFact(label: "Orbit", value: "1.00 AU", mono: false),
        ])
    }

    @Test("L1 L2 and L3 are unstable")
    func lagrangeStability() {
        let parent = Planet(designation: "SOL-3", typeEstimated: false,
                            inHabitableZone: false, recon: .scanned)
        for n in [1, 2, 3] {
            let rows = BodyFacts.rows(lagrangePoint: n, parent: parent, site: nil)
            #expect(rows.first { $0.label == "Stability" }?.value == "Unstable")
        }
    }

    @Test("a site promotes type status stage orbit and deadline")
    func siteRows() {
        let site = SpecialSite(
            designation: "SOL-MEGA-1", kind: .megastructure,
            objectType: "dyson_swarm", status: "building", stage: "phase_one",
            orbitalDistanceAu: 0.8, deadline: "2026-09-01T00:00:00Z"
        )
        #expect(BodyFacts.rows(site: site) == [
            BodyFact(label: "Type", value: "Dyson Swarm", mono: false),
            BodyFact(label: "Status", value: "Building", mono: false),
            BodyFact(label: "Stage", value: "Phase One", mono: false),
            BodyFact(label: "Orbit", value: "0.80 AU", mono: false),
            BodyFact(label: "Deadline", value: "2026-09-01T00:00:00Z", mono: true),
        ])
    }
}
