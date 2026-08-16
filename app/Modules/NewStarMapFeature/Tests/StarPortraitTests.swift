import Testing
import UniverseModels
import simd
@testable import NewStarMapFeature

@Suite("Star portrait")
struct StarPortraitTests {
    @Test("a star's colour comes from its spectral class, matching the map")
    func colourFromClass() {
        let star = SystemStar(designation: "SOL", stellarClass: "G2V", temperatureK: 5772)
        let instance = BodyPortraitRenderer.starInstance(for: star, radius: 1)
        let expected = Star.color(
            forTemperature: StellarClass(spectralType: "G2V").representativeTemperature)
        #expect(SIMD3(instance.color.x, instance.color.y, instance.color.z) == expected)
    }

    @Test("the real temperature is deliberately not used")
    func temperatureIgnored() {
        let warm = SystemStar(designation: "A", stellarClass: "G2V", temperatureK: 5900)
        let cool = SystemStar(designation: "B", stellarClass: "G8V", temperatureK: 5300)
        #expect(BodyPortraitRenderer.starInstance(for: warm, radius: 1).color
                == BodyPortraitRenderer.starInstance(for: cool, radius: 1).color)
    }

    @Test("an unknown or missing class falls back to G, as the map does")
    func unknownClass() {
        let none = SystemStar(designation: "X")
        let g = SystemStar(designation: "Y", stellarClass: "G0V")
        #expect(BodyPortraitRenderer.starInstance(for: none, radius: 1).color
                == BodyPortraitRenderer.starInstance(for: g, radius: 1).color)
    }

    @Test("the instance carries the requested radius")
    func radius() {
        let star = SystemStar(designation: "SOL")
        #expect(BodyPortraitRenderer.starInstance(for: star, radius: 1).positionRadius.w == 1)
    }
}
