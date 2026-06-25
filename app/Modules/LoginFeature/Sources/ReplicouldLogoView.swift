//
//  ReplicouldLogoView.swift
//  First Launch — the transparent Bloom logo mark, drawn live so it scales
//  crisply and centers the radiating RingField.
//

import SwiftUI
import Utils

struct ReplicouldLogoView: View {
    var size: CGFloat = 116
    var body: some View {
        Canvas { ctx, sz in
            let scale = sz.width / 500.0   // icon viewBox is -250…250
            ctx.translateBy(x: sz.width / 2, y: sz.height / 2)
            ctx.scaleBy(x: scale, y: scale)
            let O = CGPoint(x: 0, y: 0)

            // soft amber glow
            ctx.fill(
                Path(ellipseIn: CGRect(x: -210, y: -210, width: 420, height: 420)),
                with: .radialGradient(
                    Gradient(colors: [col(cAccent, 0.45), col(cAccent, 0)]),
                    center: O, startRadius: 0, endRadius: 210))

            // ring 1 (rounded) then ring 0 (sharp, carries buds)
            ctx.stroke(roundedHexPath(center: O, radius: 224, k: 0.174),
                       with: .color(col(cAccent, 0.422)),
                       style: StrokeStyle(lineWidth: 6.6, lineJoin: .round))
            ctx.stroke(roundedHexPath(center: O, radius: 158, k: 0),
                       with: .color(col(cAccent, 0.55)),
                       style: StrokeStyle(lineWidth: 7, lineJoin: .round))

            // core cube — base hex with a lit radial fill
            let core = roundedHexPath(center: O, radius: 78, k: 0)
            ctx.fill(core, with: .radialGradient(
                Gradient(colors: [col(mix(cAccent, RGB(r: 255, g: 255, b: 255), 0.55)),
                                  col(cAccent),
                                  col(mix(cAccent, RGB(r: 0, g: 0, b: 0), 0.5))]),
                center: CGPoint(x: -16, y: -22), startRadius: 0, endRadius: 110))

            // three isometric faces (contrast 45%)
            let top = polyPath([CGPoint(x: 0, y: -78), CGPoint(x: 67.55, y: -39),
                                CGPoint(x: 0, y: 0), CGPoint(x: -67.55, y: -39)])
            let right = polyPath([CGPoint(x: 67.55, y: -39), CGPoint(x: 67.55, y: 39),
                                  CGPoint(x: 0, y: 78), CGPoint(x: 0, y: 0)])
            let left = polyPath([CGPoint(x: -67.55, y: -39), CGPoint(x: 0, y: 0),
                                 CGPoint(x: 0, y: 78), CGPoint(x: -67.55, y: 39)])
            ctx.fill(left, with: .color(.black.opacity(0.081)))
            ctx.fill(right, with: .color(.black.opacity(0.027)))
            ctx.fill(top, with: .linearGradient(
                Gradient(colors: [Color(hex: "fff3d8", 0.117), Color(hex: "fff3d8", 0)]),
                startPoint: CGPoint(x: 0, y: -78), endPoint: CGPoint(x: 0, y: 0)))

            // interior edges (edge opacity 15%)
            var ridge = Path()
            ridge.move(to: CGPoint(x: -67.55, y: -39))
            ridge.addLine(to: O); ridge.addLine(to: CGPoint(x: 67.55, y: -39))
            ctx.stroke(ridge, with: .color(Color(hex: "fff4da", 0.045)),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            var front = Path()
            front.move(to: O); front.addLine(to: CGPoint(x: 0, y: 78))
            ctx.stroke(front, with: .color(Color(hex: "2a1500", 0.048)),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

            // offspring buds (halo + dot) at the six ring-0 vertices
            let budFill = col(mix(cAccent, RGB(r: 255, g: 255, b: 255), 0.18))
            for i in 0..<6 {
                let a = (-90.0 + Double(i) * 60.0) * .pi / 180
                let x = 158 * cos(a), y = 158 * sin(a)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 24, y: y - 24, width: 48, height: 48)),
                         with: .color(col(cAccent, 0.30)))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 13, y: y - 13, width: 26, height: 26)),
                         with: .color(budFill))
            }
        }
        .frame(width: size, height: size)
    }
}
