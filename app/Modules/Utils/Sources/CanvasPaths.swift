//
//  CanvasPaths.swift
//  Utils — reusable hand-rolled `Path` builders for SwiftUI `Canvas` drawing.
//

import SwiftUI

/// Pointy-top hexagon, optionally rounded toward a circle (k: 0 sharp … 1 circle).
public func roundedHexPath(center: CGPoint, radius R: CGFloat, k: Double) -> Path {
    var path = Path()
    var pts: [CGPoint] = []
    for i in 0..<6 {
        let a = (-90.0 + Double(i) * 60.0) * .pi / 180
        pts.append(CGPoint(x: center.x + R * CGFloat(cos(a)), y: center.y + R * CGFloat(sin(a))))
    }
    let kk = min(max(k, 0), 1)
    if kk <= 0.001 {
        path.move(to: pts[0])
        for i in 1..<6 { path.addLine(to: pts[i]) }
        path.closeSubpath()
        return path
    }
    // corner radius → at k=1 the six arcs meet at edge midpoints ≈ a circle
    let r = CGFloat(kk) * R * 0.8660254
    func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    path.move(to: mid(pts[5], pts[0]))
    for i in 0..<6 {
        path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 6], radius: r)
    }
    path.closeSubpath()
    return path
}

/// Closed polygon through the given points.
public func polyPath(_ points: [CGPoint]) -> Path {
    var p = Path()
    guard let first = points.first else { return p }
    p.move(to: first)
    for pt in points.dropFirst() { p.addLine(to: pt) }
    p.closeSubpath()
    return p
}
