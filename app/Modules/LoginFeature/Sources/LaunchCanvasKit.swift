//
//  LaunchCanvasKit.swift
//  Shared color plumbing for the First Launch Canvas marks (RingField +
//  ReplicouldLogoView). The geometry path builders live in the Utils module
//  (`roundedHexPath`, `polyPath`); this file holds the launch-screen palette.
//

import SwiftUI

// MARK: - Color helpers

struct RGB { var r: Double; var g: Double; var b: Double }

let cAccent = RGB(r: 255, g: 178, b: 62)     // #ffb23e
let cViolet = RGB(r: 181, g: 139, b: 255)    // relay tint

func mix(_ a: RGB, _ b: RGB, _ f: Double) -> RGB {
    RGB(r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f, b: a.b + (b.b - a.b) * f)
}

func col(_ c: RGB, _ o: Double = 1) -> Color {
    Color(.sRGB, red: c.r / 255, green: c.g / 255, blue: c.b / 255, opacity: o)
}

extension Color {
    init(hex: String, _ opacity: Double = 1) {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255,
                     opacity: opacity)
    }
}
