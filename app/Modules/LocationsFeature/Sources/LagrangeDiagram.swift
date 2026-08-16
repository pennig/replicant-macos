import CoreGraphics
import SwiftUI
import UI

/// Where the five Lagrange points fall for a planet on a circular orbit of
/// `orbitRadius` about a star at `centre`, with the planet at +x.
enum LagrangeGeometry {
    static func points(orbitRadius r: CGFloat, centre c: CGPoint) -> [Int: CGPoint] {
        [
            1: CGPoint(x: c.x + r * 0.85, y: c.y),
            2: CGPoint(x: c.x + r * 1.15, y: c.y),
            3: CGPoint(x: c.x - r, y: c.y),
            4: CGPoint(x: c.x + r * 0.5, y: c.y - r * sqrt(3) / 2),
            5: CGPoint(x: c.x + r * 0.5, y: c.y + r * sqrt(3) / 2),
        ]
    }
}

/// The five Lagrange points of a star/planet pair, with one of them selected.
/// Selection reads through size and lightness, never hue alone.
struct LagrangeDiagram: View {
    let selected: Int

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) * 0.34
            let points = LagrangeGeometry.points(orbitRadius: r, centre: centre)
            let planet = CGPoint(x: centre.x + r, y: centre.y)

            context.stroke(
                Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                with: .color(.rcSeparator),
                lineWidth: Hairline.thin
            )
            context.fill(dot(at: centre, radius: 5), with: .color(.rcTextSecondary))
            context.fill(dot(at: planet, radius: 3.5), with: .color(.rcTextSecondary))

            for (n, p) in points where n != selected {
                context.stroke(cross(at: p, arm: 2.5), with: .color(.rcTextTertiary), lineWidth: Hairline.regular)
            }
            if let p = points[selected] {
                context.fill(dot(at: p, radius: 5), with: .color(.rcAccent))
                context.stroke(dot(at: p, radius: 8), with: .color(.rcAccent), lineWidth: Hairline.regular)
                context.draw(
                    context.resolve(Text("L\(selected)").font(.rcMonoSmall).foregroundStyle(.rcTextPrimary)),
                    at: CGPoint(x: p.x, y: p.y - 16)
                )
            }
        }
    }

    private func dot(at p: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    }

    private func cross(at p: CGPoint, arm: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: p.x - arm, y: p.y)); path.addLine(to: CGPoint(x: p.x + arm, y: p.y))
        path.move(to: CGPoint(x: p.x, y: p.y - arm)); path.addLine(to: CGPoint(x: p.x, y: p.y + arm))
        return path
    }
}
