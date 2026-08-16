import Testing
import UniverseModels
@testable import LocationsFeature

@Suite("SiteGlyph")
struct SiteGlyphTests {
    @Test("an inbound impactor is a hazard, not a structure")
    func impactor() {
        let site = SpecialSite(designation: "SOL-OBJ-1", kind: .object,
                               objectType: "incoming_asteroid")
        #expect(SiteGlyph.symbolName(for: site) == "exclamationmark.triangle")
    }

    @Test("a megastructure gets the construction glyph")
    func megastructure() {
        let site = SpecialSite(designation: "SOL-MEGA-1", kind: .megastructure)
        #expect(SiteGlyph.symbolName(for: site) == "building.2")
    }

    @Test("kuiper and oort fall back to a region glyph")
    func regions() {
        for kind in [SpecialSiteKind.kuiper, .oort] {
            let site = SpecialSite(designation: "SOL-K", kind: kind)
            #expect(SiteGlyph.symbolName(for: site) == "circle.dotted")
        }
    }

    @Test("an unremarkable object gets the generic glyph")
    func object() {
        let site = SpecialSite(designation: "SOL-OBJ-2", kind: .object)
        #expect(SiteGlyph.symbolName(for: site) == "shippingbox")
    }
}
