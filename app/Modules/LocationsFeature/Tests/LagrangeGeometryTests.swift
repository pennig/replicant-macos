import Testing
import CoreGraphics
@testable import LocationsFeature

@Suite("LagrangeGeometry")
struct LagrangeGeometryTests {
    private let centre = CGPoint(x: 0, y: 0)
    private let r: CGFloat = 100

    @Test("all five points are placed")
    func fivePoints() {
        let pts = LagrangeGeometry.points(orbitRadius: r, centre: centre)
        #expect(Set(pts.keys) == [1, 2, 3, 4, 5])
    }

    @Test("L1 sits between the star and the planet, L2 beyond it, L3 opposite")
    func collinearPoints() {
        let pts = LagrangeGeometry.points(orbitRadius: r, centre: centre)
        // The planet sits at +x. Distances from the star at the origin.
        #expect(pts[1]!.x < r && pts[1]!.x > 0)
        #expect(pts[2]!.x > r)
        #expect(pts[3]!.x < 0)
        for n in [1, 2, 3] {
            #expect(abs(pts[n]!.y) < 0.001)
        }
    }

    @Test("L4 and L5 sit on the orbit, 60 degrees either side of the planet")
    func trojanPoints() {
        let pts = LagrangeGeometry.points(orbitRadius: r, centre: centre)
        for n in [4, 5] {
            let d = hypot(pts[n]!.x - centre.x, pts[n]!.y - centre.y)
            #expect(abs(d - r) < 0.001)
        }
        #expect(pts[4]!.y < 0)              // 60 degrees ahead, screen y grows downward
        #expect(pts[5]!.y > 0)
        #expect(abs(pts[4]!.x - pts[5]!.x) < 0.001)
        #expect(abs(pts[4]!.x - r * 0.5) < 0.001)
    }
}
