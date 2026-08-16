import Testing
import UniverseModels
@testable import NewStarMapFeature

@Suite("Belt portrait")
struct BeltPortraitTests {
    @Test("the band keeps the belt's true radial width")
    func widthPreserved() {
        let belt = Belt(designation: "SOL-BELT-1", innerRadiusAu: 2.1,
                        outerRadiusAu: 3.4, density: "moderate")
        let band = BodyPortraitRenderer.beltBand(for: belt)
        let expected = OrreryMapping.sceneRadius(au: 3.4) - OrreryMapping.sceneRadius(au: 2.1)
        #expect(abs((band.outerScene - band.innerScene) - expected) < 0.001)
    }

    @Test("a belt with no radii still gets a visible band")
    func noRadii() {
        let band = BodyPortraitRenderer.beltBand(for: Belt(designation: "X-BELT-1"))
        #expect(band.outerScene > band.innerScene)
    }

    @Test("density carries through, since it drives the point count")
    func density() {
        let belt = Belt(designation: "SOL-BELT-1", density: "dense")
        #expect(BodyPortraitRenderer.beltBand(for: belt).density == "dense")
    }

    @Test("a Kuiper or Oort region reads as a wide sparse band")
    func region() {
        for kind in [SpecialSiteKind.kuiper, .oort] {
            let site = SpecialSite(designation: "SOL-K", kind: kind)
            let band = BodyPortraitRenderer.regionBand(for: site)
            #expect(band.density == "sparse")
            #expect(band.outerScene - band.innerScene > 2)
        }
    }
}
