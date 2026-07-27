//
//  BodyFactFormat.swift
//  NewStarMapFeature
//
//  Number formatting for the location dossier's physical facts. Deliberately a plain
//  SwiftUI-free namespace rather than statics on the view: pure logic hung off a
//  SwiftUI `View` traps (signal 5) under `swift test` — see the
//  `swiftui-view-statics-trap-in-tests` memory note. Keeping it here also makes the
//  unit ranges testable, which is where the real decisions live.
//

import Foundation

enum BodyFactFormat {

    /// A rotation period. Below two days it reads in hours (SOL-6 = "10.7 h"); beyond
    /// that, hours stop being meaningful and days are how the game talks about it
    /// anyway (SOL-2's 5832.5 h → "243 d").
    static func hours(_ h: Double) -> String {
        h < 48 ? String(format: "%.1f h", h) : String(format: "%.0f d", h / 24)
    }

    /// An orbital period. A gas giant's year in days is an unreadable five digits
    /// (SOL-7 = 30589), so anything past ~2.5 years switches to years.
    static func days(_ d: Double) -> String {
        d < 900 ? String(format: "%.1f d", d) : String(format: "%.1f y", d / 365.25)
    }

    /// A moon's orbital distance. These span two orders of magnitude within one system
    /// (SOL-3-1 = 384 400 km, an outer Jovian ≈ 13 000 000), so the large ones go to
    /// millions rather than printing eight digits.
    static func km(_ km: Double) -> String {
        km >= 1_000_000
            ? String(format: "%.2f M km", km / 1_000_000)
            : String(format: "%.0f km", km)
    }
}
