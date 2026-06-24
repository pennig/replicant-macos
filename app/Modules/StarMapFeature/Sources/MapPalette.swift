//
//  MapPalette.swift
//  StarMapFeature
//
//  Bridges the UI design-system color tokens to SceneKit material colors. The
//  map is dark-only, so every token is resolved against the dark appearance
//  (the asset catalog carries both). Per the project rules, scene colors come
//  from the tokens — never hard-coded hex — except domain star colors derived
//  by spectral class, which are real stellar color, not UI chrome.
//

import AppKit
import SwiftUI
import UI

@MainActor
enum MapPalette {
    /// Resolve a (possibly dynamic) design token to a concrete dark-appearance NSColor.
    static func ns(_ color: Color) -> NSColor {
        var out = NSColor(color)
        if let dark = NSAppearance(named: .darkAqua) {
            dark.performAsCurrentDrawingAppearance {
                out = NSColor(color).usingColorSpace(.sRGB) ?? out
            }
        }
        return out
    }

    // Map semantics → tokens (see SceneKit Handoff Spec §2 swatch table).
    static var accent: NSColor      { ns(.rcAccent) }        // presence · home · relays (amber)
    static var life: NSColor        { ns(.rcStatusReady) }   // biosignatures (green)
    static var resource: NSColor    { ns(.rcStatusWaiting) } // mineable richness (gold)
    static var npc: NSColor         { ns(.rcNPC) }           // foreign replicants (violet)
    static var transit: NSColor     { ns(.rcStatusTransit) } // vessels / courses (blue)
    static var sensing: NSColor     { ns(.rcStatusSensing) } // scan fields (teal)
    static var relayPurple: NSColor { ns(.rcStatusRelay) }   // alt relay tone (violet)
    static var textPrimary: NSColor { ns(.rcTextPrimary) }
    static var textTertiary: NSColor { ns(.rcTextTertiary) }

    /// A star's body color from its spectral type.
    static func starColor(spectralType: String) -> NSColor {
        let hex = switch spectralType.first {
        case "O": "#9bb0ff"
        case "B": "#aabfff"
        case "A": "#cad7ff"
        case "F": "#f8f7ff"
        case "G": "#fff4ea"
        case "K": "#ffd2a1"
        case "M": "#ffb56c"
        default:  "#ffe6b0"
        }
        return NSColor(hex: hex) ?? ns(.rcTextPrimary)
    }
}

extension NSColor {
    /// Parse "#RRGGBB" / "#RRGGBBAA". Returns nil on malformed input.
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        switch s.count {
        case 6:
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        case 8:
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        default:
            return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
