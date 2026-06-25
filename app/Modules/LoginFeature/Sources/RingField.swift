//
//  RingField.swift
//  First Launch — the continuously radiating hex→circle ring field that
//  emanates from the logo mark.
//

import SwiftUI
import Utils

struct RingField: View, @MainActor Animatable {
    var origin: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Interpolate `origin` so the field glides when the logo moves between forms.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(origin.x, origin.y) }
        set { origin = CGPoint(x: newValue.first, y: newValue.second) }
    }

    // Static config (matches the saved Tweaks panel values).
    private static let ringCount: Double = 12
    private static let appearRadius: Double = 20
    private static let circleRadius: Double = 170
    private static let vanishRadius: Double = 580
    private static let spacingEase: Double = 2.4
    private static let speed: Double = 0.4

    private let birthR: Double = 16
    private let baseLife: Double = 7.2   // seconds at speed 1×

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { tl in
            Canvas { ctx, _ in
                let now = reduceMotion
                    ? baseLife * 0.5
                    : tl.date.timeIntervalSinceReferenceDate
                draw(into: ctx, now: now)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(into ctx: GraphicsContext, now: TimeInterval) {
        let count = max(2, Int(Self.ringCount.rounded()))
        let appearR = Self.appearRadius
        let vanishR = max(appearR + 40, Self.vanishRadius)
        let circleR = max(birthR + 1, Self.circleRadius)
        let ease = Self.spacingEase
        let period = baseLife / max(0.05, Self.speed)
        let span = vanishR - birthR

        for i in 0..<count {
            var p = (now / period + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
            if p < 0 { p += 1 }
            let Rc = birthR + span * pow(p, ease)              // eased outward radius
            let k = min(max((Rc - birthR) / (circleR - birthR), 0), 1)  // hex → circle by circleR

            var op = 0.0
            if Rc > appearR && Rc < vanishR {
                let f = (Rc - appearR) / (vanishR - appearR)
                op = 0.2 * min(1, f / 0.10) * min(1, (1 - f) / 0.45)
            }
            if op <= 0.001 { continue }

            let w = 1.0//0.8 + 2.2 * (1 - min(1, Rc / vanishR))
            let c = mix(cAccent, cViolet, k * 0.45)
            let path = roundedHexPath(center: origin, radius: CGFloat(Rc), k: k)
            ctx.stroke(path, with: .color(col(c, op)),
                       style: StrokeStyle(lineWidth: CGFloat(w), lineJoin: .round))
        }
    }
}
