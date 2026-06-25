//
//  CosmicBackdrop.swift
//  First Launch — the deep-space backdrop: seeded starfield, violet gradient +
//  nebula, and the legibility veil.
//

import SwiftUI

// Bespoke deep-space window gradient — not part of the shared token set, so it
// stays inline. Everything else uses the Color.rc* design tokens.
enum P {
    static let winTop = Color(hex: "1b1733")
    static let winBot = Color(hex: "08060f")
}

// MARK: - Starfield (seeded to match the HTML)

struct Starfield: View {
    struct Star { var x: Double; var y: Double; var r: Double; var o: Double }
    private let stars: [Star] = {
        var s: UInt64 = 11
        // our own random number generator with a specific seed for consistency
        func rnd() -> Double { s = (s &* 1103515245 &+ 12345) & 0x7fffffff; return Double(s) / Double(0x7fffffff) }
        return (0..<95).map { _ in
            Star(x: rnd(), y: rnd(), r: rnd() * 1.2 + 0.35, o: rnd() * 0.55 + 0.2)
        }
    }()
    var body: some View {
        Canvas { ctx, sz in
            for st in stars {
                let d = st.r * 2
                ctx.fill(Path(ellipseIn: CGRect(x: st.x * sz.width - st.r, y: st.y * sz.height - st.r,
                                                width: d, height: d)),
                         with: .color(Color(hex: "dfe8ff", st.o)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Background (gradient + nebula + veil)

struct CosmicBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [P.winTop, P.winBot], startPoint: .top, endPoint: .bottom)
            // nebula
            RadialGradient(colors: [Color(hex: "ffb23e", 0.14), .clear],
                           center: UnitPoint(x: 0.5, y: -0.12), startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color(hex: "658cff", 0.10), .clear],
                           center: UnitPoint(x: 0.12, y: 1.16), startRadius: 0, endRadius: 440)
            RadialGradient(colors: [Color(hex: "3fd3cb", 0.07), .clear],
                           center: UnitPoint(x: 1.04, y: 0.9), startRadius: 0, endRadius: 420)
        }
    }
}

struct Veil: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: "06090f", 0.62), .clear],
                           center: UnitPoint(x: 0.5, y: 0.34), startRadius: 0, endRadius: 240)
            RadialGradient(colors: [Color(hex: "06090f", 0.40), .clear],
                           center: UnitPoint(x: 0.5, y: 0.78), startRadius: 0, endRadius: 360)
        }
        .allowsHitTesting(false)
    }
}
